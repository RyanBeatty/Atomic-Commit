{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-} -- Allows automatic derivation of e.g. Monad
{-# LANGUAGE DeriveGeneric              #-} -- Allows Generic, for auto-generation of serialization code
module Main where

import Lib

import Control.Concurrent (threadDelay)
import Control.Monad (forever, mapM_, replicateM, sequence)
import Control.Monad.RWS.Lazy (
  RWST, MonadReader, MonadWriter, MonadState, MonadTrans,
  ask, tell, get, runRWST, lift, listen)
import Control.Distributed.Process (
  Process, ProcessId, send, say, expect, receiveWait,
  getSelfPid, spawnLocal, liftIO, die, link, match)
import Control.Distributed.Process.Node (initRemoteTable, runProcess, newLocalNode)
import Data.Binary (Binary)
import qualified Data.Text as T (pack, strip, append)
import qualified Data.Text.IO as TIO (getLine, putStr, putStrLn)
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import Network.Transport.TCP (createTransport, defaultTCPParameters)
import System.IO (hSetBuffering, stdout, BufferMode(..))

-- Static config of the server.
data ServerConfig = ServerConfig
  { myId  :: ProcessId      -- The proccess id of this server.
  , peers :: [ProcessId]    -- List of pids of peer processes that this process can communicate
                            -- with. Should not include pid of this process.
  , controller :: ProcessId -- The pid of the controller process.
  }
  deriving (Show)

-- Mutable state of a server.
data ServerState = ServerState
  deriving (Show)

-- Messages that servers will send and receive.
data Message =
    Tick           -- A Tick message will be sent by the ticker process to its parent process for
                   -- timeouts.
  | InitiateCommit -- Tell a server that it should become the controller of a commit and start the
                   -- commit process.
  deriving (Show, Generic, Typeable)
instance Binary Message

-- A Letter contains the process id of the sender and recipient as well as a message payload.
data Letter = Letter
  { senderOf    :: ProcessId -- Pid of the process that sent this letter.
  , recipientOf :: ProcessId -- Pid of the process that should receive this letter.
  , message     :: Message   -- Message payload.
  }
  deriving (Show, Generic, Typeable)
instance Binary Letter

newtype ServerAction m a = ServerAction { runAction :: RWST ServerConfig [Letter] ServerState m a }
  deriving (
    Functor, Applicative, Monad, MonadReader ServerConfig,
    MonadWriter [Letter], MonadState ServerState, MonadTrans)

type ProcessAction a = ServerAction Process a

newServerState :: ServerState
newServerState = ServerState

-- Event-loop of the Controller process. Will poll stdinput for commands
-- issued by the user until told to quit.
runController :: Process ()
runController = forever $ do
  liftIO $ TIO.putStr "Enter Command: "
  cmd <- liftIO $ TIO.getLine >>= return . T.strip
  case cmd of
    -- Terminate the controller immeadiately. This should also kill any linked processes.
    "quit"  -> die ("Quiting Controller..." :: String)
    "spawn" -> spawnServers 1
    -- User entered in an invalid command.
    _       -> liftIO $ TIO.putStrLn $ "Invalid Command: " `T.append` cmd

spawnServers :: Int -> Process ()
spawnServers num_servers = do
  my_pid <- getSelfPid
  -- Spawn |num_servers| number of servers and get all of the pids of the servers.
  pids <- replicateM num_servers (spawnServer my_pid)
  -- Link all of the spawned servers to this process so that they will all exit when
  -- the controller exits.
  mapM_ link pids
  -- Send the list of peers to every process that was spawned.
  mapM_ (`send` pids) pids

-- Spawn server processes. They will get the list of their peers and then start serving.
spawnServer :: ProcessId -> Process (ProcessId)
spawnServer controller = do
  spawnLocal $ do
    my_pid <- getSelfPid
    say $ "Spawned process: " ++ (show my_pid)
    -- Get list of peers without my_pid before starting to serve.
    peers <- filter (/= my_pid) <$> expect :: Process [ProcessId]
    -- Create ticker and link the ticker process to this process so
    -- that is will shutdown when this process terminates.
    ticker_pid <- spawnTicker my_pid
    link ticker_pid
    runRWST (runAction runServer) (ServerConfig my_pid peers controller) newServerState
    return ()

-- Create a ticker process that will periodically send ticks to
-- the parent server.
spawnTicker :: ProcessId -> Process ProcessId
spawnTicker parent_pid = spawnLocal $ forever $ do
  my_pid <- getSelfPid
  send parent_pid (Letter my_pid parent_pid Tick)
  liftIO $ threadDelay (10^6)

-- Run the event loop of the Server. Do a blocking wait for incoming letters,
-- run the apprioprate action for the letter, and then send all outgoing letters.
runServer :: ProcessAction ()
runServer = do
  -- Block and wait for a new Letter to arrive and then run the action
  -- Returned by the letter handler.
  action <- lift $ receiveWait [match (letterHandler)]
  -- Run the server action and get the list of output letters we should send.
  ((), outgoing_letters) <- listen action
  -- Send all of the letters to their destinations.
  lift $ mapM_ (\letter -> send (recipientOf letter) letter) outgoing_letters
  runServer

-- Will match on the message field in the received Letter and return a handler function
-- should be run in the ProcessAction monad.
letterHandler :: Letter -> Process (ProcessAction ())
letterHandler letter =
  case message letter of
    Tick    -> return $ handleTick 

handleTick :: ProcessAction ()
handleTick = lift $ say "Got Tick"

main :: IO ()
main = do
  hSetBuffering stdout NoBuffering
  Right t <- createTransport "127.0.0.1" "8080" defaultTCPParameters
  node <- newLocalNode t initRemoteTable
  runProcess node runController

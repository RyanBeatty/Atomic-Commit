{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-} -- Allows automatic derivation of e.g. Monad
{-# LANGUAGE DeriveGeneric              #-} -- Allows Generic, for auto-generation of serialization code
module Main where

import Lib

import Control.Concurrent (threadDelay)
import Control.Distributed.Process (
  Process, ProcessId, send, say, expect, receiveWait,
  getSelfPid, spawnLocal, liftIO, die, link, match)
import Control.Distributed.Process.Node (initRemoteTable, runProcess, newLocalNode)
import Control.Monad (forever, mapM_, replicateM, sequence)
import Control.Monad.RWS.Lazy (
  RWST, MonadReader, MonadWriter, MonadState, MonadTrans,
  ask, tell, get, runRWST, lift, listen)
import Data.Binary (Binary)
import qualified Data.Text as T (pack, strip, append)
import qualified Data.Text.IO as TIO (getLine, putStr, putStrLn)
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import Network.Transport.TCP (createTransport, defaultTCPParameters)
import System.IO (hSetBuffering, stdout, BufferMode(..))

-- Mutable state of the controller process.
data ControllerState = ControllerState
  { servers :: [ProcessId] -- List of all of the process ids of the servers it has spawned.
  }
  deriving (Show)

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
  | VoteRequest    -- Vote requests are sent by the commit controller to participants. Participants
                   -- should return a vote to the controller.
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

-- A ServerAction has a ServerConfig as static data, writes Letters to be sent, and has ServerState
-- as mutable state.
newtype ServerAction m a = ServerAction { runAction :: RWST ServerConfig [Letter] ServerState m a }
  deriving (
    Functor, Applicative, Monad, MonadReader ServerConfig,
    MonadWriter [Letter], MonadState ServerState, MonadTrans)

type ServerProcess a = ServerAction Process a

newControllerState :: ControllerState
newControllerState = ControllerState mempty

newServerState :: ServerState
newServerState = ServerState

-- Command-loop of the Controller process. Will poll stdinput for commands
-- issued by the user until told to quit.
runController :: ControllerState -> Process ()
runController state = do
  liftIO $ TIO.putStr "Enter Command: "
  cmd <- liftIO $ TIO.getLine >>= return . T.strip
  new_state <- case cmd of
    -- Terminate the controller immeadiately. This should also kill any linked processes.
    "quit"  -> die ("Quiting Controller..." :: String) >> return state
    -- Spawn and setup all of the servers. Save pids of all of the servers that were created.
    "spawn" -> spawnServers 1 >>= return . ControllerState
    -- User entered in an invalid command.
    _       -> (liftIO $ TIO.putStrLn $ "Invalid Command: " `T.append` cmd) >> return state
  runController new_state

spawnServers :: Int -> Process [ProcessId]
spawnServers num_servers = do
  my_pid <- getSelfPid
  -- Spawn |num_servers| number of servers and get all of the pids of the servers.
  pids <- replicateM num_servers (spawnServer my_pid)
  -- Link all of the spawned servers to this process so that they will all exit when
  -- the controller exits.
  mapM_ link pids
  -- Send the list of peers to every process that was spawned.
  mapM_ (`send` pids) pids
  return pids

-- Spawn server processes. They will get the list of their peers and then start serving.
-- Servers should know the pid of the controller process, so that they can respond to
-- requests from the controller.
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
runServer :: ServerProcess ()
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
-- should be run in the ServerProcess monad.
letterHandler :: Letter -> Process (ServerProcess ())
letterHandler letter =
  case message letter of
    Tick           -> return handleTick
    InitiateCommit -> return handleInitiateCommit
    VoteRequest    -> return . handleVoteRequest . senderOf $ letter

handleTick :: ServerProcess ()
handleTick = lift $ say "Got Tick"

-- Assume the role of commit coordinator and start the commit. Send a VoteRequest message to all
-- participants of the commit.
handleInitiateCommit :: ServerProcess ()
handleInitiateCommit = do
  config <- ask
  tell $ map (\pid -> Letter (myId config) pid VoteRequest) (peers config)

handleVoteRequest :: ProcessId -> ServerProcess ()
handleVoteRequest coordinator = undefined
 
main :: IO ()
main = do
  hSetBuffering stdout NoBuffering
  Right t <- createTransport "127.0.0.1" "8080" defaultTCPParameters
  node <- newLocalNode t initRemoteTable
  runProcess node (runController newControllerState)

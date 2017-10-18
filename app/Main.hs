{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-} -- Allows automatic derivation of e.g. Monad
{-# LANGUAGE DeriveGeneric              #-} -- Allows Generic, for auto-generation of serialization code
module Main where

import Lib

import Control.Concurrent (threadDelay)
import Control.Monad (forever, mapM_, replicateM, sequence)
import Control.Monad.RWS.Lazy (
  RWST, MonadReader, MonadWriter, MonadState,
  ask, tell, get, execRWS)
import Control.Distributed.Process (
  Process, ProcessId, send, say, expect,
  getSelfPid, spawnLocal, liftIO, die, link)
import Control.Distributed.Process.Node (initRemoteTable, runProcess, newLocalNode)
import Data.Binary (Binary)
import qualified Data.Text as T (pack, strip, append)
import qualified Data.Text.IO as TIO (getLine, putStr, putStrLn)
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import Network.Transport.TCP (createTransport, defaultTCPParameters)
import System.IO (hSetBuffering, stdout, BufferMode(..))

-- A Tick message will be sent by the ticker process to its parent process for timeouts.
data Tick = Tick
  deriving (Show, Generic, Typeable)
instance Binary Tick

-- Static config of the server.
data ServerConfig = ServerConfig
  { myId  :: ProcessId   -- The proccess id of this server.
  , peers :: [ProcessId] -- List of pids of peer processes that this process can communicate with.
                         -- Should not include pid of this process.
  }
  deriving (Show)

-- Mutable state of a server.
data ServerState = ServerState
  { -- List of pids of peer processes that this process can communicate with.
    -- Should not include pid of this process.
    foo :: [ProcessId]
  }
  deriving (Show)

-- Messages that servers will send and receive.
data Message = Message
  deriving (Show)

newtype ServerAction m a = ServerAction { runAction :: RWST ServerConfig [Message] ServerState m a }
  deriving (
    Functor, Applicative, Monad, MonadReader ServerConfig,
    MonadWriter [Message], MonadState ServerState)

type ProcessAction a = ServerAction Process a

-- Event-loop of the Controller process. Will poll stdinput for commands
-- issued by the user until told to quit.
runController :: Process ()
runController = forever $ do
  liftIO $ TIO.putStr "Enter Command: "
  cmd <- liftIO $ TIO.getLine >>= return . T.strip
  case cmd of
    -- Terminate the controller immeadiately. This should also kill any linked processes.
    "quit"  -> die ("Quiting Controller..." :: String)
    "spawn master" -> spawnServers 3
    -- User entered in an invalid command.
    _       -> liftIO $ TIO.putStrLn $ "Invalid Command: " `T.append` cmd

spawnServers :: Int -> Process ()
spawnServers num_servers = do
  -- Spawn |num_servers| number of servers and get all of the pids of the servers.
  pids <- replicateM num_servers spawnServer
  -- Link all of the spawned servers to this process so that they will all exit when
  -- the controller exits.
  mapM_ link pids
  -- Send the list of peers to every process that was spawned.
  mapM_ (`send` pids) pids

-- Spawn server processes. They will get the list of their peers and then start serving.
spawnServer :: Process (ProcessId)
spawnServer = do
  spawnLocal $ do
    my_pid <- getSelfPid
    say $ "Spawned process: " ++ (show my_pid)
    -- Get list of peers before starting to serve.
    peers <- expect :: Process [ProcessId]
    -- Create ticker and link the ticker process to this process so
    -- that is will shutdown when this process terminates.
    ticker_pid <- spawnTicker my_pid
    link ticker_pid

-- Create a ticker process that will periodically send ticks to
-- the parent server.
spawnTicker :: ProcessId -> Process ProcessId
spawnTicker parent_pid = spawnLocal $ forever $ do
  send parent_pid Tick
  liftIO $ threadDelay (10^6)

runServer :: ProcessAction ()
runServer = undefined

main :: IO ()
main = do
  hSetBuffering stdout NoBuffering
  Right t <- createTransport "127.0.0.1" "8080" defaultTCPParameters
  node <- newLocalNode t initRemoteTable
  runProcess node runController

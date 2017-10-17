{-# LANGUAGE OverloadedStrings #-}
module Main where

import Lib

import Control.Concurrent (threadDelay)
import Control.Monad (forever, mapM_, replicateM, sequence)
import Control.Distributed.Process
import Control.Distributed.Process.Node
import qualified Data.Text as T (pack, strip, append)
import qualified Data.Text.IO as TIO (getLine, putStr, putStrLn)
import Network.Transport.TCP (createTransport, defaultTCPParameters)
import System.IO (hSetBuffering, stdout, BufferMode(..))

-- Spawn a server that will endlesslessy tell the logging process to print its process id.
spawnServer :: Process (ProcessId)
spawnServer = do
  spawnLocal $ forever $ do
    my_pid <- getSelfPid
    say $ "pid: " ++ (show my_pid)
    liftIO $ threadDelay (10^6)

spawnServers :: Int -> Process ()
spawnServers num_servers = do
  -- Spawn |num_servers| number of servers and get all of the pids of the servers.
  pids <- replicateM num_servers spawnServer
  -- Link all of the spawned servers to this process so that they will all exit when
  -- the controller exits.
  mapM_ link pids

runController :: Process ()
runController = forever $ do
  liftIO $ TIO.putStr "Enter Command: "
  cmd <- liftIO $ TIO.getLine >>= return . T.strip
  case cmd of
    "q" -> die ("Quiting Controller..." :: String)
    _   -> liftIO $ TIO.putStrLn $ "Invalid Command: " `T.append` cmd

main :: IO ()
main = do
  hSetBuffering stdout NoBuffering
  Right t <- createTransport "127.0.0.1" "8080" defaultTCPParameters
  node <- newLocalNode t initRemoteTable
  runProcess node runController

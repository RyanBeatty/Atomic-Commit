{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-} -- Allows automatic derivation of e.g. Monad
{-# LANGUAGE DeriveGeneric              #-} -- Allows Generic, for auto-generation of serialization code
{-# LANGUAGE TemplateHaskell #-}
module Main where

import Lib (trim)

import Control.Concurrent (threadDelay)
import Control.Distributed.Process (
  Process, ProcessId, send, say, expect, receiveWait,
  getSelfPid, spawnLocal, liftIO, die, link, match)
import Control.Distributed.Process.Node (initRemoteTable, runProcess, newLocalNode)
import Control.Lens (makeLenses, set, over, view)
import Control.Monad (forever, mapM_, replicateM, sequence)
import Control.Monad.RWS.Lazy (
  RWST, MonadReader, MonadWriter, MonadState, MonadTrans,
  ask, tell, get, runRWST, lift, listen, modify, gets, asks)
import Data.Binary (Binary)
import qualified Data.Map.Strict as Map (Map, fromList, map)
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

-- A vote is either to commit the transaction or to abort it.
data Vote = Commit | Abort
  deriving (Show, Eq, Generic, Typeable)
instance Binary Vote

-- Mutable state of a server.
data ServerState = ServerState
  { _timeoutMap :: Map.Map ProcessId Integer -- Keeps track of timeout values for responses we are
                                             -- expecting from other processes. Everytime a tick happens
                                             -- the timeout count should be decremented for each
                                             -- expected response.
  , _votes :: [(ProcessId, Vote)] -- List of which process voted which way.
  , _myNextVote :: Vote -- Vote for this processes' next vote request.
  }
  deriving (Show)
makeLenses ''ServerState

-- Messages that servers will send and receive.
data Message =
    Tick               -- A Tick message will be sent by the ticker process to its parent process for
                       -- timeouts.
  | InitiateCommit     -- Tell a server that it should become the controller of a commit and start the
                       -- commit process.
  | VoteRequest        -- Vote requests are sent by the commit controller to participants. Participants
                       -- should return a vote to the controller.
  | VoteResponse       -- Vote responses contain a process vote on whether to commit the current transaction.
      { vote :: Vote }
  | CommitMessage
  | AbortMessage
  deriving (Show, Generic, Typeable)
instance Binary Message

-- A log message to be written to the distributed transaction log.
data DTLogMessage =
    StartCommit
  | CommitRecord
  | AbortRecord
  deriving (Show)

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
newServerState = ServerState mempty mempty Commit

-- Number of Tick messages that can pass before an expected response is marked as timing out.
timeout :: Integer
timeout = 10

-- Command-loop of the Controller process. Will poll stdinput for commands
-- issued by the user until told to quit.
runController :: ControllerState -> Process ()
runController state = do
  liftIO $ putStr "Enter Command: "
  cmd <- liftIO $ getLine >>= return . trim
  new_state <- case cmd of
    -- Terminate the controller immeadiately. This should also kill any linked processes.
    "quit"  -> die ("Quiting Controller..." :: String) >> return state
    -- Spawn and setup all of the servers. Save pids of all of the servers that were created.
    "spawn" -> spawnServers 2 >>= return . ControllerState
    ('c':'o':'m':'m':'i':'t':index) -> getSelfPid >>= \pid ->
                                       let commiter = servers state !! (read index :: Int)
                                       in send commiter (Letter pid commiter InitiateCommit) >>
                                       return state
    -- User entered in an invalid command.
    _       -> (liftIO . putStrLn $ "Invalid Command: " ++ cmd) >> return state
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
    Tick                        -> return handleTick
    InitiateCommit              -> return handleInitiateCommit
    VoteRequest                 -> return . handleVoteRequest . senderOf $ letter
    VoteResponse { vote=vote }  -> return $ handleVoteResponse (senderOf letter) vote

handleTick :: ServerProcess ()
handleTick = do
  modify (over timeoutMap (Map.map pred))
  -- TODO: Implement timeout logic

-- Assume the role of commit coordinator and start the commit. Send a VoteRequest message to all
-- participants of the commit.
handleInitiateCommit :: ServerProcess ()
handleInitiateCommit = do
  -- Output vote reuqest messages to send to all peers.
  config <- ask
  tell $ map (\pid -> Letter (myId config) pid VoteRequest) (peers config)
  -- Create timeout for every peer we sent a vote request to.
  let ps = zip (peers config) (repeat timeout)
  modify $ set timeoutMap (Map.fromList ps)
  -- Write the start commit record to the transaction log.
  writeDTLogMessage StartCommit

handleVoteRequest :: ProcessId -> ServerProcess ()
handleVoteRequest coordinator = lift $ say "Got vote request"

handleVoteResponse :: ProcessId -> Vote -> ServerProcess ()
handleVoteResponse voter vote = do
  -- Add this voter + vote to list of votes.
  modify $ over votes (++ [(voter, vote)])
  -- Check if all voters have voted.
  voted <- gets (view votes)
  config <- ask
  if map fst voted == peers config
    then do
      my_vote <- gets (view myNextVote)
      if all (== Commit) (map snd voted) && my_vote == Commit
        then do
          -- send commit message to all processes.
          writeDTLogMessage CommitRecord
          tell $ map (\pid -> Letter (myId config) pid CommitMessage) (peers config)
        else do
          -- Send abort message to all processes that voted commit.
          writeDTLogMessage AbortRecord
          let (voted_commit, _) = unzip $ filter ((==) Commit . snd) voted
          tell $ map (\pid -> Letter (myId config) pid AbortMessage) voted_commit
    else return ()

writeDTLogMessage :: DTLogMessage -> ServerProcess ()
writeDTLogMessage message = lift . liftIO $ undefined
 
main :: IO ()
main = do
  hSetBuffering stdout NoBuffering
  Right t <- createTransport "127.0.0.1" "8080" defaultTCPParameters
  node <- newLocalNode t initRemoteTable
  runProcess node (runController newControllerState)

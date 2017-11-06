module DTLog 
    ( writeStartCommit
    , writeYesRecord
    , writeCommitRecord
    , writeAbortRecord
    ) where

import System.IO (FilePath, appendFile)

-- A log message to be written to the distributed transaction log.
data DTLogMessage =
    StartCommit
  | YesRecord
  | CommitRecord
  | AbortRecord
  deriving (Show)

writeDTLogMessage :: FilePath -> DTLogMessage -> IO ()
writeDTLogMessage filepath message = appendFile filepath (show message)

writeYesRecord :: IO ()
writeYesRecord = writeDTLogMessage undefined YesRecord

writeStartCommit :: IO ()
writeStartCommit = writeDTLogMessage undefined StartCommit

writeCommitRecord :: IO ()
writeCommitRecord = writeDTLogMessage undefined CommitRecord

writeAbortRecord :: IO ()
writeAbortRecord = writeDTLogMessage undefined AbortRecord
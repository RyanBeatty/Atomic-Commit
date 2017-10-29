module DTLog 
    ( writeStartCommit
    , writeYesRecord
    , writeCommitRecord
    , writeAbortRecord
    ) where

-- A log message to be written to the distributed transaction log.
data DTLogMessage =
    StartCommit
  | YesRecord
  | CommitRecord
  | AbortRecord
  deriving (Show)

writeDTLogMessage :: DTLogMessage -> IO ()
writeDTLogMessage message = undefined

writeYesRecord :: IO ()
writeYesRecord = writeDTLogMessage YesRecord

writeStartCommit :: IO ()
writeStartCommit = writeDTLogMessage StartCommit

writeCommitRecord :: IO ()
writeCommitRecord = writeDTLogMessage CommitRecord

writeAbortRecord :: IO ()
writeAbortRecord = writeDTLogMessage AbortRecord
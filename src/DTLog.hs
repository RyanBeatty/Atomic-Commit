module DTLog 
    ( writeStartCommit
    , writeCommitRecord
    , writeAbortRecord
    ) where

-- A log message to be written to the distributed transaction log.
data DTLogMessage =
    StartCommit
  | CommitRecord
  | AbortRecord
  deriving (Show)

writeDTLogMessage :: DTLogMessage -> IO ()
writeDTLogMessage message = undefined

writeStartCommit :: IO ()
writeStartCommit = writeDTLogMessage StartCommit

writeCommitRecord :: IO ()
writeCommitRecord = writeDTLogMessage CommitRecord

writeAbortRecord :: IO ()
writeAbortRecord = writeDTLogMessage AbortRecord
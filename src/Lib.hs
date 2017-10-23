module Lib
    ( trim
    ) where

import Data.Char (isSpace)
import Data.List (dropWhile, dropWhileEnd)

-- Utility function used to strip whitespace/newlines from the user input given to the controller
-- process. Copied from StackOverflow.
trim :: String -> String
trim = dropWhileEnd isSpace . dropWhile isSpace

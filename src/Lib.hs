module Lib
    ( trim
    , choose
    , stripAndTrim
    ) where

import Data.Char (isSpace)
import Data.List (dropWhile, dropWhileEnd, stripPrefix)

-- Utility function used to strip whitespace/newlines from the user input given to the controller
-- process. Copied from StackOverflow.
trim :: String -> String
trim = dropWhileEnd isSpace . dropWhile isSpace

stripAndTrim :: String -> String -> Maybe String
stripAndTrim prefix str = trim <$> stripPrefix prefix str

-- Utility function to get the value at an index in a list when the index is in string form.
-- NOTE: index should be a valid Int in String form and be within the index bounds of list.
choose :: [a] -> String -> a
choose list index = list !! (read index :: Int)

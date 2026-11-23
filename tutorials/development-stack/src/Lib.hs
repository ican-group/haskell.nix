module Lib (greeting) where

import Data.List.Split (splitOn)
import Data.Text (Text, pack)

greeting :: Text
greeting = pack (unwords (splitOn "," "hello,from,stack"))

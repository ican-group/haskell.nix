module PkgA (greeting) where

import qualified Data.Text as T

greeting :: T.Text
greeting = T.pack "hello"

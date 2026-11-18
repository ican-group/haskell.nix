module Lib
    ( someFunc
    ) where

-- `containers` is a dependency only through ../common-dependencies.yaml
import qualified Data.Map as Map

someFunc :: IO ()
someFunc = print (Map.fromList [(1 :: Int, "one")])

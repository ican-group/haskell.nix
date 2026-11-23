module Main (main) where
import qualified Data.Text.IO as T
import Lib (greeting)
main :: IO ()
main = T.putStrLn greeting

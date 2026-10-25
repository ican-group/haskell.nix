module Main (main) where

import Constants
import Control.Monad (unless)
import System.Exit (exitFailure)

main :: IO ()
main = do
  let checks =
        [ ("size int32_t", toInteger int32Size, 4)
        , ("const -1", toInteger minusOne, -1)
        , ("const 0", toInteger zero, 0)
        , ("const UINT64_MAX", maxWord64, 18446744073709551615)
        , ("const HSC2HS_PATCHED_LAST", toInteger lastOne, 42)
        ]
      bad = [ (n, got, want) | (n, got, want) <- checks, got /= want ]
  mapM_ (\(n, got, want) ->
    putStrLn (n ++ ": got " ++ show got ++ ", expected " ++ show want)) bad
  unless (null bad) exitFailure
  putStrLn "hsc2hs constants ok"

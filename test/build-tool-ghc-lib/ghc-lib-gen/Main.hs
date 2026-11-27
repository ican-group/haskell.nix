-- A GHC source preprocessor (`ghc -F -pgmF ghc-lib-gen`) that replaces
-- @GHC_LIB_VERSION@ with the version of the `ghc` library it was built
-- against, so the tool has a real dependency on that library.
module Main (main) where

import Data.List (isPrefixOf)
import GHC.Settings.Config (cProjectVersion)
import System.Environment (getArgs)

main :: IO ()
main = do
  args <- getArgs
  case args of
    [_orig, input, output] -> readFile input >>= writeFile output . expand
    _ -> fail ("usage: ghc-lib-gen ORIG INPUT OUTPUT, got " ++ show args)

expand :: String -> String
expand s | "@GHC_LIB_VERSION@" `isPrefixOf` s =
             show cProjectVersion ++ expand (drop (length "@GHC_LIB_VERSION@") s)
expand (c:cs) = c : expand cs
expand [] = []

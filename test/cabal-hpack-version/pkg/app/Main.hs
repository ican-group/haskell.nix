{-# LANGUAGE CPP #-}
module Main (main) where

import HpackChoice.Inner (msg)
import System.Random.SplitMix (mkSMGen, nextWord64)

-- `CHOSEN_HPACK` and the `splitmix` dependency are not in package.yaml:
-- the test's hpack adds them to the `.cabal` file it generates.
#ifndef CHOSEN_HPACK
#error "built from a .cabal file the project's hpack did not generate"
#endif

-- `FROM_INCLUDE` comes from ../common.yaml, which package.yaml includes.
#ifndef FROM_INCLUDE
#error "hpack did not see the YAML file package.yaml includes"
#endif

main :: IO ()
main = do
  putStrLn msg
  print (fst (nextWord64 (mkSMGen 42)))

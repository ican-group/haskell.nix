{-# LANGUAGE CPP #-}
module Main (main) where

import Data.Default.Class (def)

-- `TEST_GHC_OPTION` is only defined through `projectPackages` (see default.nix),
-- so without it there is no `main` and the build fails.
#ifdef TEST_GHC_OPTION
main :: IO ()
main = print (def :: ())
#endif

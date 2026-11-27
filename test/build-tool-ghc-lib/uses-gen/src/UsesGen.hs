{-# OPTIONS_GHC -F -pgmF ghc-lib-gen #-}
module UsesGen (ghcLibVersion) where

ghcLibVersion :: String
ghcLibVersion = @GHC_LIB_VERSION@

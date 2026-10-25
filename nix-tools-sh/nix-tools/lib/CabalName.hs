module CabalName
  ( doCabalName
  ) where

import Stack2nix.Project (findCabalFiles)
import Cabal2Nix (cabalFilePkgName)

import CabalName.CLI (Args(..))

doCabalName :: Args -> IO ()
doCabalName args =
  findCabalFiles (argHpackUse args) (argPackageDir args)
    >>= mapM_ (putStr . cabalFilePkgName) . take 1

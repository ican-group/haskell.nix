{-# OPTIONS_GHC -F -pgmF pctool #-}
module Consumer (zlibVersionAtBuild) where

-- Filled in by the build-machine `pctool` preprocessor.
zlibVersionAtBuild :: String
zlibVersionAtBuild = @ZLIB@

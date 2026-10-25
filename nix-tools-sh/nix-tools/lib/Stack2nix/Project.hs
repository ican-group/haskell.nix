{-# LANGUAGE LambdaCase #-}

module Stack2nix.Project
  ( findCabalFiles
  ) where

import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Data.ByteString (ByteString)

import System.FilePath ((</>))
import System.Directory (listDirectory, doesFileExist)
import Data.List (isSuffixOf)

import qualified Hpack.Config as Hpack
import qualified Hpack.Render as Hpack

import Cabal2Nix (CabalFile(..), CabalFileGenerator(..))

import Stack2nix.CLI (HpackUse(..))

findCabalFiles :: HpackUse -> FilePath -> IO [CabalFile]
findCabalFiles IgnorePackageYaml path = findOnlyCabalFiles path
findCabalFiles UsePackageYamlFirst path = doesFileExist (path </> Hpack.packageConfig) >>= \case
  False -> findOnlyCabalFiles path
  True -> do
    mbPkg <- Hpack.readPackageConfig Hpack.defaultDecodeOptions {Hpack.decodeOptionsTarget = path </> Hpack.packageConfig}
    case mbPkg of
      Left e -> error e
      Right r ->
        return $ [InMemory (Just Hpack)
                           (Hpack.decodeResultCabalFile r)
                           (encodeUtf8 $ render r)]

  where
    render :: Hpack.DecodeResult -> String
    render r =
      let body = Hpack.renderPackage [] (Hpack.decodeResultPackage r)
          cabalVersion = Hpack.decodeResultCabalVersion r
      in cabalVersion ++ body

    encodeUtf8 :: String -> ByteString
    encodeUtf8 = T.encodeUtf8 . T.pack


findOnlyCabalFiles :: FilePath -> IO [CabalFile]
findOnlyCabalFiles path = fmap (OnDisk . (path </>)) . filter (isSuffixOf ".cabal") <$> listDirectory path

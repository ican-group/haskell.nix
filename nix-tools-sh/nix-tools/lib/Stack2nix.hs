{-# LANGUAGE LambdaCase, RecordWildCards, OverloadedStrings, TupleSections #-}

module Stack2nix
  ( doStack2nix
  , stackexpr
  , stack2nix
  ) where

import qualified Data.Text as T
import Data.String (fromString)

import Control.Monad.Trans.Maybe
import Control.Monad.IO.Class (liftIO)
import Control.Monad (unless, forM, forM_)
import Control.Monad.Extra (unlessM)

import qualified Data.Map as M (fromListWith, toList)
import System.FilePath ((<.>), (</>), takeDirectory, dropFileName)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist)
import System.IO (IOMode(..), openFile, hClose)
import Data.Yaml (decodeFileEither)

import Nix.Expr
import Nix.Pretty (prettyNix)
import Prettyprinter (Doc)
import Prettyprinter.Render.Text (hPutDoc)

import Distribution.Types.PackageId (PackageIdentifier(..))
import Distribution.Nixpkgs.Fetch (DerivationSource(..), Source(..), Hash(..), fetch)
import Distribution.Simple.Utils (shortRelativePath)
import Distribution.Text (simpleParse)
import Distribution.Pretty (Pretty(..))

import Cabal2Nix hiding (Git)
import qualified Cabal2Nix as C2N
import Cabal2Nix.Util

import Stack2nix.Cache (appendCache, cacheHits)
import Stack2nix.CLI (Args(..))
import Stack2nix.Project
import Stack2nix.Stack (Stack(..), Dependency(..), Location(..), PackageFlags, GhcOptions)
import Stack2nix.External.Resolve

import qualified Data.HashMap.Strict as HM


doStack2nix :: Args -> IO ()
doStack2nix args = do
  let pkgsNix = argOutputDir args </> "pkgs.nix"
      defaultNix = argOutputDir args </> "default.nix"
  pkgs <- stackexpr args
  writeDoc pkgsNix (prettyNix pkgs)
  unlessM (doesFileExist defaultNix) $ do
    writeFile defaultNix defaultNixContents

stackexpr :: Args -> IO NExpr
stackexpr args =
  do evalue <- decodeFileEither (argStackYaml args)
     case evalue of
       Left e -> error (show e)
       Right value -> stack2nix args
                      =<< resolveSnapshot (argStackYaml args) value

stack2nix :: Args -> Stack -> IO NExpr
stack2nix args (Stack resolver compiler pkgs pkgFlags ghcOpts) =
  do let extraDeps    = extraDeps2nix pkgs
         flags        = flags2nix pkgFlags
         ghcOptions   = ghcOptions2nix ghcOpts
     let _f_          = mkSym "f"
         _import_     = mkSym "import"
         _mkForce_    = mkSym "mkForce"
         _isFunction_ = mkSym "isFunction"
         _mapAttrs_   = mkSym "mapAttrs"
         _config_     = mkSym "config"
     packages <- packages2nix args pkgs
     let allPackages = extraDeps <> packages
         allPackageNames = M.fromListWith (+) ((,1 :: Int) . fst <$> allPackages)
         duplicates = filter ((>1) . snd) (M.toList allPackageNames)
     unless (null duplicates) $
        error $ concat ((\(name, _) ->
          "Duplicate definitions for package " <> show name <> "\n") <$> duplicates)
     return . mkNonRecSet $
       [ "extras" $= ("hackage" ==> mkNonRecSet
                     ([ "packages" $= mkNonRecSet (snd <$> allPackages) ]
                   ++ [ "compiler.version" $= fromString (quoted ver)
                      | (Just c) <- [compiler], let ver = filter (`elem` (".0123456789" :: [Char])) c]
                   ++ [ "compiler.nix-name" $= fromString (quoted name)
                      | (Just c) <- [compiler], let name = filter (`elem` ((['a'..'z']++['0'..'9']) :: [Char])) c]))
       , "resolver"  $= fromString (quoted resolver)
       , "modules" $= mkList [
           mkParamset [("lib", Nothing)] True ==> mkNonRecSet [ "packages" $= mkNonRecSet flags ]
         , mkNonRecSet [ "packages" $= mkNonRecSet ghcOptions ]
         -- Mark all packages as planned (stack projects do not have planned/unplanned components).
         , mkParamset [("lib", Nothing)] True ==> mkNonRecSet [ "planned" $= ("lib" @. "mkOverride" @@ mkInt 900 @@ mkBool True) ] ]
       ] ++ [
         "compiler" $= fromString (quoted c) | (Just c) <- [compiler]
       ]
-- | Transform simple package index expressions
-- The idea is to turn
--
--   - name-version[@rev:N | @sha256:SHA]
--
-- into
--
--   { name.revision = hackage.name.version.revisions.default; }
--
extraDeps2nix :: [Dependency] -> [(T.Text, Binding NExpr)]
extraDeps2nix pkgs =
  let extraDeps = [(pkgId, info) | PkgIndex pkgId info <- pkgs]
  in [ (toText pkg, quoted (toText pkg) $= ((((mkSym "hackage" @. toText pkg) @. quoted (toText ver)) @. "revisions") @. "default"))
     | (PackageIdentifier pkg ver, Nothing) <- extraDeps ]
  ++ [ (toText pkg, quoted (toText pkg) $= ((((mkSym "hackage" @. toText pkg) @. quoted (toText ver)) @. "revisions") @. quoted (T.pack sha)))
     | (PackageIdentifier pkg ver, (Just (Left sha))) <- extraDeps ]
  ++ [ (toText pkg, quoted (toText pkg) $= ((((mkSym "hackage" @. toText pkg) @. quoted (toText ver)) @. "revisions") @. toText revNo))
     | (PackageIdentifier pkg ver, (Just (Right revNo))) <- extraDeps ]
  where parsePackageIdentifier :: String -> Maybe PackageIdentifier
        parsePackageIdentifier = simpleParse
        toText :: Pretty a => a -> T.Text
        toText = fromString . show . pretty

-- | Converts 'PackageFlags' into @{ packageName = { flags = { flagA = BOOL; flagB = BOOL; }; }; }@
flags2nix :: PackageFlags -> [Binding NExpr]
flags2nix pkgFlags =
  [ quoted pkgName $= mkNonRecSet
    -- `mkOverride 900` is used here so that the default values will be replaced (they are 1000).
    -- Values without a priority are treated as 100 and will replace these ones.
    [ "flags" $= mkNonRecSet [ quoted flag $= ("lib" @. "mkOverride" @@ mkInt 900 @@ mkBool val)
                             | (flag, val) <- HM.toList flags
                             ]
    ]
  | (pkgName, flags) <- HM.toList pkgFlags
  ]

-- | Converts 'GhcOptions' into @{ packageName = { ghcOptions = "..."; }; }@
ghcOptions2nix :: GhcOptions -> [Binding NExpr]
ghcOptions2nix ghcOptions =
  [ quoted pkgName $= mkNonRecSet
    [ "ghcOptions" $= mkList [ mkStr opts ] ]
  | (pkgName, opts) <- HM.toList ghcOptions
  ]

writeDoc :: FilePath -> Doc ann -> IO ()
writeDoc file doc =
  do handle <- openFile file WriteMode
     hPutDoc handle doc
     hClose handle


-- makeRelativeToCurrentDirectory
packages2nix :: Args -> [Dependency] -> IO [(T.Text, Binding NExpr)]
packages2nix args pkgs =
     fmap concat . forM pkgs $ \case
       (LocalPath folder) ->
         do cabalFiles <- findCabalFiles (argHpackUse args) (dropFileName (argStackYaml args) </> folder)
            forM cabalFiles $ \cabalFile ->
              let pkg = cabalFilePkgName cabalFile
                  nix = pkg <.> "nix"
                  nixFile = argOutputDir args </> nix
                  src = Just . C2N.Path $ relPath </> folder
              in do createDirectoryIfMissing True (takeDirectory nixFile)
                    writeDoc nixFile =<<
                      prettyNix <$> cabal2nix True (argDetailLevel args) src cabalFile
                    return (fromString pkg, fromString pkg $= mkPath False nix)
       (DVCS (Git url rev) _ subdirs) ->
         do hits <- forM subdirs $ \subdir -> liftIO $ cacheHits (argCacheFile args) url rev subdir
            let generateBindings =
                  fetch (cabalFromPath url rev subdirs)
                    (Source url rev UnknownHash) >>= \case
                      (Just (DerivationSource{..}, genBindings)) -> genBindings derivHash
                      _ -> return []
            if any null hits
              then
                -- If any of the subdirs were missing we need to fetch the files and
                -- generate the bindings.
                generateBindings
              else do
                let allHits = concat hits
                (and <$> forM allHits (\( _, nix ) -> doesFileExist (argOutputDir args </> nix))) >>= \case
                  False ->
                    -- One or more of the generated binding files are missing
                    generateBindings
                  True ->
                    -- If the subdirs are all in the cache then the bindings should already be
                    -- generated too.
                    forM allHits $ \( pkg, nix ) ->
                      return (fromString pkg, fromString pkg $= mkPath False nix)
       _ -> return []
  where relPath = shortRelativePath (argOutputDir args) (dropFileName (argStackYaml args))
        cabalFromPath
          :: String      -- URL
          -> String      -- Revision
          -> [FilePath]  -- Subdirs
          -> FilePath    -- Local Directory
          -> MaybeT IO (String -> IO [(T.Text, Binding NExpr)])
        cabalFromPath url rev subdirs dir = do
          -- Check that all the subdirs exist if not this
          -- fail the MaybeT so that the next fetcher will be tried
          forM_ subdirs $ \subdir -> do
            let path = dir </> subdir
            d <- liftIO $ doesDirectoryExist path
            unless d $ fail ("not a directory: " ++ path)
          -- If we got this far we are confident we have downloaded
          -- with the right fetcher.  Return an action that will
          -- be used to generate the bindings.
          return $ \sha256 -> fmap concat . forM subdirs $ \subdir -> do
            let path = dir </> subdir
            cabalFiles <- liftIO $ findCabalFiles (argHpackUse args) path
            forM cabalFiles $ \cabalFile -> do
              let pkg = cabalFilePkgName cabalFile
                  nix = pkg <.> "nix"
                  nixFile = argOutputDir args </> nix
                  subdir' = if subdir == "." then Nothing
                            else Just subdir
                  src = Just $ C2N.Git url rev (Just sha256) subdir'
              createDirectoryIfMissing True (takeDirectory nixFile)
              writeDoc nixFile =<<
                prettyNix <$> cabal2nix True (argDetailLevel args) src cabalFile
              -- Only update the cache if there is not already a record
              cacheHits (argCacheFile args) url rev subdir >>= \case
                [hit] | hit == (pkg, nix) -> return ()
                _ -> appendCache (argCacheFile args) url rev subdir sha256 pkg nix
              return (fromString pkg, fromString pkg $= mkPath False nix)

defaultNixContents :: String
defaultNixContents = unlines
  [ "{ haskellNixSrc ? builtins.fetchTarball https://github.com/input-output-hk/haskell.nix/archive/master.tar.gz"
  , "}:"
  , ""
  , "let"
  , "  haskellNix = import haskellNixSrc { };"
  , "  pkgs = import haskellNix.sources.nixpkgs-2003 haskellNix.nixpkgsArgs;"
  , ""
  , "  pkgSet = pkgs.haskell-nix.mkStackPkgSet {"
  , "    stack-pkgs = import ./pkgs.nix;"
  , "    pkg-def-extras = [];"
  , "    modules = [];"
  , "  };"
  , ""
  , "in"
  , "  pkgSet.config.hsPkgs"
  ]

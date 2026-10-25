{-# LANGUAGE LambdaCase, OverloadedStrings, NamedFieldPuns, RecordWildCards, TupleSections #-}

module Plan2Nix
  ( doPlan2Nix
  , planexpr
  , plan2nix
  ) where

import           Data.Aeson
import qualified Data.Aeson.Key                as Key
import qualified Data.Aeson.KeyMap             as KeyMap
import           Data.Char                                ( isDigit )
import           Data.HashMap.Strict                      ( HashMap )
import qualified Data.HashMap.Strict           as Map
import           Data.HashSet                             ( HashSet )
import qualified Data.HashSet                  as Set
import           Data.Maybe                               ( mapMaybe
                                                          , isJust
                                                          , fromMaybe
                                                          )
import           Data.List.NonEmpty                       ( NonEmpty (..) )
import qualified Data.Text                     as Text
import           Data.Text                                ( Text )
import qualified Data.Vector                   as Vector
import           Lens.Micro
import           Lens.Micro.Aeson
import           Nix.Expr
import           Nix.Pretty                               ( prettyNix )

import Prettyprinter (Doc)
import Prettyprinter.Render.Text (hPutDoc)

import Distribution.Nixpkgs.Fetch (DerivationSource(..), Source(..), Hash(..), fetch)
import Distribution.Simple.Utils (shortRelativePath)
import Distribution.Types.Version (Version)
import Distribution.Parsec (simpleParsec)

import Control.Monad.Trans.Maybe
import Control.Monad.IO.Class (liftIO)
import Control.Monad (unless, forM)
import Control.Monad.Extra (unlessM)

import Cabal2Nix hiding (Git)
import qualified Cabal2Nix as C2N
import Cabal2Nix.Util


import Plan2Nix.CLI (Args(..))
import Plan2Nix.Plan (Plan(..), PkgSrc(..), Package(..), Location(..))

import Plan2Nix.Cache (appendCache, cacheHits)
import Plan2Nix.Project

import System.FilePath ((<.>), (</>), takeDirectory, dropFileName)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, getCurrentDirectory)
import System.IO (IOMode(..), openFile, hClose)
import Data.String (fromString)


doPlan2Nix :: Args -> IO ()
doPlan2Nix args = do
  let pkgsNix = argOutputDir args </> "pkgs.nix"
      defaultNix = argOutputDir args </> "default.nix"
  pkgs <- planexpr args
  writeDoc pkgsNix (prettyNix pkgs)
  unlessM (doesFileExist defaultNix) $ do
    writeFile defaultNix defaultNixContents

planexpr :: Args -> IO NExpr
planexpr args =
  do evalue <- eitherDecodeFileStrict (argPlanJSON args)
     case evalue of
       Left  e     -> error (show e)
       Right value -> plan2nix args $ value2plan value

writeDoc :: FilePath -> Doc ann -> IO ()
writeDoc file doc =
  do handle <- openFile file WriteMode
     hPutDoc handle doc
     hClose handle

-- PackageKey is used when selecting which version is the most recent
-- when to deduplicate the plan.
-- By including PackageType as well as version we can select the
-- NonPreExisting version of the package if the versions match.
data PackageType = PreExisting | NotPreExisting deriving (Eq, Ord)
data PackageKey = PackageKey Version PackageType deriving (Eq, Ord)

plan2nix :: Args -> Plan -> IO NExpr
plan2nix args Plan { packages, extras, components, compilerVersion, compilerPackages } = do
  -- TODO: this is an aweful hack and expects plan-to-nix to be
  -- called from the toplevel project directory.
  cwd <- getCurrentDirectory
  extrasNix <- fmap (mkNonRecSet  . concat) . forM (Map.toList extras) $ \case
    (_name, Just (Package v flags (Just (LocalPath folder)) False _)) ->
      do cabalFiles <- findCabalFiles (argHpackUse args) folder
         forM cabalFiles $ \cabalFile ->
           let pkg = cabalFilePkgName cabalFile
               nix = ".plan.nix" </> pkg <.> "nix"
               nixFile = argOutputDir args </> nix
               src = Just . C2N.Path $ relPath </> ".." </> shortRelativePath cwd folder
           in do createDirectoryIfMissing True (takeDirectory nixFile)
                 writeDoc nixFile . prettyNix =<< cabal2nix True (argDetailLevel args) src cabalFile
                 return $ fromString pkg $= mkPath False nix
    (_name, Just (Package v flags (Just (DVCS (Git url rev) subdirs)) False _)) ->
      fmap concat . forM subdirs $ \subdir ->
      do cacheHits <- liftIO $ cacheHits (argCacheFile args) url rev subdir
         case cacheHits of
           [] -> do
             fetch (\dir -> cabalFromPath url rev subdir $ dir </> subdir)
               (Source url rev UnknownHash) >>= \case
               (Just (DerivationSource{..}, genBindings)) -> genBindings derivHash
               _ -> return []
           hits ->
             forM hits $ \( pkg, nix ) -> do
               return $ fromString pkg $= mkPath False nix
    _ -> return []
  let flags = concatMap (\case
          (name, Just (Package _v f _hasDescriptionOverride _ _)) -> flags2nix name f
          _ -> []) $ Map.toList extras
      -- Set the `planned` option for all components in the plan.
      planned = map (\name -> name <> ".planned" $=
        ("lib" @. "mkOverride" @@ mkInt 900 @@ mkBool True)) $ Set.toList components
      preExisting = concatMap (\case
          (name, Just (Package _ _ _ _ True)) -> [mkStr name]
          _ -> []) $ Map.toList packages

  return $ mkNonRecSet [
    "pkgs" $= ("hackage" ==> mkNonRecSet
      [ "packages" $= mkNonRecSet (uncurry bind =<< Map.toList packages)
      , "compiler" $= mkNonRecSet
        [ "version" $= mkStr compilerVersion
        , "nix-name" $= mkStr ("ghc" <> Text.filter (/= '.') compilerVersion)
        , "packages" $= mkNonRecSet (fmap (uncurry bind') $ Map.toList $ mapKeys quoted compilerPackages)
        ]
      ])
    , "extras" $= ("hackage" ==> mkNonRecSet [ "packages" $= extrasNix ])
    , "modules" $= mkList [
        mkNonRecSet [
          "preExistingPkgs" $= mkList preExisting
        ]
      , mkParamset [("lib", Nothing)] True ==> mkNonRecSet [ "packages" $= mkNonRecSet flags ]
      , mkParamset [("lib", Nothing)] True ==> mkNonRecSet [ "packages" $= mkNonRecSet planned ]
      ]
    ]
 where
  bind :: Text -> Maybe Package -> [Binding NExpr]
  bind pkg (Just Package { packageFlags, packageHasDescriptionOverride = True }) =
      bindPath (VarName pkg :| ["revision"])  (mkSym "import" @@ mkPath False ("." </> "cabal-files" </> Text.unpack pkg <.> "nix"))
    : flagBindings pkg packageFlags
  bind pkg (Just Package { packageVersion, packageFlags, packageHasDescriptionOverride = False }) =
    let verExpr      = (mkSym "hackage" @. pkg) @. quoted packageVersion
        revExpr      = (verExpr @. "revisions") @. "default"
    in  revBinding pkg revExpr : flagBindings pkg packageFlags
  bind pkg Nothing = [revBinding pkg mkNull]
  revBinding :: Text -> NExpr -> Binding NExpr
  revBinding pkg revExpr = bindPath (VarName pkg :| ["revision"]) revExpr
  bind' pkg ver = pkg $= maybe mkNull mkStr ver
  mapKeys f = Map.fromList . fmap (\(k, v) -> (f k, v)) . Map.toList

  relPath = shortRelativePath (argOutputDir args) (dropFileName (argCabalProject args))
  cabalFromPath
          :: String    -- URL
          -> String    -- Revision
          -> FilePath  -- Subdir
          -> FilePath  -- Local Directory
          -> MaybeT IO (String -> IO [Binding NExpr])
  cabalFromPath url rev subdir path = do
          d <- liftIO $ doesDirectoryExist path
          unless d $ fail ("not a directory: " ++ path)
          cabalFiles <- liftIO $ findCabalFiles (argHpackUse args) path
          return $ \sha256 ->
            forM cabalFiles $ \cabalFile -> do
            let pkg = cabalFilePkgName cabalFile
                nix = ".plan.nix" </> pkg <.> "nix"
                nixFile = argOutputDir args </> nix
                subdir' = if subdir == "." then Nothing
                          else Just subdir
                src = Just $ C2N.Git url rev (Just sha256) subdir'
            createDirectoryIfMissing True (takeDirectory nixFile)
            writeDoc nixFile . prettyNix =<< cabal2nix True (argDetailLevel args) src cabalFile
            liftIO $ appendCache (argCacheFile args) url rev subdir sha256 pkg nix
            return $ fromString pkg $= mkPath False nix
  flagBindings pkg packageFlags = Map.foldrWithKey
    (\fname val acc -> bindPath (VarName pkg :| ["flags", fname]) (mkBool val) : acc)
    []
    packageFlags

-- | Converts the project flags for a package flags into @{ packageName = { flags = { flagA = BOOL; flagB = BOOL; }; }; }@
flags2nix :: Text -> HashMap VarName Bool -> [Binding NExpr]
flags2nix pkgName pkgFlags =
  [ quoted pkgName $= mkNonRecSet
    -- `mkOverride 900` is used here so that the default values will be replaced (they are 1000).
    -- Values without a priority are treated as 100 and will replace these ones.
    [ "flags" $= mkNonRecSet [ quoted flag $= ("lib" @. "mkOverride" @@ mkInt 900 @@ mkBool val)
                             | (VarName flag, val) <- Map.toList pkgFlags
                             ]
    ]
  ]

value2plan :: Value -> Plan
value2plan plan = Plan { packages, components, extras, compilerVersion, compilerPackages }
 where
  packages = fmap Just $ filterInstallPlan $ \pkg -> case ( pkg ^. key "type" . _String
                                              , pkg ^. key "style" . _String) of
    -- source-repo packages will be included in `extras`.  We do not need them
    -- in `packages` as well (this could lead to attribute not found errors looking
    -- for them in hackage).
    (_, _) | pkg ^. key "pkg-src" . key "type" . _String == "source-repo" -> Nothing
    (_, "global") -> Just $ Package
      { packageVersion  = pkg ^. key "pkg-version" . _String
      , packageFlags    = Map.fromList . fmap (\(k, v) -> (VarName (Key.toText k), v))
          . KeyMap.toList $ KeyMap.mapMaybe (^? _Bool) $ pkg ^. key "flags" . _Object
      , packageSrc      = Nothing
      , packageHasDescriptionOverride = isJust (pkg ^? key "pkg-cabal-sha256")
      , packagePreExisting = False
      }

    (_, "inplace") -> Just $ Package
      { packageVersion  = pkg ^. key "pkg-version" . _String
      , packageFlags    = Map.fromList . fmap (\(k, v) -> (VarName (Key.toText k), v))
          . KeyMap.toList $ KeyMap.mapMaybe (^? _Bool) $ pkg ^. key "flags" . _Object
      , packageSrc      = Nothing
      , packageHasDescriptionOverride = isJust (pkg ^? key "pkg-cabal-sha256")
      , packagePreExisting = False
      }
    -- Until we figure out how to force Cabal to reconfigure just about any package
    -- this here might be needed, so that we get the pre-existing packages as well.
    -- Or we would have to plug in our very custom minimal pkg-db as well.
    --
    -- The issue is that cabal claims anything in the package db as pre-existing and
    -- wants to reuse it if possible.
    ("pre-existing",_) -> Just $ Package
      { packageVersion  = pkg ^. key "pkg-version" . _String
      , packageFlags    = Map.empty
      , packageSrc      = Nothing
      , packageHasDescriptionOverride = isJust (pkg ^? key "pkg-cabal-sha256") -- likely this is always false
      , packagePreExisting = True
      }
    _ -> Nothing

  extras = fmap Just $ filterInstallPlan $ \pkg -> case ( pkg ^. key "style" . _String
                                                        , pkg ^. key "pkg-src" . key "type" . _String) of
    ("local", "local") -> Just $ Package
      { packageVersion  = pkg ^. key "pkg-version" . _String
      , packageFlags    = Map.fromList . fmap (\(k, v) -> (VarName (Key.toText k), v))
          . KeyMap.toList $ KeyMap.mapMaybe (^? _Bool) $ pkg ^. key "flags" . _Object
      , packageSrc      = Just . LocalPath . Text.unpack $ pkg ^. key "pkg-src" . key "path" . _String
      , packageHasDescriptionOverride = isJust (pkg ^? key "pkg-cabal-sha256") -- likely this is always false
      }
    (_, "source-repo") -> Just $ Package
      { packageVersion  = pkg ^. key "pkg-version" . _String
      , packageFlags    = Map.fromList . fmap (\(k, v) -> (VarName (Key.toText k), v))
          . KeyMap.toList $ KeyMap.mapMaybe (^? _Bool) $ pkg ^. key "flags" . _Object
      , packageSrc      = Just . flip DVCS [ Text.unpack $ fromMaybe "." $ pkg ^? key "pkg-src" . key "source-repo" . key "subdir" . _String ] $
          Git ( Text.unpack $ pkg ^. key "pkg-src" . key "source-repo" . key "location" . _String )
              ( Text.unpack $ pkg ^. key "pkg-src" . key "source-repo" . key "tag" . _String )
      , packageHasDescriptionOverride = isJust (pkg ^? key "pkg-cabal-sha256") -- likely this is always false
      }
    _ -> Nothing

  compilerVersion  = Text.dropWhile (not . isDigit) $ plan ^. key "compiler-id" . _String
  compilerPackages = fmap Just $ filterInstallPlan $ \pkg -> if isJust (pkg ^? key "style" . _String)
    then Nothing
    else Just $ pkg ^. key "pkg-version" . _String

  filterInstallPlan :: (Value -> Maybe b) -> HashMap Text b
  filterInstallPlan f = fmap snd .
    -- If the same package occurs more than once, choose the latest
    Map.fromListWith (\a b -> if fst a > fst b then a else b)
      $ mapMaybe (\pkg -> (,) (pkg ^. key "pkg-name" . _String) . (getPackageKey pkg,) <$> f pkg)
      $ Vector.toList (plan ^. key "install-plan" . _Array)

  parseVersion :: Text -> Version
  parseVersion s = fromMaybe (error $ "Unable to parse version " <> show s) . simpleParsec $ Text.unpack s

  getPackageKey :: Value -> PackageKey
  getPackageKey pkg = PackageKey (parseVersion (pkg ^. key "pkg-version" . _String)) (
    if pkg ^. key "type" . _String == "pre-existing"
      then PreExisting
      else NotPreExisting)

  -- Set of components that are included in the plan.
  components :: HashSet Text
  components =
    Set.fromList
      $ concatMap (\pkg ->
          let pkgName = pkg ^. key "pkg-name" . _String
              nixComponentAttr = Text.pack . componentNameToHaskellNixAttr pkgName . Text.unpack
          in
            map ((quoted pkgName <> ".components.") <>) $
              if pkg ^. key "type" . _String == "pre-existing"
                then [ "library" ]
                else
                  -- If a `components` attribute exists then the keys of that are the component names.
                  -- If it does not exist then look for `component-name` instead.
                  maybe
                    [nixComponentAttr $ pkg ^. key "component-name" . _String]
                    (map (nixComponentAttr . Key.toText) . KeyMap.keys)
                    (pkg ^? key "components" . _Object))
      $ Vector.toList (plan ^. key "install-plan" . _Array)

  -- Convert a cabal style component name to the haskell.nix attribute path.
  componentNameToHaskellNixAttr :: Text -> String -> String
  componentNameToHaskellNixAttr pkgName n =
    case span (/=':') n of
      ("setup", "") -> "setup"
      ("lib", "")   -> "library"
      (prefix, ':':rest) -> componentPrefixToHaskellNix prefix <> "." <> quoted rest
      _ -> error ("unknown component name format " <> show n <> " for package " <> show pkgName)

  componentPrefixToHaskellNix :: String -> String
  componentPrefixToHaskellNix "lib"   = "sublibs"
  componentPrefixToHaskellNix "flib"  = "foreignlibs"
  componentPrefixToHaskellNix "exe"   = "exes"
  componentPrefixToHaskellNix "test"  = "tests"
  componentPrefixToHaskellNix "bench" = "benchmarks"
  componentPrefixToHaskellNix x = error ("unknown component prefix " <> x)

defaultNixContents :: String
defaultNixContents = unlines
  [ "{ haskellNixSrc ? builtins.fetchTarball https://github.com/input-output-hk/haskell.nix/archive/master.tar.gz"
  , ", haskellNix ? import haskellNixSrc {}"
  , ", nixpkgs ? haskellNix.sources.nixpkgs }:"
  , ""
  , "let"
  , "  pkgs = import nixpkgs haskellNix.nixpkgsArgs;"
  , ""
  , "  pkgSet = pkgs.haskell-nix.mkCabalProjectPkgSet {"
  , "    plan-pkgs = import ./pkgs.nix;"
  , "    pkg-def-extras = [];"
  , "    modules = [];"
  , "  };"
  , ""
  , "in"
  , "  pkgSet.config.hsPkgs"
  ]

{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

import Cabal2Nix (Src, gpd2nix)
import qualified Cabal2Nix hiding (gpd2nix)
import Data.Bifunctor (first)
import qualified Data.ByteString.Lazy as BSL
import Data.Foldable (for_)
import qualified Data.Text.Encoding as T
import Distribution.Client.DistDirLayout (DistDirLayout (..))
import Distribution.Client.GlobalFlags
import Distribution.Client.HashValue (HashValue, showHashValue)
import qualified Distribution.Client.InstallPlan as InstallPlan
import Distribution.Client.NixStyleOptions (NixStyleFlags (..), defaultNixStyleFlags, nixStyleOptions)
import Distribution.Client.ProjectConfig
import Distribution.Client.ProjectOrchestration
import Distribution.Client.ProjectPlanning (ElaboratedConfiguredPackage (..), availableTargets, rebuildInstallPlan)
import Distribution.Client.ProjectPlanning.Stage (WithStage (..))
import Distribution.Client.Setup
import Distribution.Client.Types.PackageLocation (PackageLocation (..))
import Distribution.Client.Types.Repo (LocalRepo (..), RemoteRepo (..), Repo (..))
import Distribution.Client.Types.SourceRepo (SourceRepositoryPackage (..))
import Distribution.Package (pkgName)
import Distribution.PackageDescription.Parsec (parseGenericPackageDescription, runParseResult)
import Distribution.Parsec.Error (showPErrorWithSource)
import Distribution.Pretty (prettyShow)
import Distribution.Simple.Command
import Distribution.Simple.Flag
import qualified Distribution.Simple.Utils as Cabal
import Distribution.Types.SourceRepo (KnownRepoType (..), RepoType (..))
import Distribution.Verbosity (Verbosity)
import qualified Distribution.Verbosity as Verbosity
import Freeze (projectFreezeConfig)
import Nix.Expr
import Nix.Pretty (prettyNix)
import Prettyprinter (Doc)
import Prettyprinter.Render.Text (hPutDoc)
import ProjectPlanOutput (writePlanExternalRepresentation)
import System.Environment (getArgs)
import System.FilePath
import System.IO (IOMode (WriteMode), hClose, openFile)
import Distribution.Simple.Utils (topHandler)

main :: IO ()
main = do
  args <- getArgs
  case commandParseArgs cmdUI True args of
    CommandHelp help -> putStrLn (help "make-install-plan")
    CommandList opts -> putStrLn $ "commandList" ++ show opts
    CommandErrors errs -> putStrLn $ "commandErrors: " ++ show errs
    CommandReadyToGo (mkflags, _commandParse) ->
      let globalFlags = defaultGlobalFlags
          flags@NixStyleFlags{configFlags} = mkflags (commandDefaultFlags cmdUI)
          -- cabal 3.17: configVerbosity is now a Flag VerbosityFlags and `normal`
          -- is a VerbosityFlags; wrap it into a Verbosity for the API below.
          verbosity = Verbosity.mkVerbosity Verbosity.defaultVerbosityHandles
            (fromFlagOrDefault Verbosity.normal (configVerbosity configFlags))
          cliConfig = commandLineFlagsToProjectConfig globalFlags flags mempty
          -- cabal 3.17: topHandler now takes a predicate selecting which exceptions
          -- are "user" (friendly) exceptions; we treat none specially.
       in topHandler (const False) (installPlanAction verbosity cliConfig)

cmdUI :: CommandUI (NixStyleFlags ())
cmdUI =
  CommandUI
    { commandName = ""
    , commandSynopsis = "Makes an install-plan"
    , commandUsage = ("Usage: " ++)
    , commandDescription = Nothing
    , commandNotes = Nothing
    , commandDefaultFlags = defaultNixStyleFlags ()
    , commandOptions = nixStyleOptions (const [])
    }

-- cabal 3.17: many plan values are now tagged with the build Stage; this drops it.
dropStage :: WithStage a -> a
dropStage (WithStage _ a) = a

-- The following is adapted from cabal-install's Distribution.Client.CmdFreeze
installPlanAction :: Verbosity -> ProjectConfig -> IO ()
installPlanAction verbosity cliConfig = do
  ProjectBaseContext{distDirLayout, projectConfig, localPackages} <-
    establishProjectBaseContext verbosity cliConfig OtherCommand

  -- cabal 3.17: rebuildInstallPlan no longer takes the CabalDirLayout argument and
  -- returns a 4-tuple (the improved plan is no longer returned separately).
  (elaboratedPlan, elaboratedSharedConfig, totalIndexState, activeRepos) <-
    rebuildInstallPlan verbosity distDirLayout projectConfig localPackages Nothing

  -- Write plan.json
  Cabal.notice verbosity $ "Writing plan.json to " ++ distProjectCacheFile distDirLayout "plan.json"
  writePlanExternalRepresentation
    distDirLayout
    elaboratedPlan
    elaboratedSharedConfig
    -- cabal 3.17: availableTargets keys are now WithStage-qualified unit ids;
    -- drop the stage so plan.json keeps its (UnitId, ComponentName) shape.
    ((fmap . fmap . fmap) (first dropStage) (availableTargets elaboratedPlan))

  -- Write cabal.freeze
  let freezeConfig = projectFreezeConfig elaboratedPlan totalIndexState activeRepos
  writeProjectLocalFreezeConfig distDirLayout freezeConfig
  Cabal.notice verbosity $ "Wrote freeze file to " ++ distProjectFile distDirLayout "freeze"

  -- Write cabal files and their nix version
  let cabalFilesDir = distDirectory distDirLayout </> "cabal-files"
  Cabal.createDirectoryIfMissingVerbose verbosity True cabalFilesDir
  Cabal.notice verbosity $ "Writing cabal files to " ++ cabalFilesDir

  -- cabal 3.17: elabLocalToProject was renamed elabIsSourcePackage.
  let ecps = [ecp | InstallPlan.Configured ecp <- InstallPlan.toList elaboratedPlan, not $ elabIsSourcePackage ecp]

  for_ ecps $
    \ElaboratedConfiguredPackage
      { elabPkgSourceId
      , elabPkgSourceLocation
      , elabPkgSourceHash
      , elabIsSourcePackage
      , elabPkgDescriptionOverride
      } -> do
        let nixFile = cabalFilesDir </> prettyShow (pkgName elabPkgSourceId) <.> "nix"
        for_ elabPkgDescriptionOverride $ \pkgTxt -> do
          -- In the plan we have elabPkgDescription :: PackageDescription which is the cabal file after
          -- the conditionals are resolved but gpd2nix still wants a GenericPackageDescription so we need

          let gpdText = BSL.toStrict pkgTxt
          let src = packageLocation2Src elabPkgSourceLocation elabPkgSourceHash
          let gpd = case runParseResult (parseGenericPackageDescription gpdText) of
                (_, Left (_, err)) -> error ("Failed to parse in-memory cabal file: " ++ foldMap showPErrorWithSource err)
                (_, Right desc) -> desc
          let extra = mkNonRecSet ["package-description-override" $= mkStr (T.decodeUtf8 gpdText)]
          let nix = gpd2nix elabIsSourcePackage Cabal2Nix.MinimalDetails (Just src) (Just extra) gpd
          writeDoc nixFile $ prettyNix nix

packageLocation2Src :: PackageLocation local -> Maybe HashValue -> Cabal2Nix.Src
packageLocation2Src pkgSrcLoc pkgSrcHash = case pkgSrcLoc of
  LocalUnpackedPackage path -> Cabal2Nix.Path path
  LocalTarballPackage path -> Cabal2Nix.Path path
  RemoteTarballPackage uri _local -> Cabal2Nix.Repo (show uri) mSrcHash
  RepoTarballPackage repo _packageId _local -> case repo of
    (RepoLocalNoIndex lr _local) -> Cabal2Nix.Path (localRepoPath lr)
    (RepoRemote rr _local) -> Cabal2Nix.Repo (show $ remoteRepoURI rr) mSrcHash
    (RepoSecure rr _local) -> Cabal2Nix.Repo (show $ remoteRepoURI rr) mSrcHash
  RemoteSourceRepoPackage sourceRepoMaybe _local -> case sourceRepoMaybe of
    (SourceRepositoryPackage (KnownRepoType Git) location (Just tag) branch subdir []) ->
      Cabal2Nix.Git location tag branch subdir
    _otherCases -> error $ "Repository " <> show sourceRepoMaybe <> " not supported"
 where
  mSrcHash = showHashValue <$> pkgSrcHash

writeDoc :: FilePath -> Doc ann -> IO ()
writeDoc file doc = do
  handle <- openFile file WriteMode
  hPutDoc handle doc
  hClose handle

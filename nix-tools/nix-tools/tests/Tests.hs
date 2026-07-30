import Control.Monad (when)
import qualified Data.ByteString as BS
import Data.List (isInfixOf)
import Data.Maybe (isNothing)
import System.Directory (copyFile, createDirectoryIfMissing, removeDirectoryRecursive, withCurrentDirectory)
import System.Directory.Extra (findExecutable, listFiles)
import System.Environment (setEnv)
import System.Exit (ExitCode (..))
import System.FilePath (replaceExtension, takeBaseName, takeExtensions, (</>))
import System.IO.Extra (newTempDir)
import System.Process (callCommand, readProcessWithExitCode)
import Test.Tasty (TestTree, defaultMain, testGroup, withResource)
import Test.Tasty.Golden.Advanced (goldenTest2)
import Test.Tasty.Providers

main :: IO ()
main = do
  golden <- goldenTests
  -- The cli smoke tests are kept outside `goldenTests` so they don't get
  -- wrapped in the network-dependent `cabal update` resource below.
  defaultMain $ testGroup "nix-tools" [testGroup "cli" cliTests, golden]

-- | Lightweight smoke tests for executable command-line handling that need
-- neither the Hackage index nor golden files.
cliTests :: [TestTree]
cliTests =
  [ singleTest "cabal-to-nix --help exits 0 and prints usage" $
      ShellCheck $ do
        -- Preflight the executable so a missing `cabal-to-nix` on PATH becomes a
        -- clear test failure rather than an IOException that aborts the run.
        mexe <- findExecutable "cabal-to-nix"
        case mexe of
          Nothing -> return (Just "cabal-to-nix is not on PATH")
          Just _  -> do
            (code, out, err) <- readProcessWithExitCode "cabal-to-nix" ["--help"] ""
            return (checkHelp code (out ++ err))
  ]

-- | Assertion for the `--help` smoke test, factored out so it is pure and
-- easy to reason about: help must exit successfully and mention the usage.
checkHelp :: ExitCode -> String -> Maybe String
checkHelp ExitSuccess out
  | "Usage:" `isInfixOf` out = Nothing
  | otherwise = Just ("--help exited 0 but output did not contain \"Usage:\":\n" ++ out)
checkHelp (ExitFailure n) out =
  Just ("--help exited with code " ++ show n ++ ":\n" ++ out)

-- | Minimal tasty provider: run an 'IO' action returning 'Nothing' on success
-- or 'Just' an error message on failure. Avoids pulling in tasty-hunit.
newtype ShellCheck = ShellCheck (IO (Maybe String))

instance IsTest ShellCheck where
  run _ (ShellCheck act) _ = maybe (testPassed "") testFailed <$> act
  testOptions = return []

goldenTests :: IO TestTree
goldenTests = do
  -- Use a temporary CABAL_DIR
  checkRequiredProgram "make-install-plan"
  checkRequiredProgram "plan-to-nix"

  -- NOTE: we want these paths to be like "tests/golden/test1.project"
  projectFiles <- findFilesWithExtension ".project" "tests/golden"
  return $
    withHackageIndex $
      testGroup "Tests" (map testProject projectFiles)
  where
    withHackageIndex t =
      withResource
        ( do
            (cabalDir, cleanup) <- newTempDir
            setEnv "CABAL_DIR" cabalDir
            callCommand "cabal update -v"
            return cleanup
        )
        id
        (const t)

testProject :: FilePath -> TestTree
testProject projectFile = test
  where
    goldenPlanJsonFile = replaceExtension projectFile ".plan.json"
    goldenPackagesFile = replaceExtension projectFile ".pkgs.nix"

    testName = takeBaseName projectFile
    testWorkDir = replaceExtension projectFile ".workdir"

    testPlanJsonFile = testWorkDir </> "dist-newstyle/cache/plan.json"
    testPackagesFile = testWorkDir </> "plan-nix/pkgs.nix"

    test = goldenTest2 testName readExpected getActual compareResult updateExpected delete
      where
        readExpected = do
          plan <- BS.readFile goldenPlanJsonFile
          pkgs <- BS.readFile goldenPackagesFile
          return (plan, pkgs)

        updateExpected (plan, pkgs) = do
          BS.writeFile goldenPlanJsonFile plan
          BS.writeFile goldenPackagesFile pkgs

        getActual = do
          createDirectoryIfMissing True testWorkDir
          copyFile projectFile (testWorkDir </> "cabal.project")
          withCurrentDirectory testWorkDir $ do
            callCommand "make-install-plan"
            createDirectoryIfMissing True "plan-nix"
            callCommand "plan-to-nix --output plan-nix"
          plan <- BS.readFile testPlanJsonFile
          pkgs <- BS.readFile testPackagesFile
          return (plan, pkgs)

        delete = removeDirectoryRecursive testWorkDir

        compareResult a b = return $ if a == b then Nothing else Just ""

findFilesWithExtension :: String -> FilePath -> IO [FilePath]
findFilesWithExtension ext dir =
  filter ((== ext) . takeExtensions) <$> listFiles dir

checkRequiredProgram :: String -> IO ()
checkRequiredProgram prg =
  findExecutable prg >>= \mpath ->
    when (isNothing mpath) $ fail (prg ++ " is missing")

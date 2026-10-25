module Plan2Nix.CLI
  ( Args(..)
  , HpackUse(..)
  , parsePlan2NixArgs
  ) where

import Options.Applicative hiding (option)
import Data.Semigroup ((<>))
import Cabal2Nix (CabalDetailLevel(..))
import Stack2nix.CLI (HpackUse(..))

--------------------------------------------------------------------------------
-- CLI Arguments
data Args = Args
  { argOutputDir :: FilePath
  , argPlanJSON :: FilePath
  , argCabalProject :: FilePath
  , argCacheFile :: FilePath
  , argDetailLevel :: CabalDetailLevel
  , argHpackUse  :: HpackUse
  } deriving Show

-- Argument Parser
args :: Parser Args
args = Args
  <$> strOption ( long "output" <> short 'o' <> metavar "DIR" <> help "Generate output in DIR" )
  <*> strOption ( long "plan-json" <> value "dist-newstyle/cache/plan.json" <> showDefault <> metavar "FILE" <> help "Override plan.json location" )
  <*> strOption ( long "cabal-project" <> value "cabal.project" <> showDefault <> metavar "FILE" <> help "Override path to cabal.project" )
  <*> strOption ( long "cache" <> value ".nix-tools.cache" <> showDefault <> metavar "FILE" <> help "Dependency cache file" )
  <*> flag MinimalDetails FullDetails ( long "full" <> help "Output details needed to determine what files are used" )
  <*> flag UsePackageYamlFirst IgnorePackageYaml (long "ignore-package-yaml" <> help "disable hpack run and use only cabal disregarding package.yaml existence")

parsePlan2NixArgs :: IO Args
parsePlan2NixArgs = execParser opts
  where opts = info (args <**> helper)
          ( fullDesc
         <> progDesc "Generate a Nix expression for a Haskell package using Cabal"
         <> header "plan-to-nix - a stack to nix converter" )

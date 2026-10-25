module Stack2nix.CLI
  ( Args(..)
  , HpackUse(..)
  , parseStack2nixArgs
  ) where

import Options.Applicative hiding (option)
import Data.Semigroup ((<>))
import Cabal2Nix (CabalDetailLevel(..))

data HpackUse
  = IgnorePackageYaml
  | UsePackageYamlFirst
  deriving Show

--------------------------------------------------------------------------------
-- CLI Arguments
data Args = Args
  { argOutputDir :: FilePath
  , argStackYaml :: FilePath
  , argHpackUse  :: HpackUse
  , argCacheFile :: FilePath
  , argDetailLevel :: CabalDetailLevel
  } deriving Show

-- Argument Parser
args :: Parser Args
args = Args
  <$> strOption ( long "output" <> short 'o' <> metavar "DIR" <> help "Generate output in DIR" )
  <*> strOption ( long "stack-yaml" <> value "stack.yaml" <> showDefault <> metavar "FILE" <> help "Override project stack.yaml" )
  <*> flag UsePackageYamlFirst IgnorePackageYaml (long "ignore-package-yaml" <> help "disable hpack run and use only cabal disregarding package.yaml existence")
  <*> strOption ( long "cache" <> value ".stack-to-nix.cache" <> showDefault <> metavar "FILE" <> help "Dependency cache file" )
  <*> flag MinimalDetails FullDetails ( long "full" <> help "Output details needed to determine what files are used" )

parseStack2nixArgs :: IO Args
parseStack2nixArgs = execParser opts
  where opts = info (args <**> helper)
          ( fullDesc
         <> progDesc "Generate a Nix expression for a Haskell package using Stack"
         <> header "stack-to-nix - a stack to nix converter" )

module CabalName.CLI
  ( Args(..)
  , HpackUse(..)
  , parseCabalNameArgs
  ) where

import Options.Applicative hiding (option)
import Data.Semigroup ((<>))
import Stack2nix.CLI (HpackUse(..))

--------------------------------------------------------------------------------
-- CLI Arguments
data Args = Args
  { argPackageDir :: FilePath
  , argHpackUse   :: HpackUse
  } deriving Show

-- Argument Parser
args :: Parser Args
args = Args
  <$> argument str ( metavar "DIR" <> help "Directory containing the package source" )
  <*> flag UsePackageYamlFirst IgnorePackageYaml (long "ignore-package-yaml" <> help "disable hpack run and use only cabal disregarding package.yaml existence")

parseCabalNameArgs :: IO Args
parseCabalNameArgs = execParser opts
  where opts = info (args <**> helper)
          ( fullDesc
         <> progDesc "Find the name of the packeage in the specified directory"
         <> header "cabal-name - extract the name of a package" )

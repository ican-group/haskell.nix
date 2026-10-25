module StackRepos.CLI
  ( Args(..)
  , HpackUse(..)
  , parseStackReposArgs
  ) where

import Options.Applicative hiding (option)
import Data.Semigroup ((<>))
import Stack2nix.CLI (HpackUse(..))

--------------------------------------------------------------------------------
-- CLI Arguments
newtype Args = Args
  { argStackYaml :: FilePath
  } deriving Show

-- Argument Parser
args :: Parser Args
args = Args
  <$> strOption ( long "stack-yaml" <> value "stack.yaml" <> showDefault <> metavar "FILE" <> help "Override project stack.yaml" )

parseStackReposArgs :: IO Args
parseStackReposArgs = execParser opts
  where opts = info (args <**> helper)
          ( fullDesc
         <> progDesc "Collect information about remote source packages used by Stack"
         <> header "stack-repos - extract the details of remote repos" )

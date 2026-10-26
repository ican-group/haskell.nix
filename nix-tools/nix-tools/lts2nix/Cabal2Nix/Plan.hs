{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Cabal2Nix.Plan
where

import           Cabal2Nix.Util                           ( quoted
                                                          , bindPath
                                                          , hackageVersion
                                                          , hackageVersionHelper
                                                          )
import           Data.HashMap.Strict                      ( HashMap )
import qualified Data.HashMap.Strict           as Map
import           Data.List.NonEmpty                       ( NonEmpty (..) )
import           Data.Text                                ( Text )
import qualified Data.Text                     as Text
import           Nix.Expr

type Version = Text
type Revision = Text -- Can be: rNUM, cabal file sha256, or "default"

data Plan = Plan
  { packages :: HashMap Text (Maybe Package)
  , compilerVersion :: Text
  , compilerPackages :: HashMap Text (Maybe Version)
  }

data Package = Package
  { packageVersion :: Version
  , packageRevision :: Maybe Revision
  , packageFlags :: HashMap VarName Bool
  }

plan2nix :: Plan -> NExpr
plan2nix (Plan { packages, compilerVersion, compilerPackages }) =
  mkFunction "hackage"
    -- Bind the shared hackage.nix lookup guard once per file (it references the
    -- `hackage` function argument, so it must live inside this lambda).
    . mkLets [ hackageVersionHelper ]
    . mkNonRecSet
    $ [ "packages" $= (mkNonRecSet $ uncurry bind =<< Map.toList quotedPackages)
      , "compiler" $= mkNonRecSet
        [ "version" $= mkStr compilerVersion
        , "nix-name" $= mkStr ("ghc" <> Text.filter (/= '.') compilerVersion)
        , "packages" $= mkNonRecSet (fmap (uncurry bind') $ Map.toList $ mapKeys quoted compilerPackages)
        ]
      ]
 where
  quotedPackages = mapKeys quoted packages
  bind :: Text -> Maybe Package -> [Binding NExpr]
  bind pkg (Just (Package { packageVersion, packageRevision, packageFlags })) =
    let revExpr      = hackageVersion (Text.dropAround (== '"') pkg) packageVersion
                                      (maybe "default" id packageRevision)
        flagBindings = Map.foldrWithKey
          (\fname val acc -> bindPath (VarName pkg :| ["flags", fname]) (mkBool val) : acc)
          []
          packageFlags
    in  revBinding pkg revExpr : flagBindings
  bind pkg Nothing = [revBinding pkg mkNull]
  revBinding :: Text -> NExpr -> Binding NExpr
  revBinding pkg revExpr = bindPath (VarName pkg :| ["revision"]) revExpr
  bind' pkg ver = pkg $= maybe mkNull mkStr ver
  mapKeys f = Map.fromList . fmap (\(k, v) -> (f k, v)) . Map.toList

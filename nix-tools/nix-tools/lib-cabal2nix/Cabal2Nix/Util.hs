{-# LANGUAGE OverloadedStrings #-}
module Cabal2Nix.Util where

import System.Directory
import System.FilePath

import Control.Monad
import Data.String (IsString)
import Data.Text (Text)

import Data.ByteString.Char8 (pack, unpack)
import Crypto.Hash.SHA256 (hash)
import qualified Data.ByteString.Base16 as Base16

import Data.List.NonEmpty (NonEmpty)
import Data.Fix(Fix(..))
import Nix.Expr

listDirectories :: FilePath -> IO [FilePath]
listDirectories p =
  filter (/= ".git") <$> listDirectory p
  >>= filterM (doesDirectoryExist . (p </>))

quoted :: (IsString a, Semigroup a) => a -> a
quoted str = "\"" <> str <> "\""

selectOr :: NExpr -> NAttrPath NExpr -> NExpr -> NExpr
selectOr obj path alt = Fix (NSelect (Just $ alt) obj path)

mkThrow :: NExpr -> NExpr
mkThrow msg = (mkSym "builtins" @. "throw") @@ msg

-- | The name the shared hackage.nix lookup guard is bound to in the generated
-- Nix (see 'hackageVersionHelper' / 'hackageVersion').
hackageVersionName :: Text
hackageVersionName = "hackageVersion"

-- | The trailing guidance shared by both @builtins.throw@ messages emitted by
-- 'hackageVersionHelper'. Kept as a single Haskell constant so the (long)
-- wording lives in exactly one place.
notInHackage :: Text
notInHackage =
  " is not in the hackage.nix package set. You may need a more recent\
  \ hackage.nix (update your haskell.nix pin / niv sources / flake inputs),\
  \ or your index-state may be too old to include it."

-- | A dynamic (antiquoted) attribute path @${var}@, selecting by the runtime
-- value of the given variable rather than a static key.
dynSelector :: Text -> NAttrPath NExpr
dynSelector var = pure (DynamicKey (Antiquoted (mkSym var)))

-- | An interpolated double-quoted string from the given parts, e.g.
-- @[Antiquoted (mkSym "pkg"), Plain notInHackage]@ renders as
-- @"${pkg} is not ..."@.
mkInterpStr :: [Antiquoted Text NExpr] -> NExpr
mkInterpStr = Fix . NStr . DoubleQuoted

-- | The shared @let@ binding placed ONCE per generated file, inside the
-- @hackage: ...@ function (so @hackage@ is in scope):
--
-- > hackageVersion = pkg: ver: rev:
-- >   ((hackage.${pkg} or (builtins.throw "${pkg} is not in ..."))
-- >      .${ver} or (builtins.throw "${pkg}-${ver} is not in ...")).revisions.${rev};
--
-- This replaces the previous inline-per-package guard (which repeated the
-- ~180-char message twice for every one of the thousands of packages in a
-- snapshot). Guards a package or version missing from hackage.nix with an
-- actionable error instead of Nix's opaque @attribute '<ver>' missing@ (#855).
--
-- The @.revisions.${rev}@ suffix (which every call site appends) is folded into
-- the helper on purpose: every call site is then a plain function application,
-- @hackageVersion "<pkg>" "<ver>" "<rev>"@. If it were left at the call site as
-- @(hackageVersion "<pkg>" "<ver>").revisions.<rev>@ the hnix pretty-printer
-- would emit it WITHOUT the parentheses (@hackageVersion "..." "...".revisions@),
-- which Nix parses as selecting on the version argument — a different, broken
-- expression. Dynamic selection by @rev@ is equivalent to the previous
-- @.revisions.default@ / @.revisions."<sha>"@ / @.revisions.r<N>@ keys.
hackageVersionHelper :: Binding NExpr
hackageVersionHelper =
  hackageVersionName $=
    ("pkg" ==> ("ver" ==> ("rev" ==>
      plainSelect
        (selectOr
          (selectOr (mkSym "hackage") (dynSelector "pkg")
            (mkThrow (mkInterpStr [Antiquoted (mkSym "pkg"), Plain notInHackage])))
          (dynSelector "ver")
          (mkThrow (mkInterpStr
            [Antiquoted (mkSym "pkg"), Plain "-", Antiquoted (mkSym "ver"), Plain notInHackage])))
        (pure (StaticKey "revisions") <> dynSelector "rev"))))
  where
    -- plain (no @or@ fallback) selection of the given attribute path
    plainSelect obj path = Fix (NSelect Nothing obj path)

-- | A compact call site referencing the shared 'hackageVersionHelper': the
-- application @hackageVersion "<pkg>" "<ver>" "<rev>"@ (whose value is the
-- @revisions.<rev>@ record, as the callers expect). The arguments are the plain
-- (unquoted) names; the string literals rendered here supply the quoting, and
-- the helper's dynamic selection handles any characters safely. Equivalent to
-- the previous @hackage.<pkg>.<ver>.revisions.<rev>@ in the present case, but a
-- constant size regardless of the (shared) message length.
hackageVersion :: Text -> Text -> Text -> NExpr
hackageVersion pkg ver rev =
  mkSym hackageVersionName @@ mkStr pkg @@ mkStr ver @@ mkStr rev

sha256 :: String -> String
sha256 = unpack . Base16.encode . hash . pack

bindPath :: NonEmpty VarName -> NExpr -> Binding NExpr
bindPath ks e = NamedVar (fmap StaticKey ks) e nullPos

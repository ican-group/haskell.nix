{-# LANGUAGE OverloadedStrings #-}

-- | Pure regression test for the friendly hackage.nix lookup guard (issue #855).
--
-- @stack-to-nix@ / @lts-to-nix@ resolve every snapshot / @extra-deps@ package
-- through a generated @hackage.<pkg>."<ver>".revisions...@ lookup. Before #855
-- a package or version missing from hackage.nix failed with Nix's opaque
-- @attribute '<ver>' missing@. #855 wrapped the lookups in actionable
-- @builtins.throw@s.
--
-- The first cut inlined the (~180-char) guard, twice, at EVERY package — which
-- bloats a snapshot's generated Nix enormously. This test pins the reworked
-- shape: the guard lambda ('hackageVersionHelper') is emitted ONCE per file via
-- a @let@, and each package is a compact @hackageVersion "<pkg>" "<ver>"@
-- application. So the long message must appear a fixed number of times (once per
-- throw = 2) no matter how many packages are rendered.
module Main (main) where

import           Cabal2Nix.Util               (hackageVersion, hackageVersionHelper)
import           Control.Monad                (unless)
import           Data.Text                    (Text)
import qualified Data.Text                    as T
import           Nix.Expr
import           Nix.Pretty                   (prettyNix)
import           Prettyprinter                (defaultLayoutOptions, layoutPretty)
import           Prettyprinter.Render.Text    (renderStrict)
import           System.Exit                  (exitFailure)
import           System.IO                    (hPutStrLn, stderr)

-- | A sample generated file with the shared helper and *two* package entries,
-- shaped like the real @lts-to-nix@ / @stack-to-nix@ output
-- (@hackage: let hackageVersion = ...; in { packages = { ... }; }@).
sample :: NExpr
sample =
  mkFunction "hackage"
    . mkLets [ hackageVersionHelper ]
    . mkNonRecSet
    $ [ "packages" $= mkNonRecSet
          [ "aeson" $= hackageVersion "aeson" "2.2.3.0" "default"
          , "text"  $= hackageVersion "text"  "2.1.1"   "r3"
          ]
      ]

rendered :: Text
rendered =
  renderStrict (layoutPretty defaultLayoutOptions (prettyNix sample))

-- | Number of (non-overlapping) occurrences of @needle@ in @rendered@.
count :: Text -> Int
count needle = length (T.breakOnAll needle rendered)

main :: IO ()
main = do
  let needles = [ "hackageVersion = "              -- helper bound once, via let
                , "hackageVersion \"aeson\" \"2.2.3.0\" \"default\"" -- compact call site
                , "hackageVersion \"text\" \"2.1.1\" \"r3\""
                , ".revisions.${rev}"              -- revisions suffix folded into helper
                , "builtins.throw"                 -- guarded, not a bare selection
                , "hackage.nix package set"        -- actionable wording
                ]
      missing = filter (\n -> not (n `T.isInfixOf` rendered)) needles
  unless (null missing) $ die ("missing " ++ show missing)

  -- The bloat guard: with two packages rendered, the long message must still
  -- appear exactly twice (once per throw in the single shared helper), NOT
  -- twice per package.
  let msgs = count "is not in the hackage.nix package set"
  unless (msgs == 2) $
    die ("expected the long message exactly twice (once per throw, shared), got " ++ show msgs)

  -- The helper itself must be defined exactly once.
  let defs = count "hackageVersion = "
  unless (defs == 1) $
    die ("expected the helper defined exactly once, got " ++ show defs)

  putStrLn "hackageVersion guard is shared once per file with friendly errors (OK)"
 where
  die msg = do
    hPutStrLn stderr ("tests-hackage: " ++ msg ++ "\nrendered:\n" ++ T.unpack rendered)
    exitFailure

{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE LambdaCase #-}

module Main (main) where

import           Cabal2Nix
import           Cabal2Nix.Util                           ( quoted )
#if !MIN_VERSION_base(4, 17, 0)
import           Control.Applicative                      ( liftA2 )
#endif
import           Control.Monad.Trans.State.Strict
import           Crypto.Hash.SHA256                       ( hash )
import qualified Data.ByteString.Base16        as Base16
import qualified Data.ByteString.Char8         as BS
import           Data.Char                                ( isUpper )
import           Data.Foldable                            ( toList
                                                          , for_
                                                          )
import           Data.List                                ( intersperse )
import           Data.Map                                 ( Map )
import qualified Data.Map                      as Map
import           Data.Semigroup                as Sem
import           Data.Sequence                            ( Seq )
import qualified Data.Sequence                 as Seq
import           Data.String                              ( IsString(fromString)
                                                          )
import           Data.Text                                ( Text )
import qualified Data.Text                     as T       ( pack )
import           Data.Text.Encoding                       ( decodeUtf8 )
import           Distribution.Hackage.DB                  ( hackageTarball )
import qualified Distribution.Hackage.DB.Parsed
                                               as P
import qualified Distribution.Hackage.DB.Unparsed
                                               as U
import           Distribution.Pretty                      ( prettyShow
                                                          , Pretty
                                                          )
import           Distribution.Types.PackageName           ( PackageName )
import           Distribution.Types.Version               ( Version )
import           Nix                                      ( (@@)
                                                          , mkSym
                                                          , mkInt
                                                          , mkStr
                                                          , NExpr
                                                          , ($=)
                                                          , mkNonRecSet
                                                          )
import           Nix.Pretty                               ( prettyNix )
import           System.Directory                         ( createDirectoryIfMissing
                                                          )
import           System.Environment                       ( getArgs )
import           System.FilePath                          ( (</>)
                                                          , (<.>)
                                                          )

-- Avoid issues with case insensitive file systems by escaping upper case
-- characters with a leading _ character.
escapeUpperCase :: String -> String
escapeUpperCase = (>>= (\case
    '_' -> "__"
    c | isUpper c -> ['_', c]
      | otherwise -> [c]))

main :: IO ()
main = do
  out:rest <- getArgs
  (inp, src) <- case rest of
                 [tarball, url, sha256] -> return (tarball, Just $ Repo url (Just sha256))
                 [tarball, url] -> return (tarball, Just $ Repo url Nothing)
                 [tarball] -> return (tarball, Nothing)
                 [] -> hackageTarball >>= \tarball -> return (tarball, Nothing)
                 _ -> error "Usage: hackage2nix [tarball [url [hash]]]"

  db    <- U.readTarball Nothing inp

  let (nixFiles, cabalFiles) =
        runState (fmap (toList . (Seq.sortOn fst)) $ foldMapWithKeyA package2nix db) mempty
  createDirectoryIfMissing False out
  writeFile (out </> "default.nix") $ unlines [
      "with builtins; mapAttrs (_: mapAttrs (_: data: rec {",
      " inherit (data) sha256;",
      " revisions = data.revisions // {",
      "  default = revisions.\"${data.revisions.default}\";",
      " };",
      "})) {",
      -- Import all the per package nix files
      unlines [
         "  " <> quoted pname <> " = import ./nix/" <> escapeUpperCase pname <> ".nix;"
        | (pname, _) <- nixFiles
      ],
      "}"
    ]

  createDirectoryIfMissing False (out </> "nix")
  for_ nixFiles $ \(pname, nix) ->
    writeFile (out </> "nix" </> escapeUpperCase pname <.> "nix") $ show $ prettyNix nix

  createDirectoryIfMissing False (out </> "hackage")

  for_ cabalFiles $ \(cabalFile, pname, path) -> do
    gpd <- cabal2nix False MinimalDetails src $ InMemory Nothing pname $ cabalFile
    writeFile (out </> path) $ show $ prettyNix gpd

type GPDWriter = State (Seq (BS.ByteString, String, FilePath))

newtype ApplicativeMonoid f a = ApplicativeMonoid { unApplicativeMonoid :: f a }
instance (Applicative f, Semigroup a) => Sem.Semigroup (ApplicativeMonoid f a) where
  ApplicativeMonoid a <> ApplicativeMonoid b = ApplicativeMonoid $ liftA2 (Sem.<>) a b
instance (Applicative f, Monoid a) => Monoid (ApplicativeMonoid f a) where
  mempty = ApplicativeMonoid $ pure mempty
  mappend = (Sem.<>)

foldMapWithKeyA
  :: (Applicative f, Monoid b) => (k -> a -> f b) -> Map k a -> f b
foldMapWithKeyA f =
  unApplicativeMonoid . Map.foldMapWithKey (\k -> ApplicativeMonoid . f k)

fromPretty :: (Pretty a, IsString b) => a -> b
fromPretty = fromString . prettyShow

package2nix :: PackageName -> U.PackageData -> GPDWriter (Seq (String, NExpr))
package2nix pname (U.PackageData { U.versions }) = do
  versionBindings <- foldMapWithKeyA (version2nix pname) versions
  return $ Seq.singleton (fromPretty pname, (mkNonRecSet . map (uncurry ($=)) . toList $ Seq.sortOn fst $ versionBindings))

version2nix
  :: PackageName -> Version -> U.VersionData -> GPDWriter (Seq (Text, NExpr))
version2nix pname vnum (U.VersionData { U.cabalFileRevisions, U.metaFile }) =
  do
    revisionBindings <- sequenceA
      $ zipWith (revBindingJson pname vnum) cabalFileRevisions [0 ..]
    let sha256 = decodeUtf8 $ fromString $ P.parseMetaData pname vnum metaFile Map.! "sha256"
    return $ Seq.singleton (quoted (fromPretty vnum), mkNonRecSet
      [ "sha256" $= mkStr sha256
      , "revisions" $= mkNonRecSet
        ( map (uncurry ($=)) revisionBindings
        ++ ["default" $= mkStr (fst (last revisionBindings))]
        )
      ])

revBindingJson
  :: PackageName
  -> Version
  -> BS.ByteString
  -> Integer
  -> GPDWriter (Text, NExpr)
revBindingJson pname vnum cabalFile revNum = do
  let qualifiedName = mconcat $ intersperse
        "-"
        [prettyPname, fromPretty vnum, revName, BS.unpack cabalHash]
      revName :: (Semigroup a, IsString a) => a
      revName     = "r" <> fromString (show revNum)
      revPath     = "." </> "hackage" </> qualifiedName <.> "nix"
      prettyPname = fromPretty pname
      cabalHash   = Base16.encode $ hash cabalFile
  modify' $ mappend $ Seq.singleton
    (cabalFile, prettyPname ++ ".cabal", revPath)
  return (revName, mkNonRecSet
    [ "nix" $= mkSym "import" @@ mkSym (T.pack ("../hackage/" <> qualifiedName <> ".nix"))
    , "revNum" $= mkInt revNum
    , "sha256" $= mkStr (decodeUtf8 cabalHash)
    ])

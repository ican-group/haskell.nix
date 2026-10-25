{-# LANGUAGE PatternSynonyms #-}
module Freeze (projectFreezeConfig) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Distribution.Client.IndexUtils
import qualified Distribution.Client.InstallPlan as InstallPlan
import Distribution.Client.ProjectConfig
import Distribution.Client.ProjectPlanning
-- cabal 3.17: UserAnyQualifier/UserQualified moved from UserConstraintScope to the
-- new UserConstraintQualifier type (UserConstraintScope now also carries a Maybe Stage).
import Distribution.Client.Targets (UserConstraint (UserConstraint), UserConstraintQualifier (UserAnyQualifier, UserQualified), UserQualifier (UserQualToplevel))
import Distribution.Package
import Distribution.Simple.Flag (Flag, pattern Flag)
import Distribution.Solver.Types.ConstraintSource (ConstraintSource (ConstraintSourceFreeze))
import Distribution.Solver.Types.PackageConstraint (PackageProperty (PackagePropertyFlags, PackagePropertyVersion))
import Distribution.Types.Flag (FlagAssignment, nullFlagAssignment)
import Distribution.Version

--
-- From Distribution.Client.CmdFreeze (cabal-install-3.8.1.0)
--

-- | Given the install plan, produce a config value with constraints that
-- freezes the versions of packages used in the plan.
projectFreezeConfig ::
  ElaboratedInstallPlan ->
  TotalIndexState ->
  ActiveRepos ->
  ProjectConfig
projectFreezeConfig elaboratedPlan totalIndexState activeRepos0 =
  mempty
    { projectConfigShared =
        mempty
          { projectConfigConstraints =
              concat (Map.elems (projectFreezeConstraints elaboratedPlan)),
            projectConfigIndexState = Flag totalIndexState,
            projectConfigActiveRepos = Flag activeRepos
          }
    }
  where
    activeRepos :: ActiveRepos
    activeRepos = filterSkippedActiveRepos activeRepos0

-- | Given the install plan, produce solver constraints that will ensure the
-- solver picks the same solution again in future in different environments.
projectFreezeConstraints ::
  ElaboratedInstallPlan ->
  Map PackageName [(UserConstraint, ConstraintSource)]
projectFreezeConstraints plan =
  --
  -- TODO: [required eventually] this is currently an underapproximation
  -- since the constraints language is not expressive enough to specify the
  -- precise solution. See https://github.com/haskell/cabal/issues/3502.
  --
  -- For the moment we deal with multiple versions in the solution by using
  -- constraints that allow either version. Also, we do not include any
  -- /version/ constraints for packages that are local to the project (e.g.
  -- if the solution has two instances of Cabal, one from the local project
  -- and one pulled in as a setup deps then we exclude all constraints on
  -- Cabal, not just the constraint for the local instance since any
  -- constraint would apply to both instances). We do however keep flag
  -- constraints of local packages.
  --
  deleteLocalPackagesVersionConstraints
    (Map.unionWith (++) versionConstraints flagConstraints)
  where
    versionConstraints :: Map PackageName [(UserConstraint, ConstraintSource)]
    versionConstraints =
      Map.mapWithKey
        ( \p v ->
            [ ( UserConstraint (UserAnyQualifier p) (PackagePropertyVersion v),
                ConstraintSourceFreeze
              )
            ]
        )
        versionRanges

    versionRanges :: Map PackageName VersionRange
    versionRanges =
      Map.map simplifyVersionRange $
        Map.fromListWith unionVersionRanges $
          [ (packageName pkg, thisVersion (packageVersion pkg))
            | InstallPlan.PreExisting pkg <- InstallPlan.toList plan
          ]
            ++ [ (packageName pkg, thisVersion (packageVersion pkg))
                 | InstallPlan.Configured pkg <- InstallPlan.toList plan
               ]

    flagConstraints :: Map PackageName [(UserConstraint, ConstraintSource)]
    flagConstraints =
      Map.mapWithKey
        ( \p f ->
            [ ( UserConstraint (UserQualified UserQualToplevel p) (PackagePropertyFlags f),
                ConstraintSourceFreeze
              )
            ]
        )
        flagAssignments

    flagAssignments :: Map PackageName FlagAssignment
    flagAssignments =
      Map.fromList
        [ (pkgname, flags)
          | InstallPlan.Configured elab <- InstallPlan.toList plan,
            let flags = elabFlagAssignment elab
                pkgname = packageName elab,
            not (nullFlagAssignment flags)
        ]

    -- As described above, remove the version constraints on local packages,
    -- but leave any flag constraints.
    deleteLocalPackagesVersionConstraints ::
      Map PackageName [(UserConstraint, ConstraintSource)] ->
      Map PackageName [(UserConstraint, ConstraintSource)]
    deleteLocalPackagesVersionConstraints =
      Map.mergeWithKey
        ( \_pkgname () constraints ->
            case filter (not . isVersionConstraint . fst) constraints of
              [] -> Nothing
              constraints' -> Just constraints'
        )
        (const Map.empty)
        id
        localPackages

    isVersionConstraint (UserConstraint _ (PackagePropertyVersion _)) = True
    isVersionConstraint _ = False

    localPackages :: Map PackageName ()
    localPackages =
      Map.fromList
        [ (packageName elab, ())
          | InstallPlan.Configured elab <- InstallPlan.toList plan,
            -- cabal 3.17: elabLocalToProject was renamed elabIsSourcePackage.
            elabIsSourcePackage elab
        ]

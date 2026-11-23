# Caching your project's builds

Pushing your project's builds to your own binary cache (for instance
[Cachix](https://www.cachix.org/) or [Attic](https://github.com/zhaofengli/attic))
lets CI and your colleagues fetch them instead of building them again.

The catch with `haskell.nix` is that a project needs more than the closure
of its build outputs.  Before Nix can even work out how to build your
packages it builds things at *evaluation time*
([import from derivation](https://nix.dev/manual/nix/latest/language/import-from-derivation)):

* `plan-nix`: the Nix expressions generated from your `cabal.project` (or
  `stack.yaml`) by running `cabal` (or `stack-to-nix`), which needs a GHC,
  `cabal-install`, `nix-tools` and the Hackage index;
* `roots`: the tools and compiler dependencies the evaluation uses for your
  `compiler-nix-name`;
* any source filtering such as `cleanGit`.

None of these are inputs of your packages' derivations.  If you only push
the closure of, say, your executable, a fresh machine still has to build
all of them before it can even look your executable up in the cache.
(In a test project `plan-nix` alone had a 2841-path closure, and none of
it was in the executable's.)

## Pushing everything after a build

Build the parts of the project you want cached, then push the derivations
of those builds together with every output they needed.  With a flake made
from `project.flake` (as in the [template](getting-started.md#create-a-project-using-flakes)),
its `ciJobs` output has `roots` and `plan-nix` as well as the packages,
checks and shells:

```bash
sys=x86_64-linux
targets=".#ciJobs.$sys.roots .#ciJobs.$sys.plan-nix .#ciJobs.$sys.devShells.default .#hello:exe:hello"
nix build --no-link $targets
nix-store -qR --include-outputs $(nix path-info --derivation $targets) \
  | grep -v '\.drv$' \
  | cachix push mycache
```

`nix-store -qR --include-outputs` lists every derivation in the build
closure together with each of its outputs that is in your store, so it
covers both what you built and what you fetched to build it.  Instead of
`cachix push mycache`, use `attic push --stdin mycache` for Attic, or
`nix copy --stdin --to <store-url>` for any store Nix can write to (for
example `s3://my-bucket?region=eu-west-1` or `file:///path/to/cache`).

Without flakes, use the same attributes of your project:

```bash
attrs="-A roots -A plan-nix -A shell -A hsPkgs.hello.components.exes.hello"
nix-build --no-out-link $attrs
nix-store -qR --include-outputs $(nix-instantiate $attrs) \
  | grep -v '\.drv$' \
  | cachix push mycache
```

## Pushing while you build

The alternative is to push every path that appears in the store while a
command runs.  It picks up the evaluation-time builds too, without having
to name them:

```bash
cachix watch-exec mycache -- nix build .#hello:exe:hello
```

For Attic, run `attic watch-store mycache` in the background while you
build.

## Keeping the evaluation-time builds

Pushing is one half; the other is not garbage-collecting what you pushed
from your own machine or CI runner.  Building `roots` and `plan-nix` as
jobs (which `ciJobs` and `hydraJobs` do) keeps them alive on CI.  See
[How do I prevent the evaluation-time dependencies of my project from being garbage-collected?](../troubleshooting.md#how-do-i-prevent-the-evaluation-time-dependencies-of-my-project-from-being-garbage-collected)

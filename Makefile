.DEFAULT_GOAL := help

PYTHON ?= python3
TIMEOUT ?= 600
COMPILER ?= ghc9141
TEST_SUITE ?= unit-tests
SYSTEM ?= x86_64-linux
QEMU_ARG = $(if $(QEMU),--argstr qemu "$(QEMU)",)

.PHONY: help check test test-linux-cross-wrapper test-v2-cabal-overrides test-windows-basement-v1 test-windows-basement-v2 test-mingw-stdio test-qemu-linux-user test-qemu-arm32-personality test-elf-comdat-functions probe-rosetta-signals test-rosetta-signals verify

##@ Verification
check: ## Check whitespace, Nix syntax, emulator selection, and dependencies
	git diff --check
	nix-instantiate --parse builder/comp-v2-builder.nix >/dev/null
	nix-instantiate --parse builder/build-cabal-slice.nix >/dev/null
	nix-instantiate --parse builder/stage-cabal-file.nix >/dev/null
	nix-instantiate --parse test/v2-cabal-overrides.nix >/dev/null
	nix-instantiate --parse test/windows-basement.nix >/dev/null
	nix-instantiate --parse overlays/linux-cross.nix >/dev/null
	nix-instantiate --parse overlays/armv6l-linux.nix >/dev/null
	nix-instantiate --parse overlays/qemu-linux-user.nix >/dev/null
	nix-instantiate --parse overlays/haskell.nix >/dev/null
	nix-instantiate --parse test/default.nix >/dev/null
	nix-instantiate --parse test/annotations/default.nix >/dev/null
	nix-instantiate --parse modules/cabal-project.nix >/dev/null
	nix-instantiate --parse modules/stable-haskell-rts-comdat.nix >/dev/null
	nix-instantiate --parse test/elf-comdat-functions.nix >/dev/null
	nix-instantiate --extra-experimental-features flakes --eval --strict --expr 'import ./test/elf-comdat-scope.nix {}'
	nix-instantiate --parse test/qemu-linux-user.nix >/dev/null
	nix-instantiate --parse test/qemu-arm32-personality.nix >/dev/null
	nix-instantiate --eval --strict test/qemu-selection.nix
	nix-instantiate --eval --strict test/annotations/selection.nix
	nix-instantiate --eval --strict test/iserv-source-platform.nix -A passed
	nix-instantiate --eval --strict test/windows-system-libraries.nix
	nix-instantiate --eval --strict test/qemu-linux-user-inputs.nix -A passed
	nix-instantiate --parse test/rosetta-signals.nix >/dev/null
	nix-instantiate --parse overlays/mingw-stdio.nix >/dev/null
	nix-instantiate --parse test/mingw-stdio/default.nix >/dev/null
	nix-instantiate --eval --strict test/mingw-stdio/selection.nix

test: ## Run the existing test driver (COMPILER, TEST_SUITE, TIMEOUT)
	timeout -k 5 $(TIMEOUT) ./test/tests.sh $(COMPILER) $(TEST_SUITE)

test-linux-cross-wrapper: ## Test wrapper arguments, process ownership, and profiling selection
	$(PYTHON) test/linux-cross-wrapper.py

test-v2-cabal-overrides: ## Check revised metadata survives V2 source patches (SYSTEM, TIMEOUT)
	timeout -k 5 $(TIMEOUT) nix-build --no-out-link test/v2-cabal-overrides.nix --argstr system $(SYSTEM)

test-windows-basement-v1: ## Compile Windows Basement 0.0.16 through hsc2hs with builder V1 (SYSTEM, TIMEOUT)
	timeout -k 5 $(TIMEOUT) nix-build --no-out-link test/windows-basement.nix --argstr system $(SYSTEM) --arg builderVersion 1

test-windows-basement-v2: ## Compile Windows Basement 0.0.16 through hsc2hs with builder V2 (SYSTEM, TIMEOUT)
	timeout -k 5 $(TIMEOUT) nix-build --no-out-link test/windows-basement.nix --argstr system $(SYSTEM) --arg builderVersion 2

test-mingw-stdio: ## Test MinGW ISO swprintf under Wine (Linux SYSTEM, TIMEOUT)
	timeout -k 5 $(TIMEOUT) nix-build --no-out-link test/mingw-stdio --arg pkgs \
	  'let hn = import ./default.nix { system = "$(SYSTEM)"; }; in (import hn.sources.nixpkgs-unstable (hn.nixpkgsArgs // { system = "$(SYSTEM)"; })).pkgsCross.ucrt64'

verify: check test-linux-cross-wrapper ## Run syntax, dependency, and wrapper regressions

test-elf-comdat-functions: ## Test RTS COMDAT selection and duplicate rejection (native x86_64 Linux, TIMEOUT)
	timeout -k 5 $(TIMEOUT) nix-build --no-out-link test/default.nix --argstr compiler-nix-name ghc914-sh -A elf-comdat-functions.run

##@ Linux emulator diagnostics
probe-rosetta-signals: ## Record host signal behavior without requiring compliant Rosetta behavior (SYSTEM)
	timeout -k 5 $(TIMEOUT) nix-build --no-out-link test/rosetta-signals.nix --argstr system $(SYSTEM)

test-rosetta-signals: ## Require correct Linux host signal behavior (SYSTEM)
	timeout -k 5 $(TIMEOUT) nix-build --no-out-link test/rosetta-signals.nix --argstr system $(SYSTEM) --arg check true

test-qemu-linux-user: ## Check guest code updates and real fault exits (SYSTEM, optional QEMU store path)
	timeout -k 5 $(TIMEOUT) nix-build --no-out-link test/qemu-linux-user.nix --argstr system $(SYSTEM) $(QEMU_ARG)

test-qemu-arm32-personality: ## Check Android ARM32 startup and per-task personality (SYSTEM, optional QEMU store path)
	timeout -k 5 $(TIMEOUT) nix-build --no-out-link test/qemu-arm32-personality.nix --argstr system $(SYSTEM) $(QEMU_ARG)

##@ Help
help: ## Show targets and their parameters
	@awk 'BEGIN { FS = ":.*##"; color = (ENVIRON["TERM"] != "" && ENVIRON["TERM"] != "dumb"); if (color) { cyan = "\033[36m"; reset = "\033[0m" } } /^##@/ { printf "\n%s\n", substr($$0, 5) } /^[a-zA-Z0-9_-]+:.*##/ { printf "  %s%-24s%s %s\n", cyan, $$1, reset, $$2 }' $(MAKEFILE_LIST)

.DEFAULT_GOAL := help
.NOTPARALLEL:
GHC ?= ghc
GHC_PKG ?=
GHC_SOURCE ?=
WORK ?= .work
VARIANT ?= capped
EXTRA_GHC_FLAGS ?=
BOUNDED = python3 ../rosetta-poll-fork/run-bounded.py
FIXTURE_TOOL_ENV = env -u GHC_PACKAGE_PATH GHC_ENVIRONMENT=-

.PHONY: help metadata-check source-check check
help: ## Show separate preparation and future semantic checks
	@printf '%s\n' 'make source-check GHC_SOURCE=/retained/exact/ghc/source [WORK=.work-source]' 'Copies one source file and applies the patch; no compiler, fetch, or workload.' 'make metadata-check: test the private registration transformation without ghc-pkg.' 'make check GHC=/matching/selected/ghc GHC_PKG=/matching/selected/ghc-pkg VARIANT=original|capped [WORK=.work-test]' 'Explicit future action: private DB metadata 15s per command, compile 120s, fake-backend semantic test 20s. No Rosetta test.'

metadata-check: ## Check the private package-registration transformation only
	@python3 expose-fixture-modules.py --self-test

source-check: ## Check patch applicability against the exact retained source
	@test -f "$(GHC_SOURCE)/libraries/ghc-internal/src/GHC/Internal/Event/TimerManager.hs"
	@mkdir "$(WORK)"
	@mkdir -p "$(WORK)/source/src/GHC/Internal/Event"
	@cp "$(GHC_SOURCE)/libraries/ghc-internal/src/GHC/Internal/Event/TimerManager.hs" "$(WORK)/source/src/GHC/Internal/Event/TimerManager.hs"
	@$(BOUNDED) "$(WORK)/apply-patch" 15 patch --batch --fuzz=0 -p1 -d "$(WORK)/source" < ../../overlays/patches/ghc914-timer-manager-wait-cap.patch

check: ## Compile against the selected compiler's own ghc-internal and check semantics
	@case "$(VARIANT)" in original|capped) ;; *) exit 2 ;; esac
	@test -n "$(GHC_PKG)"
	@mkdir "$(WORK)"
	@mkdir "$(WORK)/build"
	@$(BOUNDED) "$(WORK)/package-info" 15 $(FIXTURE_TOOL_ENV) "$(GHC_PKG)" --no-user-package-db --expand-pkgroot describe ghc-internal
	@python3 expose-fixture-modules.py "$(WORK)/package-info.log" "$(WORK)/ghc-internal.conf"
	@$(BOUNDED) "$(WORK)/db-init" 15 $(FIXTURE_TOOL_ENV) "$(GHC_PKG)" init "$(WORK)/package.conf.d"
	@$(BOUNDED) "$(WORK)/db-update" 15 $(FIXTURE_TOOL_ENV) "$(GHC_PKG)" --no-user-package-db --package-db "$(WORK)/package.conf.d" update "$(WORK)/ghc-internal.conf"
	@$(BOUNDED) "$(WORK)/compile" 120 $(FIXTURE_TOOL_ENV) nice -n 19 "$(GHC)" --make -fforce-recomp -v0 -j1 -O0 -threaded -no-user-package-db -package-db "$(WORK)/package.conf.d" -package ghc-internal $(EXTRA_GHC_FLAGS) -package-env - -odir "$(WORK)/build" -hidir "$(WORK)/build" TimerManagerWaitCap.hs -o "$(WORK)/timer-manager-wait-cap"
	@$(BOUNDED) "$(WORK)/semantics" 20 "$(WORK)/timer-manager-wait-cap" "$(VARIANT)"

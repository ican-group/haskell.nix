CC ?= cc
CFLAGS ?= -O2
WARNINGS = -std=c11 -Werror=vla -pedantic -Wall -Wextra -Werror

.PHONY: help build handoff-source build-handoff clean
help: ## Show available targets
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ {printf "%-12s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

build: poll_fork ## Build the Linux poll/fork harness

poll_fork: poll_fork.c
	$(CC) $(CFLAGS) $(WARNINGS) -pthread -o $@ $<

handoff-source: build/poll_fork_handoff.c ## Reconstruct the exact timeout-rescue capture source

build-handoff: poll_fork_handoff ## Build the optional post-ACK phase-sweep variant

build/poll_fork_handoff.c: poll_fork.c post-ack-work.patch
	mkdir -p build
	cp poll_fork.c $@.tmp
	patch --batch --fuzz=0 $@.tmp < post-ack-work.patch
	mv $@.tmp $@

poll_fork_handoff: build/poll_fork_handoff.c
	$(CC) $(CFLAGS) $(WARNINGS) -pthread -o $@ $<

clean: ## Remove local executables and generated variant source
	rm -f poll_fork poll_fork_handoff build/poll_fork_handoff.c build/poll_fork_handoff.c.tmp

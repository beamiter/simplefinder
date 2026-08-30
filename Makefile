.PHONY: check build fmt clippy test test-daemon check-guards vim-test vim-core defcompile core-verify

check: core-verify fmt clippy test test-daemon check-guards defcompile vim-core vim-test

build:
	cargo build --release --locked

fmt:
	cargo fmt --all -- --check

clippy:
	cargo clippy --all-targets --locked -- -D warnings

test:
	cargo test --locked

# `--self-test` is the only gate install-common.sh applies to a freshly built
# binary (SIMPLECORE_VERIFY=self-test), and nothing here ran it -- so when that
# self-test degenerated into re-checking the constant it had just written,
# there was no target that would have noticed.  simpleminimap and
# simplemarkdown have carried this target all along.
test-daemon: build
	./target/release/simplefinder-daemon --self-test
	./target/release/simplefinder-daemon --help >/dev/null
	./target/release/simplefinder-daemon --version >/dev/null

# Four suites used to fall back target/debug -> lib/ and then `qall!` with
# nothing on stderr, which is indistinguishable from a pass: anything that
# stopped the daemon being built would have taken 84 assertions with it and
# left `make check` printing the same output as a full run.  Every gated suite
# is run here from a tree with neither the daemon nor the fake daemons in it.
# The four that need the real binary have to name themselves on stderr and exit
# non-zero; the ones whose precondition is genuinely optional have to print the
# SKIP line vim_tabs.vim introduced.
check-guards:
	@set -e; \
	tmp="$$(mktemp -d)"; trap 'rm -rf "$$tmp"' EXIT; mkdir -p "$$tmp/tests"; \
	for suite in vim_symbols vim_grep vim_globs vim_health; do \
	  cp "tests/$$suite.vim" "$$tmp/tests/"; \
	  if vim -Nu NONE -n -i NONE -es -S "$$tmp/tests/$$suite.vim" \
	      >/dev/null 2>"$$tmp/err"; then \
	    echo "tests/$$suite.vim: exited 0 with no daemon to test against" >&2; \
	    exit 1; \
	  fi; \
	  grep -q "tests/$$suite.vim" "$$tmp/err" || { \
	    echo "tests/$$suite.vim: gave up without saying so on stderr" >&2; \
	    exit 1; \
	  }; \
	done; \
	for suite in vim_cache vim_stream vim_tabs vim_negotiate; do \
	  cp "tests/$$suite.vim" "$$tmp/tests/"; \
	  vim -Nu NONE -n -i NONE -es -S "$$tmp/tests/$$suite.vim" \
	    >/dev/null 2>"$$tmp/err" \
	    || { echo "tests/$$suite.vim: a skipped precondition must not fail" >&2; \
	         exit 1; }; \
	  grep -q "^SKIP tests/$$suite.vim" "$$tmp/err" || { \
	    echo "tests/$$suite.vim: skipped without saying so on stderr" >&2; \
	    exit 1; \
	  }; \
	done; \
	echo "guards: every gated suite reports its own absence"

vim-test:
	cargo build --locked
	vim -Nu NONE -n -i NONE -es -S tests/vim_smoke.vim
	vim -Nu NONE -n -i NONE -es -S tests/vim_remote.vim
	vim -Nu NONE -n -i NONE -es -S tests/vim_symbols.vim
	vim -Nu NONE -n -i NONE -es -S tests/vim_globs.vim
	vim -Nu NONE -n -i NONE -es -S tests/vim_grep.vim
	vim -Nu NONE -n -i NONE -es -S tests/vim_stream.vim
	vim -Nu NONE -n -i NONE -es -S tests/vim_prompt.vim
	vim -Nu NONE -n -i NONE -es -S tests/vim_preview.vim
	vim -Nu NONE -n -i NONE -es -S tests/vim_pick.vim
	vim -Nu NONE -n -i NONE -es -S tests/vim_cache.vim
	vim -Nu NONE -n -i NONE -es -S tests/vim_tabs.vim
	vim -Nu NONE -n -i NONE -es -S tests/vim_negotiate.vim
	vim -Nu NONE -n -i NONE -es -S tests/vim_health.vim

# ---------------------------------------------------------------------------
# simplecore: the vendored daemon supervisor shared by the simple* suite.
#   https://github.com/beamiter/simplecore
# Regenerate with ../.simplecore/vendor.sh; never edit autoload/simplefinder/core.vim.
#
# These lines are vendored too.  They are the tail of this Makefile — nothing
# above the banner belongs to the bundle — and `.simplecore.manifest` records
# them as a `footer` fragment.  Until it did, they were the one bundle member
# copied by hand and hashed by nothing, so core-verify could not see them
# drift; nine plugins carried an installer in the same position.
# ---------------------------------------------------------------------------

# The bundle is copied into each plugin rather than shared by reference, so
# that every plugin stays independently installable.  Copies drift silently
# unless something checks them, and one such copy went unnoticed long enough
# for the whole .simplecore directory to go missing before it had a repository
# of its own: .simplecore.manifest pins the sha256 of every vendored file, and
# this target fails the build when a copy no longer matches.
#
#   git clone https://github.com/beamiter/simplecore ../.simplecore
#   ../.simplecore/vendor.sh --check    # suite-wide drift
#   ../.simplecore/vendor.sh            # re-vendor
#
# Whole files are plain `sha256sum -c` records.  A fragment — a run of lines
# inside a file the plugin itself owns, like this footer — is recorded as
# `footer <lines> <sha256>  <path>` and checked against the tail of <path>.
core-verify:
	@records=$$(grep -cE '^[0-9a-f]{64}' .simplecore.manifest); \
	checked=$$(grep -cE '^[0-9a-f]{64}  ' .simplecore.manifest); \
	test "$$records" = "$$checked" || { \
	  echo ".simplecore.manifest: $$((records - checked)) hash record(s) not checked" >&2; \
	  echo "  a record whose separator is not exactly two spaces is dropped by the" >&2; \
	  echo "  reader below and would verify green while its file went unchecked." >&2; \
	  exit 1; }
	@grep -E '^[0-9a-f]{64}  ' .simplecore.manifest | sha256sum -c --quiet
	@awk '$$1 == "footer" { print $$2, $$3, $$4 }' .simplecore.manifest \
	| while read -r lines sum path; do \
		test "$$(tail -n "$$lines" "$$path" | sha256sum | cut -d' ' -f1)" = "$$sum" \
		|| { echo "$$path: FAILED (simplecore footer)" >&2; exit 1; }; \
	done
	@echo "simplecore: bundle v$$(awk '$$1 == "version" { print $$2 }' .simplecore.manifest) verified"

# core-verify proves this repository is internally consistent: every vendored
# copy still matches the manifest written beside it.  It cannot prove freshness.
# A plugin that misses a re-vendor keeps verifying its own stale copy for ever,
# and stays green doing it, because the bundle is deliberately not required to
# be present for the build to work.  This target is the other half, for when it
# is present; `check` cannot depend on it without making the bundle a build
# dependency, which is the coupling the vendoring exists to avoid.
SIMPLECORE_DIR ?= ../.simplecore
core-fresh:
	@if [ -x "$(SIMPLECORE_DIR)/vendor.sh" ]; then \
	  SIMPLECORE_SUITE="$(patsubst %/,%,$(dir $(CURDIR)))" \
	    "$(SIMPLECORE_DIR)/vendor.sh" --check "$(notdir $(CURDIR))"; \
	else \
	  echo "simplecore: $(SIMPLECORE_DIR) is not checked out; freshness unverified"; \
	fi

# Supervisor regression suite: liveness, generation guards, backoff restarts,
# the crash-loop breaker, request timeouts, and both outcomes of the protocol
# handshake — the reply that lands, and the deadline that expires and fails the
# start.
vim-core:
	vim -Nu NONE -n -i NONE -es -S tests/vim_core.vim

# Vim9 compiles def bodies lazily, so a type error in a cold branch stays
# hidden until a user reaches it.  :defcompile surfaces it here instead.
defcompile:
	vim -Nu NONE -n -i NONE -es -S tests/defcompile.vim

.PHONY: core-verify core-fresh vim-core defcompile

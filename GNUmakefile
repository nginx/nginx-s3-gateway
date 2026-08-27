MAKE_MAJOR_VER    := $(shell echo $(MAKE_VERSION) | cut -d'.' -f1)

ifneq ($(shell test $(MAKE_MAJOR_VER) -gt 3; echo $$?),0)
$(error Make version $(MAKE_VERSION) is not supported, please install GNU Make 4.x)
endif

# Strict shell and Make settings for robust recipes
SHELL             := bash
.SHELLFLAGS       := -eu -o pipefail -c
.DELETE_ON_ERROR:
MAKEFLAGS         += --warn-undefined-variables
MAKEFLAGS         += --no-builtin-rules
.DEFAULT_GOAL     := help

# Directory containing this Makefile (with trailing slash)
BASE_DIR          := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

AWK               ?= $(shell command -v gawk 2> /dev/null || command -v awk 2> /dev/null)
# xdg-open first: a bare `open` on Linux is usually kbd's openvt, not a file opener
OPEN_CMD          ?= $(shell command -v xdg-open 2> /dev/null || echo open)

# --- User-tunable variables (override via environment or `make VAR=value`) ---
# NOTE: comments must stay on their own line -- GNU make keeps the whitespace
# before an inline `#` as part of the value, which corrupts docker tags.

# Docker CLI used by the build, test, and clean targets. Passed through to
# the test runner scripts under test/.
DOCKER            ?= docker

# NGINX flavor to build and test: oss or plus
NGINX_TYPE        ?= oss

# S3 addressing style exercised by the integration tests: virtual, virtual-v2,
# or path
S3_STYLE          ?= virtual-v2

# Output directory for generated JSDoc documentation
DOCS_DIR          ?= reference

# --- Internal constants ---

# The floating image tag. NOT tunable (override keeps even command-line
# assignments from changing it): Dockerfile.latest-njs and
# Dockerfile.unprivileged build FROM this literal name, and
# test/docker-compose.yaml runs it by this literal name. Parameterize those
# files before turning this into a knob.
override IMAGE_NAME := nginx-s3-gateway

# Passed through to test/run_integration_tests.sh (which defaults to the
# same value), so the suite and the `clean` teardown share one project name.
COMPOSE_PROJECT   := ngt
COMPOSE_FILE      := $(BASE_DIR)test/docker-compose.yaml
DYNAMIC_CREDENTIALS_COMPOSE_FILE := $(BASE_DIR)test/docker-compose.dynamic-credentials.yaml
PLUS_CRT          := $(BASE_DIR)plus/etc/ssl/nginx/nginx-repo.crt
PLUS_KEY          := $(BASE_DIR)plus/etc/ssl/nginx/nginx-repo.key
DOCKERFILES       := Dockerfile.oss Dockerfile.plus Dockerfile.latest-njs Dockerfile.unprivileged
# Wildcards (not `git ls-files`) so new entrypoint/test-runner/integration
# scripts are linted automatically while lint still works without git or a .git directory
# (release tarballs, docker contexts). Anchored to BASE_DIR and converted back
# to repo-relative paths because the shellcheck recipe cds into BASE_DIR.
SHELL_SCRIPTS     := test.sh \
                     standalone_ubuntu_oss_install.sh \
                     $(patsubst $(BASE_DIR)%,%,$(wildcard $(BASE_DIR)test/*.sh)) \
                     $(patsubst $(BASE_DIR)%,%,$(wildcard $(BASE_DIR)test/integration/*.sh)) \
                     $(patsubst $(BASE_DIR)%,%,$(wildcard $(BASE_DIR)common/docker-entrypoint.d/*.sh)) \
                     $(patsubst $(BASE_DIR)%,%,$(wildcard $(BASE_DIR)common/docker-entrypoint.d/*.envsh))

# Pre-existing shellcheck findings in scripts this Makefile must not modify:
# SC2027/SC2034/SC2140 in test/integration/test_api.sh and SC2068 in the sh
# entrypoint/standalone install scripts. New scripts must lint clean.
SHELLCHECK_EXCLUDES := SC2027,SC2034,SC2068,SC2140

# Single line on purpose: checkmake's parser does not follow continuations
.PHONY: help check-tools check-nginx-type check-s3-style check-plus-creds build build-oss build-plus build-latest-njs build-unprivileged test test-unit test-integration test-latest-njs test-unprivileged test-matrix test-matrix-plus retest retest-latest-njs retest-unprivileged lint makefile-check shellcheck lint-md fmt-md hadolint docs docs-open jsdoc clean clean-images all ci

##@ Help

help: ## Display this grouped target list (default goal)
	@$(AWK) 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m [VAR=value ...]\n"} \
		/^[a-zA-Z0-9_-]+:.*##/ { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 } \
		/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)
	@printf "\nCurrent settings: NGINX_TYPE=%s S3_STYLE=%s\n\n" \
		"$(NGINX_TYPE)" "$(S3_STYLE)"

##@ Prerequisites

check-tools: ## Verify required build and test tooling is present
	@ok=1; \
	for tool in $(DOCKER) curl; do \
		command -v "$$tool" > /dev/null 2>&1 || { echo "MISSING (required): $$tool"; ok=0; }; \
	done; \
	{ $(DOCKER) compose version > /dev/null 2>&1 || command -v docker-compose > /dev/null 2>&1; } || \
		{ echo "MISSING (required): docker compose plugin (or legacy docker-compose)"; ok=0; }; \
	if ! command -v mc > /dev/null 2>&1 && [ ! -x "$(BASE_DIR).bin/mc" ]; then \
		echo "MISSING (required): mc (MinIO client, used as the generic S3 test client) - or place the binary at ./.bin/mc"; ok=0; \
	fi; \
	if ! command -v md5sum > /dev/null 2>&1 && ! command -v md5 > /dev/null 2>&1; then \
		echo "MISSING (required): md5sum (or md5 on macOS)"; ok=0; \
	fi; \
	for tool in npx checkmake shellcheck rumdl; do \
		command -v "$$tool" > /dev/null 2>&1 || echo "missing (optional, needed for lint/docs): $$tool"; \
	done; \
	for tool in hadolint jq; do \
		command -v "$$tool" > /dev/null 2>&1 || echo "missing (optional): $$tool"; \
	done; \
	if [ "$$ok" -eq 1 ]; then echo "All required tools are present"; else exit 3; fi

# Internal: validate NGINX_TYPE where it is consumed. Deliberately a recipe
# rather than a parse-time $(error) so that unrelated targets (help, clean,
# lint, docs) still work when a stray NGINX_TYPE is exported in the shell.
check-nginx-type:
	@case "$(NGINX_TYPE)" in \
		oss|plus) ;; \
		*) echo "ERROR: Invalid NGINX_TYPE '$(NGINX_TYPE)' - must be 'oss' or 'plus'"; exit 2;; \
	esac

# Internal: validate S3_STYLE where the test harness consumes it, mirroring
# check-nginx-type. Every downstream consumer fails open - an unrecognized
# style silently selects virtual-style addressing (01-set-defaults.envsh,
# s3gateway.js) - so a typo here or in the CI matrix would otherwise produce
# a green run that tested the wrong style. Harness-only: the runtime image
# additionally accepts 'default' (see docs/getting_started.md), which the
# test suite never uses.
check-s3-style:
	@case "$(S3_STYLE)" in \
		virtual|virtual-v2|path) ;; \
		*) echo "ERROR: Invalid S3_STYLE '$(S3_STYLE)' - must be 'virtual', 'virtual-v2' or 'path'"; exit 2;; \
	esac

# Internal: fail fast with actionable errors when NGINX Plus credentials are absent
check-plus-creds:
	@[ -f "$(PLUS_CRT)" ] || { \
		echo "ERROR: NGINX Plus certificate not found: $(PLUS_CRT)"; \
		echo "       Copy your nginx-repo.crt there (see docs/development.md)"; \
		exit 3; }
	@[ -f "$(PLUS_KEY)" ] || { \
		echo "ERROR: NGINX Plus key not found: $(PLUS_KEY)"; \
		echo "       Copy your nginx-repo.key there (see docs/development.md)"; \
		exit 3; }
	@[ -f /etc/nginx/license.jwt ] || [ -f "$(BASE_DIR)license.jwt" ] || \
		echo "WARNING: license.jwt not found at /etc/nginx/license.jwt or ./license.jwt - integration tests will fail without it"

##@ Build

build: check-nginx-type build-$(NGINX_TYPE) ## Build the gateway image for NGINX_TYPE (oss default, or plus)

build-oss: ## Build the NGINX OSS gateway image
	cd "$(BASE_DIR)" && $(DOCKER) build -f Dockerfile.oss \
		--tag $(IMAGE_NAME) --tag $(IMAGE_NAME):oss .

# Dockerfile.plus pulls from private-registry.nginx.com, which requires a
# docker login (not BuildKit secrets). --load is required so the tags reach
# the local daemon even when the selected buildx builder uses the
# docker-container driver; without it the build lands only in the build cache.
build-plus: check-plus-creds ## Build the NGINX Plus gateway image (requires nginx-repo certs)
	@$(DOCKER) buildx version > /dev/null 2>&1 || { \
		echo "ERROR: docker buildx is required to build the NGINX Plus image"; exit 4; }
	cd "$(BASE_DIR)" && DOCKER_BUILDKIT=1 $(DOCKER) buildx build -f Dockerfile.plus --load \
		--tag $(IMAGE_NAME) --tag $(IMAGE_NAME):plus .

# Variant images build FROM the floating $(IMAGE_NAME) tag and then retag it.
# Each variant recipe first pins the floating tag back to the clean
# :$(NGINX_TYPE) base image, so variants never layer on top of each other --
# including when both variant targets run in one make invocation, where the
# phony `build` prerequisite is deduplicated and runs only once. Stacking the
# two variants on one image is deliberately unsupported (CI never exercised
# that combination when the legacy test.sh still allowed it).
build-latest-njs: build ## Layer the latest njs build onto the NGINX_TYPE image
	$(DOCKER) tag $(IMAGE_NAME):$(NGINX_TYPE) $(IMAGE_NAME)
	cd "$(BASE_DIR)" && $(DOCKER) build -f Dockerfile.latest-njs \
		--tag $(IMAGE_NAME) --tag $(IMAGE_NAME):latest-njs-$(NGINX_TYPE) .

build-unprivileged: build ## Layer the unprivileged modifications onto the NGINX_TYPE image
	$(DOCKER) tag $(IMAGE_NAME):$(NGINX_TYPE) $(IMAGE_NAME)
	cd "$(BASE_DIR)" && $(DOCKER) build -f Dockerfile.unprivileged \
		--tag $(IMAGE_NAME) --tag $(IMAGE_NAME):unprivileged-$(NGINX_TYPE) .

##@ Test (build + test)

test: build ## Build NGINX_TYPE then run the full unit + integration suite
	@$(MAKE) --no-print-directory retest

test-latest-njs: build-latest-njs ## Build the latest-njs variant then test it
	@$(MAKE) --no-print-directory retest-latest-njs

test-unprivileged: build-unprivileged ## Build the unprivileged variant then test it
	@$(MAKE) --no-print-directory retest-unprivileged

# S3_STYLE and NGINX_TYPE are passed as explicit sub-make arguments (not env
# prefixes) so they take precedence over command-line variables a user passed
# to this invocation, which would otherwise leak into sub-makes via MAKEFLAGS.
# The retest legs must stay ahead of the variant legs: test-latest-njs and
# test-unprivileged retag the floating image, which retest's NONVARIANT_GUARD
# then rejects.
test-matrix: build ## Reproduce the CI matrix locally: {virtual,virtual-v2,path} + latest-njs + unprivileged
	$(MAKE) retest NGINX_TYPE=$(NGINX_TYPE) S3_STYLE=virtual
	$(MAKE) retest NGINX_TYPE=$(NGINX_TYPE) S3_STYLE=virtual-v2
	$(MAKE) retest NGINX_TYPE=$(NGINX_TYPE) S3_STYLE=path
	$(MAKE) test-latest-njs NGINX_TYPE=$(NGINX_TYPE) S3_STYLE=virtual-v2
	$(MAKE) test-unprivileged NGINX_TYPE=$(NGINX_TYPE) S3_STYLE=virtual-v2
	@echo "$(NGINX_TYPE) test matrix passed"

test-matrix-plus: ## Run the same matrix against NGINX Plus (certs + license.jwt required)
	$(MAKE) test-matrix NGINX_TYPE=plus

##@ Test (no rebuild)

# Single source for the runner invocation contracts (see the script headers
# in test/ for the full environment documentation). Both run against whatever
# image is currently tagged as the floating IMAGE_NAME tag; S3_STYLE reaches
# the integration environment through docker-compose interpolation. The
# variant retest targets flip the runners' NJS_LATEST/UNPRIVILEGED knobs
# (default 0) with an env prefix on the recipe line.
RUN_UNIT_TESTS = DOCKER="$(DOCKER)" IMAGE_NAME="$(IMAGE_NAME)" \
	"$(BASE_DIR)test/run_unit_tests.sh"
RUN_INTEGRATION_TESTS = DOCKER="$(DOCKER)" NGINX_TYPE="$(NGINX_TYPE)" \
	S3_STYLE="$(S3_STYLE)" COMPOSE_PROJECT="$(COMPOSE_PROJECT)" \
	"$(BASE_DIR)test/run_integration_tests.sh"

# Inverse of VARIANT_GUARD below: the non-variant targets must not drive a
# floating tag that is actually the named variant image, or the run fails
# bafflingly instead of with this error (unit tests pass the stable
# `-t module` flag the latest-njs CLI dropped; integration maps host 8989 to
# port 80 while the unprivileged image listens on 8080). Checked per runner:
# unit tests only care about the njs flavor, integration only about the port.
NONVARIANT_GUARD = @variant_id="$$($(DOCKER) image inspect -f '{{.Id}}' $(IMAGE_NAME):$(1)-$(NGINX_TYPE) 2> /dev/null || true)"; \
	floating_id="$$($(DOCKER) image inspect -f '{{.Id}}' $(IMAGE_NAME) 2> /dev/null || true)"; \
	if [ -n "$$variant_id" ] && [ "$$floating_id" = "$$variant_id" ]; then \
	echo "ERROR: '$(IMAGE_NAME)' currently points at the $(1)-$(NGINX_TYPE) variant image; run 'make build' first (or 'make retest-$(1)')"; exit 2; fi

test-unit: ## Run only the njs unit tests against the currently tagged image
	$(call NONVARIANT_GUARD,latest-njs)
	$(RUN_UNIT_TESTS)

test-integration: check-nginx-type check-s3-style check-tools ## Run only the integration suite against the currently tagged image
	$(call NONVARIANT_GUARD,unprivileged)
	$(RUN_INTEGRATION_TESTS)

# check-tools fails fast on a missing integration dependency (mc, curl,
# compose, md5sum) before the unit suite spends a minute in docker, matching
# the up-front dependency checks the legacy test.sh ran at startup.
retest: check-nginx-type check-s3-style check-tools ## Test the currently tagged image without rebuilding
	$(call NONVARIANT_GUARD,latest-njs)
	$(call NONVARIANT_GUARD,unprivileged)
	$(RUN_UNIT_TESTS)
	$(RUN_INTEGRATION_TESTS)

# Guard the variant retests: NJS_LATEST/UNPRIVILEGED change how the runners
# drive the image (njs -m unit-test flag, port 8080), so running them against
# a non-variant floating tag produces baffling failures instead of this error.
VARIANT_GUARD = @variant_id="$$($(DOCKER) image inspect -f '{{.Id}}' $(IMAGE_NAME):$(1)-$(NGINX_TYPE) 2> /dev/null || true)"; \
	floating_id="$$($(DOCKER) image inspect -f '{{.Id}}' $(IMAGE_NAME) 2> /dev/null || true)"; \
	{ [ -n "$$variant_id" ] && [ "$$floating_id" = "$$variant_id" ]; } || { \
	echo "ERROR: '$(IMAGE_NAME)' is not the $(1)-$(NGINX_TYPE) variant image; run 'make build-$(1)' (or 'make test-$(1)') first"; exit 2; }

retest-latest-njs: check-nginx-type check-s3-style check-tools ## Test the current image with latest-njs semantics, no rebuild
	$(call VARIANT_GUARD,latest-njs)
	NJS_LATEST=1 $(RUN_UNIT_TESTS)
	$(RUN_INTEGRATION_TESTS)

retest-unprivileged: check-nginx-type check-s3-style check-tools ## Test the current image in unprivileged mode, no rebuild
	$(call VARIANT_GUARD,unprivileged)
	$(RUN_UNIT_TESTS)
	UNPRIVILEGED=1 $(RUN_INTEGRATION_TESTS)

##@ Lint

lint: makefile-check shellcheck lint-md ## Run all linters (checkmake + shellcheck + rumdl)
	@echo "All lints passed"

makefile-check: ## Lint this Makefile with checkmake
	cd "$(BASE_DIR)" && checkmake --config .checkmake.ini GNUmakefile

shellcheck: ## Lint shell scripts (pre-existing findings excluded, see SHELLCHECK_EXCLUDES)
	cd "$(BASE_DIR)" && shellcheck --severity=warning \
		--exclude=$(SHELLCHECK_EXCLUDES) $(SHELL_SCRIPTS)

lint-md: ## Lint Markdown docs with rumdl (report only, config in .rumdl.toml)
	cd "$(BASE_DIR)" && rumdl check .

fmt-md: ## Apply rumdl's automatic Markdown formatting fixes in place
	cd "$(BASE_DIR)" && rumdl fmt .

hadolint: ## Lint Dockerfiles with hadolint when installed (opt-in, not part of lint)
	@if command -v hadolint > /dev/null 2>&1; then \
		cd "$(BASE_DIR)" && hadolint $(DOCKERFILES); \
	else \
		echo "hadolint is not installed - skipping Dockerfile lint (https://github.com/hadolint/hadolint)"; \
	fi

##@ Documentation

# NOTE: jsdoc exits non-zero on template warnings; the `|| true` suppression
# keeps doc generation best-effort so warnings never fail `make all`.
docs: ## Generate JSDoc reference documentation into DOCS_DIR
	cd "$(BASE_DIR)" && npx jsdoc -c jsdoc/conf.json -d "$(DOCS_DIR)" || true

docs-open: docs ## Generate documentation and open it in a browser
	$(OPEN_CMD) "$(BASE_DIR)$(DOCS_DIR)/index.html"

jsdoc: docs ## Back-compat alias for docs (previous Makefile's target name)

##@ Maintenance

# The DOCS_DIR guard rejects empty, absolute, parent-traversal, and
# trailing-slash values so the rm -rf can never escape the repository (a
# trailing slash would make rm follow a symlinked DOCS_DIR into its target).
# The teardown mirrors the profile-aware compose_dynamic_credentials()
# invocation in test/run_integration_tests.sh, including its docker-compose
# fallback, so it removes the fixed metadata network as well as the regular
# stack. It also removes the mc alias that script registers and the TLS cert
# scratch directory its finish() trap normally cleans (a killed test run
# never reaches finish()). The generated keys in there are root-owned, so a
# plain rm is tried first (it works while the directory itself is
# user-owned) with a root-container fallback, the same way finish() does.
clean: ## Remove generated docs and tear down the test compose environment
	@case "$(DOCS_DIR)" in \
		""|.|..|/*|*..*|*/) echo "ERROR: refusing to rm -rf suspicious DOCS_DIR '$(DOCS_DIR)'"; exit 1;; \
	esac
	rm -rf -- "$(BASE_DIR)$(DOCS_DIR)"
	@if $(DOCKER) compose version > /dev/null 2>&1; then compose_cmd="$(DOCKER) compose"; \
	else compose_cmd="docker-compose"; fi; \
	COMPOSE_COMPATIBILITY=true \
		$$compose_cmd --profile dynamic-credentials \
		-f "$(COMPOSE_FILE)" -f "$(DYNAMIC_CREDENTIALS_COMPOSE_FILE)" -p $(COMPOSE_PROJECT) \
		down --volumes --remove-orphans 2> /dev/null || true
	@mc_cmd="$$(command -v mc || echo "$(BASE_DIR).bin/mc")"; \
	[ -x "$$mc_cmd" ] && "$$mc_cmd" alias rm $(COMPOSE_PROJECT)_rustfs_1 2> /dev/null || true
	@tls_dir="$${TMPDIR:-/tmp}/nginx-s3-gateway-$(COMPOSE_PROJECT)-tls"; \
	if [ -d "$$tls_dir" ]; then \
		rm -f "$$tls_dir"/* 2> /dev/null || true; \
		if [ -n "$$(ls -A "$$tls_dir" 2> /dev/null)" ]; then \
			$(DOCKER) run --rm --user 0:0 -v "$$tls_dir:/certs" \
				--entrypoint /bin/sh "$(IMAGE_NAME)" -c 'rm -f /certs/*' > /dev/null 2>&1 || true; \
		fi; \
		rmdir "$$tls_dir" 2> /dev/null || true; \
	fi

clean-images: ## Remove all locally built gateway image tags
	@for tag in latest oss plus latest-njs-oss latest-njs-plus unprivileged-oss unprivileged-plus; do \
		$(DOCKER) rmi "$(IMAGE_NAME):$$tag" 2> /dev/null || true; \
	done

##@ Combined

all: lint test docs ## Lint, build, test, and generate docs

ci: ## Full local CI parity: lint then the complete test matrix (oss default)
	$(MAKE) lint
	$(MAKE) test-matrix

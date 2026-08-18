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

# Docker CLI used by the build/clean targets. Caveat: the retest* targets
# delegate to test.sh, which always uses `docker` from PATH, so pointing this
# at another CLI (e.g. podman) only affects builds, not the test flows.
DOCKER            ?= docker

# NGINX flavor to build and test: oss or plus
NGINX_TYPE        ?= oss

# S3 addressing style exercised by the integration tests: virtual or virtual-v2
S3_STYLE          ?= virtual-v2

# Output directory for generated JSDoc documentation
DOCS_DIR          ?= reference

# --- Internal constants ---

# The floating image tag. NOT tunable (override keeps even command-line
# assignments from changing it): Dockerfile.latest-njs and
# Dockerfile.unprivileged build FROM this literal name, and
# test/docker-compose.yaml and test.sh's unit tests run it by this literal
# name. Parameterize those files before turning this into a knob.
override IMAGE_NAME := nginx-s3-gateway

# Must match test_compose_project in test.sh
COMPOSE_PROJECT   := ngt
COMPOSE_FILE      := $(BASE_DIR)test/docker-compose.yaml
PLUS_CRT          := $(BASE_DIR)plus/etc/ssl/nginx/nginx-repo.crt
PLUS_KEY          := $(BASE_DIR)plus/etc/ssl/nginx/nginx-repo.key
DOCKERFILES       := Dockerfile.oss Dockerfile.plus Dockerfile.latest-njs Dockerfile.unprivileged
# Wildcards (not `git ls-files`) so new entrypoint/integration scripts are
# linted automatically while lint still works without git or a .git directory
# (release tarballs, docker contexts). Anchored to BASE_DIR and converted back
# to repo-relative paths because the shellcheck recipe cds into BASE_DIR.
SHELL_SCRIPTS     := test.sh \
                     standalone_ubuntu_oss_install.sh \
                     $(patsubst $(BASE_DIR)%,%,$(wildcard $(BASE_DIR)test/integration/*.sh)) \
                     $(patsubst $(BASE_DIR)%,%,$(wildcard $(BASE_DIR)common/docker-entrypoint.d/*.sh)) \
                     $(patsubst $(BASE_DIR)%,%,$(wildcard $(BASE_DIR)common/docker-entrypoint.d/*.envsh))

# Pre-existing shellcheck findings in scripts this Makefile must not modify.
# Burn this list down when test.sh is refactored into make-native pieces.
SHELLCHECK_EXCLUDES := SC2027,SC2034,SC2068,SC2120,SC2140

# Single line on purpose: checkmake's parser does not follow continuations
.PHONY: help check-tools check-nginx-type check-plus-creds build build-oss build-plus build-latest-njs build-unprivileged test test-latest-njs test-unprivileged test-matrix test-matrix-plus retest retest-latest-njs retest-unprivileged lint makefile-check shellcheck hadolint docs docs-open jsdoc clean clean-images all ci

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
		echo "MISSING (required): mc (MinIO client) - or place the binary at ./.bin/mc"; ok=0; \
	fi; \
	if ! command -v md5sum > /dev/null 2>&1 && ! command -v md5 > /dev/null 2>&1; then \
		echo "MISSING (required): md5sum (or md5 on macOS)"; ok=0; \
	fi; \
	for tool in npx checkmake shellcheck; do \
		command -v "$$tool" > /dev/null 2>&1 || echo "missing (optional, needed for lint/docs): $$tool"; \
	done; \
	for tool in wait-for-it hadolint jq; do \
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
# phony `build` prerequisite is deduplicated and runs only once.
# Note: test.sh invoked with both --latest-njs and --unprivileged stacks the
# two variants; CI never exercises that combination and neither does this file.
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
test-matrix: build ## Reproduce the CI matrix locally: NGINX_TYPE x {virtual,virtual-v2} + latest-njs + unprivileged
	$(MAKE) retest NGINX_TYPE=$(NGINX_TYPE) S3_STYLE=virtual
	$(MAKE) retest NGINX_TYPE=$(NGINX_TYPE) S3_STYLE=virtual-v2
	$(MAKE) test-latest-njs NGINX_TYPE=$(NGINX_TYPE) S3_STYLE=virtual-v2
	$(MAKE) test-unprivileged NGINX_TYPE=$(NGINX_TYPE) S3_STYLE=virtual-v2
	@echo "$(NGINX_TYPE) test matrix passed"

test-matrix-plus: ## Run the same matrix against NGINX Plus (certs + license.jwt required)
	$(MAKE) test-matrix NGINX_TYPE=plus

##@ Test (no rebuild)

# Single source for the test.sh invocation contract. CI=true makes test.sh
# skip its internal docker build and run against whatever image is currently
# tagged as the floating IMAGE_NAME tag; S3_STYLE reaches the integration
# environment through docker-compose interpolation.
RUN_TESTS = cd "$(BASE_DIR)" && CI=true S3_STYLE="$(S3_STYLE)" ./test.sh --type $(NGINX_TYPE)

retest: check-nginx-type ## Test the currently tagged image without rebuilding
	$(RUN_TESTS)

# Guard the variant retests: --latest-njs/--unprivileged change how test.sh
# drives the image (njs -m unit-test flag, port 8080), so running them against
# a non-variant floating tag produces baffling failures instead of this error.
VARIANT_GUARD = @variant_id="$$($(DOCKER) image inspect -f '{{.Id}}' $(IMAGE_NAME):$(1)-$(NGINX_TYPE) 2> /dev/null || true)"; \
	floating_id="$$($(DOCKER) image inspect -f '{{.Id}}' $(IMAGE_NAME) 2> /dev/null || true)"; \
	{ [ -n "$$variant_id" ] && [ "$$floating_id" = "$$variant_id" ]; } || { \
	echo "ERROR: '$(IMAGE_NAME)' is not the $(1)-$(NGINX_TYPE) variant image; run 'make build-$(1)' (or 'make test-$(1)') first"; exit 2; }

retest-latest-njs: check-nginx-type ## Test the current image with latest-njs semantics, no rebuild
	$(call VARIANT_GUARD,latest-njs)
	$(RUN_TESTS) --latest-njs

retest-unprivileged: check-nginx-type ## Test the current image in unprivileged mode, no rebuild
	$(call VARIANT_GUARD,unprivileged)
	$(RUN_TESTS) --unprivileged

##@ Lint

lint: makefile-check shellcheck ## Run all linters (checkmake + shellcheck)
	@echo "All lints passed"

makefile-check: ## Lint this Makefile with checkmake
	cd "$(BASE_DIR)" && checkmake --config .checkmake.ini GNUmakefile

shellcheck: ## Lint shell scripts (pre-existing findings excluded, see SHELLCHECK_EXCLUDES)
	cd "$(BASE_DIR)" && shellcheck --severity=warning \
		--exclude=$(SHELLCHECK_EXCLUDES) $(SHELL_SCRIPTS)

hadolint: ## Lint Dockerfiles with hadolint when installed (opt-in, not part of lint)
	@if command -v hadolint > /dev/null 2>&1; then \
		cd "$(BASE_DIR)" && hadolint $(DOCKERFILES); \
	else \
		echo "hadolint is not installed - skipping Dockerfile lint (https://github.com/hadolint/hadolint)"; \
	fi

##@ Documentation

# NOTE: jsdoc exits non-zero on template warnings; the legacy `|| true`
# suppression is retained so doc generation stays best-effort. Revisit
# during the test.sh refactor phase.
docs: ## Generate JSDoc reference documentation into DOCS_DIR
	cd "$(BASE_DIR)" && npx jsdoc -c jsdoc/conf.json -d "$(DOCS_DIR)" || true

docs-open: docs ## Generate documentation and open it in a browser
	$(OPEN_CMD) "$(BASE_DIR)$(DOCS_DIR)/index.html"

jsdoc: docs ## Back-compat alias for docs (previous Makefile's target name)

##@ Maintenance

# The DOCS_DIR guard rejects empty, absolute, parent-traversal, and
# trailing-slash values so the rm -rf can never escape the repository (a
# trailing slash would make rm follow a symlinked DOCS_DIR into its target).
# The teardown mirrors test.sh's compose() invocation, including its
# docker-compose fallback, and also removes the mc alias test.sh registers.
clean: ## Remove generated docs and tear down the test compose environment
	@case "$(DOCS_DIR)" in \
		""|.|..|/*|*..*|*/) echo "ERROR: refusing to rm -rf suspicious DOCS_DIR '$(DOCS_DIR)'"; exit 1;; \
	esac
	rm -rf -- "$(BASE_DIR)$(DOCS_DIR)"
	@if $(DOCKER) compose version > /dev/null 2>&1; then compose_cmd="$(DOCKER) compose"; \
	else compose_cmd="docker-compose"; fi; \
	COMPOSE_COMPATIBILITY=true \
		$$compose_cmd -f "$(COMPOSE_FILE)" -p $(COMPOSE_PROJECT) \
		down --volumes --remove-orphans 2> /dev/null || true
	@mc_cmd="$$(command -v mc || echo "$(BASE_DIR).bin/mc")"; \
	[ -x "$$mc_cmd" ] && "$$mc_cmd" alias rm $(COMPOSE_PROJECT)_minio_1 2> /dev/null || true

clean-images: ## Remove all locally built gateway image tags
	@for tag in latest oss plus latest-njs-oss latest-njs-plus unprivileged-oss unprivileged-plus; do \
		$(DOCKER) rmi "$(IMAGE_NAME):$$tag" 2> /dev/null || true; \
	done

##@ Combined

all: lint test docs ## Lint, build, test, and generate docs

ci: ## Full local CI parity: lint then the complete test matrix (oss default)
	$(MAKE) lint
	$(MAKE) test-matrix

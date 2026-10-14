#!/usr/bin/env bash

#
#  Copyright 2026 F5, Inc.
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
#

# Starts the gateway plus the seeded S3 origin from the integration compose
# stack (test/docker-compose.yaml) for manual testing against an
# already-built gateway image. Invoked by the GNUmakefile (make test-run) -
# not intended to be run directly, although doing so is harmless.
#
# The stack, the readiness polls and the seeding recipe are the integration
# suite's own, shared through test/integration/compose_stack_lib.sh, so what
# comes up here is exactly what test/run_integration_tests.sh tests against:
# the gateway on http://localhost:8989 and the origin on http://localhost:9090
# with the fixtures from test/data/ in its bucket. Once the gateway answers,
# the script prints how to reach both services and streams the gateway's
# logs until Ctrl-C, which tears the stack down - as does a `kill` of the
# script or a closed terminal. `make clean` is the fallback teardown if a run
# is ever left behind: a second Ctrl-C during the teardown aborts the
# visible `compose down` (compose installs its own SIGINT handler, so the
# trap below cannot shield it), which is retried once with its progress
# output off; a third interrupt leaves the containers in place. make clean
# also removes the metadata network a killed suite run can leave, which this
# script never creates. The stack shares compose project ngt and host ports
# 8989/9090 with make test-integration and the smoke-test skill, so only one
# of them can run at a time: a second one recreates and finally tears down
# the first one's containers.
#
# The unprivileged image variant is not supported: the compose file publishes
# NGINX_INTERNAL_PORT as host port 8989 and this script always maps port 80
# (make test-run rejects the variant up front, as test-integration does).
#
# After Ctrl-C make itself exits with status 130: it receives the SIGINT too,
# waits for this script's teardown to finish, then re-raises the signal on
# itself. The script exits 0 on Ctrl-C so make prints no error line.
#
# Environment:
#   DOCKER           docker CLI to use (default: docker)
#   NGINX_TYPE       oss or plus (default: oss); plus requires a license.jwt
#                    at /etc/nginx/license.jwt or the repository root
#   S3_STYLE         S3 addressing style - reaches the gateway through
#                    docker-compose interpolation, whose ${S3_STYLE:-virtual-v2}
#                    fallback supplies the default
#   COMPOSE_PROJECT  docker compose project name (default: ngt) - the
#                    GNUmakefile passes its COMPOSE_PROJECT so `make clean`
#                    tears down the same project this script starts
#
# Gateway settings. Only the keys test/docker-compose.yaml passes through
# can be set from here; a variable the compose file has no key for never
# reaches the container. The bare pass-through keys are each exported below
# with a default that a make command-line variable (`make test-run
# ALLOW_DIRECTORY_LIST=false`) or an exported shell variable overrides (an
# empty value falls back to the default):
#   AWS_SIGS_VERSION                     4
#   ALLOW_DIRECTORY_LIST                 true
#   PROVIDE_INDEX_PAGE                   false
#   APPEND_SLASH_FOR_POSSIBLE_DIRECTORY  true
#   STRIP_LEADING_DIRECTORY_PATH         (empty)
#   PREFIX_LEADING_DIRECTORY_PATH        (empty)
#   STATIC_SITE_HOSTING                  (empty)
#   PROXY_CACHE_BYPASS_NO_CACHE          false
#   PROXY_CACHE_IGNORE_HEADERS           (empty)
#   ACCESS_LOG_CACHE_STATUS              false
#   IPV6_ENABLED                         (empty: auto-detect)
# Keys the compose file interpolates with defaults of its own
# (DIRECTORY_LISTING_PAGE_SIZE, CORS_ENABLED, CORS_ALLOWED_ORIGIN,
# CORS_ALLOW_PRIVATE_NETWORK_ACCESS and the TEST_* origin knobs) pass through
# from the environment unchanged; the banner shows their effective values.

set -o errexit
set -o nounset
set -o pipefail

nginx_server_proto="http"
nginx_server_host="localhost"
nginx_server_port="8989"

test_server="${nginx_server_proto}://${nginx_server_host}:${nginx_server_port}"
no_dep_exit_code=3

test_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
test_compose_config="${test_dir}/docker-compose.yaml"
test_compose_project="${COMPOSE_PROJECT:-ngt}"

# The S3 origin is RustFS (see test/docker-compose.yaml); the AWS CLI, used
# purely as a generic S3 client, talks to it for seeding.
s3_origin_server="http://localhost:9090"
s3_origin_user="AKIAIOSFODNN7EXAMPLE"
s3_origin_passwd="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
s3_origin_bucket="bucket-1"
# The compose file bind-mounts this directory into both containers, so it
# must exist before the first compose up (docker would otherwise create it
# root-owned). The path must match the one `make clean` removes.
test_tls_cert_dir="${TMPDIR:-/tmp}/nginx-s3-gateway-${test_compose_project}-tls"

DOCKER="${DOCKER:-docker}"
NGINX_TYPE="${NGINX_TYPE:-oss}"

p() {
  printf "\033[34;1m▶\033[0m "
  echo "$1"
}

e() {
  >&2 echo "$1"
}

if ! { [ "${NGINX_TYPE}" == "oss" ] || [ "${NGINX_TYPE}" == "plus" ]; }; then
  e "Invalid NGINX type: ${NGINX_TYPE} - must be either 'oss' or 'plus'"
  exit ${no_dep_exit_code}
fi

# The same harness-only S3_STYLE check as the integration runner: every
# downstream consumer fails open, so an unrecognized value would silently run
# virtual-style addressing while the banner below claimed otherwise.
if [ -n "${S3_STYLE+x}" ]; then
  case "${S3_STYLE}" in
    virtual|virtual-v2|path) ;;
    *)
      e "Invalid S3_STYLE value: '${S3_STYLE}' - must be 'virtual', 'virtual-v2' or 'path'"
      exit ${no_dep_exit_code}
      ;;
  esac
fi

docker_cmd="$(command -v "${DOCKER}" || true)"
if ! [ -x "${docker_cmd}" ]; then
  e "required dependency not found: ${DOCKER} not found in the path or not executable"
  exit ${no_dep_exit_code}
fi

curl_cmd="$(command -v curl || true)"
if ! [ -x "${curl_cmd}" ]; then
  e "required dependency not found: curl not found in the path or not executable"
  exit ${no_dep_exit_code}
fi

# origin_client (the seeding client, with the AWS CLI lookup that aborts with
# the no-dependency exit code) comes from the shared client lib; the stack
# lib's seed_origin_data relies on it.
. "${test_dir}/integration/s3_client_lib.sh" \
  "${s3_origin_server}" "${s3_origin_user}" "${s3_origin_passwd}"
s3_client_announce

# Port 80 unconditionally: see the header on the unprivileged variant.
# shellcheck source=test/integration/compose_stack_lib.sh
. "${test_dir}/integration/compose_stack_lib.sh" \
  "${docker_cmd}" "${DOCKER}" "${curl_cmd}" \
  "${test_compose_config}" "${test_compose_project}" \
  "${NGINX_TYPE}" 80 "${test_server}" "${s3_origin_bucket}"

# Every bare pass-through key in test/docker-compose.yaml gets an explicit
# value: a bare key whose variable is unset in this environment is removed
# from the container's environment altogether - taking the image's ENV
# default with it - and the entrypoint refuses to start without
# ALLOW_DIRECTORY_LIST or with an AWS_SIGS_VERSION other than 2 or 4 (an
# empty ALLOW_DIRECTORY_LIST would be accepted and silently mean "off"). The
# ${VAR:-default} form is what makes `make test-run VAR=value` work: make
# exports command-line variables into the recipe environment.
export AWS_SIGS_VERSION="${AWS_SIGS_VERSION:-4}"
export ALLOW_DIRECTORY_LIST="${ALLOW_DIRECTORY_LIST:-true}"
export PROVIDE_INDEX_PAGE="${PROVIDE_INDEX_PAGE:-false}"
export APPEND_SLASH_FOR_POSSIBLE_DIRECTORY="${APPEND_SLASH_FOR_POSSIBLE_DIRECTORY:-true}"
export STRIP_LEADING_DIRECTORY_PATH="${STRIP_LEADING_DIRECTORY_PATH:-}"
export PREFIX_LEADING_DIRECTORY_PATH="${PREFIX_LEADING_DIRECTORY_PATH:-}"
export STATIC_SITE_HOSTING="${STATIC_SITE_HOSTING:-}"
export PROXY_CACHE_BYPASS_NO_CACHE="${PROXY_CACHE_BYPASS_NO_CACHE:-false}"
export PROXY_CACHE_IGNORE_HEADERS="${PROXY_CACHE_IGNORE_HEADERS:-}"
export ACCESS_LOG_CACHE_STATUS="${ACCESS_LOG_CACHE_STATUS:-false}"
export IPV6_ENABLED="${IPV6_ENABLED:-}"
export TEST_TLS_CERT_DIR="${test_tls_cert_dir}"
# Exported once rather than per command so that up, logs and down agree on
# the container names (older-style compose names with _ instead of -).
export COMPOSE_COMPATIBILITY=true

mkdir -p "${test_tls_cert_dir}"

# Tears the stack down and exits with the status it was given. Armed before
# the first compose command so a failed `up` still cleans up. INT exits 0
# because Ctrl-C is the documented way to stop, not a failure; EXIT keeps the
# failing status of whatever tripped errexit. TERM and HUP are deliberately
# left untrapped: bash runs the EXIT trap at once for an untrapped fatal
# signal (and re-raises it afterwards), whereas it defers a trapped signal
# until the foreground command finishes - which, with the log follower
# running, would leave a `kill` of this script or a closed terminal hanging
# with the stack up.
#
# follower is the pid of the background log stream (empty until it starts);
# log_stream_started tells finish() whether the gateway log has already been
# shown.
follower=""
log_stream_started=0
finish() {
  result=$1
  # The exit below must not re-enter this function. INT/TERM are ignored so
  # a second Ctrl-C cannot kill this script halfway through the teardown; it
  # does still reach `compose down` (see the header). PIPE is ignored and
  # errexit dropped because the teardown must survive its own output
  # failing: after `make test-run | tee log` + Ctrl-C the reader is already
  # gone, and a closed terminal returns EIO - either would otherwise kill
  # the shell (SIGPIPE) or trip errexit before `compose down` ran, leaving
  # the stack up.
  trap - EXIT
  trap '' INT TERM HUP PIPE
  set +o errexit
  if [ -n "${follower}" ]; then
    # The docker CLI runs the compose plugin as a child it does not relay
    # signals to when stdout is a terminal, so signal both; whatever survives
    # ends with its container below.
    pkill -TERM -P "${follower}" 2> /dev/null
    kill -TERM "${follower}" 2> /dev/null
  fi
  echo 2> /dev/null
  if [ "${result}" -ne 0 ] && [ "${log_stream_started}" -eq 0 ]; then
    # A gateway that never answered - a rejected setting, say - has its
    # reason in its log, which `compose down` is about to delete.
    e "Error: outputting gateway container logs"
    compose logs nginx-s3-gateway 2> /dev/null
  fi
  p "Cleaning up Docker compose environment" 2> /dev/null
  # Retried with the progress output off because compose, unlike this shell,
  # dies on a broken pipe once both stdout and stderr are gone (`2>&1 | tee`
  # + Ctrl-C); the retry also completes a teardown a second Ctrl-C aborted.
  compose down --volumes --remove-orphans ||
    compose --progress quiet down --volumes --remove-orphans > /dev/null 2>&1
  # Never populated by this script (it generates no certificates), so a plain
  # rmdir is enough; `make clean` handles anything a suite run left behind.
  rmdir "${test_tls_cert_dir}" 2> /dev/null
  exit "${result}"
}
trap 'finish $?' EXIT
trap 'finish 0' INT

write_special_character_fixture

p "Starting Docker Compose Environment"
compose up -d

# The readiness probe hits /health, which nginx answers itself, so it can
# run before seeding without caching a miss; a gateway that rejects an
# overridden setting then fails here, before the seeding output.
wait_for_gateway

seed_origin_data "${s3_origin_server}"

p "Gateway:   ${test_server}  (NGINX_TYPE=${NGINX_TYPE} S3_STYLE=${S3_STYLE:-virtual-v2})"
echo "  AWS_SIGS_VERSION=${AWS_SIGS_VERSION} ALLOW_DIRECTORY_LIST=${ALLOW_DIRECTORY_LIST} PROVIDE_INDEX_PAGE=${PROVIDE_INDEX_PAGE} APPEND_SLASH_FOR_POSSIBLE_DIRECTORY=${APPEND_SLASH_FOR_POSSIBLE_DIRECTORY}"
echo "  STRIP_LEADING_DIRECTORY_PATH='${STRIP_LEADING_DIRECTORY_PATH}' PREFIX_LEADING_DIRECTORY_PATH='${PREFIX_LEADING_DIRECTORY_PATH}' IPV6_ENABLED='${IPV6_ENABLED}'"
echo "  PROXY_CACHE_BYPASS_NO_CACHE=${PROXY_CACHE_BYPASS_NO_CACHE} PROXY_CACHE_IGNORE_HEADERS='${PROXY_CACHE_IGNORE_HEADERS}' ACCESS_LOG_CACHE_STATUS=${ACCESS_LOG_CACHE_STATUS}"
# The interpolated keys pass through from the shell, so they are shown with
# the compose file's own defaults: a stale export left in the developer's
# shell would otherwise shape the gateway invisibly.
echo "  DIRECTORY_LISTING_PAGE_SIZE='${DIRECTORY_LISTING_PAGE_SIZE:-}' CORS_ENABLED=${CORS_ENABLED:-false} CORS_ALLOWED_ORIGIN='${CORS_ALLOWED_ORIGIN:-*}' CORS_ALLOW_PRIVATE_NETWORK_ACCESS='${CORS_ALLOW_PRIVATE_NETWORK_ACCESS:-}'"
p "S3 origin: ${s3_origin_server}  (bucket ${s3_origin_bucket})"
echo "  AWS_ACCESS_KEY_ID=${s3_origin_user} AWS_SECRET_ACCESS_KEY=${s3_origin_passwd}"
echo "  aws --endpoint-url ${s3_origin_server} s3 ls s3://${s3_origin_bucket}"
p "Override any setting the compose file passes through per run, e.g. make test-run ALLOW_DIRECTORY_LIST=false AWS_SIGS_VERSION=2"
p "Ctrl-C once stops the gateway and tears the stack down (make clean recovers a teardown interrupted again)"
p "Following gateway logs"

# Run in the background and waited on rather than in the foreground: bash
# defers a trapped signal until a foreground command finishes, so Ctrl-C
# would reach finish() only once the follower had exited on its own, whereas
# `wait` returns as soon as the signal arrives. (A background job starts
# with SIGINT ignored, but compose re-enables it, and finish() signals the
# follower anyway.) Not piped: under pipefail a reader that exits early
# would fail the stream.
log_stream_started=1
compose logs --follow nginx-s3-gateway &
follower=$!
wait "${follower}" || true

# Reached only when the stream ended on its own: an interrupt leaves through
# the INT trap from inside `wait`.
follower=""
e "the gateway log stream ended: the gateway container stopped"
exit 1

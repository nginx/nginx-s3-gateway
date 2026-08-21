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

# Runs the integration test suite against an already-built gateway image
# using the docker compose environment in test/docker-compose.yaml. Invoked
# by the GNUmakefile (make test-integration / make retest) - not intended to
# be run directly, although doing so is harmless.
#
# The suite starts MinIO plus the gateway, seeds test data, then drives
# test/integration/test_api.sh and test_cache_bypass.sh through a matrix of
# gateway configurations. The entrypoint-script tests run first since they
# only need the image, not the compose environment.
#
# Environment:
#   DOCKER           docker CLI to use (default: docker)
#   NGINX_TYPE       oss or plus (default: oss); plus requires a license.jwt
#                    at /etc/nginx/license.jwt or the repository root
#   UNPRIVILEGED     1 when testing the unprivileged variant image, which
#                    listens on 8080 instead of 80 (default: 0)
#   S3_STYLE         S3 addressing style under test - reaches the gateway
#                    through docker-compose interpolation, whose
#                    ${S3_STYLE:-virtual-v2} fallback supplies the default
#   COMPOSE_PROJECT  docker compose project name (default: ngt) - the
#                    GNUmakefile passes its COMPOSE_PROJECT so `make clean`
#                    tears down the same project this script starts

set -o errexit
set -o nounset
set -o pipefail

nginx_server_proto="http"
nginx_server_host="localhost"
nginx_server_port="8989"

test_server="${nginx_server_proto}://${nginx_server_host}:${nginx_server_port}"
test_fail_exit_code=2
no_dep_exit_code=3
build_dep_exit_code=4

test_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
repo_dir="$( dirname "${test_dir}" )"
test_compose_config="${test_dir}/docker-compose.yaml"
test_compose_project="${COMPOSE_PROJECT:-ngt}"

minio_server="http://localhost:9090"
minio_user="AKIAIOSFODNN7EXAMPLE"
minio_passwd="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
minio_name="${test_compose_project}_minio_1"
minio_bucket="bucket-1"

DOCKER="${DOCKER:-docker}"
NGINX_TYPE="${NGINX_TYPE:-oss}"
UNPRIVILEGED="${UNPRIVILEGED:-0}"

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

# Validate before the first numeric [ -eq ] comparison: a non-numeric value
# (e.g. UNPRIVILEGED=true) would otherwise print an 'integer expression
# expected' warning and silently select the privileged port 80 branch.
if ! { [ "${UNPRIVILEGED}" == "0" ] || [ "${UNPRIVILEGED}" == "1" ]; }; then
  e "Invalid UNPRIVILEGED value: ${UNPRIVILEGED} - must be 0 or 1"
  exit ${no_dep_exit_code}
fi

# The unprivileged image rewrites 'listen 80;' to 'listen 8080;' at build
# time (Dockerfile.unprivileged); every listen-related assertion keys off
# this single value.
if [ "${UNPRIVILEGED}" -eq 1 ]; then
  gateway_listen_port=8080
else
  gateway_listen_port=80
fi

is_windows="0"
if [ "${OS:-}" == "Windows_NT" ]; then
  is_windows="1"
elif command -v uname > /dev/null; then
  uname_output="$(uname -s)"
  if [[ "${uname_output}" == *"_NT-"* ]]; then
    is_windows="1"
  fi
fi

docker_cmd="$(command -v "${DOCKER}" || true)"
if ! [ -x "${docker_cmd}" ]; then
  e "required dependency not found: ${DOCKER} not found in the path or not executable"
  exit ${no_dep_exit_code}
fi

# An array so that a docker path containing spaces (e.g. Git Bash resolving
# to '/c/Program Files/Docker/.../docker') survives expansion intact. The
# legacy docker-compose fallback only applies to the stock docker CLI: with a
# DOCKER override (e.g. podman) it would silently drive the compose stack
# with a different engine than the rest of the suite.
if "${docker_cmd}" compose version > /dev/null 2>&1; then
  docker_compose_cmd=("${docker_cmd}" compose)
elif [ "${DOCKER}" == "docker" ] && command -v docker-compose > /dev/null; then
  docker_compose_cmd=(docker-compose)
else
  e "required dependency not found: ${DOCKER} compose (or docker-compose) not found in the path or not executable"
  exit ${no_dep_exit_code}
fi
e "Using Docker Compose command: ${docker_compose_cmd[*]}"

curl_cmd="$(command -v curl || true)"
if ! [ -x "${curl_cmd}" ]; then
  e "required dependency not found: curl not found in the path or not executable"
  exit ${no_dep_exit_code}
fi

if command -v mc > /dev/null; then
  mc_cmd="$(command -v mc)"
elif [ -x "${repo_dir}/.bin/mc" ]; then
  mc_cmd="${repo_dir}/.bin/mc"
else
  e "required dependency not found: mc not found in the path or not executable"
  exit ${no_dep_exit_code}
fi
e "Using MinIO Client: ${mc_cmd}"

wait_for_it_cmd="$(command -v wait-for-it || true)"
if ! [ -x "${wait_for_it_cmd}" ]; then
  e "wait-for-it command not available, consider installing to prevent race conditions"
fi

compose() {
  # Hint to docker-compose the internal port to map for the container
  if [ "${UNPRIVILEGED}" -eq 1 ]; then
    export NGINX_INTERNAL_PORT=8080
  else
    export NGINX_INTERNAL_PORT=80
  fi

  if [ "${NGINX_TYPE}" == "plus" ]; then
    if [ -f /etc/nginx/license.jwt ]; then
      NGINX_LICENSE_JWT="$(cat /etc/nginx/license.jwt)"
    elif [ -f "${repo_dir}/license.jwt" ]; then
      NGINX_LICENSE_JWT="$(cat "${repo_dir}/license.jwt")"
    else
      e "NGINX Plus license file not found: /etc/nginx/license.jwt or ${repo_dir}/license.jwt"
      exit ${build_dep_exit_code}
    fi
  else
    NGINX_LICENSE_JWT=""
  fi

  export NGINX_LICENSE_JWT

  "${docker_compose_cmd[@]}" -f "${test_compose_config}" -p "${test_compose_project}" "$@"
}

integration_test_data() {
  # Write problematic files to disk if we are not on Windows. Originally,
  # these files were checked in, but that prevented the git repository from
  # being cloned on Windows machines.
  if [ "$is_windows" == "0" ]; then
    echo "Writing weird filename: ${test_dir}/data/bucket-1/a/%@!*()=\$#^&|.txt"
    echo 'We are but selling water next to a river.' > "${test_dir}"'/data/bucket-1/a/%@!*()=$#^&|.txt'
  fi

  p "Starting Docker Compose Environment"
  # COMPOSE_COMPATIBILITY=true Supports older style compose filenames with _ vs -
  COMPOSE_COMPATIBILITY=true compose up -d

  # Hit minio's health check end point to see if it has started up
  for (( i=1; i<=3; i++ ))
  do
    echo "Querying minio server to see if it is ready"
    # `|| true` keeps errexit from aborting the retry loop when minio is not
    # listening yet (curl exits 7 on connection refused but still prints 000).
    minio_is_up="$(${curl_cmd} -s -o /dev/null -w '%{http_code}' "${minio_server}"/minio/health/cluster || true)"
    if [ "${minio_is_up}" = "200" ]; then
      break
    else
      sleep 2
    fi
  done

  p "Adding test data to container"
  "${mc_cmd}" alias set "$minio_name" "$minio_server" "$minio_user" "$minio_passwd"
  # --ignore-existing keeps a bucket left behind by an aborted previous run
  # (compose containers survive a failed teardown) from failing the seeding
  # step under errexit on every subsequent run.
  "${mc_cmd}" mb --ignore-existing "$minio_name/$minio_bucket"
  echo "Copying contents of ${test_dir}/data/$minio_bucket to Docker container $minio_name"
  for file in "${test_dir}/data/$minio_bucket"/*; do
    "${mc_cmd}" cp -r "${file}" "$minio_name/$minio_bucket"
  done
  echo "Docker diff output:"
  "${docker_cmd}" diff "$minio_name"
}

integration_test_listen_directives() {
  p "Verifying rendered listen directives"
  expected_listen_port="${gateway_listen_port}"
  rendered_conf="$(compose exec -T nginx-s3-gateway cat /etc/nginx/conf.d/default.conf)"
  if ! echo "${rendered_conf}" | grep -q "listen[[:space:]]*${expected_listen_port};"; then
    e "rendered default.conf is missing the IPv4 listen directive"
    exit "$test_fail_exit_code"
  fi
  # 02-ipv6-enable.sh injects the IPv6 listen directive only when the
  # container kernel supports IPv6, so assert against the same condition.
  if compose exec -T nginx-s3-gateway test -f /proc/net/if_inet6; then
    if ! echo "${rendered_conf}" | grep -q "listen[[:space:]]*\[::\]:${expected_listen_port};"; then
      e "container kernel supports IPv6 but rendered default.conf has no IPv6 listen directive"
      exit "$test_fail_exit_code"
    fi
  elif echo "${rendered_conf}" | grep -q "\[::\]"; then
    e "container kernel lacks IPv6 but rendered default.conf has an IPv6 listen directive"
    exit "$test_fail_exit_code"
  fi
}

integration_test() {
  printf "\033[34;1m▶\033[0m"
  printf "\e[1m Integration test suite for v%s signatures\e[22m\n" "$1"
  printf "\033[34;1m▶\033[0m"
  printf "\e[1m Integration test suite with ALLOW_DIRECTORY_LIST=%s\e[22m\n" "$2"
  printf "\033[34;1m▶\033[0m"
  printf "\e[1m Integration test suite with PROVIDE_INDEX_PAGE=%s\e[22m\n" "$3"
  printf "\033[34;1m▶\033[0m"
  printf "\e[1m Integration test suite with APPEND_SLASH_FOR_POSSIBLE_DIRECTORY=%s\e[22m\n" "$4"
  printf "\033[34;1m▶\033[0m"
  printf "\e[1m Integration test suite with STRIP_LEADING_DIRECTORY_PATH=%s\e[22m\n" "$5"
  printf "\033[34;1m▶\033[0m"
  printf "\e[1m Integration test suite with PREFIX_LEADING_DIRECTORY_PATH=%s\e[22m\n" "$6"

  p "Starting Docker Compose Environment"
  # COMPOSE_COMPATIBILITY=true Supports older style compose filenames with _ vs -
  COMPOSE_COMPATIBILITY=true AWS_SIGS_VERSION=$1 ALLOW_DIRECTORY_LIST=$2 PROVIDE_INDEX_PAGE=$3 APPEND_SLASH_FOR_POSSIBLE_DIRECTORY=$4 STRIP_LEADING_DIRECTORY_PATH=$5 PREFIX_LEADING_DIRECTORY_PATH=$6 compose up -d

  if [ -x "${wait_for_it_cmd}" ]; then
    "${wait_for_it_cmd}" -h "${nginx_server_host}" -p "${nginx_server_port}"
  fi

  p "Starting HTTP API tests (v$1 signatures)"
  echo "  test/integration/test_api.sh \"$test_server\" \"$test_dir\" $1 $2 $3 $4 $5 $6"
  bash "${test_dir}/integration/test_api.sh" "${test_server}" "${test_dir}" "$1" "$2" "$3" "$4" "$5" "$6";

  # We check to see if NGINX is in fact using the correct version of AWS
  # signatures as it was configured to do. `|| true` because grep -c exits 1
  # on a count of zero, which must reach the check below rather than abort
  # the script through errexit before it can print the diagnostic.
  sig_versions_found_count=$(compose logs nginx-s3-gateway | grep -c "AWS Signatures Version: v$1\|AWS v$1 Auth" || true)

  if [ "${sig_versions_found_count}" -lt 3 ]; then
    e "NGINX was not detected as using the correct signatures version - examine logs"
    compose logs nginx-s3-gateway
    exit "$test_fail_exit_code"
  fi
}

integration_test_cache_bypass() {
  bypass_setting=$1  # "false" or "true" - passed through compose to the gateway
  # The assertion set follows the setting so that the two can never be passed
  # as a mismatched pair.
  if [ "${bypass_setting}" = "true" ]; then
    bypass_phase="enabled"
  else
    bypass_phase="disabled"
  fi

  printf "\033[34;1m▶\033[0m"
  printf "\e[1m Integration test suite with PROXY_CACHE_BYPASS_NO_CACHE=%s\e[22m\n" "${bypass_setting}"

  p "Starting Docker Compose Environment"
  # The six standard configuration values are pinned to a known baseline
  # (the v4 signatures, no-listing configuration) so that URL rewriting
  # configured by the STRIP/PREFIX_LEADING_DIRECTORY_PATH passes cannot leak
  # in. Changing the environment makes compose recreate the gateway
  # container, which discards the proxy cache so that each phase starts with
  # an empty cache.
  # COMPOSE_COMPATIBILITY=true Supports older style compose filenames with _ vs -
  COMPOSE_COMPATIBILITY=true AWS_SIGS_VERSION=4 ALLOW_DIRECTORY_LIST=0 PROVIDE_INDEX_PAGE=0 APPEND_SLASH_FOR_POSSIBLE_DIRECTORY=0 STRIP_LEADING_DIRECTORY_PATH="" PREFIX_LEADING_DIRECTORY_PATH="" PROXY_CACHE_BYPASS_NO_CACHE="${bypass_setting}" compose up -d

  if [ -x "${wait_for_it_cmd}" ]; then
    "${wait_for_it_cmd}" -h "${nginx_server_host}" -p "${nginx_server_port}"
  fi

  p "Starting cache bypass tests (phase: ${bypass_phase})"
  echo "  test/integration/test_cache_bypass.sh \"$test_server\" \"$test_dir\" ${bypass_phase} \"${mc_cmd}\" \"${minio_name}\" \"${minio_bucket}\""
  bash "${test_dir}/integration/test_cache_bypass.sh" "${test_server}" "${test_dir}" "${bypass_phase}" "${mc_cmd}" "${minio_name}" "${minio_bucket}"
}

finish() {
  result=$?
  # Disarm the traps first: a test failure otherwise runs finish twice (ERR,
  # then again when its `exit` fires the EXIT trap), double-dumping logs and
  # re-running the teardown. Cleanup steps are best-effort (`|| true`) so a
  # failing step - e.g. removing an mc alias that was never registered
  # because the run aborted before integration_test_data - cannot trip
  # errexit inside the trap and replace the preserved test exit code.
  trap - EXIT ERR SIGTERM SIGINT

  if [ $result -ne 0 ]; then
    e "Error running tests - outputting container logs"
    compose logs || true
  fi

  p "Cleaning up Docker compose environment"
  compose stop || true
  compose rm -f -v || true
  "${mc_cmd}" alias rm "$minio_name" || true

  exit ${result}
}
trap finish EXIT ERR SIGTERM SIGINT

### ENTRYPOINT SCRIPT TESTS
# These only need the image and a docker CLI, so they run before the compose
# environment comes up.

p "Testing IPv6 entrypoint script"
bash "${test_dir}/integration/test_entrypoint_ipv6.sh" "${docker_cmd}" "${gateway_listen_port}"

p "Testing settings output entrypoint script"
bash "${test_dir}/integration/test_entrypoint_output_settings.sh" "${docker_cmd}"

### INTEGRATION TESTS
# The arguments correspond to gateway configuration values, e.g.
# integration_test 2 0 0 0 "" ""
# AWS_SIGS_VERSION=$1 : any valid AWS Sigs version. Supported values are `2` or `4`
# ALLOW_DIRECTORY_LIST=$2 : boolean value denoted by `0` or `1`
# PROVIDE_INDEX_PAGE=$3 : boolean value denoted by `0` or `1`
# APPEND_SLASH_FOR_POSSIBLE_DIRECTORY=$4 : boolean value denoted by `0` or `1`
# STRIP_LEADING_DIRECTORY_PATH=$5 : prefix to strip from request paths, or ""
# PREFIX_LEADING_DIRECTORY_PATH=$6 : prefix prepended to S3 keys, or ""
# All six are required (the script runs under `set -o nounset`).
#
# These are various invocations of ./test/integration/test_api.sh
# where the flags represent different configurations for that single test
# file.

integration_test_data

p "Testing API with AWS Signature V2 and allow directory listing off"
integration_test 2 0 0 0 "" ""

integration_test_listen_directives

compose stop nginx-s3-gateway # Restart with new config

p "Testing API with AWS Signature V2 and allow directory listing on"
integration_test 2 1 0 0 "" ""

compose stop nginx-s3-gateway # Restart with new config

p "Testing API with AWS Signature V2 and static site on"
integration_test 2 0 1 0 "" ""

compose stop nginx-s3-gateway # Restart with new config

p "Testing API with AWS Signature V2 and allow directory listing on and append slash and allow index"
integration_test 2 1 1 1 "" ""

compose stop nginx-s3-gateway # Restart with new config

p "Test API with AWS Signature V4 and allow directory listing off"
integration_test 4 0 0 0 "" ""

compose stop nginx-s3-gateway # Restart with new config

p "Test API with AWS Signature V4 and allow directory listing on and appending /"
integration_test 4 1 0 1 "" ""

compose stop nginx-s3-gateway # Restart with new config

p "Test API with AWS Signature V4 and static site on appending /"
integration_test 4 0 1 1 "" ""

compose stop nginx-s3-gateway # Restart with new config

p "Testing API with AWS Signature V2 and allow directory listing off and prefix stripping on"
integration_test 2 0 0 0 /my-bucket ""

compose stop nginx-s3-gateway # Restart with new config

p "Test API with AWS Signature V4 and prefix leading directory path on"
integration_test 4 0 0 0 "" "/b"

p "Test API with AWS Signature V4 and prefix leading directory path on and prefix stripping on"
integration_test 4 0 0 0 "/tostrip" "/b"

p "Testing API with AWS Signature V2 and prefix leading directory path"
integration_test 2 0 0 0 "" "/b"

compose stop nginx-s3-gateway # Restart with new config

p "Testing proxy cache bypass with PROXY_CACHE_BYPASS_NO_CACHE=false (default)"
integration_test_cache_bypass "false"

compose stop nginx-s3-gateway # Restart with new config

p "Testing proxy cache bypass with PROXY_CACHE_BYPASS_NO_CACHE=true"
integration_test_cache_bypass "true"

p "All integration tests complete"

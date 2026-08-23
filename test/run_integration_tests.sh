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
dynamic_credentials_compose_config="${test_dir}/docker-compose.dynamic-credentials.yaml"
secret_file_credentials_compose_config="${test_dir}/docker-compose.secret-file-credentials.yaml"
test_compose_project="${COMPOSE_PROJECT:-ngt}"

minio_server="http://localhost:9090"
minio_user="AKIAIOSFODNN7EXAMPLE"
minio_passwd="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
minio_name="${test_compose_project}_minio_1"
minio_bucket="bucket-1"
test_tls_cert_dir="${TMPDIR:-/tmp}/nginx-s3-gateway-${test_compose_project}-tls"
test_secrets_dir="${TMPDIR:-/tmp}/nginx-s3-gateway-${test_compose_project}-secrets"
minio_mc_args=()

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

# Blocks until the gateway answers an HTTP request, replacing the external
# wait-for-it dependency.
#
# Two problems with the previous arrangement. wait-for-it was an optional
# tool, so on a host that lacked it these waits silently became no-ops. And
# even where it was installed it only proved the *published* port was open:
# docker binds the host side of a port mapping as soon as the container
# starts, so a TCP connect succeeds while nginx inside is still booting. The
# downstream suites each carry their own 2s/4s/6s backoff loop to absorb that
# gap, and it fired on nearly every configuration change - 13 times in a
# representative CI run, all of it pure sleep.
#
# Polling the same HEAD request those suites use closes the gap for real:
# curl reports 000 until nginx accepts and answers, so this returns only once
# a request would actually succeed, and the downstream backoffs stop firing.
#
# Exits non-zero on timeout so callers abort under errexit rather than
# proceeding against a gateway that never came up.
gateway_wait_timeout=15
wait_for_gateway() {
  poll_limit=$((gateway_wait_timeout * 5))
  for (( poll=0; poll<poll_limit; poll++ )); do
    # `|| true` because curl exits non-zero (while still printing 000) until
    # the gateway answers, which errexit would otherwise treat as fatal.
    gateway_status="$("${curl_cmd}" -s -o /dev/null -w '%{http_code}' \
      --head --max-time 2 "${test_server}" || true)"
    if [ "${gateway_status}" != "000" ]; then
      return 0
    fi
    sleep 0.2
  done
  e "timed out after ${gateway_wait_timeout}s waiting for the gateway at ${test_server}"
  return 1
}

prepare_compose_env() {
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
}

compose() {
  prepare_compose_env

  "${docker_compose_cmd[@]}" -f "${test_compose_config}" -p "${test_compose_project}" "$@"
}

compose_dynamic_credentials() {
  prepare_compose_env

  # The override file nulls the static AWS_* variables, but compose treats a
  # null environment entry as pass-through-from-the-invoking-shell, not
  # unset. Scrub them so an operator's real AWS credentials can neither leak
  # into the test gateway nor bypass the metadata mock.
  env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
    "${docker_compose_cmd[@]}" --profile dynamic-credentials \
    -f "${test_compose_config}" -f "${dynamic_credentials_compose_config}" \
    -p "${test_compose_project}" "$@"
}

compose_secret_file_credentials() {
  prepare_compose_env

  export TEST_SECRETS_DIR="${test_secrets_dir}"

  # Same pass-through trap as compose_dynamic_credentials: the override nulls
  # the static AWS_* variables, so they have to be scrubbed here or the
  # gateway would read them from the environment and never touch the files.
  env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
    "${docker_compose_cmd[@]}" \
    -f "${test_compose_config}" -f "${secret_file_credentials_compose_config}" \
    -p "${test_compose_project}" "$@"
}

# Configure the compose environment and mc/curl endpoints for an HTTP or
# HTTPS MinIO origin. Kept as one function so the two origin modes cannot
# drift apart when a new TEST_* knob is added.
# set_test_origin <http|https>
set_test_origin() {
  origin_proto="$1"
  export TEST_S3_SERVER="minio"
  export TEST_S3_SERVER_PORT="9000"
  export TEST_S3_SERVER_PROTO="${origin_proto}"
  export TEST_S3_TRUSTED_CERT_PATH="/etc/ssl/certs/ca-certificates.crt"
  export TEST_MINIO_SERVER_PROTO="${origin_proto}"
  export TEST_TLS_CERT_DIR="${test_tls_cert_dir}"
  export TEST_PROXY_CACHE_SLICE_SIZE="1m"
  minio_server="${origin_proto}://localhost:9090"
  if [ "${origin_proto}" = "https" ]; then
    # Mount point of the generated test certificates inside the MinIO
    # container; MinIO serves TLS when its certs dir contains a key pair.
    export TEST_MINIO_CERTS_DIR="/tmp/test-certs"
    minio_mc_args=(--insecure)
  else
    export TEST_MINIO_CERTS_DIR="/root/.minio/certs"
    minio_mc_args=()
  fi
}

set_http_test_origin() {
  set_test_origin "http"
}

set_https_test_origin() {
  set_test_origin "https"
}

generate_tls_test_certs() {
  mkdir -p "${test_tls_cert_dir}"
  "${docker_cmd}" run --rm --user 0:0 \
    -v "${test_tls_cert_dir}:/certs" \
    --entrypoint /bin/sh nginx-s3-gateway -c '
      set -eu
      rm -f /certs/*
      openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout /certs/ca.key -out /certs/ca.crt -days 1 \
        -subj "/CN=nginx-s3-gateway test CA" >/dev/null 2>&1
      openssl req -newkey rsa:2048 -nodes \
        -keyout /certs/private.key -out /certs/server.csr \
        -subj "/CN=minio" >/dev/null 2>&1
      printf "%s\n" \
        "basicConstraints=CA:FALSE" \
        "keyUsage=digitalSignature,keyEncipherment" \
        "extendedKeyUsage=serverAuth" \
        "subjectAltName=DNS:minio,DNS:bucket-1.minio" > /certs/server.ext
      openssl x509 -req -in /certs/server.csr \
        -CA /certs/ca.crt -CAkey /certs/ca.key -CAcreateserial \
        -out /certs/public.crt -days 1 -extfile /certs/server.ext >/dev/null 2>&1
      chmod 0644 /certs/ca.crt /certs/public.crt
      chmod 0600 /certs/ca.key /certs/private.key
    '
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

  seed_minio_data
}

seed_minio_data() {

  # Hit minio's health check end point to see if it has started up
  for (( i=1; i<=3; i++ ))
  do
    echo "Querying minio server to see if it is ready"
    # `|| true` keeps errexit from aborting the retry loop when minio is not
    # listening yet (curl exits 7 on connection refused but still prints 000).
    minio_is_up="$(${curl_cmd} --insecure -s -o /dev/null -w '%{http_code}' "${minio_server}"/minio/health/cluster || true)"
    if [ "${minio_is_up}" = "200" ]; then
      break
    else
      sleep 2
    fi
  done

  p "Adding test data to container"
  # ${arr[@]+...} keeps the empty-array expansion from tripping `set -o
  # nounset` on bash < 4.4 (macOS ships bash 3.2).
  "${mc_cmd}" alias set ${minio_mc_args[@]+"${minio_mc_args[@]}"} "$minio_name" "$minio_server" "$minio_user" "$minio_passwd"
  # --ignore-existing keeps a bucket left behind by an aborted previous run
  # (compose containers survive a failed teardown) from failing the seeding
  # step under errexit on every subsequent run.
  "${mc_cmd}" mb ${minio_mc_args[@]+"${minio_mc_args[@]}"} --ignore-existing "$minio_name/$minio_bucket"
  echo "Copying contents of ${test_dir}/data/$minio_bucket to Docker container $minio_name"
  for file in "${test_dir}/data/$minio_bucket"/*; do
    "${mc_cmd}" cp ${minio_mc_args[@]+"${minio_mc_args[@]}"} -r "${file}" "$minio_name/$minio_bucket"
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

  wait_for_gateway

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

  # A small slice size lets the cache tests prove both cross-Host sharing for
  # one slice and isolation between different $slice_range values without
  # checking a large binary fixture into the repository.
  export TEST_PROXY_CACHE_SLICE_SIZE="10"

  p "Starting Docker Compose Environment"
  # The six standard configuration values are pinned to a known baseline
  # (the v4 signatures, no-listing configuration) so that URL rewriting
  # configured by the STRIP/PREFIX_LEADING_DIRECTORY_PATH passes cannot leak
  # in. Changing the environment makes compose recreate the gateway
  # container, which discards the proxy cache so that each phase starts with
  # an empty cache.
  # COMPOSE_COMPATIBILITY=true Supports older style compose filenames with _ vs -
  COMPOSE_COMPATIBILITY=true AWS_SIGS_VERSION=4 ALLOW_DIRECTORY_LIST=0 PROVIDE_INDEX_PAGE=0 APPEND_SLASH_FOR_POSSIBLE_DIRECTORY=0 STRIP_LEADING_DIRECTORY_PATH="" PREFIX_LEADING_DIRECTORY_PATH="" PROXY_CACHE_BYPASS_NO_CACHE="${bypass_setting}" compose up -d

  wait_for_gateway

  p "Starting cache bypass tests (phase: ${bypass_phase})"
  echo "  test/integration/test_cache_bypass.sh \"$test_server\" \"$test_dir\" ${bypass_phase} \"${mc_cmd}\" \"${minio_name}\" \"${minio_bucket}\""
  bash "${test_dir}/integration/test_cache_bypass.sh" "${test_server}" "${test_dir}" "${bypass_phase}" "${mc_cmd}" "${minio_name}" "${minio_bucket}"
}

integration_test_cache_ignore_headers() {
  ignore_headers=$1  # "" or a field list - passed through compose to the gateway
  # The assertion set follows the setting so that the two can never be passed
  # as a mismatched pair.
  if [ -n "${ignore_headers}" ]; then
    ignore_phase="enabled"
  else
    ignore_phase="disabled"
  fi

  printf "\033[34;1m▶\033[0m"
  printf "\e[1m Integration test suite with PROXY_CACHE_IGNORE_HEADERS='%s'\e[22m\n" "${ignore_headers}"

  p "Starting Docker Compose Environment"
  # The six standard configuration values are pinned to the same v4,
  # no-listing baseline the cache bypass passes use, and the bypass setting is
  # pinned off so neither feature can mask the other. Changing the
  # environment makes compose recreate the gateway container, which discards
  # the proxy cache so that each phase starts with an empty cache.
  # COMPOSE_COMPATIBILITY=true Supports older style compose filenames with _ vs -
  COMPOSE_COMPATIBILITY=true AWS_SIGS_VERSION=4 ALLOW_DIRECTORY_LIST=0 PROVIDE_INDEX_PAGE=0 APPEND_SLASH_FOR_POSSIBLE_DIRECTORY=0 STRIP_LEADING_DIRECTORY_PATH="" PREFIX_LEADING_DIRECTORY_PATH="" PROXY_CACHE_BYPASS_NO_CACHE=false PROXY_CACHE_IGNORE_HEADERS="${ignore_headers}" compose up -d

  wait_for_gateway

  p "Starting cache ignore headers tests (phase: ${ignore_phase})"
  echo "  test/integration/test_cache_ignore_headers.sh \"$test_server\" \"$test_dir\" ${ignore_phase} \"${mc_cmd}\" \"${minio_name}\" \"${minio_bucket}\""
  bash "${test_dir}/integration/test_cache_ignore_headers.sh" "${test_server}" "${test_dir}" "${ignore_phase}" "${mc_cmd}" "${minio_name}" "${minio_bucket}"
}

request_status() {
  "${curl_cmd}" --silent --output /dev/null --write-out '%{http_code}' "$@"
}

assert_request_status() {
  expected_status=$1
  description=$2
  shift 2
  actual_status="$(request_status "$@")"
  if [ "${actual_status}" != "${expected_status}" ]; then
    e "FAIL [${description}]: expected HTTP ${expected_status}, got ${actual_status}"
    exit "$test_fail_exit_code"
  fi
}

assert_request_not_status() {
  unexpected_status=$1
  description=$2
  shift 2
  actual_status="$(request_status "$@")"
  if [ "${actual_status}" = "${unexpected_status}" ]; then
    e "FAIL [${description}]: unexpectedly got HTTP ${unexpected_status}"
    exit "$test_fail_exit_code"
  fi
}

assert_gateway_logs_contain() {
  expected_text=$1
  description=$2
  # Capture the logs instead of piping into grep -q: under `set -o pipefail`
  # grep -q exits at the first match and a still-writing `compose logs` dies
  # with SIGPIPE (141), failing the pipeline exactly when the text is found.
  gateway_logs="$(compose logs nginx-s3-gateway 2>&1)"
  if ! grep -qF "${expected_text}" <<< "${gateway_logs}"; then
    e "FAIL [${description}]: expected gateway logs to contain '${expected_text}'"
    exit "$test_fail_exit_code"
  fi
}

start_tls_gateway() {
  trusted_cert_path=$1
  tls_s3_style=${2:-${S3_STYLE:-virtual-v2}}
  tls_s3_server=${3:-minio}
  export TEST_S3_TRUSTED_CERT_PATH="${trusted_cert_path}"
  export TEST_S3_SERVER="${tls_s3_server}"
  COMPOSE_COMPATIBILITY=true S3_STYLE="${tls_s3_style}" AWS_SIGS_VERSION=4 ALLOW_DIRECTORY_LIST=1 PROVIDE_INDEX_PAGE=1 APPEND_SLASH_FOR_POSSIBLE_DIRECTORY=1 STRIP_LEADING_DIRECTORY_PATH="" PREFIX_LEADING_DIRECTORY_PATH="" compose up -d
  wait_for_gateway
}

integration_test_proxy_ssl() {
  p "Testing HTTPS S3 origin certificate verification"
  generate_tls_test_certs
  compose stop || true
  compose rm -f -v || true
  set_https_test_origin
  integration_test_data

  p "Verifying an untrusted HTTPS S3 origin is rejected"
  start_tls_gateway "/etc/ssl/certs/ca-certificates.crt"
  assert_request_not_status 200 "untrusted object origin" "${test_server}/a.txt"
  assert_request_not_status 200 "untrusted directory origin" "${test_server}/b/"
  assert_request_not_status 200 "untrusted index origin" "${test_server}/statichost/"
  assert_gateway_logs_contain "upstream SSL certificate verify error" "untrusted origin verification"

  compose stop nginx-s3-gateway

  p "Verifying a trusted HTTPS S3 origin succeeds"
  start_tls_gateway "/etc/nginx/test-certs/ca.crt"
  assert_request_status 200 "trusted object origin" "${test_server}/a.txt"
  assert_request_status 206 "trusted sliced origin" -H "Range: bytes=0-9" "${test_server}/a.txt"
  assert_request_status 200 "trusted directory origin" "${test_server}/b/"
  assert_request_status 200 "trusted index origin" "${test_server}/statichost/"

  compose stop nginx-s3-gateway

  p "Verifying HTTPS S3 origin hostname validation"
  start_tls_gateway "/etc/nginx/test-certs/ca.crt" "path" "minio"
  assert_request_status 200 "trusted path-style origin" "${test_server}/a.txt"

  compose stop nginx-s3-gateway
  start_tls_gateway "/etc/nginx/test-certs/ca.crt" "path" "minio-mismatch"
  assert_request_not_status 200 "mismatched origin hostname" "${test_server}/a.txt"
  assert_gateway_logs_contain "upstream SSL certificate does not match" "mismatched origin hostname verification"
}

integration_test_dynamic_credentials() {
  p "Testing dynamic credential shared-memory caching"
  # Use the profile-aware config and remove its networks as well as its
  # containers. Leaving the fixed metadata subnet behind makes a later run
  # under a different COMPOSE_PROJECT fail with an overlapping-pool error.
  compose_dynamic_credentials down --volumes --remove-orphans || true
  set_http_test_origin

  COMPOSE_COMPATIBILITY=true AWS_SIGS_VERSION=4 ALLOW_DIRECTORY_LIST=0 PROVIDE_INDEX_PAGE=0 APPEND_SLASH_FOR_POSSIBLE_DIRECTORY=0 STRIP_LEADING_DIRECTORY_PATH="" PREFIX_LEADING_DIRECTORY_PATH="" compose_dynamic_credentials up -d
  wait_for_gateway
  seed_minio_data

  assert_request_status 200 "dynamic credentials first object request" "${test_server}/a.txt"

  # Captured rather than piped into grep -q for the same pipefail/SIGPIPE
  # reason as assert_gateway_logs_contain.
  credential_logs="$(compose_dynamic_credentials logs ecs-credentials 2>&1)"
  if ! grep -qF 'GET /credentials' <<< "${credential_logs}"; then
    e "FAIL [dynamic credential fetch]: the gateway never queried the metadata mock"
    exit "$test_fail_exit_code"
  fi

  # Prove cache reuse behaviorally rather than by counting access-log lines:
  # with the metadata mock stopped, further requests can only succeed if the
  # first fetch was cached in shared memory.
  compose_dynamic_credentials stop ecs-credentials
  assert_request_status 200 "dynamic credentials cached second object request" "${test_server}/b/e.txt"

  if ! compose_dynamic_credentials exec -T nginx-s3-gateway sh -c 'test ! -e /tmp/credentials.json'; then
    e "FAIL [dynamic credential disk exposure]: /tmp/credentials.json must not exist"
    exit "$test_fail_exit_code"
  fi
}

integration_test_secret_file_credentials() {
  p "Testing credentials supplied through mounted secret files"
  compose_secret_file_credentials down --volumes --remove-orphans || true
  set_http_test_origin

  # 0444 because compose bind-mounts a file-based secret with the host file's
  # own permissions: the value is read by the nginx worker user, not by root,
  # so a default-umask 0600 file would be unreadable inside the container.
  mkdir -p "${test_secrets_dir}"
  # Unlink first: the files this function leaves behind are 0444, so a run that
  # was killed before finish() could clean up would make the redirections below
  # fail with EACCES - even for their own owner - and abort the whole suite.
  rm -f "${test_secrets_dir}"/aws_access_key_id "${test_secrets_dir}"/aws_secret_access_key
  printf '%s\n' "${minio_user}" > "${test_secrets_dir}/aws_access_key_id"
  printf '%s\n' "${minio_passwd}" > "${test_secrets_dir}/aws_secret_access_key"
  chmod 0444 "${test_secrets_dir}"/aws_*

  COMPOSE_COMPATIBILITY=true AWS_SIGS_VERSION=4 ALLOW_DIRECTORY_LIST=0 PROVIDE_INDEX_PAGE=0 APPEND_SLASH_FOR_POSSIBLE_DIRECTORY=0 STRIP_LEADING_DIRECTORY_PATH="" PREFIX_LEADING_DIRECTORY_PATH="" compose_secret_file_credentials up -d
  wait_for_gateway
  seed_minio_data

  # A signed request only succeeds if the credentials made it out of the files
  # and through the nginx.conf env allowlist into the njs modules - a missing
  # `env AWS_ACCESS_KEY_ID_FILE;` directive shows up here and nowhere else.
  assert_request_status 200 "secret file credentials object request" "${test_server}/a.txt"

  # The point of the feature: the credentials are not in the environment of
  # the gateway process. Captured rather than piped into grep -q for the same
  # pipefail/SIGPIPE reason as assert_gateway_logs_contain: grep -q exits at
  # the first match and the still-writing producer dies with SIGPIPE (141),
  # failing the pipeline - and so passing this check - exactly when the secret
  # is found.
  gateway_env="$(compose_secret_file_credentials exec -T nginx-s3-gateway env 2>&1)"
  if grep -qF "${minio_passwd}" <<< "${gateway_env}"; then
    e "FAIL [secret file credentials]: the secret access key must not be in the container environment"
    exit "$test_fail_exit_code"
  fi
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
    compose_dynamic_credentials logs || true
  fi

  p "Cleaning up Docker compose environment"
  compose_dynamic_credentials down --volumes --remove-orphans || true
  "${mc_cmd}" alias rm "$minio_name" || true
  # Try a plain removal first: the cert dir is created by the invoking user,
  # so its entries are usually unlinkable without root even though the files
  # themselves are root-owned. Only spin up a root container (1-2s, and
  # impossible once the image has been pruned) when files actually survive
  # the plain attempt.
  rm -f "${test_tls_cert_dir}"/* 2> /dev/null || true
  if [ -d "${test_tls_cert_dir}" ] && [ -n "$(ls -A "${test_tls_cert_dir}" 2> /dev/null)" ]; then
    "${docker_cmd}" run --rm --user 0:0 -v "${test_tls_cert_dir}:/certs" --entrypoint /bin/sh nginx-s3-gateway -c 'rm -f /certs/*' > /dev/null 2>&1 || true
  fi
  rmdir "${test_tls_cert_dir}" 2> /dev/null || true
  # The secret files are created by the invoking user and only ever read from
  # inside the containers, so a plain removal is always enough here.
  rm -f "${test_secrets_dir}"/* 2> /dev/null || true
  rmdir "${test_secrets_dir}" 2> /dev/null || true

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

p "Testing proxy cache ignore headers entrypoint scripts"
bash "${test_dir}/integration/test_entrypoint_cache_ignore_headers.sh" "${docker_cmd}"

p "Testing file-backed credential entrypoint scripts"
bash "${test_dir}/integration/test_entrypoint_secret_files.sh" "${docker_cmd}"

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

# The cert dir must exist before the first compose up (docker would create
# a root-owned dir for the bind mount otherwise); the certificates
# themselves are only generated when the TLS phase needs them.
mkdir -p "${test_tls_cert_dir}"
set_http_test_origin
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

compose stop nginx-s3-gateway # Restart with new config

p "Testing proxy cache ignore headers with PROXY_CACHE_IGNORE_HEADERS unset (default)"
integration_test_cache_ignore_headers ""

compose stop nginx-s3-gateway # Restart with new config

p "Testing proxy cache ignore headers with PROXY_CACHE_IGNORE_HEADERS='Cache-Control Expires'"
integration_test_cache_ignore_headers "Cache-Control Expires"

integration_test_proxy_ssl

integration_test_dynamic_credentials

integration_test_secret_file_credentials

p "All integration tests complete"

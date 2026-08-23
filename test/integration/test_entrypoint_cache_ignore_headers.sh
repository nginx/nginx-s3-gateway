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

# Tests for the PROXY_CACHE_IGNORE_HEADERS plumbing (GH-64): the allowlist
# check in 00-check-for-required-env.sh and the directive that
# 25-set-proxy-ignore-headers.sh appends to the rendered
# gateway/proxy_ignore_headers.conf.
#
# These only need the image, not the compose environment. The rendering cases
# run 20-envsubst-on-templates.sh (from the base image) before the gateway
# script, mirroring the entrypoint's numeric-order execution.

set -o errexit   # abort on nonzero exit status
set -o pipefail  # don't hide errors within pipes

docker_cmd=$1

test_fail_exit_code=2
no_dep_exit_code=3

set -o nounset   # abort on unbound variable

if [ -z "${docker_cmd}" ]; then
  >&2 echo "missing first parameter: path to the docker executable"
  exit ${no_dep_exit_code}
fi

rendered_conf=/etc/nginx/conf.d/gateway/proxy_ignore_headers.conf

# Runs a shell snippet inside the gateway image with the baseline environment
# every entrypoint script needs, plus the PROXY_CACHE_IGNORE_HEADERS value
# under test. Echoes the combined output and returns the container exit code.
# MSYS_NO_PATHCONV=1 added to resolve automatic path conversion
# https://github.com/docker/for-win/issues/6754#issuecomment-629702199
runInImage() {
  ignore_headers=$1
  snippet=$2

  MSYS_NO_PATHCONV=1 "${docker_cmd}" run --rm \
    -e S3_BUCKET_NAME=test-bucket \
    -e S3_SERVER=s3.example.com \
    -e S3_SERVER_PORT=9000 \
    -e S3_SERVER_PROTO=http \
    -e S3_REGION=us-east-1 \
    -e S3_STYLE=virtual-v2 \
    -e AWS_ACCESS_KEY_ID=unit_test \
    -e AWS_SECRET_ACCESS_KEY=unit_test \
    -e AWS_SIGS_VERSION=4 \
    -e ALLOW_DIRECTORY_LIST=false \
    -e PROVIDE_INDEX_PAGE=false \
    -e APPEND_SLASH_FOR_POSSIBLE_DIRECTORY=false \
    -e CORS_ENABLED=false \
    -e PROXY_CACHE_IGNORE_HEADERS="${ignore_headers}" \
    --entrypoint /bin/sh nginx-s3-gateway -c "${snippet}" 2>&1
}

# assertValidationRejects <value> [expected_error_fragment]
assertValidationRejects() {
  value=$1
  expected_error=${2:-"PROXY_CACHE_IGNORE_HEADERS contains an unsupported field"}

  printf "  \033[36;1m▲\033[0m "
  echo "Entrypoint validation must reject PROXY_CACHE_IGNORE_HEADERS='${value}'"

  set +o errexit
  output=$(runInImage "${value}" 'bash /docker-entrypoint.d/00-check-for-required-env.sh')
  status=$?
  set -o errexit

  if [ ${status} -eq 0 ]; then
    >&2 echo "FAIL: 00-check-for-required-env.sh exited 0 for the invalid value '${value}':"
    >&2 echo "${output}"
    exit ${test_fail_exit_code}
  fi

  if ! echo "${output}" | grep -qF "${expected_error}"; then
    >&2 echo "FAIL: expected an error containing [${expected_error}] for '${value}' but got:"
    >&2 echo "${output}"
    exit ${test_fail_exit_code}
  fi
}

# assertValidationAccepts <value>
assertValidationAccepts() {
  value=$1

  printf "  \033[36;1m▲\033[0m "
  echo "Entrypoint validation must accept PROXY_CACHE_IGNORE_HEADERS='${value}'"

  if ! output=$(runInImage "${value}" 'bash /docker-entrypoint.d/00-check-for-required-env.sh'); then
    >&2 echo "FAIL: 00-check-for-required-env.sh rejected the valid value '${value}':"
    >&2 echo "${output}"
    exit ${test_fail_exit_code}
  fi
}

# Renders the templates and applies 25-set-proxy-ignore-headers.sh, then
# prints the resulting conf file with the comment lines stripped.
# assertRenders <value> <expected_directive_or_empty>
assertRenders() {
  value=$1
  expected=$2

  printf "  \033[36;1m▲\033[0m "
  echo "Rendered ${rendered_conf} for PROXY_CACHE_IGNORE_HEADERS='${value}' must be [${expected}]"

  output=$(runInImage "${value}" \
    ". /docker-entrypoint.d/01-set-defaults.envsh \
     && /docker-entrypoint.d/20-envsubst-on-templates.sh > /dev/null \
     && /docker-entrypoint.d/25-set-proxy-ignore-headers.sh > /dev/null \
     && grep -v '^#' ${rendered_conf} | tr -d '[:space:]'")

  if [ "${output}" != "${expected}" ]; then
    >&2 echo "FAIL: expected [${expected}] in ${rendered_conf} but got [${output}]"
    exit ${test_fail_exit_code}
  fi
}

assertValidationRejects "Cache-Control Content-Type"
assertValidationRejects "proxy_pass http://evil;"
# A line break must not let the rest of the value skip the allowlist: the
# whole value is interpolated into the nginx configuration, not just its
# first line.
assertValidationRejects "$(printf 'Cache-Control\nproxy_pass http://evil;')"
# A whitespace-only value is non-empty, so the apply step would render
# 'proxy_ignore_headers ;' - reject it with a diagnostic instead of letting
# NGINX fail to start.
assertValidationRejects "   " "PROXY_CACHE_IGNORE_HEADERS is set but contains no field names"
assertValidationAccepts "Cache-Control Expires"
# nginx matches these field names case-insensitively, so the allowlist does too.
assertValidationAccepts "cache-control x-accel-expires SET-COOKIE Vary"

assertRenders "Cache-Control Expires" "proxy_ignore_headersCache-ControlExpires;"
# Unset must leave the directive out entirely - proxy_ignore_headers requires
# at least one field name, so an empty rendering would be a parse error.
assertRenders "" ""

echo "PASS: PROXY_CACHE_IGNORE_HEADERS validation and rendering"

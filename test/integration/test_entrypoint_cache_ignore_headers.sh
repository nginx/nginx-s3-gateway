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

set -o nounset   # abort on unbound variable

# The shared runInImage and assertion helpers; also validates ${docker_cmd}.
. "$(dirname "${BASH_SOURCE[0]}")/entrypoint_test_lib.sh" "${docker_cmd}"

rendered_conf=/etc/nginx/conf.d/gateway/proxy_ignore_headers.conf

# Every case here signs with the same static credentials under v4; only the
# PROXY_CACHE_IGNORE_HEADERS value under test varies.
baseline_extra_env=(
  -e "AWS_ACCESS_KEY_ID=unit_test"
  -e "AWS_SECRET_ACCESS_KEY=unit_test"
  -e "AWS_SIGS_VERSION=4"
)

# assertRejects <value> [expected_error_fragment]
assertRejects() {
  value=$1
  expected_error=${2:-"PROXY_CACHE_IGNORE_HEADERS contains an unsupported field"}

  assertValidationRejects "PROXY_CACHE_IGNORE_HEADERS='${value}'" "${expected_error}" \
    -e PROXY_CACHE_IGNORE_HEADERS="${value}"
}

# assertAccepts <value>
assertAccepts() {
  assertValidationAccepts "PROXY_CACHE_IGNORE_HEADERS='$1'" \
    -e PROXY_CACHE_IGNORE_HEADERS="$1"
}

# Renders the templates and applies 25-set-proxy-ignore-headers.sh, then
# prints the resulting conf file with the comment lines stripped.
# assertRenders <value> <expected_directive_or_empty>
assertRenders() {
  value=$1
  expected=$2

  announceCase "Rendered ${rendered_conf} for PROXY_CACHE_IGNORE_HEADERS='${value}' must be [${expected}]"

  output=$(runInImage \
    ". /docker-entrypoint.d/01-set-defaults.envsh \
     && /docker-entrypoint.d/20-envsubst-on-templates.sh > /dev/null \
     && /docker-entrypoint.d/25-set-proxy-ignore-headers.sh > /dev/null \
     && grep -v '^#' ${rendered_conf} | tr -d '[:space:]'" \
    -e PROXY_CACHE_IGNORE_HEADERS="${value}")

  if [ "${output}" != "${expected}" ]; then
    failCase "FAIL: expected [${expected}] in ${rendered_conf} but got [${output}]"
  fi
}

assertRejects "Cache-Control Content-Type"
assertRejects "proxy_pass http://evil;"
# A line break must not let the rest of the value skip the allowlist: the
# whole value is interpolated into the nginx configuration, not just its
# first line.
assertRejects "$(printf 'Cache-Control\nproxy_pass http://evil;')"
# A whitespace-only value is non-empty, so the apply step would render
# 'proxy_ignore_headers ;' - reject it with a diagnostic instead of letting
# NGINX fail to start.
assertRejects "   " "PROXY_CACHE_IGNORE_HEADERS is set but contains no field names"
assertAccepts "Cache-Control Expires"
# nginx matches these field names case-insensitively, so the allowlist does too.
assertAccepts "cache-control x-accel-expires SET-COOKIE Vary"

assertRenders "Cache-Control Expires" "proxy_ignore_headersCache-ControlExpires;"
# Unset must leave the directive out entirely - proxy_ignore_headers requires
# at least one field name, so an empty rendering would be a parse error.
assertRenders "" ""

echo "PASS: PROXY_CACHE_IGNORE_HEADERS validation and rendering"

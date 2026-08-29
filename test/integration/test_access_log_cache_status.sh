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

# Integration tests for the ACCESS_LOG_CACHE_STATUS feature (GH-466). The
# gateway must already be running with the feature configured to match
# ${phase} - the runner piggybacks this script on the cache bypass phases,
# whose gateway recreation guarantees the cold cache the MISS assertion
# needs. The requests target an object no other test in those phases touches
# (/a.txt), so the matched access-log lines are exactly the ones issued here.
#
# The access log reaches the container's stdout through the base image's
# /var/log/nginx/access.log symlink, so the assertions read `docker logs` of
# the gateway container. Lines are matched on the request plus the 200
# status: nginx error-log lines quoting the request (DEBUG is on in the test
# compose file) put a comma after the closing quote, so they cannot match.

set -o errexit   # abort on nonzero exit status
set -o pipefail  # don't hide errors within pipes

test_server=$1
phase=$2
docker_cmd=$3
gateway_container=$4

test_fail_exit_code=2
no_dep_exit_code=3

set -o nounset   # abort on unbound variable

e() {
  >&2 echo "$1"
}

if [ -z "${test_server}" ]; then
  e "missing first parameter: test server location (eg http://localhost:80)"
  exit ${no_dep_exit_code}
fi

if [ "${phase}" != "disabled" ] && [ "${phase}" != "enabled" ]; then
  e "second parameter must be 'disabled' or 'enabled', got: [${phase}]"
  exit ${no_dep_exit_code}
fi

if [ -z "${docker_cmd}" ] || ! [ -x "${docker_cmd}" ]; then
  e "missing third parameter: path to the docker executable"
  exit ${no_dep_exit_code}
fi

if [ -z "${gateway_container}" ]; then
  e "missing fourth parameter: id or name of the running gateway container"
  exit ${no_dep_exit_code}
fi

curl_cmd="$(command -v curl || true)"
if ! [ -x "${curl_cmd}" ]; then
  e "required dependency not found: curl not found in the path or not executable"
  exit ${no_dep_exit_code}
fi
curl_cmd="${curl_cmd} --connect-timeout 3 --max-time 30 --no-progress-meter"

test_object_path="/a.txt"

announce() {
  printf "  \033[36;1m▲\033[0m "
  echo "$1"
}

# Issues a GET for ${test_object_path} and fails unless it returns 200: a
# non-200 would write its own access-log line and corrupt the status-sequence
# assertion below with a misleading diagnostic.
# getTestObject <label> [extra curl args...]
getTestObject() {
  label=$1
  shift

  status="$(${curl_cmd} --silent --output /dev/null --write-out '%{http_code}' \
    "$@" "${test_server}${test_object_path}")"
  if [ "${status}" != "200" ]; then
    e "FAIL [${label}]: expected HTTP 200 for GET ${test_object_path}, got ${status}"
    exit ${test_fail_exit_code}
  fi
}

# Prints the access-log lines for the requests this script issued, in order.
matchedLogLines() {
  gateway_logs="$("${docker_cmd}" logs "${gateway_container}" 2>&1)"
  # || true: no matching line is asserted on by the callers, not here.
  grep -F "\"GET ${test_object_path} HTTP/1.1\" 200 " <<< "${gateway_logs}" || true
}

if [ "${phase}" = "enabled" ]; then
  announce "Access log cache status [enabled]: MISS, HIT, then BYPASS for ${test_object_path}"

  # Cold cache (the runner recreated the gateway for this phase), so the
  # first fetch misses, the second hits, and - since this phase also runs
  # with PROXY_CACHE_BYPASS_NO_CACHE=true - a no-cache request bypasses.
  getTestObject "prime cache"
  getTestObject "cached fetch"
  getTestObject "bypassing fetch" -H "Cache-Control: no-cache"

  statuses="$(matchedLogLines | awk '{printf "%s ", $NF}')"
  if [ "${statuses}" != '"MISS" "HIT" "BYPASS" ' ]; then
    e "FAIL [access log cache status sequence]: expected [\"MISS\" \"HIT\" \"BYPASS\"], got [${statuses}] from:"
    matchedLogLines >&2
    exit ${test_fail_exit_code}
  fi
else
  announce "Access log cache status [disabled]: log lines end at the X-Forwarded-For field"

  getTestObject "fetch with cache status logging off"

  log_line="$(matchedLogLines | tail -n 1)"
  if [ -z "${log_line}" ]; then
    e "FAIL [access log format]: no access-log line found for GET ${test_object_path}"
    exit ${test_fail_exit_code}
  fi
  # curl sends no X-Forwarded-For, so the historical format ends in its "-"
  # placeholder; a trailing cache-status field would end in "MISS" instead.
  if [ "${log_line%\"-\"}" = "${log_line}" ]; then
    e "FAIL [access log format]: expected the line to end at the X-Forwarded-For field but got:"
    e "${log_line}"
    exit ${test_fail_exit_code}
  fi
fi

echo "  Access log cache status tests (phase: ${phase}) passed"

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

# Integration tests for the CORS contract. The gateway must already be
# running with CORS_ENABLED=true and CORS_ALLOWED_ORIGIN set to the origin
# passed as the third argument; this script only issues requests.
#
# This is a dedicated script rather than a test_api.sh mode because
# test_api.sh pins the CORS-off side of the same GH-496 method policy
# (OPTIONS rejected with 405, Allow "GET, HEAD", no
# Access-Control-Allow-Origin on 405s) - the two scripts assert opposite
# sides of one contract; keep them in sync.
#
# No Origin request header is sent anywhere: the gateway's CORS handling
# keys on the request method alone (cors.conf matches $request_method
# against the baked-in CORS_ENABLED), and header emission must not silently
# grow a dependency on one.

set -o errexit   # abort on nonzero exit status
set -o pipefail  # don't hide errors within pipes

test_server=$1
test_dir=$2
cors_allowed_origin=$3

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

# No fixture bodies are compared today; the argument is validated anyway so
# this script keeps the same (test_server, test_dir, ...) calling convention
# as every other integration script.
if [ -z "${test_dir}" ]; then
  e "missing second parameter: path to test data directory"
  exit ${no_dep_exit_code}
fi

if [ -z "${cors_allowed_origin}" ]; then
  e "missing third parameter: the origin the gateway was configured to allow (CORS_ALLOWED_ORIGIN)"
  exit ${no_dep_exit_code}
fi

curl_cmd="$(command -v curl || true)"
if ! [ -x "${curl_cmd}" ]; then
  e "required dependency not found: curl not found in the path or not executable"
  exit ${no_dep_exit_code}
fi
curl_cmd="${curl_cmd} --connect-timeout 3 --max-time 30 --no-progress-meter"

# Sends one request and captures the status line plus response headers into
# the `headers` global that the assertHeader* helpers below read, so the
# status assertion and every header assertion for a request observe the same
# response. HEAD uses --head so curl does not wait for a body that will
# never arrive. -o /dev/null is load-bearing on every request shape: with
# --head the headers are also curl's "document", and without -o the -D -
# dump and the document would both land on stdout, doubling every header and
# breaking the count assertions.
# assertRequest <method> <path> <expected_status> <label>
assertRequest() {
  method="$1"
  path="$2"
  expected_status="$3"
  label="$4"
  uri="${test_server}${path}"

  printf "  \033[36;1m▲\033[0m "
  echo "CORS [${label}]: ${method} ${path}"

  if [ "${method}" = "HEAD" ]; then
    headers="$(${curl_cmd} -D - -o /dev/null --head "${uri}")"
  else
    headers="$(${curl_cmd} -D - -o /dev/null -X "${method}" "${uri}")"
  fi

  IFS= read -r status_line <<< "${headers}"
  actual_status="${status_line#* }"
  actual_status="${actual_status:0:3}"

  if [ "${expected_status}" != "${actual_status}" ]; then
    e "Response code didn't match expectation. CORS [${label}] Request [${method} ${uri}] Expected [${expected_status}] Actual [${actual_status}]"
    e "curl command: ${curl_cmd} -D - -o /dev/null -X '${method}' '${uri}'"
    exit ${test_fail_exit_code}
  fi
}

# Prints the value of the first occurrence of <header_name> in the captured
# headers (name matched case-insensitively via tr - bash 3.2 on macOS has no
# ${var,,} expansion), with the trailing CR stripped. Prints nothing when
# the header is absent, which is indistinguishable from present-but-empty;
# absence and multiplicity checks therefore go through countHeader.
# headerValue <header_name>
headerValue() {
  wanted="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  value=""
  while IFS= read -r header; do
    name="$(printf '%s' "${header%%:*}" | tr '[:upper:]' '[:lower:]')"
    if [ "${name}" = "${wanted}" ]; then
      value="${header#*: }"
      value="${value%$'\r'}"
      break
    fi
  done <<< "${headers}"
  printf '%s' "${value}"
}

# Prints how many times <header_name> occurs in the captured headers.
# Counted in the loop rather than with grep -c, which exits 1 on a zero
# count and would abort the script through errexit/pipefail.
# countHeader <header_name>
countHeader() {
  wanted="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  count=0
  while IFS= read -r header; do
    name="$(printf '%s' "${header%%:*}" | tr '[:upper:]' '[:lower:]')"
    if [ "${name}" = "${wanted}" ]; then
      count=$((count + 1))
    fi
  done <<< "${headers}"
  printf '%s' "${count}"
}

# Asserts against the response captured by the preceding assertRequest.
# assertHeaderEquals <header_name> <expected_value> <label>
assertHeaderEquals() {
  header_name="$1"
  expected_value="$2"
  header_label="$3"
  actual_value="$(headerValue "${header_name}")"

  if [ "${expected_value}" != "${actual_value}" ]; then
    e "${header_name} header didn't match expectation. CORS [${header_label}] Request [${method} ${uri}] Expected [${expected_value}] Actual [${actual_value}]"
    e "curl command: ${curl_cmd} -D - -o /dev/null -X '${method}' '${uri}'"
    exit ${test_fail_exit_code}
  fi
}

# assertHeaderCount <header_name> <expected_count> <label>
assertHeaderCount() {
  header_name="$1"
  expected_count="$2"
  header_label="$3"
  actual_count="$(countHeader "${header_name}")"

  if [ "${expected_count}" != "${actual_count}" ]; then
    e "${header_name} header count didn't match expectation. CORS [${header_label}] Request [${method} ${uri}] Expected [${expected_count}] Actual [${actual_count}]"
    e "curl command: ${curl_cmd} -D - -o /dev/null -X '${method}' '${uri}'"
    exit ${test_fail_exit_code}
  fi
}

# Check to see if HTTP server is available
set +o errexit
# Allow curl command to fail with a non-zero exit code for this block because
# we want to use it to test to see if the server is actually up.
for (( i=1; i<=3; i++ )); do
  # Add the -v flag to the curl command below to debug why curl is failing
  response="$(${curl_cmd} -s -o /dev/null -w '%{http_code}' --head "${test_server}")"
  if [ "${response}" != "000" ]; then
    break
  fi
  wait_time="$((i * 2))"
  e "Failed to access ${test_server} - trying again in ${wait_time} seconds, try ${i}/3"
  sleep ${wait_time}
done
set -o errexit

# The retry loop's last probe is six seconds stale once the final backoff
# sleep finishes, so probe once more before giving up: a slow-starting
# gateway that became ready during the last sleep must not be reported as
# down. An empty response means curl exited without probing (usage error or
# killed by a signal), so re-probe for that case as well.
if [ "${response}" = "000" ] || [ -z "${response}" ]; then
  response="$(${curl_cmd} -s -o /dev/null -w '%{http_code}' --head "${test_server}" || true)"
fi

# Without this guard an unreachable server kills the script via errexit at
# the first assertion's curl - a bare curl exit code blamed on whichever
# assertion happened to run first - instead of one clear diagnostic and the
# documented exit code. Mirrors the guards in test_api.sh and
# test_cache_bypass.sh; keep them in sync.
if [ "${response}" = "000" ] || [ -z "${response}" ]; then
  e "unable to reach the test server at [${test_server}] - is the gateway running?"
  exit ${no_dep_exit_code}
fi

# --- Preflight --------------------------------------------------------------
# The advertised method list must mirror the method policy the gateway
# actually enforces (LIMIT_METHODS_TO_CSV). The previous hardcoded list
# advertised POST - which every path rejects on this read-only gateway
# (GH-496/GH-551) - and omitted HEAD, which the gateway serves. Each of the
# three Access-Control-Allow-Methods rows in cors.conf.template (OPTIONS,
# GET, HEAD) gets its own assertion below so a partially applied edit cannot
# pass. Access-Control-Max-Age and Access-Control-Allow/Expose-Headers are
# deliberately not asserted: they are static template text a deployment may
# customize by overriding cors.conf, not part of the method-policy contract
# under test. Access-Control-Allow-Private-Network IS asserted: the CORS leg
# configures CORS_ALLOW_PRIVATE_NETWORK_ACCESS=TRUE, so the preflight must
# carry the header with the normalized literal 'true' (GH-600) - emitted by
# the OPTIONS_1 block only, hence no matching assertion on GET/HEAD.
assertRequest "OPTIONS" "/a.txt" "204" "preflight approved"
assertHeaderEquals "Access-Control-Allow-Origin" "${cors_allowed_origin}" "preflight passes the configured origin through"
assertHeaderEquals "Access-Control-Allow-Methods" "GET, HEAD, OPTIONS" "preflight advertises the enforced read-only policy"
assertHeaderEquals "Access-Control-Allow-Private-Network" "true" "preflight carries the normalized private-network consent"
assertHeaderCount "Access-Control-Allow-Private-Network" "1" "preflight carries the private-network header exactly once"

# --- Served methods ---------------------------------------------------------
assertRequest "GET" "/a.txt" "200" "GET served with CORS headers"
assertHeaderEquals "Access-Control-Allow-Origin" "${cors_allowed_origin}" "GET carries the origin"
assertHeaderEquals "Access-Control-Allow-Methods" "GET, HEAD, OPTIONS" "GET methods row mirrors the policy"

assertRequest "HEAD" "/a.txt" "200" "HEAD served with CORS headers"
assertHeaderEquals "Access-Control-Allow-Origin" "${cors_allowed_origin}" "HEAD carries the origin"
assertHeaderEquals "Access-Control-Allow-Methods" "GET, HEAD, OPTIONS" "HEAD methods row mirrors the policy"

# A GET through the regex */index.html location (a different location
# context from `location /` -> @s3) exercises that location's own cors.conf
# include: the 200 must carry the origin exactly once, from the GET_1 if
# block alone.
assertRequest "GET" "/gh551-writeguard/index.html" "200" "index.html GET served with CORS headers"
assertHeaderEquals "Access-Control-Allow-Origin" "${cors_allowed_origin}" "index.html GET carries the origin"
assertHeaderCount "Access-Control-Allow-Origin" "1" "index.html GET carries the origin exactly once"

# --- Rejected methods -------------------------------------------------------
# Non-read methods are rejected in the rewrite phase of `location /`
# (GH-496) and answered by @error405, which cors.conf cannot decorate - its
# if rows only ever match GET, HEAD, and OPTIONS. The origin here comes from
# the $cors_error_origin map in default.conf.template; without it a
# cross-origin caller sees an opaque CORS failure instead of this
# 405 + Allow contract. With CORS enabled, Allow must include OPTIONS
# (test_api.sh pins the CORS-off value "GET, HEAD").
assertRequest "POST" "/a.txt" "405" "POST rejected"
assertHeaderEquals "Allow" "GET, HEAD, OPTIONS" "405 Allow includes OPTIONS when CORS is enabled"
assertHeaderEquals "Access-Control-Allow-Origin" "${cors_allowed_origin}" "405 carries the origin"
assertHeaderCount "Access-Control-Allow-Origin" "1" "405 carries the origin exactly once"

assertRequest "PUT" "/a.txt" "405" "PUT rejected"
assertHeaderEquals "Access-Control-Allow-Origin" "${cors_allowed_origin}" "PUT 405 carries the origin"

assertRequest "DELETE" "/a.txt" "405" "DELETE rejected"
assertHeaderEquals "Access-Control-Allow-Origin" "${cors_allowed_origin}" "DELETE 405 carries the origin"

# --- Sanitized 404s ---------------------------------------------------------
# A missing object surfaces as the sanitized 404 from @error404. For GET the
# origin comes from cors.conf's GET_1 if block, which declares add_header
# directives of its own and therefore does NOT inherit the location-level
# $cors_error_origin add_header (nginx add_header inheritance is
# all-or-nothing per context) - the count assertion pins that the two
# sources can never double up.
assertRequest "GET" "/gh496-cors-does-not-exist" "404" "sanitized 404 carries CORS headers"
assertHeaderEquals "Access-Control-Allow-Origin" "${cors_allowed_origin}" "404 carries the origin"
assertHeaderCount "Access-Control-Allow-Origin" "1" "404 carries the origin exactly once"

# On */index.html paths, non-read methods are denied by limit_except and
# collapsed to the same sanitized 404 (GH-551). No cors.conf if row matches
# POST, so only the map-driven location-level add_header can supply the
# origin, and the count doubles as the duplication guard for that path. The
# dedicated gh551-writeguard fixture is used for the same blast-radius
# reason as in test_api.sh: a regression that forwarded the POST to S3 must
# not corrupt fixtures other assertions and legs depend on.
assertRequest "POST" "/gh551-writeguard/index.html" "404" "GH-551 denial carries CORS headers"
assertHeaderEquals "Access-Control-Allow-Origin" "${cors_allowed_origin}" "GH-551 404 carries the origin"
assertHeaderCount "Access-Control-Allow-Origin" "1" "GH-551 404 carries the origin exactly once"

echo "  CORS tests passed"

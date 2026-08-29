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

# Integration tests for the PROXY_CACHE_BYPASS_NO_CACHE feature. The gateway
# must already be running with the feature configured; this script only
# issues requests and mutates objects in the S3 origin to prove whether
# a request with Cache-Control: no-cache bypasses the local proxy cache.
#
# The test relies on PROXY_CACHE_VALID_OK being long (1h in the test compose
# file) so that a primed cache entry stays fresh for the duration of the run,
# making "stale body served" a deterministic assertion.

set -o errexit   # abort on nonzero exit status
set -o pipefail  # don't hide errors within pipes

test_server=$1
test_dir=$2
phase=$3
origin_endpoint=$4
origin_bucket=$5
origin_access_key=$6
origin_secret_key=$7

test_fail_exit_code=2
no_dep_exit_code=3
checksum_length=32

set -o nounset   # abort on unbound variable

e() {
  >&2 echo "$1"
}

if [ -z "${test_server}" ]; then
  e "missing first parameter: test server location (eg http://localhost:80)"
  exit ${no_dep_exit_code}
fi

if [ -z "${test_dir}" ]; then
  e "missing second parameter: path to test data directory"
  exit ${no_dep_exit_code}
fi

if [ "${phase}" != "disabled" ] && [ "${phase}" != "enabled" ]; then
  e "third parameter must be 'disabled' or 'enabled', got: [${phase}]"
  exit ${no_dep_exit_code}
fi

if [ -z "${origin_endpoint}" ]; then
  e "missing fourth parameter: endpoint URL of the S3 origin (eg http://localhost:9090)"
  exit ${no_dep_exit_code}
fi

if [ -z "${origin_bucket}" ]; then
  e "missing fifth parameter: name of the S3 origin bucket"
  exit ${no_dep_exit_code}
fi

if [ -z "${origin_access_key}" ] || [ -z "${origin_secret_key}" ]; then
  e "missing sixth/seventh parameter: access key and secret key for the S3 origin"
  exit ${no_dep_exit_code}
fi

curl_cmd="$(command -v curl || true)"
if ! [ -x "${curl_cmd}" ]; then
  e "required dependency not found: curl not found in the path or not executable"
  exit ${no_dep_exit_code}
fi
curl_cmd="${curl_cmd} --connect-timeout 3 --max-time 30 --no-progress-meter"

# Allow for MacOS which does not support "md5sum"
# but has "md5 -r" which can be substituted
checksum_cmd="$(command -v md5sum || command -v md5 || true)"

if ! [ -x "${checksum_cmd}" ]; then
  e "required dependency not found: md5sum not found in the path or not executable"
  exit ${no_dep_exit_code}
fi

file_convert_command="$(command -v dd || true)"

if ! [ -x "${file_convert_command}" ]; then
  e "required dependency not found: dd not found in the path or not executable"
  exit ${no_dep_exit_code}
fi

# If we are using the `md5` executable
# then use the -r flag which makes it behave the same as `md5sum`
# this is done after the `-x` check for ability to execute
# since it will not pass with the flag
if [[ $checksum_cmd =~ \/md5$ ]]; then
  checksum_cmd="${checksum_cmd} -r"
fi

fixture_dir="${test_dir}/data/${origin_bucket}/cache-bypass"

# Populates the curl_args array with the optional Host and Cache-Control
# request headers shared by the assertion helpers below, so the two helpers
# cannot drift in what they send. Callers expand it nounset-safely as
# ${curl_args[@]+"${curl_args[@]}"} because an empty-array expansion trips
# `set -o nounset` on bash < 4.4 (macOS ships bash 3.2).
# buildCurlHeaderArgs <host_or_empty> <cache_control_or_empty>
buildCurlHeaderArgs() {
  curl_args=()

  if [ -n "$1" ]; then
    curl_args+=(-H "Host: $1")
  fi

  if [ -n "$2" ]; then
    curl_args+=(-H "Cache-Control: $2")
  fi
}

# Asserts that a GET of <url_path>, optionally sent with a Cache-Control
# request header, returns a body identical to <local_file>.
# assertGetEquals <url_path> <local_file> <cache_control_value_or_empty> <label> [host_header]
assertGetEquals() {
  path="$1"
  expected_file="$2"
  cache_control="$3"
  label="$4"
  host="${5:-}"
  uri="${test_server}${path}"
  buildCurlHeaderArgs "${host}" "${cache_control}"

  printf "  \033[36;1m▲\033[0m "
  echo "Cache bypass [${label}]: GET ${path} (Host: ${host:-<default>}, Cache-Control: ${cache_control:-<none>})"

  checksum_output="$(${checksum_cmd} "${expected_file}")"
  expected_checksum="${checksum_output:0:${checksum_length}}"

  curl_checksum_output="$(${curl_cmd} ${curl_args[@]+"${curl_args[@]}"} "${uri}" | ${checksum_cmd})"
  actual_checksum="${curl_checksum_output:0:${checksum_length}}"

  if [ "${expected_checksum}" != "${actual_checksum}" ]; then
    e "Checksum doesn't match expectation. Cache bypass [${label}] Request [GET ${uri} Host: ${host:-<default>} Cache-Control: ${cache_control:-<none>}] Expected [${expected_checksum} = $(basename "${expected_file}")] Actual [${actual_checksum}]"
    e "curl command: ${curl_cmd} ${curl_args[*]+"${curl_args[*]}"} '${uri}' | ${checksum_cmd}"
    exit ${test_fail_exit_code}
  fi
}

# Same as assertGetEquals but for a byte-range request, which the gateway
# routes to the @s3_sliced location backed by the separate slice cache.
# assertRangeGetEquals <url_path> <local_file> <start> <end> <cache_control_value_or_empty> <label> [host_header]
assertRangeGetEquals() {
  path="$1"
  expected_file="$2"
  range_start="$3"
  range_end="$4"
  cache_control="$5"
  label="$6"
  host="${7:-}"
  uri="${test_server}${path}"
  byte_count=$((range_end - range_start + 1)) # add one since we read through the last byte
  buildCurlHeaderArgs "${host}" "${cache_control}"

  printf "  \033[36;1m▲\033[0m "
  echo "Cache bypass [${label}]: GET ${path} bytes ${range_start}-${range_end} (Host: ${host:-<default>}, Cache-Control: ${cache_control:-<none>})"

  file_checksum="$(${file_convert_command} if="${expected_file}" bs=1 skip="${range_start}" count="${byte_count}" 2>/dev/null | ${checksum_cmd})"
  expected_checksum="${file_checksum:0:${checksum_length}}"

  curl_checksum_output="$(${curl_cmd} ${curl_args[@]+"${curl_args[@]}"} -r "${range_start}"-"${range_end}" "${uri}" | ${checksum_cmd})"
  actual_checksum="${curl_checksum_output:0:${checksum_length}}"

  if [ "${expected_checksum}" != "${actual_checksum}" ]; then
    e "Checksum doesn't match expectation. Cache bypass [${label}] Request [GET ${uri} Host: ${host:-<default>} Range: ${range_start}-${range_end} Cache-Control: ${cache_control:-<none>}] Expected [${expected_checksum} = $(basename "${expected_file}")] Actual [${actual_checksum}]"
    e "curl command: ${curl_cmd} ${curl_args[*]+"${curl_args[*]}"} -r ${range_start}-${range_end} '${uri}' | ${checksum_cmd}"
    exit ${test_fail_exit_code}
  fi
}

# origin_client (and the aws_cmd lookup, which aborts with the no-dependency
# exit code when the AWS CLI is missing) comes from the shared client lib, so
# its operator-credential isolation cannot drift from the parent runner's.
# The lib derives TLS handling from the endpoint scheme.
. "$(dirname "${BASH_SOURCE[0]}")/s3_client_lib.sh" \
  "${origin_endpoint}" "${origin_access_key}" "${origin_secret_key}"

# Overwrites an object in the S3 origin with the contents of a local
# file, without touching the gateway's cache.
# overwriteObject <local_src_file> <object_key>
overwriteObject() {
  local_src="$1"
  object_key="$2"
  echo "  Overwriting object ${origin_bucket}/${object_key} with contents of $(basename "${local_src}")"
  origin_client s3 cp --no-progress "${local_src}" "s3://${origin_bucket}/${object_key}" > /dev/null
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
# documented exit code. Mirrors the guard in test_api.sh; keep the two in
# sync.
if [ "${response}" = "000" ] || [ -z "${response}" ]; then
  e "unable to reach the test server at [${test_server}] - is the gateway running?"
  exit ${no_dep_exit_code}
fi

if [ "${phase}" = "disabled" ]; then
  # With PROXY_CACHE_BYPASS_NO_CACHE=false (the default), a request with
  # Cache-Control: no-cache must NOT bypass the cache.
  assertGetEquals "/cache-bypass/disabled.txt" "${fixture_dir}/disabled.txt" "" "prime cache"
  overwriteObject "${fixture_dir}/updated.txt" "cache-bypass/disabled.txt"
  assertGetEquals "/cache-bypass/disabled.txt" "${fixture_dir}/disabled.txt" "no-cache" "no-cache ignored when feature off"
  assertGetEquals "/cache-bypass/disabled.txt" "${fixture_dir}/disabled.txt" "" "cache entry untouched"

  # The slice cache must ignore the header as well. @s3_sliced only receives
  # proxy_cache_bypass through server-level inheritance, so cover the
  # feature-off contract for byte-range requests explicitly: a stray
  # location-level bypass directive would otherwise never fail a test.
  assertRangeGetEquals "/cache-bypass/sliced.txt" "${fixture_dir}/sliced.txt" 0 9 "" "prime slice cache"
  overwriteObject "${fixture_dir}/updated.txt" "cache-bypass/sliced.txt"
  assertRangeGetEquals "/cache-bypass/sliced.txt" "${fixture_dir}/sliced.txt" 0 9 "no-cache" "no-cache ignored by slice cache when feature off"

  # Viewer Host is not part of the effective S3 request identity. A different
  # Host header must reuse the same full-body and slice cache entries instead
  # of forcing a second fetch to S3. A different slice range must still fetch
  # independently.
  assertGetEquals "/cache-bypass/enabled.txt" "${fixture_dir}/enabled.txt" "" "prime cache under first viewer Host" "a.example"
  overwriteObject "${fixture_dir}/updated.txt" "cache-bypass/enabled.txt"
  assertGetEquals "/cache-bypass/enabled.txt" "${fixture_dir}/enabled.txt" "" "different viewer Host shares cache entry" "b.example"
  overwriteObject "${fixture_dir}/enabled.txt" "cache-bypass/enabled.txt"

  assertRangeGetEquals "/cache-bypass/sliced.txt" "${fixture_dir}/sliced.txt" 0 9 "" "prime slice under first viewer Host" "a.example"
  overwriteObject "${fixture_dir}/updated.txt" "cache-bypass/sliced.txt"
  assertRangeGetEquals "/cache-bypass/sliced.txt" "${fixture_dir}/sliced.txt" 0 9 "" "different viewer Host shares slice entry" "b.example"
  assertRangeGetEquals "/cache-bypass/sliced.txt" "${fixture_dir}/updated.txt" 10 19 "" "different slice range stays independent" "b.example"

  # Restore the overwritten objects so that the enabled phase and any rerun
  # against a warm origin start from the checked-in fixture content.
  overwriteObject "${fixture_dir}/enabled.txt" "cache-bypass/enabled.txt"
  overwriteObject "${fixture_dir}/disabled.txt" "cache-bypass/disabled.txt"
  overwriteObject "${fixture_dir}/sliced.txt" "cache-bypass/sliced.txt"
else
  # With PROXY_CACHE_BYPASS_NO_CACHE=true, only a request whose
  # Cache-Control header contains a syntactically valid no-cache token
  # bypasses the cache; the fresh response must refresh the cache entry.
  assertGetEquals "/cache-bypass/enabled.txt" "${fixture_dir}/enabled.txt" "" "prime cache"
  overwriteObject "${fixture_dir}/updated.txt" "cache-bypass/enabled.txt"
  assertGetEquals "/cache-bypass/enabled.txt" "${fixture_dir}/enabled.txt" "" "normal requests still cached"
  assertGetEquals "/cache-bypass/enabled.txt" "${fixture_dir}/enabled.txt" "x-no-cache-y" "no-cache substring must not match"
  assertGetEquals "/cache-bypass/enabled.txt" "${fixture_dir}/enabled.txt" "max-age=0" "other directives must not match"
  assertGetEquals "/cache-bypass/enabled.txt" "${fixture_dir}/updated.txt" "no-cache" "no-cache bypasses the cache"
  assertGetEquals "/cache-bypass/enabled.txt" "${fixture_dir}/updated.txt" "" "bypass refreshed the cache entry"
  overwriteObject "${fixture_dir}/enabled.txt" "cache-bypass/enabled.txt"
  assertGetEquals "/cache-bypass/enabled.txt" "${fixture_dir}/enabled.txt" "max-age=0, no-cache" "no-cache token in a directive list bypasses"
  assertGetEquals "/cache-bypass/enabled.txt" "${fixture_dir}/enabled.txt" "" "bypass refreshed the cache entry again"

  # Byte-range requests are served from the separate slice cache in the
  # @s3_sliced location, which inherits proxy_cache_bypass from the
  # server level.
  assertRangeGetEquals "/cache-bypass/sliced.txt" "${fixture_dir}/sliced.txt" 0 9 "" "prime slice cache"
  overwriteObject "${fixture_dir}/updated.txt" "cache-bypass/sliced.txt"
  assertRangeGetEquals "/cache-bypass/sliced.txt" "${fixture_dir}/sliced.txt" 0 9 "" "slice cache still serves cached bytes"
  assertRangeGetEquals "/cache-bypass/sliced.txt" "${fixture_dir}/updated.txt" 0 9 "no-cache" "no-cache bypasses the slice cache"
  assertRangeGetEquals "/cache-bypass/sliced.txt" "${fixture_dir}/updated.txt" 0 9 "" "bypass refreshed the slice cache"

  # Restore the overwritten object and bypass once more so that both the origin
  # and the slice cache end the phase holding the checked-in fixture content,
  # keeping reruns against a warm gateway/origin deterministic.
  overwriteObject "${fixture_dir}/sliced.txt" "cache-bypass/sliced.txt"
  assertRangeGetEquals "/cache-bypass/sliced.txt" "${fixture_dir}/sliced.txt" 0 9 "no-cache" "restored object re-primed into the slice cache"
fi

echo "  Cache bypass tests (phase: ${phase}) passed"

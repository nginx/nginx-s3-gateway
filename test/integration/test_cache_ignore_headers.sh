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

# Integration tests for the PROXY_CACHE_IGNORE_HEADERS feature (GH-64). The
# gateway must already be running with the feature configured; this script
# seeds objects that carry a cache-defeating Cache-Control value, then issues
# requests and mutates the objects in the MinIO backend to prove whether the
# gateway honored or ignored that header.
#
# The disabled phase is what reproduces GH-64: an origin that returns
# 'Cache-Control: private, max-age=0' - the Google Cloud Storage default for
# authenticated reads - makes NGINX treat every response as uncacheable, so
# nothing is ever written to /var/cache/nginx/s3_proxy. That phase also keeps
# the enabled phase honest: if MinIO ever stopped returning the header, the
# disabled phase would fail here rather than the enabled phase passing
# vacuously.
#
# The test relies on PROXY_CACHE_VALID_OK being long (1h in the test compose
# file) so that a primed cache entry stays fresh for the duration of the run,
# making "stale body served" a deterministic assertion.

set -o errexit   # abort on nonzero exit status
set -o pipefail  # don't hide errors within pipes

test_server=$1
test_dir=$2
phase=$3
mc_cmd=$4
minio_alias=$5
minio_bucket=$6

test_fail_exit_code=2
no_dep_exit_code=3
checksum_length=32

# The Google Cloud Storage default for objects that are not publicly
# readable. Any value containing 'private' or 'no-store' makes NGINX treat the
# response as uncacheable; this one mirrors the origin behavior from GH-64.
# No space after the comma: mc splits --attr pairs on ';' and a bare comma is
# valid HTTP.
cache_control_attr="Cache-Control=private,max-age=0"

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
  e "missing third parameter: test phase - must be 'disabled' or 'enabled'"
  exit ${no_dep_exit_code}
fi

if ! [ -x "${mc_cmd}" ]; then
  e "required dependency not found: mc not found at [${mc_cmd}] or not executable"
  exit ${no_dep_exit_code}
fi

if [ -z "${minio_alias}" ]; then
  e "missing fifth parameter: mc alias of the MinIO backend"
  exit ${no_dep_exit_code}
fi

if [ -z "${minio_bucket}" ]; then
  e "missing sixth parameter: name of the MinIO bucket"
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

# If we are using the `md5` executable
# then use the -r flag which makes it behave the same as `md5sum`
# this is done after the `-x` check for ability to execute
# since it will not pass with the flag
if [[ $checksum_cmd =~ \/md5$ ]]; then
  checksum_cmd="${checksum_cmd} -r"
fi

fixture_dir="${test_dir}/data/${minio_bucket}/cache-ignore-headers"

# Writes a local file to an object in the MinIO backend with the
# cache-defeating Cache-Control metadata attached. Used both to seed and to
# mutate, so the header is present on every response the gateway sees - the
# generic fixture upload in run_integration_tests.sh sets no metadata.
# putObjectWithCacheControl <local_src_file> <object_key>
putObjectWithCacheControl() {
  local_src="$1"
  object_key="$2"
  echo "  Writing ${minio_bucket}/${object_key} from $(basename "${local_src}") with ${cache_control_attr}"
  "${mc_cmd}" cp --attr "${cache_control_attr}" "${local_src}" \
    "${minio_alias}/${minio_bucket}/${object_key}" > /dev/null
}

# Asserts that a GET of <url_path> returns a body identical to <local_file>.
# assertGetEquals <url_path> <local_file> <label>
assertGetEquals() {
  path="$1"
  expected_file="$2"
  label="$3"
  uri="${test_server}${path}"

  printf "  \033[36;1m▲\033[0m "
  echo "Cache ignore headers [${label}]: GET ${path}"

  checksum_output="$(${checksum_cmd} "${expected_file}")"
  expected_checksum="${checksum_output:0:${checksum_length}}"

  curl_checksum_output="$(${curl_cmd} "${uri}" | ${checksum_cmd})"
  actual_checksum="${curl_checksum_output:0:${checksum_length}}"

  if [ "${expected_checksum}" != "${actual_checksum}" ]; then
    e "Checksum doesn't match expectation. Cache ignore headers [${label}] Request [GET ${uri}] Expected [${expected_checksum} = $(basename "${expected_file}")] Actual [${actual_checksum}]"
    e "curl command: ${curl_cmd} '${uri}' | ${checksum_cmd}"
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
# documented exit code. Mirrors the guard in test_api.sh; keep the two in
# sync.
if [ "${response}" = "000" ] || [ -z "${response}" ]; then
  e "unable to reach the test server at [${test_server}] - is the gateway running?"
  exit ${no_dep_exit_code}
fi

object_key="cache-ignore-headers/${phase}.txt"
original_fixture="${fixture_dir}/${phase}.txt"

# Re-seed with the Cache-Control metadata the phase depends on, and restore
# the original body so that a rerun against a warm stack starts from a known
# state.
putObjectWithCacheControl "${original_fixture}" "${object_key}"

if [ "${phase}" = "disabled" ]; then
  # With PROXY_CACHE_IGNORE_HEADERS unset (the default), the origin's
  # 'Cache-Control: private, max-age=0' must suppress caching entirely - the
  # behavior reported in GH-64. A body change in the bucket is therefore
  # visible on the very next request.
  assertGetEquals "/${object_key}" "${original_fixture}" "first request"
  putObjectWithCacheControl "${fixture_dir}/updated.txt" "${object_key}"
  assertGetEquals "/${object_key}" "${fixture_dir}/updated.txt" "origin Cache-Control suppressed caching"
else
  # With PROXY_CACHE_IGNORE_HEADERS="Cache-Control Expires", the same origin
  # header is ignored and PROXY_CACHE_VALID_OK (1h) governs instead, so the
  # primed entry is served even after the object changes in the bucket.
  assertGetEquals "/${object_key}" "${original_fixture}" "prime cache"
  putObjectWithCacheControl "${fixture_dir}/updated.txt" "${object_key}"
  assertGetEquals "/${object_key}" "${original_fixture}" "cached entry served despite origin Cache-Control"
fi

# Restore the fixture so reruns against a warm stack stay deterministic.
putObjectWithCacheControl "${original_fixture}" "${object_key}"

echo "Cache ignore headers tests (phase: ${phase}) passed"

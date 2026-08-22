#!/usr/bin/env bash

#
#  Copyright 2020 F5 Networks
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

set -o errexit   # abort on nonzero exit status
set -o pipefail  # don't hide errors within pipes

test_server=$1
test_dir=$2
signature_version=$3
allow_directory_list=$4
index_page=$5
append_slash=$6
strip_leading_directory=$7
prefix_leading_directory_path=$8

test_fail_exit_code=2
no_dep_exit_code=3
checksum_length=32

## Check for Windows Machine.  Temporary fix to skip non-ascii characters on Windows to run Integration Tests
## I know there could be other windows machines that display OS differently or don't have the issue with UTF-8
## but I don't have them to test.
## remove this once UTF-8 issue solved.

is_windows="0"
if [ -n "${OS:-}" ] && [ "${OS}" == "Windows_NT" ]; then
  is_windows="1"
elif command -v uname > /dev/null; then
  uname_output="$(uname -s)"
  if [[ "${uname_output}" == *"_NT-"* ]]; then
    is_windows="1"
  fi
fi

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

assertHttpRequestEquals() {
  method="$1"
  path="$2"

  if [[ $path == /* ]]; then
    uri="${test_server}${path}"
  else
    uri="${test_server}/${path}"
  fi

  if [ "${index_page}" == "1" ]; then
    # Follow 302 redirect if testing static hosting
    # Add the -v flag to the curl command below to debug why curl is failing
    extra_arg="-L"
  else
    extra_arg=""
  fi

  printf "  \033[36;1m▲\033[0m "
  echo "Testing object: ${method} ${path}"

  if [ "${method}" = "HEAD" ]; then
    expected_response_code="$3"
    actual_response_code="$(${curl_cmd} -o /dev/null -w '%{http_code}' --head "${uri}" ${extra_arg})"

    if [ "${expected_response_code}" != "${actual_response_code}" ]; then
      e "Response code didn't match expectation. Request [${method} ${uri}] Expected [${expected_response_code}] Actual [${actual_response_code}]"
      e "curl command: ${curl_cmd} -o /dev/null -w '%{http_code}' --head '${uri}' ${extra_arg}"
      exit ${test_fail_exit_code}
    fi
  elif [ "${method}" = "GET" ]; then
    body_data_path="${test_dir}/$3"

    if [ -f "$body_data_path" ]; then
      checksum_output="$(${checksum_cmd} "${body_data_path}")"
      expected_checksum="${checksum_output:0:${checksum_length}}"

      curl_checksum_output="$(${curl_cmd} -X "${method}" "${uri}" ${extra_arg} | ${checksum_cmd})"
      s3_file_checksum="${curl_checksum_output:0:${checksum_length}}"

      if [ "${expected_checksum}" != "${s3_file_checksum}" ]; then
        e "Checksum doesn't match expectation. Request [${method} ${uri}] Expected [${expected_checksum}] Actual [${s3_file_checksum}]"
        e "curl command: ${curl_cmd} -X '${method}' '${uri}' ${extra_arg} | ${checksum_cmd}"
        exit ${test_fail_exit_code}
      fi
    else
      expected_response_code="$3"
      actual_response_code="$(${curl_cmd} -o /dev/null -w '%{http_code}' "${uri}" ${extra_arg})"

      if [ "${expected_response_code}" != "${actual_response_code}" ]; then
        e "Response code didn't match expectation. Request [${method} ${uri}] Expected [${expected_response_code}] Actual [${actual_response_code}]"
        e "curl command: ${curl_cmd} -o /dev/null -w '%{http_code}' '${uri}' ${extra_arg}"
        exit ${test_fail_exit_code}
      fi
    fi
  # Not a real method but better than making a whole new helper or massively refactoring this one
  elif [ "${method}" = "GET_RANGE" ]; then
    # Call format to check for a range of byte 30 to 1000:
    # assertHttpRequestEquals "GET_RANGE" "a.txt" "data/bucket-1/a.txt" 30 1000 "206"
    body_data_path="${test_dir}/$3"
    range_start="$4"
    range_end="$5"
    byte_count=$((range_end - range_start + 1)) # add one since we read through the last byte
    expected_response_code="$6"

    file_checksum=$(${file_convert_command} if="$body_data_path" bs=1 skip="$range_start" count="$byte_count" 2>/dev/null | ${checksum_cmd})
    expected_checksum="${file_checksum:0:${checksum_length}}"

    curl_checksum_output="$(${curl_cmd} -X "GET" -r "${range_start}"-"${range_end}" "${uri}" ${extra_arg} | ${checksum_cmd})"
    s3_file_checksum="${curl_checksum_output:0:${checksum_length}}"
    
    if [ "${expected_checksum}" != "${s3_file_checksum}" ]; then
        e "Checksum doesn't match expectation. Request [GET ${uri} Range: "${range_start}"-"${range_end}"] Expected [${expected_checksum}] Actual [${s3_file_checksum}]"
        e "curl command: ${curl_cmd} -X "GET" -r "${range_start}"-"${range_end}" "${uri}" ${extra_arg} | ${checksum_cmd}"
        exit ${test_fail_exit_code}
    fi
  elif [ "${method}" = "PUT" ] || [ "${method}" = "POST" ] || [ "${method}" = "DELETE" ]; then
    # Write methods must be rejected by the gateway, so only the immediate
    # response code is asserted - deliberately no redirect following.
    expected_response_code="$3"
    actual_response_code="$(${curl_cmd} -X "${method}" -o /dev/null -w '%{http_code}' "${uri}")"

    if [ "${expected_response_code}" != "${actual_response_code}" ]; then
      e "Response code didn't match expectation. Request [${method} ${uri}] Expected [${expected_response_code}] Actual [${actual_response_code}]"
      e "curl command: ${curl_cmd} -X '${method}' -o /dev/null -w '%{http_code}' '${uri}'"
      exit ${test_fail_exit_code}
    fi
  else
    # A typo'd method must fail the suite loudly - silently continuing here
    # would make every assertion with a bad method vacuously pass.
    e "Method unsupported: [${method}]"
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
# sleep finishes, so probe once more before giving up: under the old
# fall-through the first assertion's curl was, in effect, that final probe,
# and a slow-starting gateway that became ready during the last sleep must
# keep passing. An empty response means curl exited without probing (usage
# error or killed by a signal), so re-probe for that case as well.
if [ "${response}" = "000" ] || [ -z "${response}" ]; then
  response="$(${curl_cmd} -s -o /dev/null -w '%{http_code}' --head "${test_server}" || true)"
fi

# Without this guard an unreachable server kills the script via errexit at
# the first assertion's curl - a bare curl exit code blamed on whichever
# assertion happened to run first - instead of one clear diagnostic and the
# documented exit code. Mirrors the guard in test_cache_bypass.sh; keep the
# two in sync.
if [ "${response}" = "000" ] || [ -z "${response}" ]; then
  e "unable to reach the test server at [${test_server}] - is the gateway running?"
  exit ${no_dep_exit_code}
fi

if [ -n "${prefix_leading_directory_path}" ]; then
  assertHttpRequestEquals "GET" "/c/d.txt" "data/bucket-1/b/c/d.txt"

  if [ -n "${strip_leading_directory}" ]; then
    # When these two flags are used together, stripped value is basically
    # replaced with the specified prefix
    assertHttpRequestEquals "GET" "/tostrip/c/d.txt" "data/bucket-1/b/c/d.txt"
  fi

  # Exit early for this case since all tests following will fail because of the added prefix
  exit 0
fi

# Ordinary filenames
assertHttpRequestEquals "HEAD" "a.txt" "200"
assertHttpRequestEquals "HEAD" "a.txt?some=param&that=should&be=stripped#aaah" "200"
assertHttpRequestEquals "HEAD" "b/c/d.txt" "200"
assertHttpRequestEquals "HEAD" "b/c/../e.txt" "200"
assertHttpRequestEquals "HEAD" "b/e.txt" "200"
# Double slashes are preserved in the S3 URI, so this is a distinct missing
# object rather than an alias for b/e.txt. A cache key based on nginx's
# normalized $uri would incorrectly reuse the b/e.txt entry here.
assertHttpRequestEquals "HEAD" "b//e.txt" "404"
assertHttpRequestEquals "HEAD" "a/abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.txt" "200"

# Byte range requests
assertHttpRequestEquals "GET_RANGE" 'a/plus%2Bplus.txt' "data/bucket-1/a/plus+plus.txt" 30 1000 "206"

# We try to request URLs that are properly encoded as well as URLs that
# are not properly encoded to understand what works and what does not.

# Weird filenames
assertHttpRequestEquals "HEAD" "b/c/%3D" "200"
assertHttpRequestEquals "HEAD" "b/c/=" "200"

assertHttpRequestEquals "HEAD" "b/c/%40" "200"
assertHttpRequestEquals "HEAD" "b/c/@" "200"

assertHttpRequestEquals "HEAD" "b/c/%27%281%29.txt" "200"
assertHttpRequestEquals "HEAD" "b/c/'(1).txt" "200"

# These URLs do not work unencoded
assertHttpRequestEquals "HEAD" 'a/plus%2Bplus.txt' "200"
assertHttpRequestEquals "HEAD" "%D1%81%D0%B8%D1%81%D1%82%D0%B5%D0%BC%D1%8B/%25bad%25file%25name%25" "200"

# Testing these files does not currently work on Windows
if [ ${is_windows} == "0" ]; then
  assertHttpRequestEquals "HEAD" "a/c/%E3%81%82" "200"
  assertHttpRequestEquals "HEAD" "a/c/あ" "200"

  assertHttpRequestEquals "HEAD" "b/%E3%82%AF%E3%82%BA%E7%AE%B1/%E3%82%B4%E3%83%9F.txt" "200"
  assertHttpRequestEquals "HEAD" "b/クズ箱/ゴミ.txt" "200"

  assertHttpRequestEquals "HEAD" "%D1%81%D0%B8%D1%81%D1%82%D0%B5%D0%BC%D1%8B/system.txt" "200"
  assertHttpRequestEquals "HEAD" "системы/system.txt" "200"

  assertHttpRequestEquals "HEAD" "b/%E3%83%96%E3%83%84%E3%83%96%E3%83%84.txt" "200"
  assertHttpRequestEquals "HEAD" "b/ブツブツ.txt" "200"

  # These URLs do not work unencoded
  assertHttpRequestEquals "HEAD" 'a/%25%40%21%2A%28%29%3D%24%23%5E%26%7C.txt' "200"
  assertHttpRequestEquals "HEAD" 'a/%E3%81%93%E3%82%8C%E3%81%AF%E3%80%80This%20is%20ASCII%20%D1%81%D0%B8%D1%81%D1%82%D0%B5%D0%BC%D1%8B%20%20%D7%97%D7%9F%20.txt' "200"
fi

# Expected 400s
# curl will not send this to server now
# assertHttpRequestEquals "HEAD" "request with unencoded spaces" "400"

# Expected 404s
if [ "${append_slash}" == "1" ] && [ "${index_page}" == "0" ]; then
  assertHttpRequestEquals "HEAD" "not%20found" "302"
  assertHttpRequestEquals "HEAD" "b/c" "302"
else
  assertHttpRequestEquals "HEAD" "not%20found" "404"
  assertHttpRequestEquals "HEAD" "b/c" "404"
fi

# Directory HEAD 404s
# Unfortunately, the logic here can't be properly encoded into the test.
# With minio, we can't return anything *but* a 404 for HEAD requests to a directory.
# With AWS S3, HEAD requests to a directory will return 200 *only* when we are
# running with v4 signatures.
# Now, both of these cases have the exception of HEAD returning 200 on the root
# directory.
if [ "${allow_directory_list}" == "1" ] || [ "${index_page}" == "1" ]; then
  assertHttpRequestEquals "HEAD" "/" "200"
else
  assertHttpRequestEquals "HEAD" "/" "404"
fi
assertHttpRequestEquals "HEAD" "b/" "404"
assertHttpRequestEquals "HEAD" "/b/c/" "404"
assertHttpRequestEquals "HEAD" "/soap" "404"
# As with b//e.txt above, b//c is a distinct S3 key and must not inherit the
# normalized /b/c response from another cache entry.
assertHttpRequestEquals "HEAD" "b//c" "404"

if [ "${index_page}" == "1" ]; then
assertHttpRequestEquals "HEAD" "/statichost/" "200"
assertHttpRequestEquals "HEAD" "/nonexistdir/noindexdir/" "404"
assertHttpRequestEquals "HEAD" "/nonexistdir/noindexdir" "404"
assertHttpRequestEquals "HEAD" "/statichost/noindexdir/multipledir/" "200"
assertHttpRequestEquals "HEAD" "/nonexistdir/" "404"
assertHttpRequestEquals "HEAD" "/nonexistdir" "404"
  if [ ${append_slash} == "1" ]; then
  assertHttpRequestEquals "HEAD" "/statichost" "200"
  assertHttpRequestEquals "HEAD" "/statichost/noindexdir/multipledir" "200"
  else
  assertHttpRequestEquals "HEAD" "/statichost" "404"
  assertHttpRequestEquals "HEAD" "/statichost/noindexdir/multipledir" "404"
  fi
fi

# Verify GET is working
assertHttpRequestEquals "GET" "a.txt" "data/bucket-1/a.txt"
assertHttpRequestEquals "GET" "a/abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.txt" "data/bucket-1/a/abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.txt"
assertHttpRequestEquals "GET" "a.txt?some=param&that=should&be=stripped#aaah" "data/bucket-1/a.txt"
assertHttpRequestEquals "GET" "b/c/d.txt" "data/bucket-1/b/c/d.txt"

assertHttpRequestEquals "GET" "b/c/%3D" "data/bucket-1/b/c/="
assertHttpRequestEquals "GET" "b/c/=" "data/bucket-1/b/c/="

assertHttpRequestEquals "GET" "b/c/%27%281%29.txt" "data/bucket-1/b/c/'(1).txt"
assertHttpRequestEquals "GET" "b/c/'(1).txt" "data/bucket-1/b/c/'(1).txt"

assertHttpRequestEquals "GET" "b/e.txt" "data/bucket-1/b/e.txt"

if [ -n "${strip_leading_directory}" ]; then
  assertHttpRequestEquals "GET" "/my-bucket/a.txt" "data/bucket-1/a.txt"
fi

# These URLs do not work unencoded
assertHttpRequestEquals "GET" 'a/plus%2Bplus.txt' "data/bucket-1/a/plus+plus.txt"

# Testing these files does not currently work on Windows
if [ ${is_windows} == "0" ]; then
  assertHttpRequestEquals "GET" "a/c/%E3%81%82" "data/bucket-1/a/c/あ"
  assertHttpRequestEquals "GET" "b/%E3%83%96%E3%83%84%E3%83%96%E3%83%84.txt" "data/bucket-1/b/ブツブツ.txt"
  assertHttpRequestEquals "GET" "b/%E3%82%AF%E3%82%BA%E7%AE%B1/%E3%82%B4%E3%83%9F.txt" "data/bucket-1/b/クズ箱/ゴミ.txt"
  assertHttpRequestEquals "GET" "%D1%81%D0%B8%D1%81%D1%82%D0%B5%D0%BC%D1%8B/system.txt" "data/bucket-1/системы/system.txt"
  assertHttpRequestEquals "GET" "%D1%81%D0%B8%D1%81%D1%82%D0%B5%D0%BC%D1%8B/%25bad%25file%25name%25" "data/bucket-1/системы/%bad%file%name%"
  assertHttpRequestEquals "GET" 'a/%25%40%21%2A%28%29%3D%24%23%5E%26%7C.txt' 'data/bucket-1/a/%@!*()=$#^&|.txt'
  assertHttpRequestEquals "GET" 'a/%E3%81%93%E3%82%8C%E3%81%AF%E3%80%80This%20is%20ASCII%20%D1%81%D0%B8%D1%81%D1%82%D0%B5%D0%BC%D1%8B%20%20%D7%97%D7%9F%20.txt' "data/bucket-1/a/これは　This is ASCII системы  חן .txt"
fi

# GH-551 regression: the regex location for */index.html paths must reject
# non-read methods at the nginx layer and never proxy them to S3. The
# limit_except denial (403) is sanitized to 404 by the location's error_page.
# A dedicated fixture is used so that (a) a regression's DELETE/PUT cannot
# corrupt /statichost/index.html, which the static-hosting assertions below
# depend on and which is never re-seeded between configurations, and (b) the
# verifying GET cannot be satisfied from a proxy_cache entry warmed by any
# other assertion (proxy_cache_key includes the effective upstream S3 URI).
# Note that only DELETE and PUT give the GET real teeth: a pre-fix gateway
# also surfaced POST as a sanitized 404 (upstream error via error_page), so
# the POST assertion pins the sanitized status, not the non-forwarding.
assertHttpRequestEquals "DELETE" "/gh551-writeguard/index.html" "404"
assertHttpRequestEquals "PUT" "/gh551-writeguard/index.html" "404"
assertHttpRequestEquals "POST" "/gh551-writeguard/index.html" "404"
# The object must still exist afterward with its original content: the
# rejected DELETE/PUT above must not have reached the bucket.
assertHttpRequestEquals "GET" "/gh551-writeguard/index.html" "data/bucket-1/gh551-writeguard/index.html"

# The write-method policy for ordinary object paths lives in `location /`:
# its empty limit_except starves unlisted methods of a content handler, so
# nginx's static module rejects them and the server-level error_page answers
# 405 with an Allow header - nothing is ever sent to S3.
assertHttpRequestEquals "PUT" "a.txt" "405"
assertHttpRequestEquals "DELETE" "a.txt" "405"

if [ "${index_page}" == "1" ]; then
assertHttpRequestEquals "GET" "/statichost/" "data/bucket-1/statichost/index.html"
assertHttpRequestEquals "GET" "/statichost/noindexdir/multipledir/" "data/bucket-1/statichost/noindexdir/multipledir/index.html"
  if [ "${append_slash}" == "1" ]; then
  assertHttpRequestEquals "GET" "/statichost" "data/bucket-1/statichost/index.html"
  assertHttpRequestEquals "GET" "/statichost/noindexdir/multipledir" "data/bucket-1/statichost/noindexdir/multipledir/index.html"
  fi

  if [ "${allow_directory_list}" == "1" ]; then
    if [ "$append_slash" == "1" ]; then
      assertHttpRequestEquals "GET" "test" "200"
      assertHttpRequestEquals "GET" "test/" "200"
      assertHttpRequestEquals "GET" "test?foo=bar" "200"
      assertHttpRequestEquals "GET" "test/?foo=bar" "200"
    fi
  fi
fi

if [ "${allow_directory_list}" == "1" ]; then
  assertHttpRequestEquals "GET" "/" "200"
  assertHttpRequestEquals "GET" "b/" "200"
  assertHttpRequestEquals "GET" "/b/c/" "200"
  assertHttpRequestEquals "GET" "b/%E3%82%AF%E3%82%BA%E7%AE%B1/" "200"
  assertHttpRequestEquals "GET" "b/クズ箱/" "200"
  assertHttpRequestEquals "GET" "%D1%81%D0%B8%D1%81%D1%82%D0%B5%D0%BC%D1%8B/" "200"
  assertHttpRequestEquals "GET" "системы/" "200"
  if [ "$append_slash" == "1" ]; then
    if [ "${index_page}" == "0" ]; then
      assertHttpRequestEquals "GET" "b" "302"
    fi
  else
    assertHttpRequestEquals "GET" "b" "404"
  fi
elif [ "${index_page}" == "1" ]; then
  assertHttpRequestEquals "GET" "/" "data/bucket-1/index.html"
else
  assertHttpRequestEquals "GET" "/" "404"
fi

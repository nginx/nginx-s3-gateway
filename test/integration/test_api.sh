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
# Accepted to keep the caller CLI contract stable but currently unused: the
# last signature-version branch (the v4-only //statichost redirect gate) was
# removed by GH-88, which made the assertion hold under both versions.
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

# Builds the request URI for a test path, tolerating a missing leading
# slash. Sets the global variable `uri` (this file's helpers communicate
# through globals rather than subshell captures).
# buildTestUri <path>
buildTestUri() {
  if [[ $1 == /* ]]; then
    uri="${test_server}$1"
  else
    uri="${test_server}/$1"
  fi
}

assertHttpRequestEquals() {
  method="$1"
  path="$2"

  buildTestUri "${path}"

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
  elif [ "${method}" = "PUT" ] || [ "${method}" = "POST" ] || [ "${method}" = "DELETE" ] || [ "${method}" = "OPTIONS" ]; then
    # Non-read methods must be rejected by the gateway (OPTIONS included when
    # CORS is disabled, as it is in this environment), so only the immediate
    # response is asserted - deliberately no redirect following.
    expected_response_code="$3"
    # A single request feeds both the status assertion and the 405 header
    # assertions below, so every assertion observes the same response - two
    # requests could straddle a config reload and pass/fail on different
    # responses (mirrors assertRequest in test_cors.sh; keep them in sync).
    headers="$(${curl_cmd} -X "${method}" -D - -o /dev/null "${uri}")"
    IFS= read -r status_line <<< "${headers}"
    actual_response_code="${status_line#* }"
    actual_response_code="${actual_response_code:0:3}"

    if [ "${expected_response_code}" != "${actual_response_code}" ]; then
      e "Response code didn't match expectation. Request [${method} ${uri}] Expected [${expected_response_code}] Actual [${actual_response_code}]"
      e "curl command: ${curl_cmd} -X '${method}' -D - -o /dev/null '${uri}'"
      exit ${test_fail_exit_code}
    fi

    if [ "${expected_response_code}" = "405" ]; then
      # Every 405 must carry the Allow header @error405 promises (RFC 9110).
      # CORS is disabled in every leg that runs this script (the
      # CORS-enabled contract lives in test_cors.sh), so the exact value is
      # pinned; add_header silently omits the header when
      # LIMIT_METHODS_TO_CSV renders empty, which only a value assertion
      # can catch. For the same reason Access-Control-Allow-Origin must be
      # absent: with CORS off the $cors_error_origin map renders empty and
      # add_header must omit the header entirely rather than leak the
      # CORS_ALLOWED_ORIGIN default onto rejection responses. The whole
      # header block is scanned (no early break) because both headers must
      # be observed regardless of their order in the response.
      expected_allow="GET, HEAD"
      actual_allow=""
      actual_acao=""
      while IFS= read -r header; do
        case "${header}" in
          [Aa]llow:\ *)
            actual_allow="${header#*: }"
            actual_allow="${actual_allow%$'\r'}"
            ;;
          [Aa]ccess-[Cc]ontrol-[Aa]llow-[Oo]rigin:*)
            actual_acao="${header%$'\r'}"
            ;;
        esac
      done <<< "${headers}"

      if [ "${expected_allow}" != "${actual_allow}" ]; then
        e "Allow header didn't match expectation. Request [${method} ${uri}] Expected [${expected_allow}] Actual [${actual_allow}]"
        e "curl command: ${curl_cmd} -X '${method}' -D - -o /dev/null '${uri}'"
        exit ${test_fail_exit_code}
      fi

      if [ -n "${actual_acao}" ]; then
        e "Access-Control-Allow-Origin must be absent on 405s when CORS is disabled. Request [${method} ${uri}] Got [${actual_acao}]"
        e "curl command: ${curl_cmd} -X '${method}' -D - -o /dev/null '${uri}'"
        exit ${test_fail_exit_code}
      fi
    fi
  else
    # A typo'd method must fail the suite loudly - silently continuing here
    # would make every assertion with a bad method vacuously pass.
    e "Method unsupported: [${method}]"
    exit ${test_fail_exit_code}
  fi
}

# Assert that a slash-appending redirect is relative and preserves the
# viewer-visible path without reflecting request authority headers.
# assertRedirectLocation <path> <host_header> <expected_location> [forwarded_proto]
assertRedirectLocation() {
  path="$1"
  host="$2"
  expected_location="$3"
  forwarded_proto="${4:-}"
  curl_args=(-H "Host: ${host}")

  if [ -n "${forwarded_proto}" ]; then
    curl_args+=(-H "X-Forwarded-Proto: ${forwarded_proto}")
  fi

  buildTestUri "${path}"

  printf "  \033[36;1m▲\033[0m "
  echo "Testing redirect: GET ${path} (Host: ${host}, X-Forwarded-Proto: ${forwarded_proto:-<none>})"

  headers="$(${curl_cmd} "${curl_args[@]}" -D - -o /dev/null "${uri}")"
  actual_location=""
  while IFS= read -r header; do
    case "${header}" in
      [Ll]ocation:\ *)
        actual_location="${header#*: }"
        actual_location="${actual_location%$'\r'}"
        break
        ;;
    esac
  done <<< "${headers}"

  if [ "${expected_location}" != "${actual_location}" ]; then
    e "Redirect location didn't match expectation. Request [GET ${uri} Host: ${host} X-Forwarded-Proto: ${forwarded_proto:-<none>}] Expected [${expected_location}] Actual [${actual_location}]"
    # Print the argument vector actually sent: hand-assembling the repro
    # would inject an empty X-Forwarded-Proto header (curl treats
    # -H 'Name: ' as header deletion) and change the request under test.
    e "curl command: ${curl_cmd} ${curl_args[*]} -D - -o /dev/null '${uri}'"
    exit ${test_fail_exit_code}
  fi
}

# Asserts that a path carrying percent-encoded control bytes cannot inject a
# response header. Origins differ on the upstream answer for such keys - AWS
# answers 404, which makes @trailslash emit a redirect, while RustFS
# rejects control bytes in object keys with 400 and no redirect is emitted at
# all. Both shapes are safe, so the redirect itself is optional here; what
# must never happen is the decoded CR/LF splitting a header, and when a
# Location IS emitted it must still carry the bytes percent-encoded.
# assertRedirectSafeFromHeaderInjection <path> <host_header> <expected_location_when_redirected> <injected_header_name>
assertRedirectSafeFromHeaderInjection() {
  path="$1"
  host="$2"
  expected_location="$3"
  injected_header_name="$4"

  buildTestUri "${path}"

  printf "  \033[36;1m▲\033[0m "
  echo "Testing header-injection safety: GET ${path} (Host: ${host})"

  headers="$(${curl_cmd} -H "Host: ${host}" -D - -o /dev/null "${uri}")"
  actual_location=""
  status=""
  while IFS= read -r header; do
    case "${header}" in
      HTTP/*)
        status="$(echo "${header}" | awk '{print $2}')"
        ;;
      [Ll]ocation:\ *)
        actual_location="${header#*: }"
        actual_location="${actual_location%$'\r'}"
        ;;
      "${injected_header_name}:"*)
        e "Header injection detected: response contains a '${injected_header_name}' header. Request [GET ${uri} Host: ${host}]"
        exit ${test_fail_exit_code}
        ;;
    esac
  done <<< "${headers}"

  # Both safe upstream shapes are 3xx (redirect emitted) or 4xx (origin
  # rejected the control bytes). A 2xx means the decoded key unexpectedly
  # resolved; a 5xx means the gateway itself broke on the input. Either
  # would previously have slipped through because only the redirect
  # location, when present, was being checked.
  case "${status}" in
    3*|4*) ;;
    *)
      e "Unexpected status for a control-byte path. Request [GET ${uri} Host: ${host}] Status [${status}]"
      exit ${test_fail_exit_code}
      ;;
  esac

  if [ -n "${actual_location}" ] && [ "${expected_location}" != "${actual_location}" ]; then
    e "Redirect location didn't match expectation. Request [GET ${uri} Host: ${host}] Expected [${expected_location}] Actual [${actual_location}]"
    exit ${test_fail_exit_code}
  fi
}

# Fetch a URL with GET and assert a literal substring is present in
# (mode "contains") or absent from (mode "lacks") the response body.
# The response is fetched once per path and reused by consecutive assertions
# against the same path, so a group of assertions observes a single atomic
# response (mirroring the single-fetch rationale of the 405 checks in
# assertHttpRequestEquals) instead of paying one round trip per assertion.
# assertHttpBodyPart <contains|lacks> <path> <literal>
assertHttpBodyPart() {
  mode="$1"
  path="$2"
  expected_part="$3"

  buildTestUri "${path}"

  printf "  \033[36;1m▲\033[0m "
  echo "Testing body ${mode}: GET ${path} [${expected_part}]"

  if [ "${uri}" != "${body_part_uri:-}" ]; then
    # "|| true": a transport-level curl failure must fall through to the
    # status check below for a proper diagnostic instead of killing the
    # suite via errexit with curl's raw exit code.
    body_part_response="$(${curl_cmd} -w '\n%{http_code}' "${uri}")" || true
    body_part_status="${body_part_response##*$'\n'}"
    body_part_body="${body_part_response%$'\n'*}"
    body_part_uri="${uri}"
  fi

  # An error page trivially lacks any forbidden text, so without this check
  # "lacks" assertions would vacuously pass against a 4xx/5xx response.
  if [ "${body_part_status:-}" != "200" ]; then
    e "Response status is not 200. Request [GET ${uri}] Status [${body_part_status:-<none>}]"
    e "Response body was: ${body_part_body:-}"
    exit ${test_fail_exit_code}
  fi

  if [ "${mode}" = "contains" ]; then
    if [[ ${body_part_body} != *"${expected_part}"* ]]; then
      e "Response body does not contain expected text. Request [GET ${uri}] Expected [${expected_part}]"
      e "Response body was: ${body_part_body}"
      exit ${test_fail_exit_code}
    fi
  elif [ "${mode}" = "lacks" ]; then
    if [[ ${body_part_body} == *"${expected_part}"* ]]; then
      e "Response body contains text that must be absent. Request [GET ${uri}] Forbidden [${expected_part}]"
      e "Response body was: ${body_part_body}"
      exit ${test_fail_exit_code}
    fi
  else
    # A typo'd mode must fail the suite loudly rather than vacuously pass.
    e "Mode unsupported: [${mode}]"
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
  if [ "${index_page}" == "1" ]; then
    # Index-page legs run with PREFIX_LEADING_DIRECTORY_PATH=/statichost, so
    # the /b-shaped assertions below do not apply. GH-575: the index probe
    # must target the client-facing path so the loopback re-entry applies the
    # STRIP/PREFIX map exactly once; before that fix the probe always 404'd
    # and every directory silently fell back to a listing.
    assertHttpRequestEquals "GET" "/" "data/bucket-1/statichost/index.html"
    assertHttpRequestEquals "HEAD" "/" "200"
    assertHttpRequestEquals "GET" "/noindexdir/multipledir/" "data/bucket-1/statichost/noindexdir/multipledir/index.html"
    # No index.html in noindexdir/ -> falls back to the directory listing.
    assertHttpBodyPart "contains" "/noindexdir/" '<h1>Index of /noindexdir/</h1>'
    assertHttpBodyPart "contains" "/noindexdir/" 'href="/noindexdir/noindex.html"'

    if [ -n "${strip_leading_directory}" ]; then
      # The probe URI is built from the raw client path, so it traverses the
      # strip map arm on loopback: ${strip_leading_directory}/index.html must
      # strip and prefix to the same S3 key as /index.html.
      assertHttpRequestEquals "GET" "${strip_leading_directory}/" "data/bucket-1/statichost/index.html"
      # GH-88: the collapse precedes the strip on the index probe's loopback
      # re-entry too - a doubled-slash spelling of the stripped prefix must
      # land on the same index page instead of bypassing the strip.
      assertHttpRequestEquals "GET" "/${strip_leading_directory}//" "data/bucket-1/statichost/index.html"
    fi

    # Exit early like the non-index prefix branch below: everything past the
    # prefix block assumes unprefixed paths.
    exit 0
  fi

  if [ -n "${strip_leading_directory}" ]; then
    # GH-88: duplicate slashes collapse BEFORE the STRIP map chooses its
    # rewrite arm, so a doubled slash at the stripped prefix must take the
    # same strip+prefix rewrite as the canonical spelling - uncollapsed it
    # would fail the map's anchored regex, skip the strip, and address the
    # wrong S3 key. Cold-cache: stays ABOVE every other request for
    # b/c/d.txt (all slash spellings share one cache entry keyed on the
    # normalized $s3uri, and a warmed entry would mask the regression).
    assertHttpRequestEquals "GET" "/${strip_leading_directory}//c/d.txt" "data/bucket-1/b/c/d.txt"
  fi

  # GH-88: duplicate client slashes collapse after the PREFIX map prepends
  # /b, so the rewritten path reaches S3 without empty segments. Cold-cache
  # in no-strip legs: stays above the canonical /c/d.txt request below.
  assertHttpRequestEquals "GET" "/c//d.txt" "data/bucket-1/b/c/d.txt"

  assertHttpRequestEquals "GET" "/c/d.txt" "data/bucket-1/b/c/d.txt"

  if [ -n "${strip_leading_directory}" ]; then
    # When these two flags are used together, stripped value is basically
    # replaced with the specified prefix
    assertHttpRequestEquals "GET" "/tostrip/c/d.txt" "data/bucket-1/b/c/d.txt"
  fi

  if [ "${allow_directory_list}" == "1" ]; then
    # Listing links and headings must present client-facing paths: the
    # gateway prepends PREFIX_LEADING_DIRECTORY_PATH (/b) to every incoming
    # URI, so a link leaking the internal prefix gets it prepended a second
    # time when followed and produces an empty listing.
    assertHttpBodyPart "contains" "/" 'href="/c/"'
    assertHttpBodyPart "contains" "/" 'href="/e.txt"'
    # Assert the exact leaked shapes an unstripped implementation would emit
    # rather than a broad 'href="/b/' canary: a fixture legitimately named
    # "b" under the exposed subtree would produce a correct stripped link
    # href="/b/..." and false-fail the broad form.
    assertHttpBodyPart "lacks" "/" 'href="/b/c/"'
    assertHttpBodyPart "lacks" "/" 'href="/b/e.txt"'
    assertHttpBodyPart "contains" "/" '<h1>Index of /</h1>'
    # The exposed root presents as a root: no ".." row above itself.
    assertHttpBodyPart "lacks" "/" 'href="../"'
    # Stripped links must round-trip: following /c/ from the root listing
    # must itself yield a correct, prefix-free listing.
    assertHttpBodyPart "contains" "/c/" '<h1>Index of /c/</h1>'
    assertHttpBodyPart "contains" "/c/" 'href="/c/d.txt"'
    assertHttpBodyPart "lacks" "/c/" 'href="/b/c/d.txt"'
    assertHttpBodyPart "contains" "/c/" 'href="../"'

    if [ -n "${strip_leading_directory}" ]; then
      # The strip+prefix+listing composition: GET ${strip_leading_directory}/
      # strips to "/", has the prefix prepended, and must yield the same
      # canonical, prefix-free listing as "/" - links emitted under the strip
      # alias land back on canonical paths. Without these requests the strip
      # map arm is never traversed while listing is on.
      assertHttpBodyPart "contains" "${strip_leading_directory}/" '<h1>Index of /</h1>'
      assertHttpBodyPart "contains" "${strip_leading_directory}/" 'href="/c/"'
      assertHttpBodyPart "lacks" "${strip_leading_directory}/" 'href="/b/c/"'
      assertHttpBodyPart "contains" "${strip_leading_directory}/c/" '<h1>Index of /c/</h1>'
      assertHttpBodyPart "contains" "${strip_leading_directory}/c/" 'href="/c/d.txt"'
      assertHttpBodyPart "contains" "${strip_leading_directory}/c/" 'href="../"'
    fi
  fi

  # Exit early for this case since all tests following will fail because of the added prefix
  exit 0
fi

# GH-578: legal but non-canonical request encodings. The gateway re-encodes
# every URI into one canonical form before proxying and must sign that same
# form (v2 used to sign the raw client bytes, so every request below failed
# upstream with SignatureDoesNotMatch, surfaced as a sanitized 404). These
# assertions must stay ABOVE the first canonical-form request for the same
# object and method: all encoding variants of an object share one proxy
# cache entry (the cache key is the normalized $s3uri), so a cache warmed
# by the canonical form would serve these from memory and hide a signing
# regression - which is exactly how this bug evaded CI. curl sends these
# paths byte-for-byte (it does not re-encode; only dot-segments would be
# rewritten, and none appear here).
assertHttpRequestEquals "HEAD" "a/plus+plus.txt" "200"
assertHttpRequestEquals "GET" "a/plus+plus.txt" "data/bucket-1/a/plus+plus.txt"
assertHttpRequestEquals "HEAD" "%61.txt" "200"
assertHttpRequestEquals "GET" "%61.txt" "data/bucket-1/a.txt"
# Lowercase hex needs an object of its own: a/plus%2bplus.txt would share
# the raw-'+' cache entry warmed just above and never reach upstream.
assertHttpRequestEquals "HEAD" "b/c/%3d" "200"
assertHttpRequestEquals "GET" "b/c/%3d" "data/bucket-1/b/c/="

if [ ${is_windows} == "0" ]; then
  # Raw sub-delims !*() mixed with percent-encoded bytes. %25, %40, %23 and
  # %26 must stay encoded in any client request: raw '%@' is an invalid
  # percent-sequence and raw '#'/'&' would not survive as path data.
  assertHttpRequestEquals "HEAD" 'a/%25%40!*()%3D%24%23%5E%26%7C.txt' "200"
  assertHttpRequestEquals "GET" 'a/%25%40!*()%3D%24%23%5E%26%7C.txt' 'data/bucket-1/a/%@!*()=$#^&|.txt'
fi

# GH-88: runs of duplicate literal slashes collapse before the request is
# signed and proxied, so these alias the canonical keys requested below.
# They must stay ABOVE the first canonical-form request for the same
# object, for the same cold-cache reason as the GH-578 block above: all
# slash spellings share one cache entry keyed on the normalized $s3uri,
# so a cache warmed by the canonical form would hide a signing or
# normalization regression.
assertHttpRequestEquals "HEAD" "b//e.txt" "200"
assertHttpRequestEquals "GET" "b//e.txt" "data/bucket-1/b/e.txt"
assertHttpRequestEquals "GET" "b//c///d.txt" "data/bucket-1/b/c/d.txt"
# The escape hatch: a percent-encoded slash is object-key data, never a
# path separator, and is not collapsed. b/%2Fe.txt addresses the distinct
# key 'b//e.txt' (which no fixture carries) under its own cache key
# '/b//e.txt', so it must NOT alias the b/e.txt entry warmed above.
assertHttpRequestEquals "HEAD" "b/%2Fe.txt" "404"

if [ -n "${strip_leading_directory}" ]; then
  # GH-88: duplicate slashes collapse BEFORE the STRIP map chooses its
  # rewrite arm, so a leading doubled slash must not bypass the strip
  # (uncollapsed, '//<strip>/...' fails the map's anchored regex and the
  # unstripped path becomes the S3 key). Cold-cache: a.txt's canonical
  # spelling is first requested below.
  assertHttpRequestEquals "HEAD" "/${strip_leading_directory}//a.txt" "200"
fi

# Ordinary filenames
assertHttpRequestEquals "HEAD" "a.txt" "200"
assertHttpRequestEquals "HEAD" "a.txt?some=param&that=should&be=stripped#aaah" "200"
assertHttpRequestEquals "HEAD" "b/c/d.txt" "200"
assertHttpRequestEquals "HEAD" "b/c/../e.txt" "200"
assertHttpRequestEquals "HEAD" "b/e.txt" "200"
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

# Canonical forms of objects exercised raw above (GH-578); these resolve
# from the shared cache entry keyed on the normalized $s3uri and assert the
# encoding variants converge on one object. The %bad%file%name% path has no
# requestable raw form: raw '%ba' is an invalid percent-sequence.
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

  # Fully-encoded forms. The first is the canonical twin of the raw !*()
  # case above (GH-578); the second has no raw form at all (a request line
  # cannot carry raw spaces).
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
  # GH-88: b//c collapses to b/c and follows the same append-slash path.
  assertHttpRequestEquals "HEAD" "b//c" "302"
  # The Location is built from nginx's slash-merged $uri, so the duplicate
  # slash cannot survive into the redirect target either.
  assertRedirectLocation "/b//c" "a.example" "/b/c/"
else
  assertHttpRequestEquals "HEAD" "not%20found" "404"
  assertHttpRequestEquals "HEAD" "b/c" "404"
  assertHttpRequestEquals "HEAD" "b//c" "404"
fi

# Directory HEAD 404s
# Unfortunately, the logic here can't be properly encoded into the test.
# With RustFS, we can't return anything *but* a 404
# for HEAD requests to a directory.
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

# Canonical twin of the raw a/plus+plus.txt GET above (GH-578).
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

# GH-496: the method policy for ordinary object paths lives in `location /`,
# which rejects unlisted methods in the rewrite phase with an immediate 405 -
# before credentials are fetched and without consulting the local filesystem.
# Nothing is ever sent to S3. POST is the load-bearing assertion: the pre-fix
# empty limit_except starved unlisted methods of a content handler, so
# nginx's static module probed the local docroot and answered POST with 404
# (missing file) or 405 (present file) instead of a uniform 405. The
# nonexistent-path POST assertion pins that the status no longer depends on
# what exists on the container filesystem (the static module rejected PUT
# before any filesystem access, so its row just completes the
# method/existence matrix). OPTIONS must be rejected here because CORS is
# disabled in every leg that runs this script; test_cors.sh asserts the
# CORS-enabled flip side, where OPTIONS is served as the preflight.
assertHttpRequestEquals "PUT" "a.txt" "405"
assertHttpRequestEquals "DELETE" "a.txt" "405"
assertHttpRequestEquals "POST" "a.txt" "405"
assertHttpRequestEquals "POST" "gh496-does-not-exist" "405"
assertHttpRequestEquals "PUT" "gh496-does-not-exist" "405"
assertHttpRequestEquals "OPTIONS" "a.txt" "405"

if [ "${index_page}" == "1" ]; then
assertHttpRequestEquals "GET" "/statichost/" "data/bucket-1/statichost/index.html"
assertHttpRequestEquals "GET" "/statichost/noindexdir/multipledir/" "data/bucket-1/statichost/noindexdir/multipledir/index.html"
  if [ "${append_slash}" == "1" ]; then
  assertHttpRequestEquals "GET" "/statichost" "data/bucket-1/statichost/index.html"
  assertHttpRequestEquals "GET" "/statichost/noindexdir/multipledir" "data/bucket-1/statichost/noindexdir/multipledir/index.html"
  assertRedirectLocation "/statichost" "a.example" "/statichost/"
  assertRedirectLocation "/statichost" "b.example" "/statichost/"
  assertRedirectLocation "/statichost" "attacker.example" "/statichost/" "https"
  assertRedirectLocation "/statichost?foo=bar" "a.example" "/statichost/?foo=bar"
  assertRedirectLocation "/%5Cevil.example/foo" "a.example" "/%5Cevil.example/foo/"
  # NGINX exposes a percent-decoded r.uri to njs, so the redirect helper must
  # re-escape delimiters and control bytes before they reach Location.
  assertRedirectLocation "/%3Ffoo" "a.example" "/%3Ffoo/"
  assertRedirectLocation "/%23foo" "a.example" "/%23foo/"
  assertRedirectLocation "/%25foo" "a.example" "/%25foo/"
  assertRedirectSafeFromHeaderInjection "/foo%0D%0AX-Evil%3A%20yes" "a.example" "/foo%0D%0AX-Evil%3A%20yes/" "X-Evil"
  # GH-88: the duplicate slash is collapsed before signing and proxying
  # under BOTH signature versions (pre-fix, the previous origin's SigV2
  # handling 404'd the raw double-slash key upstream, so this only held
  # for v4), so S3
  # returns a plain 404 for 'statichost' and @trailslash emits the
  # collapsed Location - which also proves it cannot become a
  # scheme-relative `//...` URL.
  assertRedirectLocation "//statichost" "a.example" "/statichost/"
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
  # GH-88: duplicate slashes collapse in ListObjects (V1) prefixes too, and
  # '//' aliases the root listing. The body assertion matters: an
  # uncollapsed '//' would list the (nonexistent) prefix '/' and still
  # render a 200 "No Files Available for Listing" page. With
  # PROVIDE_INDEX_PAGE on, the collapsed root instead resolves to the root
  # index page before the listing branch is consulted.
  if [ "${index_page}" == "0" ]; then
    assertHttpRequestEquals "GET" "//" "200"
    assertHttpBodyPart "contains" "//" '<h1>Index of /</h1>'
  else
    assertHttpRequestEquals "GET" "//" "data/bucket-1/index.html"
  fi
  assertHttpBodyPart "contains" "b//c///" '<h1>Index of /b/c/</h1>'
  assertHttpBodyPart "contains" "b//c///" 'href="/b/c/d.txt"'
  # GH-150: without DIRECTORY_LISTING_PAGE_SIZE the fixture set fits in one
  # listing response, so no pagination link may render.
  assertHttpBodyPart "lacks" "b//c///" 'Next page'
  if [ "$append_slash" == "1" ]; then
    if [ "${index_page}" == "0" ]; then
      assertHttpRequestEquals "GET" "b" "302"
    fi
  else
    assertHttpRequestEquals "GET" "b" "404"
  fi
elif [ "${index_page}" == "1" ]; then
  assertHttpRequestEquals "GET" "/" "data/bucket-1/index.html"
  # GH-88: '//' collapses to the root and serves the same index page.
  assertHttpRequestEquals "GET" "//" "data/bucket-1/index.html"
else
  assertHttpRequestEquals "GET" "/" "404"
  # GH-88 guard: '//' collapses to the root and must hit the same 404
  # guard in redirectToS3 - not bypass the uriPath === '/' check and
  # proxy a signed bucket-root GET upstream, which would leak an object
  # listing while directory listing is disabled.
  assertHttpRequestEquals "GET" "//" "404"
fi

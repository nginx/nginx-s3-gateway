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

# Integration tests for directory listing pagination (GH-150). The gateway
# must already be running with ALLOW_DIRECTORY_LIST=1,
# APPEND_SLASH_FOR_POSSIBLE_DIRECTORY=1 and DIRECTORY_LISTING_PAGE_SIZE=2 so
# that the checked-in fixture set spans multiple listing pages. The `marker`
# query parameter is the only client parameter the gateway forwards to S3;
# every page ending in a truncated response must render a "Next page" link
# whose marker is relative to the listed directory.
#
# Markers are treated as opaque: AWS and RustFS return the last key of the
# page as NextMarker, but some S3-compatible backends decorate it with an
# internal continuation hint appended to the key, so assertions check that
# a marker STARTS WITH the expected relative key and otherwise navigate with the
# marker extracted from the page, exactly like a browsing client. All
# expected strings are asserted in their percent-encoded (ASCII) form so the
# assertions are safe on shells with broken UTF-8 handling.

set -o errexit   # abort on nonzero exit status
set -o pipefail  # don't hide errors within pipes

test_server=$1
test_dir=$2
prefix_leading_directory_path=$3

test_fail_exit_code=2
no_dep_exit_code=3
max_page_walk=15

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

## Check for Windows Machine, mirroring test_api.sh: the reserved-character
## fixture 'a/%@!*()=$#^&|.txt' is only seeded by integration_test_data when
## the host is not Windows, and without it the /a/ page boundaries shift.
is_windows="0"
if [ -n "${OS:-}" ] && [ "${OS}" == "Windows_NT" ]; then
  is_windows="1"
elif command -v uname > /dev/null; then
  uname_output="$(uname -s)"
  if [[ "${uname_output}" == *"_NT-"* ]]; then
    is_windows="1"
  fi
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

# Fetches ${test_server}$1 into ${tmp_dir}/page.html and fails the run unless
# the response status matches $2.
fetch_expecting() {
  path_and_query=$1
  expected_status=$2
  # "|| true": a transport-level curl failure must fall through to the
  # status check below for a proper diagnostic instead of killing the
  # suite via errexit with curl's raw exit code.
  status="$(${curl_cmd} -s -o "${tmp_dir}/page.html" -w '%{http_code}' "${test_server}${path_and_query}")" || true
  if [ "${status}" != "${expected_status}" ]; then
    e "Unexpected status for [${path_and_query}]: got [${status}], expected [${expected_status}]"
    cat "${tmp_dir}/page.html" >&2
    exit ${test_fail_exit_code}
  fi
}

assert_page_contains() {
  needle=$1
  message=$2
  if ! grep -F -q -- "${needle}" "${tmp_dir}/page.html"; then
    e "FAIL: ${message}: page does not contain [${needle}]"
    cat "${tmp_dir}/page.html" >&2
    exit ${test_fail_exit_code}
  fi
}

assert_page_lacks() {
  needle=$1
  message=$2
  if grep -F -q -- "${needle}" "${tmp_dir}/page.html"; then
    e "FAIL: ${message}: page unexpectedly contains [${needle}]"
    cat "${tmp_dir}/page.html" >&2
    exit ${test_fail_exit_code}
  fi
}

# Prints the marker from the page's "Next page" link, or nothing when the
# page renders no link.
next_marker() {
  sed -n 's/.*href="?marker=\([^"]*\)".*/\1/p' "${tmp_dir}/page.html"
}

# The backend decides the exact marker value (AWS/RustFS: the last key;
# other backends may append an internal hint), but the marker must always
# begin with the page's last entry relative to the listed directory -
# anything else means the gateway leaked an internal prefix or the
# stylesheet mis-stripped it.
assert_next_marker_starts_with() {
  expected_prefix=$1
  message=$2
  actual="$(next_marker)"
  case "${actual}" in
    "${expected_prefix}"*) ;;
    *)
      e "FAIL: ${message}: next marker is [${actual}], expected it to start with [${expected_prefix}]"
      cat "${tmp_dir}/page.html" >&2
      exit ${test_fail_exit_code}
      ;;
  esac
}

# Asserts that a slashless directory request ($1) draws the append-slash
# redirect with the marker preserved: Location must equal $2. "|| true": a
# transport-level curl failure must reach the Location check's diagnostic
# instead of aborting via errexit with curl's raw exit code.
assert_redirect_location() {
  path_and_query=$1
  expected_location=$2
  message=$3
  ${curl_cmd} -s -D "${tmp_dir}/headers.txt" -o /dev/null "${test_server}${path_and_query}" || true
  location="$(tr -d '\r' < "${tmp_dir}/headers.txt" | awk 'tolower($1) == "location:" { print $2 }')"
  if [ "${location}" != "${expected_location}" ]; then
    e "FAIL: ${message}: Location is [${location}], expected [${expected_location}]"
    tr -d '\r' < "${tmp_dir}/headers.txt" >&2
    exit ${test_fail_exit_code}
  fi
}

if [ -n "${prefix_leading_directory_path}" ]; then
  # PREFIX_LEADING_DIRECTORY_PATH leg (the runner passes "/b"): the client
  # root lists the internal prefix, and neither the rendered links nor the
  # pagination marker may leak that prefix back to the client.
  e "  pagination probes with PREFIX_LEADING_DIRECTORY_PATH=${prefix_leading_directory_path}"

  fetch_expecting "/" "200"
  assert_page_contains 'href="/c/"' "prefixed page 1 lists the c/ directory"
  assert_page_contains 'href="/e.txt"' "prefixed page 1 lists e.txt"
  assert_page_contains 'Next page' "prefixed page 1 is truncated"
  # A marker like b%2Fe.txt would leak the internal prefix and, re-prepended
  # by the gateway, produce a marker S3 cannot match.
  assert_page_lacks 'marker=b%2F' "prefixed page 1 marker does not leak the internal prefix"
  assert_next_marker_starts_with 'e.txt' "prefixed page 1 marker is prefix-relative"

  fetch_expecting "/?marker=$(next_marker)" "200"
  assert_page_contains 'href="/%E3%82%AF%E3%82%BA%E7%AE%B1/"' "prefixed page 2 lists the Unicode directory"
  assert_page_contains 'href="/%E3%83%96%E3%83%84%E3%83%96%E3%83%84.txt"' "prefixed page 2 lists the Unicode file"
  assert_page_lacks 'href="/e.txt"' "prefixed page 2 does not repeat page 1"
  assert_page_lacks 'Next page' "prefixed page 2 is the final page"

  # The append-slash redirect must preserve the marker under the prefix
  # rewrite too: the internal /b prefix is prepended to /c before the S3
  # 404 routes to @trailslash, and the Location must stay client-facing
  # (built from $uri, never from the rewritten $uri_path).
  assert_redirect_location "/c?marker=e.txt" "/c/?marker=e.txt" \
    "prefixed append-slash redirect dropped or rewrote the marker"

  exit 0
fi

e "  pagination probes at the bucket root"

# Root page 1: with a page size of 2 the first page holds exactly a.txt and
# the a/ directory, and the marker for the following page starts at the a/
# prefix.
fetch_expecting "/" "200"
assert_page_contains 'href="/a.txt"' "root page 1 lists a.txt"
assert_page_contains 'href="/a/"' "root page 1 lists the a/ directory"
assert_page_lacks 'href="/b/"' "root page 1 is truncated before b/"
assert_page_contains 'Next page' "root page 1 renders a next link"
assert_next_marker_starts_with 'a%2F' "root page 1 marker starts at the a/ prefix"

fetch_expecting "/?marker=$(next_marker)" "200"
assert_page_contains 'href="/b/"' "root page 2 lists b/"
assert_page_contains 'href="/cache-bypass/"' "root page 2 lists cache-bypass/"
assert_page_lacks 'href="/a.txt"' "root page 2 does not repeat page 1"

e "  bounded walk across every root page"

# Following the next links must visit every entry exactly once and terminate.
: > "${tmp_dir}/union.html"
current_path="/"
page_count=0
while true; do
  fetch_expecting "${current_path}" "200"
  cat "${tmp_dir}/page.html" >> "${tmp_dir}/union.html"
  page_count=$((page_count + 1))
  marker="$(next_marker)"
  if [ -z "${marker}" ]; then
    break
  fi
  if [ "${page_count}" -ge "${max_page_walk}" ]; then
    e "FAIL: root listing did not terminate within ${max_page_walk} pages"
    exit ${test_fail_exit_code}
  fi
  current_path="/?marker=${marker}"
done

if [ "${page_count}" -lt 2 ]; then
  e "FAIL: root walk visited only ${page_count} page(s) - pagination did not engage"
  exit ${test_fail_exit_code}
fi

cp "${tmp_dir}/union.html" "${tmp_dir}/page.html"
assert_page_contains 'href="/index.html"' "root walk union lists index.html"
assert_page_contains 'href="/test/"' "root walk union lists test/"
assert_page_contains 'href="/statichost/"' "root walk union lists statichost/"
assert_page_contains 'href="/%D1%81%D0%B8%D1%81%D1%82%D0%B5%D0%BC%D1%8B/"' "root walk union lists the Unicode directory"

if [ "${is_windows}" == "0" ]; then
  e "  special-character keys as page boundaries under /a/"

  # /a/ holds five entries, so page 2 ends at plus+plus.txt: the '+' must
  # round-trip percent-encoded (a bare '+' would reach S3 as a space or break
  # the signed canonical query). Skipped on Windows: the reserved-character
  # fixture is not seeded there, which also shifts every page boundary.
  fetch_expecting "/a/" "200"
  assert_page_contains 'href="/a/%25%40%21%2A%28%29%3D%24%23%5E%26%7C.txt"' "a/ page 1 encodes the reserved-character key"
  assert_next_marker_starts_with 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.txt' "a/ page 1 marker is the last key"

  fetch_expecting "/a/?marker=$(next_marker)" "200"
  assert_page_contains 'href="/a/c/"' "a/ page 2 lists the c/ directory"
  assert_next_marker_starts_with 'plus%2Bplus.txt' "a/ page 2 marker percent-encodes the plus sign"

  fetch_expecting "/a/?marker=$(next_marker)" "200"
  assert_page_contains 'href="/a/%E3%81%93%E3%82%8C%E3%81%AF' "a/ page 3 lists the Unicode file"
  assert_page_lacks 'Next page' "a/ page 3 is the final page"
else
  e "  skipping /a/ page-boundary probes: reserved-character fixture is not seeded on Windows"
fi

e "  defined behavior for hostile and edge-case markers"

# /b/ holds four entries: page 1 is c/ and e.txt, page 2 is the two Unicode
# entries and fits exactly, so no next link may render on it.
fetch_expecting "/b/" "200"
assert_page_contains 'href="/b/c/"' "b/ page 1 lists c/"
assert_next_marker_starts_with 'e.txt' "b/ page 1 marker"

# A plain-key marker (what AWS returns as NextMarker, and what a hand-built
# or stale link contains) must work regardless of backend decoration.
fetch_expecting "/b/?marker=e.txt" "200"
assert_page_contains 'href="/b/%E3%82%AF%E3%82%BA%E7%AE%B1/"' "b/ page 2 lists the Unicode directory"
assert_page_lacks 'href="/b/e.txt"' "b/ page 2 does not repeat page 1"
assert_page_lacks 'Next page' "exact-fit final page renders no next link"
cp "${tmp_dir}/page.html" "${tmp_dir}/expected_page2.html"

# Only the marker parameter is forwarded: an extra parameter must change
# nothing (if it were forwarded, the signature would break and the gateway
# would return a sanitized 404).
fetch_expecting "/b/?marker=e.txt&fake=param" "200"
if ! cmp -s "${tmp_dir}/page.html" "${tmp_dir}/expected_page2.html"; then
  e "FAIL: an unknown query parameter changed the listing response"
  exit ${test_fail_exit_code}
fi

# A malformed percent-sequence is ignored (listing restarts at page 1)
# rather than surfacing as a 500 from the js_set handler.
fetch_expecting "/b/?marker=%zz" "200"
assert_page_contains 'href="/b/c/"' "malformed marker restarts from page 1"

# A marker past the final key yields the empty-listing page. U+10FFFF
# (%F4%8F%BF%BF) is the highest code point, so it sorts after every valid
# UTF-8 key - a plain ASCII marker like 'zzzz' would NOT be past the end,
# because the multi-byte Unicode fixture keys sort after it.
fetch_expecting "/b/?marker=%F4%8F%BF%BF" "200"
assert_page_contains 'No Files Available for Listing' "past-the-end marker renders the empty listing"

# The append-slash redirect must preserve the marker so a paginated URL
# without the trailing slash still resolves to the right page.
assert_redirect_location "/b?marker=e.txt" "/b/?marker=e.txt" \
  "append-slash redirect dropped the marker"

e "  directory listing pagination probes passed"

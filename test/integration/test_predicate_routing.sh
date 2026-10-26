#!/usr/bin/env bash

# Copyright 2026 F5, Inc.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Only terminal requests: safe to run before the first credential fetch in
# a cold-cache test. The caller waits on /health, never on a proxied path.
set -euo pipefail

test_server=$1
cors_enabled=$2
cors_origin=${3:-*}
expected_allow="GET, HEAD"
if [ "${cors_enabled}" = true ]; then
  expected_allow="GET, HEAD, OPTIONS"
fi

request() {
  local method=$1 path=$2 expected=$3 response actual
  # --path-as-is prevents curl from resolving dot segments before nginx sees
  # them. Status, headers and downloaded size all come from the same request.
  response=$(curl --silent --show-error --connect-timeout 3 --max-time 30 \
    --path-as-is -X "${method}" -D - -o /dev/null \
    -w '\nROUTING_RESULT:%{http_code}:%{size_download}' "${test_server}${path}")
  actual=${response##*ROUTING_RESULT:}
  headers=${response%ROUTING_RESULT:*}
  if [ "${actual%%:*}" != "${expected}" ]; then
    >&2 echo "FAIL: ${method} ${path}: expected ${expected}, got ${actual}"
    exit 2
  fi
  if [ "${expected}" = 204 ] && [ "${actual#*:}" != 0 ]; then
    >&2 echo "FAIL: preflight ${path} returned a body"
    exit 2
  fi
}

header() {
  local name=$1 expected=$2 line actual="" count=0
  while IFS= read -r line; do
    if [ "$(printf '%s' "${line%%:*}" | tr '[:upper:]' '[:lower:]')" = "${name}" ]; then
      actual=${line#*: }
      actual=${actual%$'\r'}
      count=$((count + 1))
    fi
  done <<< "${headers}"
  if [ "${actual}" != "${expected}" ] || [ "${count}" -ne 1 ]; then
    >&2 echo "FAIL: ${name}: expected one [${expected}], got ${count} [${actual}]"
    exit 2
  fi
}

origin_header() {
  if [ "${cors_enabled}" = true ]; then
    header access-control-allow-origin "${cors_origin}"
  elif grep -qi '^Access-Control-Allow-Origin:' <<< "${headers}"; then
    >&2 echo "FAIL: CORS-disabled response carries Access-Control-Allow-Origin"
    exit 2
  fi
}

# These expectations depend on normalized viewer paths, not object existence
# or S3 STRIP/PREFIX rewrites. Exercise the same paths under rewritten legs.
for path in /a.txt /gh609-missing /route/a.txt /indexXhtml /INDEX.html \
  /x/index.html/../file '/file?next=/index.html'; do
  for method in POST PATCH OPTIONS; do
    if [ "${method}" = OPTIONS ] && [ "${cors_enabled}" = true ]; then
      request "${method}" "${path}" 204
      header access-control-allow-methods "${expected_allow}"
    else
      request "${method}" "${path}" 405
      header allow "${expected_allow}"
    fi
    origin_header
  done
done

for path in /index.html /gh551-writeguard/index.html /gh609-missing/index.html \
  /health/index.html /soap/index.html /route/index.html /x//index.html \
  '/x/%69ndex%2Ehtml' '/x%2Findex.html' '/x/index.html?ignored=1'; do
  request POST "${path}" 404
  origin_header
  if [ "${cors_enabled}" = true ]; then
    request OPTIONS "${path}" 204
    header access-control-allow-methods "${expected_allow}"
  else
    request OPTIONS "${path}" 404
  fi
  origin_header
done

# NGINX rejects non-uppercase method tokens before location selection. These
# are parser errors, not gateway 405/404 responses, and carry no CORS headers.
for method in options Options get Get head Head; do
  request "${method}" /a.txt 400
  request "${method}" /gh551-writeguard/index.html 400
done

# Prefixes deliberately have no path-segment boundary. Their descendants
# ending in index.html are handled by the regex instead (tested above).
for method in POST OPTIONS; do
  for path in /health /healthcheck; do
    request "${method}" "${path}" 200
  done
  for path in /soap /soapbox; do
    request "${method}" "${path}" 404
  done
done

echo "  Predicate routing tests passed (CORS=${cors_enabled})"

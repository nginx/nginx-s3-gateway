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

# Tests for the STRIP/PREFIX_LEADING_DIRECTORY_PATH normalization in
# 01-set-defaults.envsh (GH-576): the request-path map in
# default.conf.template concatenates $PREFIX_LEADING_DIRECTORY_PATH with
# paths that always begin with "/", so a trailing-slash value produced
# double-slash S3 keys and 404'd every request. Equivalent value shapes must
# render a byte-identical map.
#
# These only need the image, not the compose environment. The rendering cases
# run 20-envsubst-on-templates.sh (from the base image) after the defaults
# script, mirroring the entrypoint's numeric-order execution.

set -o errexit   # abort on nonzero exit status
set -o pipefail  # don't hide errors within pipes

docker_cmd=$1

set -o nounset   # abort on unbound variable

# The shared runInImage and assertion helpers; also validates ${docker_cmd}.
. "$(dirname "${BASH_SOURCE[0]}")/entrypoint_test_lib.sh" "${docker_cmd}"

# Renders the templates with the given prefix/strip values and prints the
# $uri_full_path -> $uri_path map block from the rendered default.conf with
# all whitespace removed, so equivalent shapes can be compared byte-for-byte.
# The snippet is single-quoted: the sed range uses "." in place of "$" to
# keep the nginx variable names from being expanded by any shell layer.
render_map_snippet='. /docker-entrypoint.d/01-set-defaults.envsh \
 && /docker-entrypoint.d/20-envsubst-on-templates.sh > /dev/null \
 && sed -n "/map .uri_full_path .uri_path/,/}/p" /etc/nginx/conf.d/default.conf | tr -d "[:space:]"'

# Nothing here varies the credentials or the signature version, so they ride in
# the baseline rather than being repeated by every rendering.
baseline_extra_env=(
  -e "AWS_ACCESS_KEY_ID=unit_test"
  -e "AWS_SECRET_ACCESS_KEY=unit_test"
  -e "AWS_SIGS_VERSION=4"
)

# renderMap <prefix_value> <strip_value>
renderMap() {
  prefix=$1
  strip=$2

  runInImage "${render_map_snippet}" \
    -e STRIP_LEADING_DIRECTORY_PATH="${strip}" \
    -e PREFIX_LEADING_DIRECTORY_PATH="${prefix}"
}

# assertRendersSameMap <canonical_rendering> <prefix_value> <strip_value>
assertRendersSameMap() {
  canonical=$1
  prefix=$2
  strip=$3

  announceCase "Map for PREFIX='${prefix}' STRIP='${strip}' must render identically to its canonical shape"

  actual=$(renderMap "${prefix}" "${strip}")
  if [ "${actual}" != "${canonical}" ]; then
    failCase "FAIL: PREFIX='${prefix}' STRIP='${strip}' rendered a different map." \
      "Expected: [${canonical}]" \
      "Actual:   [${actual}]"
  fi
}

# The canonical, documented shapes.
canonical_prefix=$(renderMap "/b" "")
canonical_disabled=$(renderMap "" "")
canonical_strip=$(renderMap "/b" "/tostrip")

# Guard against vacuous comparisons: the canonical renders must actually
# carry the configured values (and so differ from one another).
if ! echo "${canonical_prefix}" | grep -qF '/b$1'; then
  failCase "FAIL: canonical PREFIX=/b map does not contain '/b\$1': [${canonical_prefix}]"
fi
if ! echo "${canonical_strip}" | grep -qF '~^/tostrip(.*)'; then
  failCase "FAIL: canonical STRIP=/tostrip map does not contain the strip arm: [${canonical_strip}]"
fi
if [ "${canonical_prefix}" == "${canonical_disabled}" ]; then
  failCase "FAIL: PREFIX=/b and PREFIX='' rendered identically: [${canonical_prefix}]"
fi

# Trailing slashes are trimmed and a missing leading slash is added.
assertRendersSameMap "${canonical_prefix}" "/b/" ""
assertRendersSameMap "${canonical_prefix}" "/b//" ""
assertRendersSameMap "${canonical_prefix}" "b" ""
assertRendersSameMap "${canonical_prefix}" "b/" ""

# A bare "/" (or slashes only) disables the prefix, same as unset.
assertRendersSameMap "${canonical_disabled}" "/" ""
assertRendersSameMap "${canonical_disabled}" "//" ""

# STRIP is trimmed of trailing slashes too, so the capture keeps its leading
# slash and the strip+prefix composition matches the documented shape.
assertRendersSameMap "${canonical_strip}" "/b" "/tostrip/"
assertRendersSameMap "${canonical_strip}" "/b/" "/tostrip/"

echo "PASS: STRIP/PREFIX_LEADING_DIRECTORY_PATH shapes normalize to identical rendered maps"

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

test_fail_exit_code=2
no_dep_exit_code=3

set -o nounset   # abort on unbound variable

if [ -z "${docker_cmd}" ]; then
  >&2 echo "missing first parameter: path to the docker executable"
  exit ${no_dep_exit_code}
fi

# Renders the templates with the given prefix/strip values and prints the
# $uri_full_path -> $uri_path map block from the rendered default.conf with
# all whitespace removed, so equivalent shapes can be compared byte-for-byte.
# The snippet is single-quoted: the sed range uses "." in place of "$" to
# keep the nginx variable names from being expanded by any shell layer.
render_map_snippet='. /docker-entrypoint.d/01-set-defaults.envsh \
 && /docker-entrypoint.d/20-envsubst-on-templates.sh > /dev/null \
 && sed -n "/map .uri_full_path .uri_path/,/}/p" /etc/nginx/conf.d/default.conf | tr -d "[:space:]"'

# renderMap <prefix_value> <strip_value>
# MSYS_NO_PATHCONV=1 added to resolve automatic path conversion
# https://github.com/docker/for-win/issues/6754#issuecomment-629702199
renderMap() {
  prefix=$1
  strip=$2

  MSYS_NO_PATHCONV=1 "${docker_cmd}" run --rm \
    -e S3_BUCKET_NAME=test-bucket \
    -e S3_SERVER=s3.example.com \
    -e S3_SERVER_PORT=9000 \
    -e S3_SERVER_PROTO=http \
    -e S3_REGION=us-east-1 \
    -e S3_STYLE=virtual-v2 \
    -e AWS_ACCESS_KEY_ID=unit_test \
    -e AWS_SECRET_ACCESS_KEY=unit_test \
    -e AWS_SIGS_VERSION=4 \
    -e ALLOW_DIRECTORY_LIST=false \
    -e PROVIDE_INDEX_PAGE=false \
    -e APPEND_SLASH_FOR_POSSIBLE_DIRECTORY=false \
    -e CORS_ENABLED=false \
    -e STRIP_LEADING_DIRECTORY_PATH="${strip}" \
    -e PREFIX_LEADING_DIRECTORY_PATH="${prefix}" \
    --entrypoint /bin/sh nginx-s3-gateway -c "${render_map_snippet}" 2>&1
}

# assertRendersSameMap <canonical_rendering> <prefix_value> <strip_value>
assertRendersSameMap() {
  canonical=$1
  prefix=$2
  strip=$3

  printf "  \033[36;1m▲\033[0m "
  echo "Map for PREFIX='${prefix}' STRIP='${strip}' must render identically to its canonical shape"

  actual=$(renderMap "${prefix}" "${strip}")
  if [ "${actual}" != "${canonical}" ]; then
    >&2 echo "FAIL: PREFIX='${prefix}' STRIP='${strip}' rendered a different map."
    >&2 echo "Expected: [${canonical}]"
    >&2 echo "Actual:   [${actual}]"
    exit ${test_fail_exit_code}
  fi
}

# The canonical, documented shapes.
canonical_prefix=$(renderMap "/b" "")
canonical_disabled=$(renderMap "" "")
canonical_strip=$(renderMap "/b" "/tostrip")

# Guard against vacuous comparisons: the canonical renders must actually
# carry the configured values (and so differ from one another).
if ! echo "${canonical_prefix}" | grep -qF '/b$1'; then
  >&2 echo "FAIL: canonical PREFIX=/b map does not contain '/b\$1': [${canonical_prefix}]"
  exit ${test_fail_exit_code}
fi
if ! echo "${canonical_strip}" | grep -qF '~^/tostrip(.*)'; then
  >&2 echo "FAIL: canonical STRIP=/tostrip map does not contain the strip arm: [${canonical_strip}]"
  exit ${test_fail_exit_code}
fi
if [ "${canonical_prefix}" == "${canonical_disabled}" ]; then
  >&2 echo "FAIL: PREFIX=/b and PREFIX='' rendered identically: [${canonical_prefix}]"
  exit ${test_fail_exit_code}
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

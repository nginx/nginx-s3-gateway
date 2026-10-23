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

# Tests for the STRIP/PREFIX_LEADING_DIRECTORY_PATH request-path map in
# default.conf.template, at the rendered-configuration level:
#
# - the normalization in 01-set-defaults.envsh (GH-576): the map
#   concatenates $PREFIX_LEADING_DIRECTORY_PATH with paths that always begin
#   with "/", so a trailing-slash value produced double-slash S3 keys and
#   404'd every request. Equivalent value shapes must render a byte-identical
#   map.
# - the capture discipline the map relies on: the remainder
#   of the path is bound to the named capture $s3gw_path_after_strip, which
#   must be declared exactly once and referenced only inside the map that
#   performs the match, and the rendered gateway configuration must contain
#   no positional captures ($1..$9) at all. nginx -t cannot check either
#   property - a second declaration or a stray reference elsewhere is valid
#   syntax - so they are asserted textually here, on the complete rendered
#   configuration.
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

# The name of the capture the map binds the path remainder to. Reserved for
# the gateway - see the comment above the map in default.conf.template.
capture_name="s3gw_path_after_strip"

# Renders the templates the way the entrypoint does. The snippet is
# single-quoted so that no shell layer expands the nginx variable names.
render_snippet='. /docker-entrypoint.d/01-set-defaults.envsh \
 && /docker-entrypoint.d/20-envsubst-on-templates.sh > /dev/null'

# Renders and prints the $uri_full_path -> $uri_path map block from the
# rendered default.conf with all whitespace removed, so equivalent shapes can
# be compared byte-for-byte. The sed range uses "." in place of "$" to keep
# the variable names from being expanded by any shell layer.
render_map_snippet="${render_snippet}"' \
 && sed -n "/map .uri_full_path .uri_path/,/}/p" /etc/nginx/conf.d/default.conf | tr -d "[:space:]"'

# Renders and prints the complete rendered gateway configuration with comment
# lines removed, so the capture assertions below cannot be satisfied (or
# tripped) by prose.
render_all_snippet="${render_snippet}"' \
 && find /etc/nginx/conf.d -name "*.conf" -exec grep -hv "^[[:space:]]*#" {} +'

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
if ! echo "${canonical_prefix}" | grep -qF "/b\$${capture_name}"; then
  failCase "FAIL: canonical PREFIX=/b map does not prepend /b to the captured path: [${canonical_prefix}]"
fi
if ! echo "${canonical_strip}" | grep -qF "~^/tostrip(?<${capture_name}>.*)"; then
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

# The capture name must survive rendering even when a same-named variable is
# present in the container environment. What keeps it literal is
# NGINX_ENVSUBST_FILTER (set in the Dockerfiles): the renderer substitutes
# only the names that match it, and the filter admits ALL-CAPS names only.
# Both halves are asserted so the case guards the filter rather than merely
# the absence of the variable: with the filter cleared the injected value must
# leak into the map (proving this very variable is otherwise substitutable),
# and with the image's filter in force it must not.
announceCase "Rendered map must keep \$${capture_name} literal only because of NGINX_ENVSUBST_FILTER"
leaked=$(runInImage "${render_map_snippet}" \
  -e STRIP_LEADING_DIRECTORY_PATH="/tostrip" \
  -e PREFIX_LEADING_DIRECTORY_PATH="/b" \
  -e "${capture_name}=/injected" \
  -e NGINX_ENVSUBST_FILTER="")
if [[ ${leaked} != *"/injected"* ]]; then
  failCase "FAIL: with NGINX_ENVSUBST_FILTER cleared, the injected value did not reach the map, so the positive control is broken:" \
    "Actual: [${leaked}]"
fi
actual=$(runInImage "${render_map_snippet}" \
  -e STRIP_LEADING_DIRECTORY_PATH="/tostrip" \
  -e PREFIX_LEADING_DIRECTORY_PATH="/b" \
  -e "${capture_name}=/injected")
if [ "${actual}" != "${canonical_strip}" ]; then
  failCase "FAIL: a same-named environment variable changed the rendered map." \
    "Expected: [${canonical_strip}]" \
    "Actual:   [${actual}]"
fi

# Capture discipline, checked on the complete rendered configuration under the
# strip+prefix shape (the only one in which the regex arm carries a value).
announceCase "Rendered configuration must declare \$${capture_name} once, reference it only in the map, and hold no positional captures"
rendered=$(runInImage "${render_all_snippet}" \
  -e STRIP_LEADING_DIRECTORY_PATH="/tostrip" \
  -e PREFIX_LEADING_DIRECTORY_PATH="/b")

declarations=$(echo "${rendered}" | grep -cF "(?<${capture_name}>" || true)
if [ "${declarations}" -ne 1 ]; then
  failCase "FAIL: expected exactly one declaration of (?<${capture_name}>...) in the rendered configuration, found ${declarations}:" \
    "$(echo "${rendered}" | grep -F "(?<${capture_name}>" || true)"
fi

# Every line that mentions the capture must be the map's own regex arm, which
# both declares it and consumes it. Anything else is a reference outside the
# block that performs the match. Both reference spellings, $name and ${name},
# are searched for.
references_elsewhere=$(echo "${rendered}" | grep -E "\\\$\{?${capture_name}\b" | grep -vF "(?<${capture_name}>" || true)
if [ -n "${references_elsewhere}" ]; then
  failCase "FAIL: \$${capture_name} is referenced outside the map that declares it:" \
    "${references_elsewhere}"
fi

positional=$(echo "${rendered}" | grep -E '\$[1-9]' || true)
if [ -n "${positional}" ]; then
  failCase "FAIL: the rendered gateway configuration contains positional captures:" \
    "${positional}"
fi

# The rendered configuration must also be one nginx accepts. nginx -t needs a
# resolver address because runInImage runs with --network none and the image's
# /etc/resolv.conf is then empty; the value is never contacted.
#
# NGINX Plus refuses to run nginx -t without a license. The compose stack gets
# its license through the runner, but these containers are started directly,
# so the license is resolved here through the shared lookup and installed by
# the base image's own 40-env-to-license.sh. The flavor is detected from the
# image rather than passed in: every entrypoint test takes only the docker
# command, and nothing else here differs between flavors.
license_args=()
license_snippet="true"
if [[ "$(runInImage 'nginx -v')" == *"nginx-plus"* ]]; then
  # shellcheck source=test/plus_license_lib.sh
  . "$(dirname "${BASH_SOURCE[0]}")/../plus_license_lib.sh"
  if ! resolvePlusLicenseInto; then
    failCase "FAIL: ${plus_license_not_found_message}"
  fi
  license_args=(-e "NGINX_LICENSE_JWT=${plus_license_jwt}")
  license_snippet="/docker-entrypoint.d/40-env-to-license.sh > /dev/null"
fi

announceCase "Rendered configuration must pass nginx -t"
if ! output=$(runInImage "${render_snippet} && ${license_snippet} && nginx -t" \
  -e STRIP_LEADING_DIRECTORY_PATH="/tostrip(?=/|\$)" \
  -e PREFIX_LEADING_DIRECTORY_PATH="/b" \
  -e DNS_RESOLVERS="127.0.0.1" \
  "${license_args[@]+"${license_args[@]}"}"); then
  failCase "FAIL: nginx -t rejected the rendered configuration:" "${output}"
fi

echo "PASS: STRIP/PREFIX_LEADING_DIRECTORY_PATH shapes normalize to identical rendered maps and keep the capture scoped"

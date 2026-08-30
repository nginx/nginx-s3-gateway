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

# Tests for the shared boolean grammar (GH-600): every boolean setting must be
# spelling-validated by 00-check-for-required-env.sh through
# gateway_env_lib.sh, empty values must keep passing (the compose file's bare
# pass-through keys deliver empty strings by design), the
# CORS_ALLOW_PRIVATE_NETWORK_ACCESS tri-state must render the literal header
# values true/false/empty, and the shell table must agree with
# utils.js#parseBoolean spelling for spelling.
#
# These only need the image, not the compose environment.

set -o errexit   # abort on nonzero exit status
set -o pipefail  # don't hide errors within pipes

docker_cmd=$1

set -o nounset   # abort on unbound variable

# The shared runInImage and assertion helpers; also validates ${docker_cmd}.
. "$(dirname "${BASH_SOURCE[0]}")/entrypoint_test_lib.sh" "${docker_cmd}"

# Every case here signs with the same static credentials under v4; only the
# boolean value under test varies.
baseline_extra_env=(
  -e "AWS_ACCESS_KEY_ID=unit_test"
  -e "AWS_SECRET_ACCESS_KEY=unit_test"
  -e "AWS_SIGS_VERSION=4"
)

### Membership: every boolean setting must be in the validation list.

# Booleans the baseline environment pins are overridden through
# container_setup: a duplicate -e would depend on docker's flag ordering
# (see the hook notes in entrypoint_test_lib.sh).
for name in ALLOW_DIRECTORY_LIST PROVIDE_INDEX_PAGE \
    APPEND_SLASH_FOR_POSSIBLE_DIRECTORY CORS_ENABLED; do
  container_setup="export ${name}=on"
  assertValidationRejects "${name}='on'" "${name} contains an invalid value"
  container_setup="export ${name}=yes"
  assertValidationAccepts "${name}='yes'"
done
container_setup="true"

# The remaining two-state booleans are unset in the baseline. Empty must
# keep passing: it is what a bare compose pass-through key delivers when the
# invoking shell leaves the variable unset.
for name in FOUR_O_FOUR_ON_EMPTY_BUCKET DEBUG AWS_EC2_METADATA_V1_DISABLED \
    PROXY_CACHE_BYPASS_NO_CACHE ACCESS_LOG_CACHE_STATUS; do
  assertValidationRejects "${name}='on'" "${name} contains an invalid value" \
    -e "${name}=on"
  assertValidationAccepts "${name}='yes'" -e "${name}=yes"
  assertValidationAccepts "${name}='NO'" -e "${name}=NO"
  assertValidationAccepts "${name} empty" -e "${name}="
done

# The grammar is case-insensitive; one variable stands in for all of them
# (the table itself is pinned in the shell/njs agreement case below).
assertValidationAccepts "DEBUG='TrUe'" -e "DEBUG=TrUe"
assertValidationAccepts "DEBUG='0'" -e "DEBUG=0"

# The tri-state settings keep their "or unset means ..." diagnostics.
assertValidationRejects "IPV6_ENABLED='on'" \
  "IPV6_ENABLED contains an invalid value (on). Valid values: true, false, or unset for auto-detection" \
  -e "IPV6_ENABLED=on"
assertValidationAccepts "IPV6_ENABLED='yes'" -e "IPV6_ENABLED=yes"
assertValidationAccepts "IPV6_ENABLED empty" -e "IPV6_ENABLED="

assertValidationRejects "CORS_ALLOW_PRIVATE_NETWORK_ACCESS='enabled'" \
  "CORS_ALLOW_PRIVATE_NETWORK_ACCESS contains an invalid value (enabled). Valid values: true, false, or unset to omit the Access-Control-Allow-Private-Network header" \
  -e "CORS_ALLOW_PRIVATE_NETWORK_ACCESS=enabled"
assertValidationAccepts "CORS_ALLOW_PRIVATE_NETWORK_ACCESS='TRUE'" \
  -e "CORS_ALLOW_PRIVATE_NETWORK_ACCESS=TRUE"
assertValidationAccepts "CORS_ALLOW_PRIVATE_NETWORK_ACCESS empty" \
  -e "CORS_ALLOW_PRIVATE_NETWORK_ACCESS="

### CORS_ALLOW_PRIVATE_NETWORK_ACCESS rendering: the header value is
### constrained to the literal strings true/false, with empty omitting the
### add_header - never the 1/0 the two-state booleans normalize to.

rendered_cors_conf=/etc/nginx/conf.d/gateway/cors.conf

# assertPrivateNetworkHeaderRenders <description> <expected_value> [extra docker run args...]
assertPrivateNetworkHeaderRenders() {
  description=$1
  expected=$2
  shift 2

  announceCase "Rendered ${rendered_cors_conf} must hold the ${description} private-network header"

  output=$(runInImage \
    ". /docker-entrypoint.d/01-set-defaults.envsh \
     && /docker-entrypoint.d/20-envsubst-on-templates.sh > /dev/null \
     && grep -F 'Access-Control-Allow-Private-Network' ${rendered_cors_conf}" \
    "$@")

  if ! printf '%s' "${output}" | \
      grep -qF "add_header 'Access-Control-Allow-Private-Network' '${expected}';"; then
    failCase "FAIL: expected the rendered private-network add_header value to be '${expected}' but got:" \
      "${output}"
  fi
}

assertPrivateNetworkHeaderRenders "normalized-true (=TRUE)" "true" \
  -e "CORS_ALLOW_PRIVATE_NETWORK_ACCESS=TRUE"
assertPrivateNetworkHeaderRenders "normalized-false (=no)" "false" \
  -e "CORS_ALLOW_PRIVATE_NETWORK_ACCESS=no"
assertPrivateNetworkHeaderRenders "omitted (unset)" ""

### Drift guard: the shell grammar and utils.js#parseBoolean must agree for
### every canonical spelling and a handful of near-misses. Without this the
### two implementations start diverging again the first time either side is
### touched (the pre-GH-600 state: njs accepted lowercase 'yes', the shell
### did not).

# The njs CLI is transitioning from `-t module` to `-m` and the latest-njs
# variant only understands the new flag; NJS_LATEST does not reach the
# integration runner, so detect the flag inside the image instead.
drift_snippet="$(cat << 'SNIPPET'
set -e
. /etc/nginx/gateway_env_lib.sh
printf '%s\n' true TRUE TrUe yes YES yEs Yes 1 false FALSE FaLsE no NO nO No 0 \
  on off enabled disabled 01 'yes ' ' true' truthy '' > /tmp/spellings
while IFS= read -r v; do
  printf '%s=%s\n' "$v" "$(parseBoolean "$v")"
done < /tmp/spellings > /tmp/shell_verdicts
# A trailing newline cannot ride through the line-based spellings file, and it
# is the one artifact command substitution would hide (GH-600 review): probe
# it explicitly on both sides.
nl="$(printf '\nx')"; nl="${nl%x}"
printf 'trailing-newline=%s\n' "$(parseBoolean "true${nl}")" >> /tmp/shell_verdicts
cat > /tmp/pb_test.js << 'JS'
import utils from "include/utils.js";
import fs from "fs";
const lines = fs.readFileSync("/tmp/spellings", "utf8").split("\n");
lines.pop();
lines.forEach(function (v) {
    console.log(v + "=" + (utils.parseBoolean(v) ? "1" : "0"));
});
console.log("trailing-newline=" + (utils.parseBoolean("true\n") ? "1" : "0"));
JS
if /usr/bin/njs -t module /dev/null > /dev/null 2>&1; then
  njs_flags="-t module"
else
  njs_flags="-m"
fi
# shellcheck disable=SC2086 # njs_flags is deliberately two words
/usr/bin/njs ${njs_flags} -p /etc/nginx /tmp/pb_test.js > /tmp/njs_verdicts
diff /tmp/shell_verdicts /tmp/njs_verdicts
SNIPPET
)"

announceCase "gateway_env_lib.sh parseBoolean must agree with utils.js parseBoolean"
if ! output=$(runInImage "${drift_snippet}"); then
  failCase "FAIL: the shell and njs boolean tables disagree (shell=left, njs=right):" \
    "${output}"
fi

echo "PASS: boolean spelling validation, private-network header rendering and shell/njs table agreement"

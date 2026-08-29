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

# Tests for the ACCESS_LOG_CACHE_STATUS plumbing (GH-466): the boolean
# spelling check in 00-check-for-required-env.sh, the log format that
# 01-set-defaults.envsh derives into the rendered gateway/logging.conf, and
# the settings banner line.
#
# These only need the image, not the compose environment. The rendering cases
# run 01-set-defaults.envsh and 20-envsubst-on-templates.sh (from the base
# image) in order, mirroring the entrypoint's numeric-order execution, and
# compare the whole comment-stripped rendering: the disabled case doubles as
# the proof that the format stays byte-identical to the historical static one.

set -o errexit   # abort on nonzero exit status
set -o pipefail  # don't hide errors within pipes

docker_cmd=$1

set -o nounset   # abort on unbound variable

# The shared runInImage and assertion helpers; also validates ${docker_cmd}.
. "$(dirname "${BASH_SOURCE[0]}")/entrypoint_test_lib.sh" "${docker_cmd}"

rendered_conf=/etc/nginx/conf.d/gateway/logging.conf

# Every case here signs with the same static credentials under v4; only the
# ACCESS_LOG_CACHE_STATUS value under test varies.
baseline_extra_env=(
  -e "AWS_ACCESS_KEY_ID=unit_test"
  -e "AWS_SECRET_ACCESS_KEY=unit_test"
  -e "AWS_SIGS_VERSION=4"
)

expected_disabled="$(cat << 'EXPECTED'
log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
'$status $body_bytes_sent "$http_referer" '
'"$http_user_agent" "$http_x_forwarded_for"';

access_log  /var/log/nginx/access.log  main;
EXPECTED
)"

expected_enabled="$(cat << 'EXPECTED'
log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
'$status $body_bytes_sent "$http_referer" '
'"$http_user_agent" "$http_x_forwarded_for" "$upstream_cache_status"';

access_log  /var/log/nginx/access.log  main;
EXPECTED
)"

# assertRejects <value>
assertRejects() {
  assertValidationRejects "ACCESS_LOG_CACHE_STATUS='$1'" \
    "ACCESS_LOG_CACHE_STATUS contains an invalid value" \
    -e ACCESS_LOG_CACHE_STATUS="$1"
}

# assertAccepts <value>
assertAccepts() {
  assertValidationAccepts "ACCESS_LOG_CACHE_STATUS='$1'" \
    -e ACCESS_LOG_CACHE_STATUS="$1"
}

# Renders the templates the way the entrypoint does and compares the
# resulting conf file, comment lines stripped, against an expected rendering.
# assertRenders <description> <expected_content> [extra docker run args...]
assertRenders() {
  description=$1
  expected=$2
  shift 2

  announceCase "Rendered ${rendered_conf} must hold the ${description} format"

  output=$(runInImage \
    ". /docker-entrypoint.d/01-set-defaults.envsh \
     && /docker-entrypoint.d/20-envsubst-on-templates.sh > /dev/null \
     && grep -v '^#' ${rendered_conf}" \
    "$@")

  if [ "${output}" != "${expected}" ]; then
    failCase "FAIL: expected ${rendered_conf} (comments stripped) to be:" \
      "${expected}" "but got:" "${output}"
  fi
}

# parseBoolean treats every unrecognized spelling - including the lowercase
# 'yes' - as false, so these must fail at startup rather than silently keep
# the cache status out of the access log.
assertRejects "yes"
assertRejects "enabled"
assertAccepts "true"
assertAccepts "false"
assertAccepts "YES"
assertAccepts "0"

# Unset must render the historical combined-log-compatible format unchanged;
# enabling appends exactly one trailing field.
assertRenders "default (cache status disabled)" "${expected_disabled}"
assertRenders "cache-status-enabled" "${expected_enabled}" \
  -e ACCESS_LOG_CACHE_STATUS=true

assertBannerContains "the cache status field as disabled by default" \
  "Access log includes upstream cache status: 0"
assertBannerContains "the cache status field as enabled" \
  "Access log includes upstream cache status: 1" \
  -e ACCESS_LOG_CACHE_STATUS=true

echo "PASS: ACCESS_LOG_CACHE_STATUS validation, rendering and banner"

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

# Tests for the 99-output-settings.sh entrypoint banner (GH-367). The Origin
# and Host Header lines must reflect the S3_UPSTREAM/S3_HOST_HEADER values
# computed per S3_STYLE by 01-set-defaults.envsh instead of always assuming
# the virtual-host form, which showed a bucket-prefixed hostname even for
# path-style deployments. Sourcing 01-set-defaults.envsh before running the
# banner script mirrors the entrypoint's numeric-order execution.

set -o errexit   # abort on nonzero exit status
set -o pipefail  # don't hide errors within pipes

docker_cmd=$1

check_banner() {
  style=$1
  expected_origin=$2
  expected_host_header=$3

  # MSYS_NO_PATHCONV=1 added to resolve automatic path conversion
  # https://github.com/docker/for-win/issues/6754#issuecomment-629702199
  output=$(MSYS_NO_PATHCONV=1 "${docker_cmd}" run --rm \
    -e S3_BUCKET_NAME=test-bucket \
    -e S3_SERVER=s3.example.com \
    -e S3_SERVER_PORT=9000 \
    -e S3_SERVER_PROTO=http \
    -e CORS_ENABLED=false \
    -e S3_STYLE="${style}" \
    --entrypoint /bin/sh nginx-s3-gateway -c \
    '. /docker-entrypoint.d/01-set-defaults.envsh && sh /docker-entrypoint.d/99-output-settings.sh')

  if ! echo "${output}" | grep -qF "Origin: ${expected_origin}"; then
    >&2 echo "FAIL [S3_STYLE=${style}]: expected 'Origin: ${expected_origin}' in banner:"
    >&2 echo "${output}"
    exit 2
  fi

  if ! echo "${output}" | grep -qF "Host Header: ${expected_host_header}"; then
    >&2 echo "FAIL [S3_STYLE=${style}]: expected 'Host Header: ${expected_host_header}' in banner:"
    >&2 echo "${output}"
    exit 2
  fi
}

# Path style keeps the bucket out of the hostname entirely - the GH-367 fix.
check_banner path       "http://s3.example.com:9000"             "s3.example.com:9000"
check_banner virtual-v2 "http://test-bucket.s3.example.com:9000" "test-bucket.s3.example.com:9000"
# Legacy virtual style connects to the bare server and routes the bucket
# through the Host header (which carries no port).
check_banner virtual    "http://s3.example.com:9000"             "test-bucket.s3.example.com"

echo "PASS: settings banner reports per-S3_STYLE origin and host header"

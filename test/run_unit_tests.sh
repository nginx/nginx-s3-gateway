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

# Runs the njs unit test suites inside the already-built gateway image.
# Invoked by the GNUmakefile (make test-unit / make retest) - not intended
# to be run directly, although doing so is harmless.
#
# Every test/unit/*_test.js file is discovered by glob and runs twice: once
# without AWS_SESSION_TOKEN and once with it, because credential handling
# branches on token presence. New test files are picked up automatically.
#
# Environment:
#   DOCKER      docker CLI to use (default: docker)
#   IMAGE_NAME  gateway image tag to test (default: nginx-s3-gateway)
#   NJS_LATEST  1 when testing the latest-njs variant image (default: 0)

set -o errexit
set -o nounset
set -o pipefail

script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

DOCKER="${DOCKER:-docker}"
IMAGE_NAME="${IMAGE_NAME:-nginx-s3-gateway}"
NJS_LATEST="${NJS_LATEST:-0}"

# Validate before the numeric [ -eq ] comparison below: a non-numeric value
# (e.g. NJS_LATEST=true) would otherwise print an 'integer expression
# expected' warning and silently select the stable-njs `-t module` flag,
# which the latest-njs image's CLI does not understand.
if ! { [ "${NJS_LATEST}" = "0" ] || [ "${NJS_LATEST}" = "1" ]; }; then
  >&2 echo "Invalid NJS_LATEST value: ${NJS_LATEST} - must be 0 or 1"
  exit 2
fi

p() {
  printf "\033[34;1m▶\033[0m "
  echo "$1"
}

# The njs CLI is transitioning from `-t module` to `-m`; the latest-njs
# variant image ships a CLI that only understands the new flag.
if [ "${NJS_LATEST}" -eq 1 ]; then
  njs_module_flags=(-m)
else
  njs_module_flags=(-t module)
fi

# Environment the modules read at import time. Values here must be present
# before the module loads because they are captured into module-level
# constants - mutating process.env inside a test cannot change them.
unit_test_env=(
  -e "DEBUG=true"
  -e "S3_STYLE=virtual-v2"
  -e "S3_SERVICE=s3"
  -e "AWS_ACCESS_KEY_ID=unit_test"
  -e "AWS_SECRET_ACCESS_KEY=unit_test"
  -e "S3_BUCKET_NAME=unit_test"
  -e "S3_SERVER=unit_test"
  -e "S3_SERVER_PROTO=https"
  -e "S3_SERVER_PORT=443"
  -e "S3_REGION=test-1"
  -e "AWS_SIGS_VERSION=4"
  -e "APPEND_SLASH_FOR_POSSIBLE_DIRECTORY=true"
)

# Additional arguments (extra -e flags) may follow the test file name.
run_unit_test() {
  test_file="$1"
  shift
  # MSYS_NO_PATHCONV=1 stops Git Bash on Windows from rewriting the
  # container-side paths: https://github.com/docker/for-win/issues/6754
  MSYS_NO_PATHCONV=1 "${DOCKER}" run     \
    --rm                                 \
    -v "${script_dir}/unit:/var/tmp"     \
    --workdir /var/tmp                   \
    "${unit_test_env[@]}"                \
    "$@"                                 \
    --entrypoint /usr/bin/njs            \
    "${IMAGE_NAME}" "${njs_module_flags[@]}" -p '/etc/nginx' "/var/tmp/${test_file}"
}

for test_path in "${script_dir}"/unit/*_test.js; do
  test_file="$(basename "${test_path}")"
  p "Running unit tests in ${test_file} without a session token"
  run_unit_test "${test_file}"
  p "Running unit tests in ${test_file} with a session token"
  run_unit_test "${test_file}" -e "AWS_SESSION_TOKEN=unit_test"
done

p "All unit tests complete"

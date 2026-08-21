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

# DEPRECATED: this script is retained only for backwards compatibility and
# now delegates to the GNUmakefile, which is the sole supported interface for
# build and test workflows. Use the make targets directly instead:
#
#   ./test.sh --type oss            ->  make test  NGINX_TYPE=oss
#   CI=true ./test.sh --type oss    ->  make retest NGINX_TYPE=oss
#   ./test.sh --latest-njs ...      ->  make test-latest-njs / retest-latest-njs
#   ./test.sh --unprivileged ...    ->  make test-unprivileged / retest-unprivileged
#
# Run `make help` for the full target list. The test logic itself lives in
# test/run_unit_tests.sh and test/run_integration_tests.sh.

set -o errexit
set -o nounset
set -o pipefail

script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

e() {
  >&2 echo "$1"
}

usage() {
  e "Usage: $0 [--latest-njs] [--unprivileged] [--type <oss|plus>]"
  exit 1
}

e "WARNING: test.sh is deprecated and now delegates to make."
e "         Use the make targets directly - run 'make help' for the list."

for arg in "$@"; do
  shift
  case "$arg" in
    '--help')           set -- "$@" '-h'   ;;
    '--latest-njs')     set -- "$@" '-j'   ;;
    '--unprivileged')   set -- "$@" '-u'   ;;
    '--type')           set -- "$@" '-t'   ;;
    *)                  set -- "$@" "$arg" ;;
  esac
done

njs_latest=0
unprivileged=0
nginx_type="oss"

while getopts "hjut:" arg; do
  case "${arg}" in
    j) njs_latest=1 ;;
    u) unprivileged=1 ;;
    t) nginx_type="${OPTARG}" ;;
    *) usage ;;
  esac
done
shift $((OPTIND-1))

# The legacy script stacked the two variants onto one image when both flags
# were given; the make targets deliberately do not support that combination.
if [ "${njs_latest}" -eq 1 ] && [ "${unprivileged}" -eq 1 ]; then
  e "Combining --latest-njs and --unprivileged is no longer supported;"
  e "run 'make test-latest-njs' and 'make test-unprivileged' separately."
  exit 1
fi

variant=""
if [ "${njs_latest}" -eq 1 ]; then
  variant="-latest-njs"
elif [ "${unprivileged}" -eq 1 ]; then
  variant="-unprivileged"
fi

# The legacy contract: CI=true skipped the docker build and tested the image
# already tagged nginx-s3-gateway. That maps to the no-rebuild retest targets.
if [ "${CI:-false}" = "true" ]; then
  target="retest${variant}"
else
  target="test${variant}"
fi

make_args=("${target}" "NGINX_TYPE=${nginx_type}")
if [ -n "${S3_STYLE:-}" ]; then
  make_args+=("S3_STYLE=${S3_STYLE}")
fi

e "Delegating to: make -C ${script_dir} ${make_args[*]}"
exec make -C "${script_dir}" "${make_args[@]}"

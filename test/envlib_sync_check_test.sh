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

# Self-test for the envlib-sync-check lint target (GH-600): the guard that
# keeps the installer's synced copy of gateway_env_lib.sh from drifting is
# itself only useful if its failure branches actually fire. Each case copies
# the real GNUmakefile and the two synced files into a scratch directory,
# mutates them, and runs the real target there via make -C, so the sed
# extraction and the guards are exercised exactly as `make lint` runs them.
#
# Needs only GNU make and coreutils - no docker, no image.

set -o errexit   # abort on nonzero exit status
set -o pipefail  # don't hide errors within pipes
set -o nounset   # abort on unbound variable

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

test_fail_exit_code=2

sandbox="$(mktemp -d)"
trap 'rm -rf "${sandbox}"' EXIT

failCase() {
  >&2 printf '%s\n' "$@"
  exit "${test_fail_exit_code}"
}

# resetSandbox recreates pristine copies of the three files the target reads.
resetSandbox() {
  mkdir -p "${sandbox}/common/etc/nginx"
  cp "${repo_dir}/GNUmakefile" "${sandbox}/GNUmakefile"
  cp "${repo_dir}/common/etc/nginx/gateway_env_lib.sh" \
    "${sandbox}/common/etc/nginx/gateway_env_lib.sh"
  cp "${repo_dir}/standalone_ubuntu_oss_install.sh" \
    "${sandbox}/standalone_ubuntu_oss_install.sh"
}

# runCheck prints the target's combined output; its exit status is the
# target's. The caller captures both.
runCheck() {
  make -s -C "${sandbox}" envlib-sync-check 2>&1
}

# assertCheckFails <case description> <expected output fragment> runs the
# target in the current sandbox state and requires a nonzero exit whose
# output contains the fragment.
assertCheckFails() {
  description=$1
  expected_fragment=$2

  echo "  case: ${description}"
  if output="$(runCheck)"; then
    failCase "FAIL: envlib-sync-check passed but must fail when ${description}" \
      "output:" "${output}"
  fi
  if ! printf '%s' "${output}" | grep -qF "${expected_fragment}"; then
    failCase "FAIL: envlib-sync-check failed as expected (${description}) but without the expected diagnostic" \
      "expected fragment: ${expected_fragment}" "output:" "${output}"
  fi
}

# Pristine copies must pass: this validates the fixture itself, so the
# failure cases below cannot pass vacuously against a broken sandbox.
echo "  case: pristine copies stay in sync"
resetSandbox
if ! output="$(runCheck)"; then
  failCase "FAIL: envlib-sync-check must pass on pristine copies" \
    "output:" "${output}"
fi

# A drifted function body in one copy must be caught.
resetSandbox
sed -i 's/true | yes | 1)/true | yes | 1 | maybe)/' \
  "${sandbox}/standalone_ubuntu_oss_install.sh"
assertCheckFails "the installer copy drifts" \
  "gateway_env_lib functions differ"

# Markers stripped from BOTH files must be caught: two empty sed extractions
# would otherwise diff clean (the vacuous-pass guard).
resetSandbox
sed -i '/gateway_env_lib functions BEGIN/d' \
  "${sandbox}/common/etc/nginx/gateway_env_lib.sh" \
  "${sandbox}/standalone_ubuntu_oss_install.sh"
assertCheckFails "the markers are stripped from both files" \
  "region not found"

# A marker stripped from a single file must be caught and the diagnostic must
# name that file.
resetSandbox
sed -i '/gateway_env_lib functions BEGIN/d' \
  "${sandbox}/common/etc/nginx/gateway_env_lib.sh"
assertCheckFails "the marker is stripped from the library file" \
  "region not found in common/etc/nginx/gateway_env_lib.sh"

echo "PASS: envlib-sync-check catches drift and missing markers"

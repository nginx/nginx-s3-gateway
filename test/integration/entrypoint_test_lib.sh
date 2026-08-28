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

# Shared helpers for the entrypoint test scripts (test_entrypoint_*.sh).
#
# This file is sourced, never executed; it carries a shebang only because
# a dialect is what shellcheck needs to lint it (make lint globs
# test/integration/*.sh). The path to the docker executable is passed as the
# sourcing argument:
#
#   . "$(dirname "${BASH_SOURCE[0]}")/entrypoint_test_lib.sh" "${docker_cmd}"
#
# The baseline container environment lives here because it has to track the
# gateway's required variables (the `required` array in
# common/docker-entrypoint.d/00-check-for-required-env.sh). With a copy per
# script, a newly required variable leaves whichever copy was missed failing its
# containers for an unrelated reason (GH-593).
#
# Two hooks adapt the helpers to a script's cases. Assign them after sourcing,
# or the defaults below overwrite them; container_setup may also be reassigned
# for a one-off case and restored afterwards:
#
#   baseline_extra_env  extra `-e` arguments every container in that script
#                       needs (the credentials or signature version its cases
#                       share). Must not repeat a baseline variable - a
#                       duplicate `-e` would depend on docker's flag ordering.
#   container_setup     shell snippet run inside the container ahead of the
#                       entrypoint script under test, e.g. writing secret files.
#
# Every helper below scopes its own working variables with `local` - the one
# exception, _runInImageAllowingFailure, is explained at its definition - so a
# sourcing script is free to use names like ${output}, ${status} or ${value}
# across a helper call. Those locals are also not readable from a sourcing
# script: shellcheck's SC2154 is warning-level, so a variable referenced in a
# script that never assigns it fails `make lint`. Abort through failCase.

docker_cmd=$1

test_fail_exit_code=2
no_dep_exit_code=3

if [ -z "${docker_cmd}" ]; then
  >&2 echo "missing first parameter: path to the docker executable"
  exit ${no_dep_exit_code}
fi

# The entrypoint script the assertValidation* helpers drive.
check_env="bash /docker-entrypoint.d/00-check-for-required-env.sh"

# The settings banner. It needs the defaults 01-set-defaults.envsh computes, so
# that is sourced first, exactly as the real entrypoint does.
banner_snippet=". /docker-entrypoint.d/01-set-defaults.envsh && bash /docker-entrypoint.d/99-output-settings.sh"

baseline_extra_env=()
container_setup="true"

# Runs a shell snippet inside the gateway image with the baseline environment
# every entrypoint script needs, minus credentials and the signature version:
# AWS_SIGS_VERSION is required by 00-check-for-required-env.sh, but it is the
# variable these tests vary most, so each script supplies it per case or through
# ${baseline_extra_env}. Extra `docker run` arguments for the case under test are
# passed after the snippet. Echoes the combined output and returns the container
# exit code.
#
# --network none keeps the IMDS probe in the credential ladder from reaching
# 169.254.169.254: on a cloud CI runner it answers, which would satisfy the
# credential requirement and hide the checks under test.
#
# MSYS_NO_PATHCONV=1 added to resolve automatic path conversion
# https://github.com/docker/for-win/issues/6754#issuecomment-629702199
# runInImage <snippet> [extra docker run args...]
runInImage() {
  local snippet=$1
  shift

  # The ${array[@]+...} form keeps an empty array from tripping
  # `set -o nounset` on bash < 4.4 (macOS ships bash 3.2).
  MSYS_NO_PATHCONV=1 "${docker_cmd}" run --rm \
    --network none \
    -e S3_BUCKET_NAME=test-bucket \
    -e S3_SERVER=s3.example.com \
    -e S3_SERVER_PORT=9000 \
    -e S3_SERVER_PROTO=http \
    -e S3_REGION=us-east-1 \
    -e S3_STYLE=virtual-v2 \
    -e ALLOW_DIRECTORY_LIST=false \
    -e PROVIDE_INDEX_PAGE=false \
    -e APPEND_SLASH_FOR_POSSIBLE_DIRECTORY=false \
    -e CORS_ENABLED=false \
    ${baseline_extra_env[@]+"${baseline_extra_env[@]}"} \
    "$@" \
    --entrypoint /bin/sh nginx-s3-gateway -c "${snippet}" 2>&1
}

# Runs runInImage without aborting the test on a nonzero exit, leaving the
# combined output in ${output} and the container exit code in ${status}. Both
# are assigned without `local` on purpose: they are this function's return
# channel, and dynamic scoping lands them in the caller's own locals.
# _runInImageAllowingFailure <snippet> [extra docker run args...]
_runInImageAllowingFailure() {
  set +o errexit
  output=$(runInImage "$@")
  status=$?
  set -o errexit
}

# Prints the progress line that precedes every case.
# announceCase <message>
announceCase() {
  printf "  \033[36;1m▲\033[0m "
  echo "$1"
}

# Reports a failed case on stderr, one argument per line, and aborts the script.
# failCase <message...>
failCase() {
  local message
  for message in "$@"; do
    >&2 echo "${message}"
  done

  exit ${test_fail_exit_code}
}

# assertValidationAccepts <description> [extra docker run args...]
# A plain acceptance is the empty-fragment case of assertValidationAnnounces:
# `grep -F ''` matches any output.
assertValidationAccepts() {
  local description=$1
  shift

  _assertValidationAccepted "Entrypoint validation must accept ${description}" \
    "${description}" "" "$@"
}

# Accepts like assertValidationAccepts and additionally requires the credential
# ladder's announcement line, so a branch-ordering regression (e.g. the ECS
# check shadowing the AssumeRole announcement again) fails even though
# validation still passes.
# assertValidationAnnounces <description> <expected_output_fragment> [extra docker run args...]
assertValidationAnnounces() {
  local description=$1
  local expected_fragment=$2
  shift 2

  _assertValidationAccepted "Entrypoint validation must accept and announce ${description}" \
    "${description}" "${expected_fragment}" "$@"
}

# _assertValidationAccepted <progress_message> <description> <expected_fragment> [extra docker run args...]
_assertValidationAccepted() {
  local progress_message=$1
  local description=$2
  local expected_fragment=$3
  local output
  shift 3

  announceCase "${progress_message}"

  if ! output=$(runInImage "${container_setup} && ${check_env}" "$@"); then
    failCase "FAIL: 00-check-for-required-env.sh rejected ${description}:" "${output}"
  fi

  if ! echo "${output}" | grep -qF "${expected_fragment}"; then
    failCase "FAIL: expected the output to contain [${expected_fragment}] for ${description} but got:" \
      "${output}"
  fi
}

# assertValidationRejects <description> <expected_error_fragment> [extra docker run args...]
assertValidationRejects() {
  local description=$1
  local expected_error=$2
  shift 2

  _assertValidationRejected "${description}" "${expected_error}" "" "$@"
}

# Rejects like assertValidationRejects and additionally requires a fragment to
# be absent, so a rejection can be pinned to the guard that must fire rather
# than a guard that must stay silent for the same configuration.
# assertValidationRejectsWithout <description> <expected_error_fragment> <forbidden_fragment> [extra docker run args...]
assertValidationRejectsWithout() {
  local description=$1
  local expected_error=$2
  local forbidden_fragment=$3
  shift 3

  _assertValidationRejected "${description}" "${expected_error}" "${forbidden_fragment}" "$@"
}

# The forbidden fragment is optional: an empty one is skipped rather than
# matched, because `grep -F ''` matches every output.
# _assertValidationRejected <description> <expected_error_fragment> <forbidden_fragment> [extra docker run args...]
_assertValidationRejected() {
  local description=$1
  local expected_error=$2
  local forbidden_fragment=$3
  # Declared here so _runInImageAllowingFailure's assignments land in this
  # frame rather than in the sourcing script's globals.
  local output status
  shift 3

  announceCase "Entrypoint validation must reject ${description}"

  _runInImageAllowingFailure "${container_setup} && ${check_env}" "$@"

  if [ ${status} -eq 0 ]; then
    failCase "FAIL: 00-check-for-required-env.sh exited 0 for ${description}:" "${output}"
  fi

  if ! echo "${output}" | grep -qF "${expected_error}"; then
    failCase "FAIL: expected an error containing [${expected_error}] for ${description} but got:" \
      "${output}"
  fi

  if [ -n "${forbidden_fragment}" ] && echo "${output}" | grep -qF "${forbidden_fragment}"; then
    failCase "FAIL: expected the output NOT to contain [${forbidden_fragment}] for ${description} but got:" \
      "${output}"
  fi
}

# assertBannerContains <description> <expected_fragment> [extra docker run args...]
assertBannerContains() {
  local description=$1
  local expected_fragment=$2
  local output
  shift 2

  announceCase "Settings banner must report ${description}"

  if ! output=$(runInImage "${container_setup} && ${banner_snippet}" "$@"); then
    failCase "FAIL: 99-output-settings.sh failed for ${description}:" "${output}"
  fi

  if ! echo "${output}" | grep -qF "${expected_fragment}"; then
    failCase "FAIL: expected the banner to contain [${expected_fragment}] for ${description} but got:" \
      "${output}"
  fi
}

# The counterpart of assertBannerContains, for a value the banner must never
# print (a secret) rather than one it must report.
# assertBannerLacks <description> <forbidden_fragment> [extra docker run args...]
assertBannerLacks() {
  local description=$1
  local forbidden_fragment=$2
  local output
  shift 2

  announceCase "Settings banner must not report ${description}"

  if ! output=$(runInImage "${container_setup} && ${banner_snippet}" "$@"); then
    failCase "FAIL: 99-output-settings.sh failed for ${description}:" "${output}"
  fi

  if echo "${output}" | grep -qF "${forbidden_fragment}"; then
    failCase "FAIL: expected the banner NOT to contain [${forbidden_fragment}] for ${description} but got:" \
      "${output}"
  fi
}

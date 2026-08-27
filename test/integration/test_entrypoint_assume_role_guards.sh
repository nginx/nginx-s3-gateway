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

# Tests for the STS AssumeRole startup guards (GH-122): AWS_ROLE_ARN without a
# web identity token file selects AssumeRole mode, which requires the static
# credentials that sign the STS call and is incompatible with signature v2
# (AssumeRole always yields a session token, which v2 signatures cannot
# cover). Also asserts the settings banner reports the effective AssumeRole
# state.
#
# These only need the image, not the compose environment. Every container runs
# with --network none so that the IMDS probe in the credential ladder always
# fails: on a cloud CI runner 169.254.169.254 is reachable and would otherwise
# satisfy the credential requirement, hiding the checks under test.

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

test_role_arn="arn:aws:iam::000000000000:role/entrypoint-test"

# Runs a shell snippet inside the gateway image with the baseline environment
# every entrypoint script needs, minus credentials and the signature version.
# Extra `-e` arguments for the case under test are passed after the snippet.
# Echoes the combined output and returns the container exit code.
# MSYS_NO_PATHCONV=1 added to resolve automatic path conversion
# https://github.com/docker/for-win/issues/6754#issuecomment-629702199
runInImage() {
  snippet=$1
  shift

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
    "$@" \
    --entrypoint /bin/sh nginx-s3-gateway -c "${snippet}" 2>&1
}

check_env="bash /docker-entrypoint.d/00-check-for-required-env.sh"

# assertValidationAccepts <description> [extra docker -e args...]
assertValidationAccepts() {
  description=$1
  shift

  printf "  \033[36;1m▲\033[0m "
  echo "Entrypoint validation must accept ${description}"

  if ! output=$(runInImage "${check_env}" "$@"); then
    >&2 echo "FAIL: 00-check-for-required-env.sh rejected ${description}:"
    >&2 echo "${output}"
    exit ${test_fail_exit_code}
  fi
}

# assertValidationRejects <description> <expected_error_fragment> [extra docker -e args...]
assertValidationRejects() {
  description=$1
  expected_error=$2
  shift 2

  printf "  \033[36;1m▲\033[0m "
  echo "Entrypoint validation must reject ${description}"

  set +o errexit
  output=$(runInImage "${check_env}" "$@")
  status=$?
  set -o errexit

  if [ ${status} -eq 0 ]; then
    >&2 echo "FAIL: 00-check-for-required-env.sh exited 0 for ${description}:"
    >&2 echo "${output}"
    exit ${test_fail_exit_code}
  fi

  if ! echo "${output}" | grep -qF "${expected_error}"; then
    >&2 echo "FAIL: expected an error containing [${expected_error}] for ${description} but got:"
    >&2 echo "${output}"
    exit ${test_fail_exit_code}
  fi
}

# assertBannerContains <description> <expected_fragment> [extra docker -e args...]
# The banner script needs the defaults 01-set-defaults.envsh computes, so it
# is sourced first, exactly as the real entrypoint does.
assertBannerContains() {
  description=$1
  expected_fragment=$2
  shift 2

  printf "  \033[36;1m▲\033[0m "
  echo "Settings banner must report ${description}"

  banner=". /docker-entrypoint.d/01-set-defaults.envsh && bash /docker-entrypoint.d/99-output-settings.sh"
  if ! output=$(runInImage "${banner}" "$@"); then
    >&2 echo "FAIL: 99-output-settings.sh failed for ${description}:"
    >&2 echo "${output}"
    exit ${test_fail_exit_code}
  fi
  if ! echo "${output}" | grep -qF "${expected_fragment}"; then
    >&2 echo "FAIL: expected the banner to contain [${expected_fragment}] for ${description} but got:"
    >&2 echo "${output}"
    exit ${test_fail_exit_code}
  fi
}

assertValidationRejects "a role ARN without static credentials" \
  "Required AWS_ACCESS_KEY_ID (or AWS_ACCESS_KEY_ID_FILE) environment variable missing" \
  -e AWS_SIGS_VERSION=4 \
  -e AWS_ROLE_ARN="${test_role_arn}"

# A set-but-empty static credential must also count as missing: the njs
# modules read it as unconfigured and would fall through to the instance
# credential providers at request time, so accepting it would start a
# gateway in a different credential mode than the one just announced.
assertValidationRejects "a role ARN with an empty static access key" \
  "Required AWS_ACCESS_KEY_ID (or AWS_ACCESS_KEY_ID_FILE) environment variable missing" \
  -e AWS_SIGS_VERSION=4 \
  -e AWS_ROLE_ARN="${test_role_arn}" \
  -e AWS_ACCESS_KEY_ID= \
  -e AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY

assertValidationRejects "a role ARN with signature v2" \
  "AWS_ROLE_ARN cannot be used with AWS_SIGS_VERSION=2" \
  -e AWS_SIGS_VERSION=2 \
  -e AWS_ROLE_ARN="${test_role_arn}" \
  -e AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE \
  -e AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY

assertValidationAccepts "a role ARN with static credentials and signature v4" \
  -e AWS_SIGS_VERSION=4 \
  -e AWS_ROLE_ARN="${test_role_arn}" \
  -e AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE \
  -e AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY

# A set-but-empty role ARN must count as absent: a bare compose pass-through
# key of an unset host variable leaves the variable set but empty, and the
# njs modules treat that as no role at all.
assertValidationAccepts "an empty role ARN with static credentials" \
  -e AWS_SIGS_VERSION=4 \
  -e AWS_ROLE_ARN= \
  -e AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE \
  -e AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY

assertBannerContains "AssumeRole enabled with the role ARN" \
  "STS AssumeRole: enabled (${test_role_arn})" \
  -e AWS_SIGS_VERSION=4 \
  -e AWS_ROLE_ARN="${test_role_arn}" \
  -e AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE \
  -e AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY

assertBannerContains "AssumeRole disabled without a role ARN" \
  "STS AssumeRole: disabled" \
  -e AWS_SIGS_VERSION=4 \
  -e AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE \
  -e AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY

# The banner mirrors _isAssumeRoleMode in awscredentials.js: without static
# credentials the role ARN is ignored (njs uses the instance credential
# providers - e.g. an ECS credentials URI), so the banner must not claim the
# mode is active. The banner script does not validate, so this combination
# renders even though 00-check-for-required-env.sh would refuse to start
# without any credential provider configured.
assertBannerContains "AssumeRole disabled when static credentials are missing" \
  "STS AssumeRole: disabled" \
  -e AWS_SIGS_VERSION=4 \
  -e AWS_ROLE_ARN="${test_role_arn}"

echo "PASS: STS AssumeRole startup guards"

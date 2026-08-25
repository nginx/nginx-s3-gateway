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

# Tests for the AWS_SESSION_TOKEN x AWS_SIGS_VERSION=2 startup guard (GH-578
# corollary): the v2 signer covers no x-amz-* headers, so a session token is
# never part of the signature and S3 rejects every request. The entrypoint
# must fail fast on that combination instead of starting a gateway that 404s
# on every object.
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

session_token_path=/tmp/secrets/aws_session_token

write_token_file="mkdir -p /tmp/secrets \
  && printf 'FwoGZXIvYXdzEXAMPLETOKEN' > ${session_token_path}"

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

guard_error="cannot be used with AWS_SIGS_VERSION=2"

# assertValidationAccepts <description> [extra docker -e args...]
assertValidationAccepts() {
  description=$1
  shift

  printf "  \033[36;1m▲\033[0m "
  echo "Entrypoint validation must accept ${description}"

  if ! output=$(runInImage "${write_token_file} && ${check_env}" "$@"); then
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
  output=$(runInImage "${write_token_file} && ${check_env}" "$@")
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

assertValidationRejects "a session token with signature v2" \
  "${guard_error}" \
  -e AWS_SIGS_VERSION=2 \
  -e AWS_SESSION_TOKEN=FwoGZXIvYXdzEXAMPLETOKEN

assertValidationRejects "a file-backed session token with signature v2" \
  "${guard_error}" \
  -e AWS_SIGS_VERSION=2 \
  -e AWS_SESSION_TOKEN_FILE="${session_token_path}"

assertValidationAccepts "a session token with signature v4" \
  -e AWS_SIGS_VERSION=4 \
  -e AWS_SESSION_TOKEN=FwoGZXIvYXdzEXAMPLETOKEN

assertValidationAccepts "signature v2 with static credentials and no token" \
  -e AWS_SIGS_VERSION=2 \
  -e AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE \
  -e AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY

# A set-but-empty token must count as absent: an env-file line with no value
# or a compose pass-through of an unset host variable leaves the variable set
# but empty, and the njs modules treat that as no token at all.
assertValidationAccepts "signature v2 with static credentials and an empty session token" \
  -e AWS_SIGS_VERSION=2 \
  -e AWS_SESSION_TOKEN= \
  -e AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE \
  -e AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY

echo "PASS: signature v2 session token startup guard"

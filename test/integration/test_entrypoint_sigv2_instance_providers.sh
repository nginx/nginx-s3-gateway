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
# Tests for the instance credential provider x AWS_SIGS_VERSION=2 startup
# guard (GH-592): every instance credential provider (ECS container
# credentials, EC2 IMDS, EKS web identity and pod identity) issues temporary
# credentials, whose session token a v2 signature can never cover, so the
# only working v2 configuration is long-lived static credentials. The
# entrypoint must fail fast when signature v2 is combined with anything
# else instead of starting a gateway that fails every request.
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

access_key_id_path=/tmp/secrets/aws_access_key_id
secret_access_key_path=/tmp/secrets/aws_secret_access_key

write_credential_files="mkdir -p /tmp/secrets \
  && printf 'AKIAIOSFODNN7EXAMPLE' > ${access_key_id_path} \
  && printf 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY' > ${secret_access_key_path} \
  && chmod 0444 /tmp/secrets/*"

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

guard_error="AWS_SIGS_VERSION=2 requires static credentials"

# assertValidationAccepts <description> [extra docker -e args...]
assertValidationAccepts() {
  description=$1
  shift

  printf "  \033[36;1m▲\033[0m "
  echo "Entrypoint validation must accept ${description}"

  if ! output=$(runInImage "${write_credential_files} && ${check_env}" "$@"); then
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
  output=$(runInImage "${write_credential_files} && ${check_env}" "$@")
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

assertValidationRejects "ECS container credentials with signature v2" \
  "${guard_error}" \
  -e AWS_SIGS_VERSION=2 \
  -e AWS_CONTAINER_CREDENTIALS_RELATIVE_URI=/credentials

assertValidationRejects "a web identity token file with signature v2" \
  "${guard_error}" \
  -e AWS_SIGS_VERSION=2 \
  -e AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token

assertValidationRejects "an EKS pod identity token file with signature v2" \
  "${guard_error}" \
  -e AWS_SIGS_VERSION=2 \
  -e AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE=/var/run/secrets/pods.eks.amazonaws.com/serviceaccount/eks-pod-identity-token

# One-sided static credentials count as unconfigured: njs requires both
# halves of the pair and would fall through to the container credentials at
# request time.
assertValidationRejects "ECS container credentials with signature v2 and only an access key id" \
  "${guard_error}" \
  -e AWS_SIGS_VERSION=2 \
  -e AWS_CONTAINER_CREDENTIALS_RELATIVE_URI=/credentials \
  -e AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE

# Set-but-empty static credentials also count as unconfigured: an env-file
# line with no value or a compose pass-through of an unset host variable
# leaves the variable set but empty, and njs reads that as no credentials.
assertValidationRejects "ECS container credentials with signature v2 and empty static credentials" \
  "${guard_error}" \
  -e AWS_SIGS_VERSION=2 \
  -e AWS_CONTAINER_CREDENTIALS_RELATIVE_URI=/credentials \
  -e AWS_ACCESS_KEY_ID= \
  -e AWS_SECRET_ACCESS_KEY=

# With no credential source at all the missing-statics error fires too; the
# v2 guard must still appear so the operator learns an instance provider is
# not a remedy.
assertValidationRejects "signature v2 with no credential source at all" \
  "${guard_error}" \
  -e AWS_SIGS_VERSION=2

assertValidationAccepts "ECS container credentials with signature v4" \
  -e AWS_SIGS_VERSION=4 \
  -e AWS_CONTAINER_CREDENTIALS_RELATIVE_URI=/credentials

# Static credentials win over every instance provider in njs (environment
# credentials win, as in the AWS SDKs), so this configuration signs with the
# statics and works under v2. This pins the guard to the njs mode predicate
# rather than to the announcement ladder, whose ECS branch would match here.
assertValidationAccepts "signature v2 with static credentials alongside an ECS credentials URI" \
  -e AWS_SIGS_VERSION=2 \
  -e AWS_CONTAINER_CREDENTIALS_RELATIVE_URI=/credentials \
  -e AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE \
  -e AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY

assertValidationAccepts "signature v2 with file-backed static credentials alongside an ECS credentials URI" \
  -e AWS_SIGS_VERSION=2 \
  -e AWS_CONTAINER_CREDENTIALS_RELATIVE_URI=/credentials \
  -e AWS_ACCESS_KEY_ID_FILE="${access_key_id_path}" \
  -e AWS_SECRET_ACCESS_KEY_FILE="${secret_access_key_path}"

# The same statics-win precedence holds for the token-file providers: njs
# signs with the statics whenever both halves are configured, so these
# combinations work under v2 and the guard must stay keyed to the statics
# predicate, not to the presence of a token-file variable (which every
# reject case above happens to set).
assertValidationAccepts "signature v2 with static credentials alongside a web identity token file" \
  -e AWS_SIGS_VERSION=2 \
  -e AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token \
  -e AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE \
  -e AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY

assertValidationAccepts "signature v2 with static credentials alongside an EKS pod identity token file" \
  -e AWS_SIGS_VERSION=2 \
  -e AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE=/var/run/secrets/pods.eks.amazonaws.com/serviceaccount/eks-pod-identity-token \
  -e AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE \
  -e AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY

echo "PASS: signature v2 instance credential provider startup guard"

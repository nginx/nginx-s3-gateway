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

set -o nounset   # abort on unbound variable

# The shared runInImage and assertion helpers; also validates ${docker_cmd}.
. "$(dirname "${BASH_SOURCE[0]}")/entrypoint_test_lib.sh" "${docker_cmd}"

session_token_path=/tmp/secrets/aws_session_token

write_token_file="mkdir -p /tmp/secrets \
  && printf 'FwoGZXIvYXdzEXAMPLETOKEN' > ${session_token_path}"

# Only the file-backed cases read the token file, but writing it for every
# case costs nothing and keeps one setup snippet for the whole script.
container_setup="${write_token_file}"

guard_error="cannot be used with AWS_SIGS_VERSION=2"

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

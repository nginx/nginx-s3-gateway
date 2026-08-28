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

set -o nounset   # abort on unbound variable

# The shared runInImage and assertion helpers; also validates ${docker_cmd}.
. "$(dirname "${BASH_SOURCE[0]}")/entrypoint_test_lib.sh" "${docker_cmd}"

test_role_arn="arn:aws:iam::000000000000:role/entrypoint-test"

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

assertValidationAnnounces "a role ARN with static credentials and signature v4" \
  "fetching S3 credentials via STS AssumeRole" \
  -e AWS_SIGS_VERSION=4 \
  -e AWS_ROLE_ARN="${test_role_arn}" \
  -e AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE \
  -e AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY

# AssumeRole leads the njs provider ladder (environment credentials win, as
# in the AWS SDKs), so with a container credentials URI configured alongside
# a fully configured AssumeRole mode the announcement must name AssumeRole,
# not ECS - the settings banner already reports AssumeRole for this
# combination and the two lines must not contradict each other.
assertValidationAnnounces "a role ARN with static credentials inside an ECS task" \
  "fetching S3 credentials via STS AssumeRole" \
  -e AWS_SIGS_VERSION=4 \
  -e AWS_CONTAINER_CREDENTIALS_RELATIVE_URI=/credentials \
  -e AWS_ROLE_ARN="${test_role_arn}" \
  -e AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE \
  -e AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY

# Without static credentials AssumeRole mode is off (njs uses the container
# credentials), so the ECS branch must still win the announcement and the
# stray-ARN fail-fast below it must NOT fire.
assertValidationAnnounces "a stray role ARN inside an ECS task without static credentials" \
  "Running inside an ECS task, using container credentials" \
  -e AWS_SIGS_VERSION=4 \
  -e AWS_CONTAINER_CREDENTIALS_RELATIVE_URI=/credentials \
  -e AWS_ROLE_ARN="${test_role_arn}"

# The same tolerance applies to EKS pod identity: without static credentials
# njs ignores the stray ARN and serves via pod identity, so the pod identity
# branch must win the announcement and the stray-ARN fail-fast must NOT fire.
assertValidationAnnounces "a stray role ARN with EKS pod identity without static credentials" \
  "Running inside EKS with EKS pod identity" \
  -e AWS_SIGS_VERSION=4 \
  -e AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE=/var/run/secrets/pods.eks.amazonaws.com/serviceaccount/eks-pod-identity-token \
  -e AWS_ROLE_ARN="${test_role_arn}"

# The AssumeRole sigv2 guard must only fire when AssumeRole is actually
# active: a stray ARN without statics inside an ECS task leaves njs on the
# container credentials, so signature v2 validation must not blame a mode
# that is off. The configuration still fails - container credentials are
# temporary, which v2 signatures can never cover - but through the instance
# credential provider guard (GH-592), whose message names the actual problem.
assertValidationRejectsWithout "a stray role ARN with signature v2 inside an ECS task" \
  "AWS_SIGS_VERSION=2 requires static credentials" \
  "AWS_ROLE_ARN cannot be used with AWS_SIGS_VERSION=2" \
  -e AWS_SIGS_VERSION=2 \
  -e AWS_CONTAINER_CREDENTIALS_RELATIVE_URI=/credentials \
  -e AWS_ROLE_ARN="${test_role_arn}"

# The rejection must still announce the provider njs would actually use:
# validation collects every failure before exiting, so the ECS ladder branch
# has already named the effective mode by the time the #592 guard fires. A
# refactor that early-exits the guard ahead of the ladder, or a ladder
# reorder that lets the ambiguous stray-ARN branch shadow the ECS branch,
# would silently drop that diagnostic under v2 (the v4 twin above only pins
# the accepting path).
assertValidationRejects "a stray role ARN with signature v2 inside an ECS task (rejection still announces the ECS provider)" \
  "Running inside an ECS task, using container credentials" \
  -e AWS_SIGS_VERSION=2 \
  -e AWS_CONTAINER_CREDENTIALS_RELATIVE_URI=/credentials \
  -e AWS_ROLE_ARN="${test_role_arn}"

# The S3_SESSION_TOKEN deprecation is unconditional: a fully configured
# AssumeRole mode (or any other ladder branch) must not shadow it into a
# silent ignore.
assertValidationRejects "a deprecated S3_SESSION_TOKEN alongside AssumeRole" \
  "Deprecated the S3_SESSION_TOKEN!" \
  -e AWS_SIGS_VERSION=4 \
  -e S3_SESSION_TOKEN=deprecated-token \
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

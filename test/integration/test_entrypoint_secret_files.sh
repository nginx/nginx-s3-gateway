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

# Tests for the file-backed credential plumbing (GH-67): the validation that
# 00-check-for-required-env.sh applies to AWS_ACCESS_KEY_ID_FILE and its
# siblings, and the settings banner 99-output-settings.sh renders when the
# access key id came from a file.
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

# Writes the two credential secret files inside the container. The access key
# id file deliberately ends in a newline: a secret written by an editor or by
# `echo` does, and it must not survive into the credential value.
write_secrets="mkdir -p /tmp/secrets \
  && printf 'AKIAIOSFODNN7EXAMPLE\n' > ${access_key_id_path} \
  && printf 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY' > ${secret_access_key_path}"

# Runs a shell snippet inside the gateway image with the baseline environment
# every entrypoint script needs, minus any credentials. Extra `-e` arguments
# for the case under test are passed after the snippet. Echoes the combined
# output and returns the container exit code.
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
    -e AWS_SIGS_VERSION=4 \
    -e ALLOW_DIRECTORY_LIST=false \
    -e PROVIDE_INDEX_PAGE=false \
    -e APPEND_SLASH_FOR_POSSIBLE_DIRECTORY=false \
    -e CORS_ENABLED=false \
    "$@" \
    --entrypoint /bin/sh nginx-s3-gateway -c "${snippet}" 2>&1
}

check_env="bash /docker-entrypoint.d/00-check-for-required-env.sh"

# Whether this image runs the entrypoint as a different user than the NGINX
# workers - that is, whether there is a privilege boundary to test at all.
# The unprivileged image deletes the `user` directive from nginx.conf and runs
# as the worker user itself, so a file the entrypoint can create is by
# definition one the worker can reach. Mirrors the entrypoint's own logic.
image_drops_privileges() {
  MSYS_NO_PATHCONV=1 "${docker_cmd}" run --rm --network none \
    --entrypoint /bin/sh nginx-s3-gateway -c '
      worker="$(awk '"'"'$1 == "user" { sub(/;.*$/, "", $2); print $2; exit }'"'"' /etc/nginx/nginx.conf 2> /dev/null)"
      [ -n "${worker}" ] && [ "$(id -u)" -eq 0 ] && [ "${worker}" != "$(id -un)" ]' > /dev/null 2>&1
}

# uid:gid of the image's nginx user, for the case that runs the entrypoint as
# the worker user. Resolved from the image rather than hardcoded because the
# base image is free to renumber it.
docker_nginx_uid() {
  MSYS_NO_PATHCONV=1 "${docker_cmd}" run --rm --network none \
    --entrypoint /bin/sh nginx-s3-gateway -c 'id -u nginx; id -g nginx' | paste -sd:
}

# assertValidationAccepts <description> [extra docker -e args...]
assertValidationAccepts() {
  description=$1
  shift

  printf "  \033[36;1m▲\033[0m "
  echo "Entrypoint validation must accept ${description}"

  if ! output=$(runInImage "${write_secrets} && ${check_env}" "$@"); then
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
  output=$(runInImage "${write_secrets} && ${check_env}" "$@")
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

assertValidationAccepts "credentials supplied entirely by file" \
  -e AWS_ACCESS_KEY_ID_FILE="${access_key_id_path}" \
  -e AWS_SECRET_ACCESS_KEY_FILE="${secret_access_key_path}"

# A session token by file must select the same branch as the variable itself,
# which requires neither an access key nor IMDS.
assertValidationAccepts "a session token supplied by file" \
  -e AWS_SESSION_TOKEN_FILE="${access_key_id_path}"

# An env-file line with no value, or a compose pass-through of an unset shell
# variable, leaves the direct variable set but empty. The njs modules fall
# through to the file in that case, so validation must not reject it.
assertValidationAccepts "an empty access key alongside its file" \
  -e AWS_ACCESS_KEY_ID= \
  -e AWS_ACCESS_KEY_ID_FILE="${access_key_id_path}" \
  -e AWS_SECRET_ACCESS_KEY_FILE="${secret_access_key_path}"

assertValidationRejects "neither form of the access key" \
  "Required AWS_ACCESS_KEY_ID (or AWS_ACCESS_KEY_ID_FILE) environment variable missing" \
  -e AWS_SECRET_ACCESS_KEY_FILE="${secret_access_key_path}"

# Supplying both forms is ambiguous: the operator cannot tell which value the
# gateway will sign with, so fail rather than silently picking one.
assertValidationRejects "both the access key and its file" \
  "AWS_ACCESS_KEY_ID and AWS_ACCESS_KEY_ID_FILE are mutually exclusive" \
  -e AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE \
  -e AWS_ACCESS_KEY_ID_FILE="${access_key_id_path}" \
  -e AWS_SECRET_ACCESS_KEY_FILE="${secret_access_key_path}"

assertValidationRejects "an access key file that does not exist" \
  "AWS_ACCESS_KEY_ID_FILE does not refer to an existing regular file" \
  -e AWS_ACCESS_KEY_ID_FILE=/tmp/secrets/no_such_file \
  -e AWS_SECRET_ACCESS_KEY_FILE="${secret_access_key_path}"

assertValidationRejects "an empty access key file path" \
  "AWS_ACCESS_KEY_ID_FILE must not be empty when set" \
  -e AWS_ACCESS_KEY_ID_FILE=""

# A whitespace-only file yields an empty credential, which satisfies every
# check downstream and then fails at the S3 origin as an opaque 403.
printf "  \033[36;1m▲\033[0m "
echo "Entrypoint validation must reject a whitespace-only access key file"
set +o errexit
output=$(runInImage \
  "mkdir -p /tmp/secrets && printf '\n  \n' > ${access_key_id_path} \
   && printf 'secret' > ${secret_access_key_path} && ${check_env}" \
  -e AWS_ACCESS_KEY_ID_FILE="${access_key_id_path}" \
  -e AWS_SECRET_ACCESS_KEY_FILE="${secret_access_key_path}")
status=$?
set -o errexit
if [ ${status} -eq 0 ] || ! echo "${output}" | grep -qF "AWS_ACCESS_KEY_ID_FILE refers to an empty file"; then
  >&2 echo "FAIL: expected a whitespace-only access key file to be rejected but got:"
  >&2 echo "${output}"
  exit ${test_fail_exit_code}
fi

# Mode 0000 is deliberate rather than 0400: root bypasses DAC read checks, so a
# 0000 file is readable by root and not by anyone else. That makes this a
# regression test for probing as the worker user - a root `test -r` would
# accept it - and it works whichever user the entrypoint runs as, because a
# non-root owner is denied by its own empty owner bits.
printf "  \033[36;1m▲\033[0m "
echo "Entrypoint validation must reject an access key file the worker cannot read"
set +o errexit
output=$(runInImage \
  "${write_secrets} && chmod 0000 ${access_key_id_path} && ${check_env}" \
  -e AWS_ACCESS_KEY_ID_FILE="${access_key_id_path}" \
  -e AWS_SECRET_ACCESS_KEY_FILE="${secret_access_key_path}")
status=$?
set -o errexit
if [ ${status} -eq 0 ] || ! echo "${output}" | grep -qF "cannot read"; then
  >&2 echo "FAIL: expected an unreadable access key file to be rejected but got:"
  >&2 echo "${output}"
  exit ${test_fail_exit_code}
fi

# The worker also has to be able to traverse every parent directory, which a
# `test -r` on the file alone would not catch. This one needs a real privilege
# boundary: a directory its owner cannot traverse still stops the entrypoint
# from stat-ing the file at all, which is a different (also correct) error.
if image_drops_privileges; then
  printf "  \033[36;1m▲\033[0m "
  echo "Entrypoint validation must reject an access key file under a private directory"
  set +o errexit
  output=$(runInImage \
    "${write_secrets} && chmod 0700 /tmp/secrets && ${check_env}" \
    -e AWS_ACCESS_KEY_ID_FILE="${access_key_id_path}" \
    -e AWS_SECRET_ACCESS_KEY_FILE="${secret_access_key_path}")
  status=$?
  set -o errexit
  if [ ${status} -eq 0 ] || ! echo "${output}" | grep -qF "cannot read"; then
    >&2 echo "FAIL: expected an unreachable access key file to be rejected but got:"
    >&2 echo "${output}"
    exit ${test_fail_exit_code}
  fi
else
  printf "  \033[36;1m▲\033[0m "
  echo "Skipping the private-directory case: this image runs the entrypoint as the worker user"
fi

# The unprivileged image runs the entrypoint as the worker user itself, so the
# probe must fall back to a direct test rather than trying to drop privileges.
printf "  \033[36;1m▲\033[0m "
echo "Entrypoint validation must accept a worker-readable file when running unprivileged"
if ! output=$(runInImage "${write_secrets} && ${check_env}" \
  --user "$(docker_nginx_uid)" \
  -e AWS_ACCESS_KEY_ID_FILE="${access_key_id_path}" \
  -e AWS_SECRET_ACCESS_KEY_FILE="${secret_access_key_path}"); then
  >&2 echo "FAIL: 00-check-for-required-env.sh rejected a worker-readable file when run as the worker user:"
  >&2 echo "${output}"
  exit ${test_fail_exit_code}
fi

# The banner must report where the access key id came from rather than
# printing a blank line, and must never print the secret key.
printf "  \033[36;1m▲\033[0m "
echo "Settings banner must report the file the access key id was read from"
output=$(runInImage \
  "${write_secrets} \
   && . /docker-entrypoint.d/01-set-defaults.envsh \
   && sh /docker-entrypoint.d/99-output-settings.sh" \
  -e AWS_ACCESS_KEY_ID_FILE="${access_key_id_path}" \
  -e AWS_SECRET_ACCESS_KEY_FILE="${secret_access_key_path}")

if ! echo "${output}" | grep -qF "Access Key ID: (read from ${access_key_id_path})"; then
  >&2 echo "FAIL: expected the banner to name the access key id file but got:"
  >&2 echo "${output}"
  exit ${test_fail_exit_code}
fi

if echo "${output}" | grep -qF "wJalrXUtnFEMI"; then
  >&2 echo "FAIL: the settings banner leaked the secret access key:"
  >&2 echo "${output}"
  exit ${test_fail_exit_code}
fi

echo "PASS: file-backed credential validation and settings banner"

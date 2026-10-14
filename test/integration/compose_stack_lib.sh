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

# Shared helpers that drive the integration compose stack
# (test/docker-compose.yaml): the compose command detection, the compose
# wrapper with its NGINX Plus license lookup, the gateway readiness poll and
# the S3 origin seeding recipe. Sourced by test/run_integration_tests.sh (the
# suite) and test/run_gateway.sh (make test-run) so that what the latter
# stands up is exactly what the suite tests against - a copy per script would
# drift (GH-593 precedent for sourced test helpers).
#
# This file is sourced, never executed; it carries a shebang only because a
# dialect is what shellcheck needs to lint it (make lint globs
# test/integration/*.sh). Its inputs are passed as the sourcing arguments:
#
#   # shellcheck source=test/integration/compose_stack_lib.sh
#   . "${test_dir}/integration/compose_stack_lib.sh" \
#     "${docker_cmd}" "${DOCKER}" "${curl_cmd}" \
#     "${test_compose_config}" "${test_compose_project}" \
#     "${NGINX_TYPE}" "${gateway_listen_port}" \
#     "${test_server}" "${s3_origin_bucket}"
#
#   1  resolved path to the docker executable
#   2  the docker CLI name as the sourcer was given it (DOCKER): the legacy
#      docker-compose fallback below applies only to the stock docker CLI
#   3  resolved path to curl
#   4  compose file
#   5  compose project name (`make clean` tears down the same project)
#   6  NGINX flavor, oss or plus - plus triggers the license.jwt lookup
#   7  port nginx listens on inside the container (80, or 8080 for the
#      unprivileged image), which the compose file publishes as host 8989
#   8  gateway URL whose /health endpoint wait_for_gateway polls
#   9  origin bucket name, which also names the fixture dir test/data/<bucket>
#
# Contract with the sourcer:
#   - it defines p() and e() (progress and error output) before sourcing; the
#     helpers print through them, so the output stays the sourcer's
#   - it sources s3_client_lib.sh, which provides origin_client, before
#     calling seed_origin_data
#   - it puts the `# shellcheck source=` directive shown above on the sourcing
#     line when it reads a variable back from here (the suite's overlay
#     wrappers read docker_compose_cmd, because their env -u scrub cannot
#     invoke a shell function): shellcheck's SC2154 is warning-level and
#     fails make lint for a variable a script references but never assigns,
#     and the directive lets it follow this file - which is already in make
#     lint's file list, so no -x is needed - and see the assignment
#
# Names this file defines in the sourcer's namespace, besides the functions:
# the stack_* variables (private to this file), docker_compose_cmd (the one
# shared array, see above), the sourcing arguments re-assigned under the names
# the helpers used when they lived in the suite (docker_cmd, curl_cmd,
# test_compose_config, test_compose_project, s3_origin_bucket - so the sourcer
# sees the same value it passed in), and the NGINX_INTERNAL_PORT and
# NGINX_LICENSE_JWT exports the compose file interpolates. Function-level
# state is declared local. A sourcer must not reuse any of these names.

# Exit statuses, matching the sourcing scripts' own constants (the suite's
# test_fail_exit_code and no_dep_exit_code; run_gateway.sh's
# no_dep_exit_code). Defined here rather than read from the sourcer so that
# this file never references a name it does not assign, and because
# run_gateway.sh, which runs no tests, has no test-failure code of its own.
stack_test_fail_exit_code=2
stack_no_dep_exit_code=3
stack_build_dep_exit_code=4

# `${N-}` rather than `$N`: the sourcers run under nounset, and a bare `$9`
# would abort with "unbound variable" before the check below could name the
# missing parameter.
docker_cmd=${1-}
stack_docker_cli_name=${2-}
curl_cmd=${3-}
test_compose_config=${4-}
test_compose_project=${5-}
stack_nginx_type=${6-}
stack_nginx_internal_port=${7-}
stack_gateway_url=${8-}
s3_origin_bucket=${9-}

if [ -z "${docker_cmd}" ] || [ -z "${stack_docker_cli_name}" ] || [ -z "${curl_cmd}" ] || \
   [ -z "${test_compose_config}" ] || [ -z "${test_compose_project}" ] || \
   [ -z "${stack_nginx_type}" ] || [ -z "${stack_nginx_internal_port}" ] || \
   [ -z "${stack_gateway_url}" ] || [ -z "${s3_origin_bucket}" ]; then
  >&2 echo "missing sourcing parameter(s): docker path, docker CLI name, curl path, compose file, compose project, NGINX type, NGINX internal port, gateway URL and origin bucket"
  exit "${stack_no_dep_exit_code}"
fi

if ! declare -F p > /dev/null || ! declare -F e > /dev/null; then
  >&2 echo "compose_stack_lib.sh: the sourcing script must define p() and e() before sourcing it"
  exit "${stack_no_dep_exit_code}"
fi

# Only the directory this file lives under is resolved through cd/pwd (it
# cannot be missing while the file is being sourced); the fixture and
# repository paths are derived from it by concatenation and checked
# explicitly, because a failed `$( cd ... && pwd )` inside an assignment
# trips the sourcers' errexit with no message at all. The resolved form keeps
# the paths echoed below byte-identical to the ones the suite computed when
# these helpers lived there.
stack_test_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." >/dev/null 2>&1 && pwd )"
stack_data_dir="${stack_test_dir}/data"
stack_repo_dir="$( cd "${stack_test_dir}/.." >/dev/null 2>&1 && pwd )"

# test/data sits under the root .gitignore's blanket `data/` rule and is only
# present because the fixtures were force-added, so a tree exported or
# cleaned without it is a realistic state worth a clear message.
if [ ! -d "${stack_data_dir}/${s3_origin_bucket}" ]; then
  e "origin fixture directory not found: ${stack_data_dir}/${s3_origin_bucket}"
  exit "${stack_no_dep_exit_code}"
fi

stack_is_windows="0"
if [ "${OS:-}" == "Windows_NT" ]; then
  stack_is_windows="1"
elif command -v uname > /dev/null && [[ "$(uname -s)" == *"_NT-"* ]]; then
  stack_is_windows="1"
fi

# An array so that a docker path containing spaces (e.g. Git Bash resolving
# to '/c/Program Files/Docker/.../docker') survives expansion intact. The
# legacy docker-compose fallback only applies to the stock docker CLI: with a
# DOCKER override (e.g. podman) it would silently drive the compose stack
# with a different engine than the rest of the suite.
if "${docker_cmd}" compose version > /dev/null 2>&1; then
  docker_compose_cmd=("${docker_cmd}" compose)
elif [ "${stack_docker_cli_name}" == "docker" ] && command -v docker-compose > /dev/null; then
  docker_compose_cmd=(docker-compose)
else
  e "required dependency not found: ${stack_docker_cli_name} compose (or docker-compose) not found in the path or not executable"
  exit "${stack_no_dep_exit_code}"
fi
e "Using Docker Compose command: ${docker_compose_cmd[*]}"

# The NGINX Plus license is resolved once here rather than on every compose
# call: a missing license then aborts before anything is created, and the
# teardown's own compose call - made from a sourcer's exit trap - can no
# longer re-trigger the abort. An `exit` inside a function escapes the
# `|| true` those traps wrap the teardown in, which cut the cleanup short
# and printed the error twice.
stack_license_jwt=""
if [ "${stack_nginx_type}" == "plus" ]; then
  if [ -f /etc/nginx/license.jwt ]; then
    stack_license_jwt="$(cat /etc/nginx/license.jwt)"
  elif [ -f "${stack_repo_dir}/license.jwt" ]; then
    stack_license_jwt="$(cat "${stack_repo_dir}/license.jwt")"
  else
    e "NGINX Plus license file not found: /etc/nginx/license.jwt or ${stack_repo_dir}/license.jwt"
    exit "${stack_build_dep_exit_code}"
  fi
fi

# Blocks until the gateway answers an HTTP request, replacing the external
# wait-for-it dependency.
#
# Two problems with the previous arrangement. wait-for-it was an optional
# tool, so on a host that lacked it these waits silently became no-ops. And
# even where it was installed it only proved the *published* port was open:
# docker binds the host side of a port mapping as soon as the container
# starts, so a TCP connect succeeds while nginx inside is still booting. The
# downstream suites each carry their own 2s/4s/6s backoff loop to absorb that
# gap, and it fired on nearly every configuration change - 13 times in a
# representative CI run, all of it pure sleep.
#
# Polling the gateway closes the gap for real: curl reports 000 until nginx
# accepts and answers, so this returns only once a request would actually
# succeed, and the downstream backoffs stop firing. The probe targets /health,
# which nginx answers itself (`return 200`, nothing proxied), so it neither
# fetches credentials nor warms the proxy cache - a HEAD on / did both, which
# forced callers to seed before polling (a pre-seed miss on index.html would
# be cached as a 404) and spent the single credential fetch the assume-role
# phase counts. Any answer counts as ready: the probe proves that nginx is
# up, not that the origin is.
#
# The limit is wall-clock time rather than a probe count: against a listener
# that accepts but never answers, each probe blocks for its --max-time, and
# 75 such probes would hide a near three-minute wait behind a "15s" message.
#
# Exits non-zero on timeout so callers abort under errexit rather than
# proceeding against a gateway that never came up.
stack_gateway_wait_timeout=15
wait_for_gateway() {
  local deadline=$((SECONDS + stack_gateway_wait_timeout))
  local gateway_status
  while (( SECONDS < deadline )); do
    # `|| true` because curl exits non-zero (while still printing 000) until
    # the gateway answers, which errexit would otherwise treat as fatal.
    gateway_status="$("${curl_cmd}" -s -o /dev/null -w '%{http_code}' \
      --head --max-time 2 "${stack_gateway_url}/health" || true)"
    if [ "${gateway_status}" != "000" ]; then
      return 0
    fi
    sleep 0.2
  done
  e "timed out after ${stack_gateway_wait_timeout}s waiting for the gateway at ${stack_gateway_url}/health"
  return 1
}

prepare_compose_env() {
  # Hint to docker-compose the internal port to map for the container
  export NGINX_INTERNAL_PORT="${stack_nginx_internal_port}"
  export NGINX_LICENSE_JWT="${stack_license_jwt}"
}

compose() {
  prepare_compose_env

  "${docker_compose_cmd[@]}" -f "${test_compose_config}" -p "${test_compose_project}" "$@"
}

write_special_character_fixture() {
  # Write problematic files to disk if we are not on Windows. Originally,
  # these files were checked in, but that prevented the git repository from
  # being cloned on Windows machines.
  if [ "${stack_is_windows}" == "0" ]; then
    echo "Writing weird filename: ${stack_data_dir}/${s3_origin_bucket}/a/%@!*()=\$#^&|.txt"
    echo 'We are but selling water next to a river.' > "${stack_data_dir}/${s3_origin_bucket}"'/a/%@!*()=$#^&|.txt'
  fi
}

# Waits for the origin at the given endpoint, then (re)creates the bucket and
# uploads the fixtures. The endpoint is an argument because the suite re-points
# it between its HTTP and HTTPS phases.
# seed_origin_data <origin endpoint url>
seed_origin_data() {
  local origin_endpoint=$1
  local origin_is_up iam_is_up iam_probe_error i

  # Hit the origin's health check end point to see if it has started up.
  # This is the only readiness gate for phases that start the origin alone
  # (integration_test_assume_role's `up -d rustfs` returns before the
  # healthcheck passes, unlike the full `up -d`, where the gateway's
  # depends_on blocks on it), so fail with a clear message rather than
  # falling through to client commands that would abort the suite with an
  # opaque connectivity error.
  origin_is_up=""
  for (( i=1; i<=15; i++ ))
  do
    echo "Querying the S3 origin to see if it is ready"
    # `|| true` keeps errexit from aborting the retry loop when the origin is
    # not listening yet (curl exits 7 on connection refused but still prints
    # 000).
    origin_is_up="$("${curl_cmd}" --insecure -s -o /dev/null -w '%{http_code}' "${origin_endpoint}"/health || true)"
    if [ "${origin_is_up}" = "200" ]; then
      break
    else
      sleep 2
    fi
  done
  if [ "${origin_is_up}" != "200" ]; then
    e "the S3 origin at ${origin_endpoint} did not become ready (last health status: ${origin_is_up})"
    exit "${stack_test_fail_exit_code}"
  fi

  # RustFS's IAM subsystem can lag /health right after a stack recreation
  # (authenticated calls are rejected with "waiting for iam"), so also gate
  # on an authenticated API call. list-buckets is used because it succeeds
  # for the root user whether or not the bucket exists yet. The probe's
  # stderr is kept (2>&1 before the stdout redirect captures only stderr) and
  # printed on exhaustion: an InvalidAccessKeyId from drifted credentials
  # would otherwise be indistinguishable from the IAM lag this loop absorbs.
  iam_is_up=""
  iam_probe_error=""
  for (( i=1; i<=15; i++ ))
  do
    echo "Querying the S3 origin API to see if it accepts authenticated requests"
    if iam_probe_error="$(origin_client s3api list-buckets 2>&1 > /dev/null)"; then
      iam_is_up="1"
      break
    else
      sleep 2
    fi
  done
  if [ "${iam_is_up}" != "1" ]; then
    e "the S3 origin at ${origin_endpoint} did not accept an authenticated request"
    e "last error from the S3 client: ${iam_probe_error}"
    exit "${stack_test_fail_exit_code}"
  fi

  p "Adding test data to container"
  # A bucket left behind by an aborted previous run (compose containers
  # survive a failed teardown) must not fail the seeding step under errexit
  # (the equivalent of the previous S3 client's ignore-existing bucket
  # creation), so a create-bucket failure falls back to a head-bucket probe:
  # it succeeds when the failure was BucketAlreadyOwnedByYou and keeps a
  # genuine failure loud - head-bucket's stderr is not discarded and errexit
  # aborts on it. Probe-then-create would instead abort the suite when a
  # transient probe failure sent an existing bucket into create-bucket.
  if ! origin_client s3api create-bucket --bucket "${s3_origin_bucket}" > /dev/null 2>&1; then
    origin_client s3api head-bucket --bucket "${s3_origin_bucket}" > /dev/null
  fi
  echo "Copying contents of ${stack_data_dir}/${s3_origin_bucket} to the S3 origin"
  # --no-progress keeps the transfer meter out of CI logs but still prints
  # one upload line per object. The --exclude patterns keep hidden files
  # (.DS_Store, editor swap files - invisible to git because test/data is
  # blanket-gitignored) out of the bucket the way the dotfile-skipping glob
  # this replaced did: the directory-listing legs assert an exact object
  # population, and a stray dotfile would shift every pagination page.
  origin_client s3 cp --recursive --no-progress \
    --exclude ".*" --exclude "*/.*" \
    "${stack_data_dir}/${s3_origin_bucket}" "s3://${s3_origin_bucket}"
  # RustFS declares VOLUME /data, so `docker diff` (which the seeding step
  # once printed here) would show nothing; list the seeded objects instead.
  echo "Seeded bucket contents:"
  origin_client s3 ls --recursive "s3://${s3_origin_bucket}"
}

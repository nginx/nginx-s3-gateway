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

# Verifies that a built gateway image actually ships the nginx release it is
# meant to, by interrogating the image itself rather than its build inputs.
# Invoked by the GNUmakefile (make verify-image) and by the publish workflow
# against the pushed digests.
#
# The checks exist because the version in a Dockerfile's FROM line is not the
# version that ends up in the image: the OSS build installs module packages
# from apt (whose exact-version dependency can move the nginx binary), the
# Plus build overlays a second image onto the base, and the latest-njs
# variant overwrites the njs module and CLI with files built from source. The
# image's NGINX_VERSION environment variable is inherited from the base and
# never updated, so it is deliberately not consulted. What is checked:
#
#   1. the version the nginx binary reports, against the expected release;
#   2. the installed nginx package version, which must agree with the binary;
#   3. the njs module loads into that binary and the njs CLI runs (`nginx -t`
#      on the image's own nginx.conf, which loads both dynamic modules);
#   4. the request-path map in the rendered default.conf binds the path
#      remainder to its named capture, and no positional capture appears
#      anywhere in the rendered gateway configuration.
#
# The rendering in (3) and (4) runs the entrypoint's defaults and template
# scripts with a baseline environment; nothing is contacted over the network
# (the container runs with --network none and a placeholder resolver).
#
# Usage: verify_image.sh <image-ref> <oss|plus> <expected> [platform]
#
#   image-ref   image tag or digest reference to verify
#   oss|plus    which version scheme to check against:
#                 oss  - the release is the nginx version (e.g. 1.31.7); the
#                        binary must report it and the nginx package version
#                        must be <release>-<revision>
#                 plus - the release is the nginx-plus package release (e.g.
#                        37.0.7); the binary must report
#                        "(nginx-plus-r<release>)" and the nginx-plus package
#                        version must be <release>-<revision>
#   expected    either the release itself, or the path of the Dockerfile
#               whose pin declares it (the FROM tag for Dockerfile.oss, the
#               release asserted in the RUN step for Dockerfile.plus), so
#               that the check and the pin cannot drift apart
#   platform    optional docker --platform value (e.g. linux/arm64), for
#               verifying one architecture of a multi-arch reference; the
#               image must already be pullable
#
# Environment:
#   DOCKER      docker CLI to use (default: docker)
#
# For plus, `nginx -t` refuses to run without a license. The license is
# resolved by test/plus_license_lib.sh (the same lookup the integration
# harness uses) and handed to the base image's own 40-env-to-license.sh
# through NGINX_LICENSE_JWT; it is never contacted.

set -o errexit
set -o nounset
set -o pipefail

DOCKER="${DOCKER:-docker}"
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

image_ref="${1:-}"
flavor="${2:-}"
expected="${3:-}"
platform="${4:-}"

usage_exit_code=2
verify_fail_exit_code=3

if [ -z "${image_ref}" ] || [ -z "${flavor}" ] || [ -z "${expected}" ]; then
  >&2 echo "usage: $0 <image-ref> <oss|plus> <expected-release|Dockerfile> [platform]"
  exit ${usage_exit_code}
fi

case "${flavor}" in
  oss | plus) ;;
  *)
    >&2 echo "unknown flavor '${flavor}' - must be oss or plus"
    exit ${usage_exit_code}
    ;;
esac

# Resolve the expected release from a Dockerfile pin when a path was given.
if [ -f "${expected}" ]; then
  dockerfile="${expected}"
  case "${flavor}" in
    oss) expected_version="$(sed -n 's/^FROM nginx:\([0-9.]*\)@.*/\1/p' "${dockerfile}")" ;;
    plus) expected_version="$(sed -n 's/.*grep -F "(nginx-plus-r\([0-9.]*\))".*/\1/p' "${dockerfile}")" ;;
  esac
  if [ -z "${expected_version}" ]; then
    >&2 echo "could not read the expected ${flavor} release from the pin in ${dockerfile}"
    exit ${usage_exit_code}
  fi
else
  expected_version="${expected}"
fi

p() {
  printf "\033[34;1m▶\033[0m "
  echo "$1"
}

fail() {
  >&2 echo "FAIL: $1"
  shift
  for line in "$@"; do
    >&2 echo "      ${line}"
  done
  exit ${verify_fail_exit_code}
}

platform_args=()
if [ -n "${platform}" ]; then
  platform_args=(--platform "${platform}")
fi

license_args=()
license_snippet="true"
if [ "${flavor}" = "plus" ]; then
  # shellcheck source=test/plus_license_lib.sh
  . "${script_dir}/plus_license_lib.sh"
  if ! resolvePlusLicenseInto; then
    >&2 echo "${plus_license_not_found_message}"
    exit ${usage_exit_code}
  fi
  license_args=(-e "NGINX_LICENSE_JWT=${plus_license_jwt}")
  license_snippet="/docker-entrypoint.d/40-env-to-license.sh > /dev/null"
fi

# Runs a shell snippet in the image with the gateway's required environment
# and no network. The baseline mirrors test/integration/entrypoint_test_lib.sh.
# MSYS_NO_PATHCONV=1 added to resolve automatic path conversion
# https://github.com/docker/for-win/issues/6754#issuecomment-629702199
runInImage() {
  MSYS_NO_PATHCONV=1 "${DOCKER}" run --rm \
    --network none \
    "${platform_args[@]+"${platform_args[@]}"}" \
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
    -e AWS_ACCESS_KEY_ID=verify \
    -e AWS_SECRET_ACCESS_KEY=verify \
    -e AWS_SIGS_VERSION=4 \
    -e DNS_RESOLVERS=127.0.0.1 \
    -e STRIP_LEADING_DIRECTORY_PATH=/verify \
    -e PREFIX_LEADING_DIRECTORY_PATH=/verified \
    "${license_args[@]+"${license_args[@]}"}" \
    --entrypoint /bin/sh "${image_ref}" -c "$1" 2>&1
}

p "Verifying ${image_ref}${platform:+ (${platform})} as ${flavor} ${expected_version}"

# 1. The binary. Each probe keeps its combined output on failure: a docker
# daemon that is unreachable, a --platform the host cannot execute, or a
# missing dpkg-query would otherwise exit through errexit with nothing but
# make's "Error N" to go on.
binary_version="$(runInImage 'nginx -v')" \
  || fail "could not run nginx -v in the image:" "${binary_version}"
case "${flavor}" in
  oss) expected_banner="nginx version: nginx/${expected_version}" ;;
  plus) expected_banner="(nginx-plus-r${expected_version})" ;;
esac
if [[ ${binary_version} != *"${expected_banner}"* ]]; then
  fail "nginx binary does not report the expected release" \
    "expected: [${expected_banner}]" \
    "actual:   [${binary_version}]"
fi
echo "  binary:  ${binary_version}"

# 2. The package database must agree with the binary, so that a later apt or
# overlay step cannot have replaced one without the other.
case "${flavor}" in
  oss) package_name="nginx" ;;
  plus) package_name="nginx-plus" ;;
esac
package_version="$(runInImage "dpkg-query -W -f '\${Version}' ${package_name}")" \
  || fail "could not query the ${package_name} package in the image:" "${package_version}"
if [[ ${package_version} != "${expected_version}-"* ]]; then
  fail "${package_name} package version does not match the expected release" \
    "expected: [${expected_version}-<revision>]" \
    "actual:   [${package_version}]"
fi
echo "  package: ${package_name} ${package_version}"

# 3./4. Render the configuration the way the entrypoint does, then check that
# nginx accepts it (which loads the njs and xslt modules into this binary),
# that the njs CLI runs, and that the rendered configuration keeps its
# capture discipline.
render_output="$(runInImage "
  . /docker-entrypoint.d/01-set-defaults.envsh \
  && /docker-entrypoint.d/20-envsubst-on-templates.sh > /dev/null \
  && ${license_snippet} \
  && nginx -t 2>&1 \
  && njs -v > /dev/null \
  && echo '---rendered---' \
  && find /etc/nginx/conf.d -name '*.conf' -exec grep -hv '^[[:space:]]*#' {} +
")" || fail "rendering or nginx -t failed in the image:" "${render_output}"

rendered="${render_output#*---rendered---$'\n'}"

if ! echo "${rendered}" | grep -qF '(?<s3gw_path_after_strip>.*)'; then
  fail "the rendered request-path map does not bind the path remainder to the named capture"
fi
declarations="$(echo "${rendered}" | grep -cF '(?<s3gw_path_after_strip>' || true)"
if [ "${declarations}" -ne 1 ]; then
  fail "expected exactly one declaration of the named capture, found ${declarations}"
fi
references_elsewhere="$(echo "${rendered}" | grep -E '\$\{?s3gw_path_after_strip\b' | grep -vF '(?<s3gw_path_after_strip>' || true)"
if [ -n "${references_elsewhere}" ]; then
  fail "the named capture is referenced outside the map that declares it:" "${references_elsewhere}"
fi
positional="$(echo "${rendered}" | grep -E '\$[1-9]' || true)"
if [ -n "${positional}" ]; then
  fail "the rendered gateway configuration contains positional captures:" "${positional}"
fi
echo "  config:  nginx -t ok, modules load, capture scoped"

echo "PASS: ${image_ref}${platform:+ (${platform})} ships ${flavor} ${expected_version}"

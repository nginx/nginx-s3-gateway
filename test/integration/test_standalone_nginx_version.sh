#!/usr/bin/env bash

# Copyright 2026 F5, Inc.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/entrypoint_test_lib.sh" "$1"
installer="$(dirname "${BASH_SOURCE[0]}")/../../standalone_ubuntu_oss_install.sh"
version_block=$(sed -n '/^# --- predicate routing version check BEGIN ---$/,/^# --- predicate routing version check END ---$/p' "${installer}")
if [ -z "${version_block}" ]; then
  failCase "FAIL: standalone version check is missing"
fi

# Containers copy the template tree automatically, but standalone explicitly
# downloads each file. Check the whole OSS manifest, including both signature
# versions; rendered nginx -t in the integration suite checks their includes.
repo_dir="$(dirname "${installer}")"
download_lines=$(grep '^download ' "${installer}")
templates_downloaded() {
  local lines=$1 template relative destination
  for template in "${repo_dir}"/common/etc/nginx/templates/*.template \
    "${repo_dir}"/common/etc/nginx/templates/gateway/*.template \
    "${repo_dir}"/oss/etc/nginx/templates/*.template \
    "${repo_dir}"/oss/etc/nginx/templates/gateway/*.template; do
    relative=${template#"${repo_dir}/"}
    destination=/${relative#*/}
    if ! grep -qFx "download \"${relative}\" \"${destination}\"" <<< "${lines}"; then
      return 1
    fi
  done
}
if ! templates_downloaded "${download_lines}"; then
  failCase "FAIL: standalone download list omits a gateway template or has the wrong destination"
fi
without_preflight=$(grep -v '/cors_preflight.conf.template' <<< "${download_lines}")
if templates_downloaded "${without_preflight}"; then
  failCase "FAIL: template manifest check missed a removed preflight download"
fi

# Guard the placement as well as the extracted behavior: an old installation
# must fail before the installer replaces even /etc/nginx/environment.
if ! awk '
  /^# --- predicate routing version check END ---$/ { checked=1 }
  /cat > "\/etc\/nginx\/environment"/ { if (!checked) exit 1; found=1 }
  END { if (!found) exit 1 }
' "${installer}"; then
  failCase "FAIL: standalone version check must precede configuration replacement"
fi

# Run the actual installer block in the image (real dpkg numeric comparison),
# mocking only commands that would install packages or operate on the host.
# Event markers make install -> check -> stop -> configure ordering observable.
snippet='
set -eu
nginx() { printf "%s\n" "$TEST_NGINX_BANNER" >&2; return "$TEST_NGINX_STATUS"; }
apt-get() { echo EVENT_INSTALL; }
systemctl() { echo EVENT_STOP; }
to_install=$TEST_INSTALL_PACKAGES
eval "$TEST_VERSION_BLOCK"
echo EVENT_CONFIGURE
'

check_version() {
  local banner=$1 expected=$2 packages=$3 nginx_status=${4:-0} output status=0
  output=$(runInImage 'bash -c "$TEST_VERSION_SNIPPET"' \
    -e "TEST_VERSION_SNIPPET=${snippet}" \
    -e "TEST_VERSION_BLOCK=${version_block}" -e "TEST_NGINX_BANNER=${banner}" \
    -e "TEST_NGINX_STATUS=${nginx_status}" -e "TEST_INSTALL_PACKAGES=${packages}") || status=$?
  if [ "${expected}" = reject ]; then
    if [ "${status}" = 0 ] || ! grep -qF 'requires NGINX 1.31.6' <<< "${output}" \
      || grep -qE 'EVENT_STOP|EVENT_CONFIGURE' <<< "${output}"; then
      failCase "FAIL: unsafe standalone rejection for [${banner}]:" "${output}"
    fi
  else
    if [ "${status}" != 0 ] || ! grep -qF EVENT_CONFIGURE <<< "${output}"; then
      failCase "FAIL: standalone rejected [${banner}]:" "${output}"
    fi
    if [ -n "${packages}" ] && [ "$(grep '^EVENT_' <<< "${output}")" != $'EVENT_INSTALL\nEVENT_STOP\nEVENT_CONFIGURE' ]; then
      failCase "FAIL: standalone install/check/stop ordering changed:" "${output}"
    fi
  fi
}

for packages in "" "nginx nginx-module-njs nginx-module-xslt"; do
  for version in 1.29.8 1.31.5; do
    check_version "nginx version: nginx/${version}" reject "${packages}"
  done
  for version in 1.31.6 1.31.10 1.32.0 2.0.0; do
    check_version "nginx version: nginx/${version}" accept "${packages}"
  done
  check_version "nginx version: nginx/unknown" reject "${packages}"
  check_version "nginx version: nginx/1.31.6 (nginx-plus-r37.2.0)" accept "${packages}"
  check_version "nginx version: nginx/1.31.5 (custom build)" reject "${packages}"
  check_version "nginx version: nginx/1.31.6junk" reject "${packages}"
  check_version "nginx version: nginx/1.31.6.1" reject "${packages}"
  check_version "nginx version: nginx/1.31.6" reject "${packages}" 1
done

echo "  Standalone NGINX version tests passed"

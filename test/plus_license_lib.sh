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

# The one place the NGINX Plus license is looked up on the host, so that every
# script that hands it to a container agrees on where it comes from. Sourced
# by test/integration/compose_stack_lib.sh (the compose stack), by
# test/verify_image.sh and by test/integration/test_entrypoint_prefix_normalization.sh
# (both start containers directly, outside compose). This file is sourced,
# never executed; it carries a shebang only because a dialect is what the
# linter needs (make lint globs test/*.sh).
#
# Lookup order: /etc/nginx/license.jwt, then license.jwt at the repository
# root. Nothing contacts the license endpoint; the token is only placed where
# nginx -t expects it, by the base image's own 40-env-to-license.sh.

# Resolves the license into plus_license_jwt and sets
# plus_license_not_found_message to the matching diagnostic. Returns nonzero
# (and leaves the token empty) when neither location holds a file, or when
# the file that was found cannot be read - a root-only license.jwt is a
# realistic state on a shared host, and a silently empty token would let the
# compose stack start and fail later with a misleading "license expired"
# style error instead of aborting before anything is created. The caller
# decides how to report the failure, since the suite, the verifier and the
# entrypoint test each abort with their own exit code and message style.
#
# Callers invoke this inside `if ! resolvePlusLicenseInto`, which disables
# errexit for the function body, so every command that can fail is checked
# explicitly. The result travels through a variable rather than stdout so a
# command substitution cannot alter the token (the convention matches
# gateway_env_lib.sh's lowercaseValueInto).
#
# resolvePlusLicenseInto
plus_license_jwt=""
plus_license_not_found_message=""
plus_license_repo_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." >/dev/null 2>&1 && pwd )"
resolvePlusLicenseInto() {
  local license_file
  plus_license_jwt=""
  plus_license_not_found_message=""

  if [ -f /etc/nginx/license.jwt ]; then
    license_file=/etc/nginx/license.jwt
  elif [ -f "${plus_license_repo_dir}/license.jwt" ]; then
    license_file="${plus_license_repo_dir}/license.jwt"
  else
    plus_license_not_found_message="NGINX Plus license file not found: /etc/nginx/license.jwt or ${plus_license_repo_dir}/license.jwt"
    return 1
  fi

  if ! plus_license_jwt="$(cat "${license_file}")" || [ -z "${plus_license_jwt}" ]; then
    plus_license_jwt=""
    plus_license_not_found_message="NGINX Plus license file ${license_file} exists but is empty or cannot be read by $(id -un)"
    return 1
  fi
  return 0
}

#!/bin/sh

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

# Shared helpers for the gateway's entrypoint scripts, sourced as
# /etc/nginx/gateway_env_lib.sh (COPY common/etc /etc in the Dockerfiles).
#
# This file is sourced, never executed; it carries a shebang only because a
# dialect is what shellcheck needs to lint it. It deliberately does not live
# in common/docker-entrypoint.d/, where the base image's entrypoint would
# execute it as a no-op script. It must stay strictly POSIX sh: consumers
# range from the entrypoint's dash shell (01-set-defaults.envsh under
# `set -eu`) to bash (00-check-for-required-env.sh and the standalone
# installer).
#
# standalone_ubuntu_oss_install.sh cannot source this file (it is a single
# self-contained download), so it carries a byte-identical copy of the marked
# region below. `make lint` diffs the two regions (envlib-sync-check); edit
# both together.
#
# The boolean grammar is shared with utils.js#parseBoolean, whose table the
# unit tests and test_entrypoint_boolean_validation.sh pin against this one:
# true spellings are `true`, `yes`, `1`; false spellings are `false`, `no`,
# `0`; each in any letter case. Anything else is an unrecognized spelling -
# validateBooleanVar rejects it, while the parse functions fall back the way
# their callers historically did (parseBoolean to 0, parseBooleanTristate to
# the empty string).

# --- gateway_env_lib functions BEGIN ---
# Prints $1 lowercased (boolean spellings are ASCII, so tr's classes suffice).
lowercaseValue() {
  printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'
}

# Prints 1 when $1 is a recognized true spelling, otherwise 0. Unrecognized
# spellings mean false here so that startup validation, not parsing, is the
# single place that rejects them.
parseBoolean() {
  case "$(lowercaseValue "${1:-}")" in
    true | yes | 1)
      echo 1
      ;;
    *)
      echo 0
      ;;
  esac
}

# Prints 1 for a recognized true spelling, 0 for a recognized false spelling,
# and the empty string otherwise - for settings where unset/empty is a third
# state (IPV6_ENABLED's auto-detection, the omitted
# Access-Control-Allow-Private-Network header). An unrecognized non-empty
# value also prints the empty string: validateBooleanVar is expected to have
# rejected it already, and the historical behavior of both tri-state
# consumers was to fall back to the unset case.
parseBooleanTristate() {
  case "$(lowercaseValue "${1:-}")" in
    true | yes | 1)
      echo 1
      ;;
    false | no | 0)
      echo 0
      ;;
    *)
      echo ""
      ;;
  esac
}

# Succeeds (exit 0) when $1 is a recognized boolean spelling.
isBooleanSpelling() {
  case "$(lowercaseValue "${1:-}")" in
    true | yes | 1 | false | no | 0)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# validateBooleanVar NAME VALUE [valid_values_suffix]
#
# Returns nonzero and prints the standard diagnostic to stderr when VALUE is
# non-empty and not a recognized boolean spelling. Empty values pass: every
# boolean setting treats unset/empty as its default, and the test harness
# and compose file rely on empty pass-through values staying accepted. The
# optional suffix extends the "Valid values: true, false" clause for
# settings where unset is meaningful (e.g. ", or unset for auto-detection").
validateBooleanVar() {
  if [ -n "${2:-}" ] && ! isBooleanSpelling "${2:-}"; then
    >&2 echo "${1:-} contains an invalid value (${2:-}). Valid values: true, false${3:-}"
    return 1
  fi
  return 0
}
# --- gateway_env_lib functions END ---

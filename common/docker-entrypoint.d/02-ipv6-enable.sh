#!/bin/sh
#
#  Copyright 2026 F5 Networks
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

# Adds an IPv6 listen directive to the NGINX configuration when the runtime
# kernel supports IPv6 (or IPV6_ENABLED forces it). The official NGINX image
# ships /docker-entrypoint.d/10-listen-on-ipv6-by-default.sh for the same
# purpose, but it edits /etc/nginx/conf.d/default.conf, which
# 20-envsubst-on-templates.sh re-renders from our template afterwards,
# discarding the edit. This script edits the template itself and is numbered
# to run before the official scripts (GH-499).
#
# The template ships IPv4-only ('listen 80;') so that it is always a valid
# NGINX configuration on its own: on kernels booted with ipv6.disable=1,
# binding [::] fails at startup with 'socket() ... (97: Address family not
# supported by protocol)' (GH-499), and installs that never run this script
# (standalone_ubuntu_oss_install.sh, read-only file systems) stay bootable.

set -e

# Shared boolean parsing helpers (parseBooleanTristate). Sourced from
# /etc/nginx rather than /docker-entrypoint.d so the base image's entrypoint
# never executes it as a script of its own.
# shellcheck source=common/etc/nginx/gateway_env_lib.sh
. /etc/nginx/gateway_env_lib.sh

ME=$(basename "$0")

# Both paths can be overridden with positional parameters so tests can
# exercise the detection and rewrite logic against fixture files. The
# container entrypoint invokes this script without arguments, so production
# always uses the defaults.
DEFAULT_CONF_TEMPLATE="${1:-/etc/nginx/templates/default.conf.template}"
IF_INET6="${2:-/proc/net/if_inet6}"

entrypoint_log() {
    if [ -z "${NGINX_ENTRYPOINT_QUIET_LOGS:-}" ]; then
        echo "$@"
    fi
}

# Single source of truth for what counts as an IPv6 listen directive; used
# by the detection greps and the removal sed below so they cannot drift.
IPV6_LISTEN_RE='^[[:space:]]*listen[[:space:]].*\[::\]'

if [ ! -f "$DEFAULT_CONF_TEMPLATE" ]; then
    entrypoint_log "$ME: info: $DEFAULT_CONF_TEMPLATE does not exist, skipping IPv6 listen enablement"
    exit 0
fi

# Explicit IPV6_ENABLED wins; otherwise auto-detect. /proc/net/if_inet6 only
# exists when the kernel has IPv6 support - the same check the official
# image's 10-listen-on-ipv6-by-default.sh uses. The empty tri-state result
# covers unset/empty and unrecognized spellings alike; the latter never get
# here in a real container because 00-check-for-required-env.sh fails startup
# on them first.
case "$(parseBooleanTristate "${IPV6_ENABLED:-}")" in
  1)
    ipv6_wanted=1
    ;;
  0)
    ipv6_wanted=0
    ;;
  *)
    if [ -f "$IF_INET6" ]; then
      ipv6_wanted=1
    else
      ipv6_wanted=0
    fi
    ;;
esac

if [ "$ipv6_wanted" -eq 0 ]; then
    if ! grep -q "$IPV6_LISTEN_RE" "$DEFAULT_CONF_TEMPLATE"; then
        entrypoint_log "$ME: info: IPv6 disabled, keeping IPv4-only listen configuration"
        exit 0
    fi

    if [ -n "${IPV6_ENABLED:-}" ]; then
        reason="IPV6_ENABLED is false"
    else
        reason="kernel has no IPv6 support"
    fi

    # Remove IPv6 listen directives whether disabled explicitly (the kill
    # switch for docker-commit'd images and custom templates) or by
    # auto-detection: a previous IPv6-capable boot of this container may
    # have injected the directive below, and leaving it in place would make
    # NGINX fail to bind [::] at startup - the exact GH-499 symptom this
    # script exists to prevent. The directive is re-added on the next
    # IPv6-capable start.
    if sed -i "/${IPV6_LISTEN_RE}/d" "$DEFAULT_CONF_TEMPLATE" 2>/dev/null; then
        entrypoint_log "$ME: info: $reason, removed IPv6 listen directives from $DEFAULT_CONF_TEMPLATE"
    else
        entrypoint_log "$ME: warn: $reason but can not modify $DEFAULT_CONF_TEMPLATE (read-only file system?) - IPv6 listen directives remain and NGINX may fail to start"
    fi
    exit 0
fi

# Idempotency: on container restart the entrypoint runs again against the
# already-edited template. Also respects custom templates with their own
# IPv6 listeners.
if grep -q "$IPV6_LISTEN_RE" "$DEFAULT_CONF_TEMPLATE"; then
    entrypoint_log "$ME: info: IPv6 listen directive already present in $DEFAULT_CONF_TEMPLATE, skipping"
    exit 0
fi

# Derive the port from the template's own IPv4 listen directive instead of
# hard-coding it: Dockerfile.unprivileged rewrites 'listen 80;' to
# 'listen 8080;' at build time, and custom templates may use other ports.
port=$(sed -n 's/^[[:space:]]*listen[[:space:]]\{1,\}\([0-9]\{1,\}\);[[:space:]]*$/\1/p' "$DEFAULT_CONF_TEMPLATE" | head -n 1)
if [ -z "$port" ]; then
    if [ -n "${IPV6_ENABLED:-}" ]; then
        # An explicit opt-in must not be defeated silently at info level
        # (00-check-for-required-env.sh validates IPV6_ENABLED for the same
        # reason).
        entrypoint_log "$ME: warn: IPV6_ENABLED is true but no plain 'listen <port>;' directive was found in $DEFAULT_CONF_TEMPLATE - IPv6 listener NOT enabled"
    else
        entrypoint_log "$ME: info: no plain 'listen <port>;' directive found in $DEFAULT_CONF_TEMPLATE, skipping IPv6 listen enablement"
    fi
    exit 0
fi

# Insert an IPv6 twin after every plain 'listen <port>;' line, preserving
# indentation and spacing via backrefs. The escaped literal newline in the
# replacement is POSIX sed syntax (GNU '\n' is not portable). A sed failure
# (read-only file system) downgrades to IPv4-only instead of aborting the
# entrypoint.
if ! sed -i 's/^\([[:space:]]*\)listen\([[:space:]]\{1,\}\)\([0-9]\{1,\}\);[[:space:]]*$/&\
\1listen\2[::]:\3;/' "$DEFAULT_CONF_TEMPLATE" 2>/dev/null; then
    if [ -n "${IPV6_ENABLED:-}" ]; then
        entrypoint_log "$ME: warn: IPV6_ENABLED is true but can not modify $DEFAULT_CONF_TEMPLATE (read-only file system?) - IPv6 listener NOT enabled"
    else
        entrypoint_log "$ME: info: can not modify $DEFAULT_CONF_TEMPLATE (read-only file system?), keeping IPv4-only listen configuration"
    fi
    exit 0
fi

entrypoint_log "$ME: info: enabled IPv6 listen on port $port in $DEFAULT_CONF_TEMPLATE"

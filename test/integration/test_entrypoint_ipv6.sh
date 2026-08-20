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

# Tests for the 02-ipv6-enable.sh entrypoint script (GH-499). The script's
# template and if_inet6 paths are overridable via positional parameters, so
# every branch - including the kernel-without-IPv6 path, which cannot be
# reproduced inside a Docker container (--sysctl does not remove
# /proc/net/if_inet6) - is exercised against fixture files inside the built
# image. Running inside the image also guarantees GNU sed regardless of the
# host OS.

set -o errexit   # abort on nonzero exit status
set -o pipefail  # don't hide errors within pipes

docker_cmd=$1
expected_port=$2

"${docker_cmd}" run --rm -e EXPECTED_PORT="${expected_port}" \
  --entrypoint /bin/sh nginx-s3-gateway -c '
set -e
script=/docker-entrypoint.d/02-ipv6-enable.sh
tpl=/tmp/default.conf.template
fail() { echo "FAIL: $1" >&2; exit 2; }

# 1. Kernel without IPv6 (nonexistent if_inet6 path): template untouched and
#    still carries its IPv4 listen directive - the GH-499 fix itself.
cp /etc/nginx/templates/default.conf.template "$tpl"
sh "$script" "$tpl" /nonexistent/if_inet6
if grep -q "\[::\]" "$tpl"; then fail "injected IPv6 despite kernel lacking support"; fi
grep -q "listen[[:space:]]*${EXPECTED_PORT};" "$tpl" || fail "IPv4 listen directive missing"

# 2. Kernel with IPv6 (any existing file stands in for if_inet6): an IPv6
#    twin is injected on the port derived from the IPv4 listen directive.
sh "$script" "$tpl" /etc/os-release
grep -q "listen[[:space:]]*\[::\]:${EXPECTED_PORT};" "$tpl" || fail "IPv6 listen directive missing"
grep -q "listen[[:space:]]*${EXPECTED_PORT};" "$tpl" || fail "IPv4 listen directive lost during injection"

# 3. Re-run (container restart): template must be byte-identical.
cp "$tpl" /tmp/before
sh "$script" "$tpl" /etc/os-release
cmp -s "$tpl" /tmp/before || fail "second run modified the template"

# 4. Explicit opt-out removes previously injected IPv6 listen directives
#    (the kill switch for docker-committed images and custom templates).
IPV6_ENABLED=false sh "$script" "$tpl" /etc/os-release
if grep -q "\[::\]" "$tpl"; then fail "IPV6_ENABLED=false left IPv6 listen directives in place"; fi
grep -q "listen[[:space:]]*${EXPECTED_PORT};" "$tpl" || fail "IPV6_ENABLED=false removed the IPv4 listen directive"

# 5. Explicit opt-out on a fresh template prevents injection entirely.
cp /etc/nginx/templates/default.conf.template "$tpl"
IPV6_ENABLED=false sh "$script" "$tpl" /etc/os-release
if grep -q "\[::\]" "$tpl"; then fail "IPV6_ENABLED=false still injected IPv6"; fi

# 6. Explicit opt-in forces injection even when the kernel check would fail.
IPV6_ENABLED=true sh "$script" "$tpl" /nonexistent/if_inet6
grep -q "listen[[:space:]]*\[::\]:${EXPECTED_PORT};" "$tpl" || fail "IPV6_ENABLED=true did not inject IPv6"

# 7. Template without a plain listen anchor is conservatively left untouched.
printf "server {\n    include foo.conf;\n}\n" > "$tpl"
sh "$script" "$tpl" /etc/os-release
if grep -q "\[::\]" "$tpl"; then fail "injected IPv6 without an IPv4 listen anchor"; fi

echo "entrypoint IPv6 script tests passed"
'

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

set -e

proxy_ignore_headers_conf=/etc/nginx/conf.d/gateway/proxy_ignore_headers.conf

# proxy_ignore_headers requires at least one field name, so the directive has
# to be omitted entirely rather than rendered with an empty value.
if [ -z "${PROXY_CACHE_IGNORE_HEADERS:-}" ]; then
  exit 0
fi

if [ ! -f "${proxy_ignore_headers_conf}" ]; then
  >&2 echo "Proxy ignore headers configuration file not found: ${proxy_ignore_headers_conf}"
  exit 1
fi

# PROXY_CACHE_IGNORE_HEADERS is checked against the field names nginx accepts
# by 00-check-for-required-env.sh before any entrypoint script can interpolate
# it into nginx configuration - mirroring how 23-enable_s3_proxy_ssl.sh trusts
# the pre-flight checks. Appending rather than overwriting is safe because
# 20-envsubst-on-templates.sh re-renders the stub from its template on every
# start, before this script runs.
cat >> "${proxy_ignore_headers_conf}" <<CONF
proxy_ignore_headers ${PROXY_CACHE_IGNORE_HEADERS};
CONF

echo "Ignoring the caching effect of these S3 response headers: ${PROXY_CACHE_IGNORE_HEADERS}"

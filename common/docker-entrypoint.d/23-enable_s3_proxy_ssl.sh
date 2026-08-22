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

s3_proxy_ssl_conf=/etc/nginx/conf.d/gateway/s3_proxy_ssl.conf

if [ "${S3_SERVER_PROTO}" != "https" ]; then
  exit 0
fi

if [ ! -f "${s3_proxy_ssl_conf}" ]; then
  >&2 echo "S3 proxy SSL configuration file not found: ${s3_proxy_ssl_conf}"
  exit 1
fi

# S3_TRUSTED_CERT_PATH syntax (absolute path, conservative character set) is
# validated by 00-check-for-required-env.sh before any entrypoint script can
# interpolate it into nginx configuration - mirroring how
# 22-enable_js_fetch_trusted_certificate.sh trusts the pre-flight checks.
# Only the file's presence can change between that check and this apply step.
if [ ! -f "${S3_TRUSTED_CERT_PATH}" ]; then
  >&2 echo "S3_TRUSTED_CERT_PATH environment variable error: no file found at the path: ${S3_TRUSTED_CERT_PATH}"
  exit 1
fi

# proxy_ssl_verify_depth bounds the number of untrusted intermediates rather
# than trust itself, and the nginx default of 1 rejects otherwise-valid
# chains that carry two or more intermediate CAs (common in private PKI).
cat >> "${s3_proxy_ssl_conf}" <<EOF
proxy_ssl_verify on;
proxy_ssl_verify_depth 5;
proxy_ssl_trusted_certificate ${S3_TRUSTED_CERT_PATH};
EOF

echo "Enabling S3 origin TLS certificate verification with ${S3_TRUSTED_CERT_PATH}"

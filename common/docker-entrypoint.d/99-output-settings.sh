#!/bin/sh
#
#  Copyright 2025 F5 Networks
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

# The IPv6 listen directive is injected by 02-ipv6-enable.sh only when the
# kernel supports IPv6 or IPV6_ENABLED forces it (GH-499), so report the
# effective rendered state rather than a configuration value.
if grep -q '^[[:space:]]*listen[[:space:]].*\[::\]' /etc/nginx/conf.d/default.conf 2>/dev/null; then
  ipv6_listen="enabled"
else
  ipv6_listen="disabled"
fi

cat <<EOM
S3 Backend Environment:
  Service: ${S3_SERVICE:-s3}
  Access Key ID: ${AWS_ACCESS_KEY_ID}
  Origin: ${S3_SERVER_PROTO}://${S3_BUCKET_NAME}.${S3_SERVER}:${S3_SERVER_PORT}
  Region: ${S3_REGION}
  Addressing Style: ${S3_STYLE}
  AWS Signatures Version: v${AWS_SIGS_VERSION}
  DNS Resolvers: ${DNS_RESOLVERS}
  IPv6 Listen: ${ipv6_listen}
  Directory Listing Enabled: ${ALLOW_DIRECTORY_LIST}
  Directory Listing Path Prefix: ${DIRECTORY_LISTING_PATH_PREFIX}
  Provide Index Pages Enabled: ${PROVIDE_INDEX_PAGE}
  Append slash for directory enabled: ${APPEND_SLASH_FOR_POSSIBLE_DIRECTORY}
  Stripping the following headers from responses: x-amz-;${HEADER_PREFIXES_TO_STRIP}
  Allow the following headers from responses (these take precedence over the above): ${HEADER_PREFIXES_ALLOWED}
  CORS Enabled: ${CORS_ENABLED}
  CORS Allow Private Network Access: ${CORS_ALLOW_PRIVATE_NETWORK_ACCESS}
  Proxy cache using stale setting: ${PROXY_CACHE_USE_STALE}
  Proxy cache bypass on Cache-Control no-cache: ${PROXY_CACHE_BYPASS_NO_CACHE}
EOM

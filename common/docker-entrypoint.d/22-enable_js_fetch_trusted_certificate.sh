#!/usr/bin/bash

#
#  Copyright 2022 F5 Networks
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

if [ -f /etc/nginx/conf.d/gateway/js_fetch_trusted_certificate.conf ] && [ -n "${JS_TRUSTED_CERT_PATH+x}" ]; then
  if [ ! -f "${JS_TRUSTED_CERT_PATH}" ]; then
    >&2 echo "JS_TRUSTED_CERT_PATH environment variable error: no file found at the path: ${JS_TRUSTED_CERT_PATH}"
    exit 1
  fi

  echo "js_fetch_trusted_certificate ${JS_TRUSTED_CERT_PATH};" >> /etc/nginx/conf.d/gateway/js_fetch_trusted_certificate.conf
  echo "Enabling js_fetch_trusted_certificate ${JS_TRUSTED_CERT_PATH}"
fi

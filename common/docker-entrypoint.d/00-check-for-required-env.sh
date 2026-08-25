#!/usr/bin/bash
#
#  Copyright 2020 F5 Networks
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

# This script checks to see that required environment variables were correctly
# passed into the Docker container.

set -e

failed=0

required=("S3_BUCKET_NAME" "S3_SERVER" "S3_SERVER_PORT" "S3_SERVER_PROTO"
"S3_REGION" "S3_STYLE" "ALLOW_DIRECTORY_LIST" "AWS_SIGS_VERSION"
"CORS_ENABLED")

# Each static credential may be supplied either in its own environment
# variable or, following the container secret-store convention, in a file named
# by a '<VAR>_FILE' companion variable (GH-67). The njs modules read whichever
# form is present, so the checks below accept either one. These cannot go in
# the ${required} array, which only knows how to name a single variable.

# The credential files are read by the NGINX worker processes at request time,
# not by this script. In the standard images this script runs as root while
# nginx.conf drops the workers to an unprivileged user, so a plain `test -r`
# here says nothing about whether a worker can read the file: a root-only
# secret would start up cleanly and then fail every single request. Resolve the
# worker user so the check below can probe as that user instead.
nginx_worker_user="$(awk '$1 == "user" { sub(/;.*$/, "", $2); print $2; exit }' /etc/nginx/nginx.conf 2> /dev/null || true)"
if [ -z "${nginx_worker_user}" ]; then
  # The unprivileged image deletes the `user` directive, and NGINX cannot
  # change user without root anyway - the workers then run as whoever started
  # the container, which is also who runs this script.
  nginx_worker_user="$(id -un)"
fi

# Whether privileges can actually be dropped to probe as that user. Anything
# unexpected - no such user, no su, not root - falls back to testing as
# ourselves rather than refusing to start over a check we cannot perform.
if [ "$(id -u)" -eq 0 ] && [ "${nginx_worker_user}" != "$(id -un)" ] &&
   id -u "${nginx_worker_user}" > /dev/null 2>&1 &&
   command -v su > /dev/null 2>&1; then
  can_probe_as_nginx_worker=1
else
  can_probe_as_nginx_worker=0
fi

# Reports whether the NGINX worker user can read a path. Unlike a root
# `test -r` this also catches a parent directory the worker cannot traverse,
# because access(2) resolves the whole path as the probing user.
isReadableByNginxWorker() {
  probe_path=$1

  if [ "${can_probe_as_nginx_worker}" -eq 0 ]; then
    [ -r "${probe_path}" ]
    return
  fi

  # The path is passed as a positional parameter rather than interpolated into
  # the -c string so that a path containing shell metacharacters cannot alter
  # the command that runs.
  su -s /bin/sh "${nginx_worker_user}" -c 'test -r "$1"' sh "${probe_path}"
}

# Fails when neither form of a static credential is configured.
requireStaticCredential() {
  name=$1
  file_name="${name}_FILE"

  if [[ ! -v $name ]] && [[ ! -v $file_name ]]; then
    >&2 echo "Required ${name} (or ${file_name}) environment variable missing"
    failed=1
  fi
}

# Validates a '<VAR>_FILE' companion variable when it is set. This runs in
# every credential mode, not just the static one, so that a mistyped path fails
# at start up rather than turning every proxied request into a 500.
checkCredentialFile() {
  name=$1
  file_name="${name}_FILE"

  if [[ ! -v $file_name ]]; then
    return
  fi

  path="${!file_name}"

  # Only a non-empty direct value conflicts: the njs modules fall through to
  # the file when the variable is set but empty (as an env-file line with no
  # value or a compose pass-through of an unset variable leaves it), so
  # rejecting that would refuse a configuration that works.
  if [ -n "${!name:-}" ]; then
    >&2 echo "${name} and ${file_name} are mutually exclusive - set only one of them"
    failed=1
  fi

  if [ -z "${path}" ]; then
    >&2 echo "${file_name} must not be empty when set"
    failed=1
  elif [ ! -f "${path}" ]; then
    >&2 echo "${file_name} does not refer to an existing regular file (${path})"
    failed=1
  elif ! isReadableByNginxWorker "${path}"; then
    >&2 echo "${file_name} refers to a file the NGINX worker user (${nginx_worker_user}) cannot read (${path}). A file-based secret keeps the permissions of its source file, so make it readable by that user, for example with chmod 0444."
    failed=1
  # An all-whitespace file yields an empty credential, which passes every check
  # downstream and only fails at the S3 origin as an opaque 403.
  elif [ -z "$(tr -d '[:space:]' < "${path}")" ]; then
    >&2 echo "${file_name} refers to an empty file (${path})"
    failed=1
  fi
}

# Require some form of authentication to be configured.

# a) Using container credentials. This is indicated by AWS_CONTAINER_CREDENTIALS_RELATIVE_URI being set.
#    See https://docs.aws.amazon.com/sdkref/latest/guide/feature-container-credentials.html
#    Example: We are running inside an ECS task.
if [[ -v AWS_CONTAINER_CREDENTIALS_RELATIVE_URI ]]; then
  echo "Running inside an ECS task, using container credentials"

elif [[ -v S3_SESSION_TOKEN ]]; then
  echo "Deprecated the S3_SESSION_TOKEN! Use the environment variable of AWS_SESSION_TOKEN instead"
  failed=1

elif [[ -v AWS_SESSION_TOKEN ]] || [[ -v AWS_SESSION_TOKEN_FILE ]]; then
  echo "S3 Session token specified - not using IMDS for credentials"

# b) Using Instance Metadata Service (IMDS) credentials, if IMDS is present at http://169.254.169.254.
#    See https://docs.aws.amazon.com/sdkref/latest/guide/feature-imds-credentials.html.
#    Example: We are running inside an EC2 instance.
elif TOKEN=`curl -X PUT --silent --fail --connect-timeout 2 --max-time 2 "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"` && curl  -H "X-aws-ec2-metadata-token: $TOKEN" --output /dev/null --silent --head --fail --connect-timeout 2 --max-time 5 "http://169.254.169.254"; then
  echo "Running inside an EC2 instance, using IMDS for credentials"

# c) Using assume role credentials. This is indicated by AWS_WEB_IDENTITY_TOKEN_FILE being set.
#    See https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-role.html.
#    Example: We are running inside an EKS cluster with IAM roles for service accounts enabled.
elif [[ -v AWS_WEB_IDENTITY_TOKEN_FILE ]]; then
  echo "Running inside EKS with IAM roles for service accounts"
  if [[ ! -v AWS_ROLE_SESSION_NAME ]]; then
    # The default value is set as a nginx-s3-gateway unless the value is defined.
    AWS_ROLE_SESSION_NAME="nginx-s3-gateway"
  fi

# d) Using EKS pod identity. This is indicated by AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE being set.
#    See https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html.
#    Example: We are running inside an EKS cluster with a pod identity configured.
elif [[ -v AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE ]]; then
  echo "Running inside EKS with EKS pod identity"
  if [[ ! -v AWS_ROLE_SESSION_NAME ]]; then
    # The default value is set as a nginx-s3-gateway unless the value is defined.
    AWS_ROLE_SESSION_NAME="nginx-s3-gateway"
  fi

elif [[ -v S3_ACCESS_KEY_ID ]]; then
  echo "Deprecated the S3_ACCESS_KEY_ID! Use the environment variable of AWS_ACCESS_KEY_ID instead"
  failed=1

elif [[ -v S3_SECRET_KEY ]]; then
  echo "Deprecated the S3_SECRET_KEY! Use the environment variable of AWS_SECRET_ACCESS_KEY instead"
  failed=1

elif [[ -v AWS_SECRET_KEY ]]; then
  echo "AWS_SECRET_KEY is not a valid setting! Use the environment variable of AWS_SECRET_ACCESS_KEY instead"
  failed=1


# If none of the options above is used, require static credentials.
# See https://docs.aws.amazon.com/sdkref/latest/guide/feature-static-credentials.html.
else
  requireStaticCredential "AWS_ACCESS_KEY_ID"
  requireStaticCredential "AWS_SECRET_ACCESS_KEY"
fi

for credential_name in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; do
  checkCredentialFile "${credential_name}"
done

if [[ -v S3_DEBUG ]]; then
  echo "Deprecated the S3_DEBUG! Use the environment variable of DEBUG instead"
  failed=1
fi

for name in ${required[@]}; do
  if [[ ! -v $name ]]; then
      >&2 echo "Required ${name} environment variable missing"
      failed=1
  fi
done

if [ "${S3_SERVER_PROTO}" != "http" ] && [ "${S3_SERVER_PROTO}" != "https" ]; then
    >&2 echo "S3_SERVER_PROTO contains an invalid value (${S3_SERVER_PROTO}). Valid values: http, https"
    failed=1
fi

if [ -n "${S3_TRUSTED_CERT_PATH+x}" ]; then
  if [ -z "${S3_TRUSTED_CERT_PATH}" ]; then
    >&2 echo "S3_TRUSTED_CERT_PATH must not be empty when set"
    failed=1
  elif [ "${S3_TRUSTED_CERT_PATH#/}" = "${S3_TRUSTED_CERT_PATH}" ]; then
    >&2 echo "S3_TRUSTED_CERT_PATH must be an absolute path"
    failed=1
  elif [[ "${S3_TRUSTED_CERT_PATH}" =~ [^A-Za-z0-9_./-] ]]; then
    >&2 echo "S3_TRUSTED_CERT_PATH contains unsupported characters"
    failed=1
  fi
fi

if [ "${AWS_SIGS_VERSION}" != "2" ] && [ "${AWS_SIGS_VERSION}" != "4" ]; then
  >&2 echo "AWS_SIGS_VERSION contains an invalid value (${AWS_SIGS_VERSION}). Valid values: 2, 4"
  failed=1
fi

# Temporary credentials cannot work with signature v2: the gateway's v2
# signer covers no x-amz-* headers, so the X-Amz-Security-Token header it
# sends is never part of the signature and S3 rejects every request with
# SignatureDoesNotMatch. Fail fast instead of starting a gateway that
# 404s on every object (GH-578). A set-but-empty variable counts as absent,
# matching the njs modules (an env-file line with no value or a compose
# pass-through of an unset variable leaves the variable set but empty).
if [ "${AWS_SIGS_VERSION}" = "2" ] && { [ -n "${AWS_SESSION_TOKEN:-}" ] || [ -n "${AWS_SESSION_TOKEN_FILE:-}" ]; }; then
  >&2 echo "AWS_SESSION_TOKEN(_FILE) cannot be used with AWS_SIGS_VERSION=2: v2 signatures do not cover the session token, so S3 rejects every request. Use AWS_SIGS_VERSION=4 or remove the session token."
  failed=1
fi

parseBoolean() {
  case "$1" in
    TRUE | true | True | YES | Yes | 1)
      echo 1
      ;;
    *)
      echo 0
      ;;
  esac
}

if [ -n "${HEADER_PREFIXES_TO_STRIP+x}" ]; then
  if [[ "${HEADER_PREFIXES_TO_STRIP}" =~ [A-Z] ]]; then
    >&2 echo "HEADER_PREFIXES_TO_STRIP must not contain uppercase characters"
    failed=1
  fi
fi

# PROXY_CACHE_BYPASS_NO_CACHE is optional (unset and empty default to
# false), but when it is set it must be a spelling that parseBoolean
# recognizes. parseBoolean treats every unrecognized value - including the
# lowercase 'yes' - as false, so a typo would otherwise silently disable the
# cache bypass feature.
if [ -n "${PROXY_CACHE_BYPASS_NO_CACHE:-}" ]; then
  case "${PROXY_CACHE_BYPASS_NO_CACHE}" in
    TRUE | true | True | YES | Yes | 1 | FALSE | false | False | NO | No | 0) ;;
    *)
      >&2 echo "PROXY_CACHE_BYPASS_NO_CACHE contains an invalid value (${PROXY_CACHE_BYPASS_NO_CACHE}). Valid values: true, false"
      failed=1
      ;;
  esac
fi

# PROXY_CACHE_IGNORE_HEADERS is optional (unset and empty leave
# proxy_ignore_headers out of the configuration entirely). Its value is
# interpolated verbatim into nginx configuration by
# 25-set-proxy-ignore-headers.sh, so accept only the field names the
# proxy_ignore_headers directive recognizes. nginx compares them
# case-insensitively, so any spelling of a valid field is passed through as
# the operator wrote it.
# https://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_ignore_headers
if [ -n "${PROXY_CACHE_IGNORE_HEADERS:-}" ]; then
  # read -ra rather than an unquoted for-loop so the intentional word
  # splitting is explicit and shellcheck stays clean. read stops at the first
  # line break, so line breaks are folded to spaces beforehand - otherwise
  # everything after a newline would skip this check and still be written
  # verbatim into the nginx configuration.
  read -ra proxy_cache_ignore_header_fields <<< "${PROXY_CACHE_IGNORE_HEADERS//[$'\n\r']/ }"
  if [ ${#proxy_cache_ignore_header_fields[@]} -eq 0 ]; then
    # A whitespace-only value is non-empty, so the apply step would render
    # 'proxy_ignore_headers ;' and NGINX would refuse to start. Fail here with
    # a diagnostic instead.
    >&2 echo "PROXY_CACHE_IGNORE_HEADERS is set but contains no field names. Unset it to leave proxy_ignore_headers out of the configuration."
    failed=1
  else
    for field in "${proxy_cache_ignore_header_fields[@]}"; do
      case "${field,,}" in
        x-accel-redirect | x-accel-expires | x-accel-limit-rate | x-accel-buffering | x-accel-charset | expires | cache-control | set-cookie | vary) ;;
        *)
          >&2 echo "PROXY_CACHE_IGNORE_HEADERS contains an unsupported field (${field}). Valid fields: X-Accel-Redirect X-Accel-Expires X-Accel-Limit-Rate X-Accel-Buffering X-Accel-Charset Expires Cache-Control Set-Cookie Vary"
          failed=1
          ;;
      esac
    done
  fi
fi

# IPV6_ENABLED is optional (unset and empty mean auto-detection from kernel
# IPv6 support), but when it is set it must be a recognized spelling: an
# unrecognized value would silently fall through to auto-detection in
# 02-ipv6-enable.sh, defeating the explicit override.
if [ -n "${IPV6_ENABLED:-}" ]; then
  case "${IPV6_ENABLED}" in
    TRUE | true | True | YES | Yes | 1 | FALSE | false | False | NO | No | 0) ;;
    *)
      >&2 echo "IPV6_ENABLED contains an invalid value (${IPV6_ENABLED}). Valid values: true, false, or unset for auto-detection"
      failed=1
      ;;
  esac
fi


# PREFIX_LEADING_DIRECTORY_PATH is rendered verbatim into the nginx
# configuration: into the request-path map and into listing.xsl's
# xslt_string_param, which wraps the value in single quotes. A single quote
# or a literal '$' in the value therefore produces a configuration nginx
# refuses to parse ("unexpected end of parameter" / "unknown variable"), so
# fail here with a message that names the real culprit instead.
case "${PREFIX_LEADING_DIRECTORY_PATH:-}" in
  *"'"* | *'$'*)
    >&2 echo "PREFIX_LEADING_DIRECTORY_PATH must not contain single quote or '\$' characters because the value is rendered into the NGINX configuration (${PREFIX_LEADING_DIRECTORY_PATH})"
    failed=1
    ;;
esac

if [ $failed -gt 0 ]; then
  exit 1
fi

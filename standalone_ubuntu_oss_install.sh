#!/usr/bin/env bash

set -o errexit   # abort on nonzero exit status
set -o pipefail  # don't hide errors within pipes

if [ "$EUID" -ne 0 ];then
  >&2 echo "This script requires root level access to run"
  exit 1
fi

if ! dpkg --status grep 2>/dev/null | grep --quiet Status > /dev/null; then
  >&2 echo "This script requires the grep package to be installed in order to run"
  exit 1
fi

if ! dpkg --status coreutils 2>/dev/null | grep --quiet Status > /dev/null; then
  >&2 echo "This script requires the coreutils package to be installed in order to run"
  exit 1
fi

if ! dpkg --status apt 2>/dev/null | grep --quiet Status > /dev/null; then
  >&2 echo "This script requires the apt package to be installed in order to run"
  exit 1
fi

if ! dpkg --status wget 2>/dev/null | grep --quiet Status > /dev/null; then
  >&2 echo "This script requires the wget package to be installed in order to run"
  exit 1
fi

failed=0

required=("S3_BUCKET_NAME" "S3_SERVER" "S3_SERVER_PORT" "S3_SERVER_PROTO"
"S3_REGION" "S3_STYLE" "ALLOW_DIRECTORY_LIST" "AWS_SIGS_VERSION")

if [ ! -z ${AWS_CONTAINER_CREDENTIALS_RELATIVE_URI+x} ]; then
  echo "Running inside an ECS task, using container credentials"
  uses_iam_creds=1
elif TOKEN=$(curl -X PUT --silent --fail --connect-timeout 2 --max-time 2 "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600") && \
  curl -H "X-aws-ec2-metadata-token: $TOKEN" --output /dev/null --silent --head --fail --connect-timeout 2 --max-time 5 "http://169.254.169.254"; then 
  echo "Running inside an EC2 instance, using IMDSv2 for credentials"
  uses_iam_creds=1
elif curl --output /dev/null --silent --head --fail --connect-timeout 2 "http://169.254.169.254"; then
  echo "Running inside an EC2 instance, using IMDSv1 for credentials"
  uses_iam_creds=1
else
  # Each static credential may be supplied either in its own environment
  # variable or, following the container secret-store convention, in a file
  # named by a '<VAR>_FILE' companion variable (GH-67). The njs modules read
  # whichever form is present, so accept either one here. Setting both is
  # ambiguous and rejected.
  for name in "AWS_ACCESS_KEY_ID" "AWS_SECRET_ACCESS_KEY"; do
    file_name="${name}_FILE"
    if [ -z ${!name+x} ] && [ -z ${!file_name+x} ]; then
      >&2 echo "Required ${name} (or ${file_name}) environment variable missing"
      failed=1
    fi
  done
  uses_iam_creds=0
fi

# The credential files are read by the NGINX worker processes at request time,
# not by this script. This script runs as root while the nginx.conf it writes
# further down drops the workers to the nginx user, so a plain `test -r` here
# says nothing about whether a worker can read the file: a root-only secret
# would install cleanly and then fail every single request. On a first install
# the nginx package - and so the nginx user - does not exist yet, in which case
# fall back to testing as ourselves rather than refusing to install over a
# check we cannot perform.
nginx_worker_user="nginx"
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

for name in "AWS_ACCESS_KEY_ID" "AWS_SECRET_ACCESS_KEY" "AWS_SESSION_TOKEN"; do
  file_name="${name}_FILE"
  if [ -z ${!file_name+x} ]; then
    continue
  fi
  # Only a non-empty direct value conflicts: the njs modules fall through to
  # the file when the variable is set but empty.
  if [ -n "${!name:-}" ]; then
    >&2 echo "${name} and ${file_name} are mutually exclusive - set only one of them"
    failed=1
  fi
  if [ -z "${!file_name}" ]; then
    >&2 echo "${file_name} must not be empty when set"
    failed=1
  elif [ ! -f "${!file_name}" ]; then
    >&2 echo "${file_name} does not refer to an existing regular file (${!file_name})"
    failed=1
  elif ! isReadableByNginxWorker "${!file_name}"; then
    >&2 echo "${file_name} refers to a file the NGINX worker user (${nginx_worker_user}) cannot read (${!file_name}). Make it readable by that user, for example with chmod 0444."
    failed=1
  # An all-whitespace file yields an empty credential, which passes every
  # check downstream and then throws in njs on every request. Match the
  # container entrypoint and fail here instead.
  elif [ -z "$(tr -d '[:space:]' < "${!file_name}")" ]; then
    >&2 echo "${file_name} refers to an empty file (${!file_name})"
    failed=1
  fi
done

if [[ -v AWS_SESSION_TOKEN ]] || [[ -v AWS_SESSION_TOKEN_FILE ]]; then
  echo "S3 Session token present"
fi

for name in ${required[@]}; do
  if [ -z ${!name+x} ]; then
      >&2 echo "Required ${name} environment variable missing"
      failed=1
  fi
done

if [ "${S3_SERVER_PROTO}" != "http" ] && [ "${S3_SERVER_PROTO}" != "https" ]; then
    >&2 echo "S3_SERVER_PROTO contains an invalid value (${S3_SERVER_PROTO}). Valid values: http, https"
    failed=1
fi

if [ -z "${S3_TRUSTED_CERT_PATH+x}" ]; then
  S3_TRUSTED_CERT_PATH="/etc/ssl/certs/ca-certificates.crt"
fi

if [ -z "${S3_TRUSTED_CERT_PATH}" ]; then
  >&2 echo "S3_TRUSTED_CERT_PATH must not be empty when set"
  failed=1
elif [ "${S3_TRUSTED_CERT_PATH#/}" = "${S3_TRUSTED_CERT_PATH}" ]; then
  >&2 echo "S3_TRUSTED_CERT_PATH must be an absolute path"
  failed=1
elif [[ "${S3_TRUSTED_CERT_PATH}" =~ [^A-Za-z0-9_./-] ]]; then
  >&2 echo "S3_TRUSTED_CERT_PATH contains unsupported characters"
  failed=1
elif [ "${S3_SERVER_PROTO}" = "https" ] && [ ! -f "${S3_TRUSTED_CERT_PATH}" ]; then
  >&2 echo "S3_TRUSTED_CERT_PATH environment variable error: no file found at the path: ${S3_TRUSTED_CERT_PATH}"
  failed=1
fi

# PROXY_CACHE_IGNORE_HEADERS is optional (unset and empty leave
# proxy_ignore_headers out of the configuration entirely). Its value is
# interpolated verbatim into nginx configuration by
# apply_proxy_ignore_headers in template_nginx_config.sh, so accept only the
# field names the proxy_ignore_headers directive recognizes. nginx compares
# them case-insensitively, so any spelling of a valid field is passed through
# as the operator wrote it. This mirrors the check in
# common/docker-entrypoint.d/00-check-for-required-env.sh.
# https://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_ignore_headers
if [ -n "${PROXY_CACHE_IGNORE_HEADERS:-}" ]; then
  # read stops at the first line break, so line breaks are folded to spaces
  # beforehand - otherwise everything after a newline would skip this check
  # and still be written verbatim into the nginx configuration.
  read -ra proxy_cache_ignore_header_fields <<< "${PROXY_CACHE_IGNORE_HEADERS//[$'\n\r']/ }"
  if [ ${#proxy_cache_ignore_header_fields[@]} -eq 0 ]; then
    # A whitespace-only value is non-empty, so the apply step would render
    # 'proxy_ignore_headers ;' and NGINX would refuse to start.
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

if [ "${AWS_SIGS_VERSION}" != "2" ] && [ "${AWS_SIGS_VERSION}" != "4" ]; then
  >&2 echo "AWS_SIGS_VERSION contains an invalid value (${AWS_SIGS_VERSION}). Valid values: 2, 4"
  failed=1
fi

# PREFIX_LEADING_DIRECTORY_PATH is rendered verbatim into the nginx
# configuration: into the request-path map and into listing.xsl's
# xslt_string_param, which wraps the value in single quotes. A single quote
# or a literal '$' in the value therefore produces a configuration nginx
# refuses to parse ("unexpected end of parameter" / "unknown variable"), so
# fail here with a message that names the real culprit instead. This mirrors
# the check in common/docker-entrypoint.d/00-check-for-required-env.sh.
case "${PREFIX_LEADING_DIRECTORY_PATH:-}" in
  *"'"* | *'$'*)
    >&2 echo "PREFIX_LEADING_DIRECTORY_PATH must not contain single quote or '\$' characters because the value is rendered into the NGINX configuration (${PREFIX_LEADING_DIRECTORY_PATH})"
    failed=1
    ;;
esac

if [ $failed -gt 0 ]; then
  exit 1
fi

if [ "${1}" == "" ]; then
  branch="main"
else
  branch="${1}"
fi
echo "Installing using github '${branch}' branch"

# Normalize to 1/0: the fail-closed map in default.conf.template only
# enables the cache bypass for the exact value '1'; anything else
# disables it.
case "${PROXY_CACHE_BYPASS_NO_CACHE:-false}" in
  TRUE | true | True | YES | Yes | 1) PROXY_CACHE_BYPASS_NO_CACHE=1 ;;
  *) PROXY_CACHE_BYPASS_NO_CACHE=0 ;;
esac

# Normalize to 1/0: cors.conf.template matches "$request_method_1" literally
# and the LIMIT_METHODS_TO selection below compares against '1', so the
# documented true/false form would otherwise silently disable CORS. This
# mirrors the parseBoolean normalization in
# common/docker-entrypoint.d/01-set-defaults.envsh.
case "${CORS_ENABLED:-false}" in
  TRUE | true | True | YES | Yes | 1) CORS_ENABLED=1 ;;
  *) CORS_ENABLED=0 ;;
esac

# Normalize STRIP_LEADING_DIRECTORY_PATH and PREFIX_LEADING_DIRECTORY_PATH for
# the request-path map in default.conf.template, which concatenates
# $PREFIX_LEADING_DIRECTORY_PATH with paths that always begin with "/": a
# trailing slash would produce double-slash S3 keys and 404 every request
# (GH-576). PREFIX also gains a leading slash if missing; STRIP is a regex
# fragment, so only its trailing slashes are trimmed. The normalized values
# are written into /etc/nginx/environment below, so both the template
# renderer and the nginx master see the same value. This mirrors the
# normalization in common/docker-entrypoint.d/01-set-defaults.envsh.

# Prints $1 with all trailing slashes removed ("" stays "").
trimTrailingSlashes() {
  while [ "${1%/}" != "$1" ]; do
    set -- "${1%/}"
  done
  printf '%s' "$1"
}

PREFIX_LEADING_DIRECTORY_PATH="$(trimTrailingSlashes "${PREFIX_LEADING_DIRECTORY_PATH:-}")"
case "${PREFIX_LEADING_DIRECTORY_PATH}" in
  "" | /*) ;;
  *) PREFIX_LEADING_DIRECTORY_PATH="/${PREFIX_LEADING_DIRECTORY_PATH}" ;;
esac

STRIP_LEADING_DIRECTORY_PATH="$(trimTrailingSlashes "${STRIP_LEADING_DIRECTORY_PATH:-}")"

# This is the primary logic to determine the s3 host used for the
# upstream (the actual proxying action) as well as the `Host` header
#
# It is currently slightly more complex than necessary because we are transitioning
# to a new logic which is defined by "virtual-v2". "virtual-v2" is the recommended setting
# for all deployments.

# S3_UPSTREAM needs the port specified. The port must
# correspond to https/http in the proxy_pass directive.
if [ "${S3_STYLE}" == "virtual-v2" ]; then
  S3_UPSTREAM="${S3_BUCKET_NAME}.${S3_SERVER}:${S3_SERVER_PORT}"
  S3_HOST_HEADER="${S3_BUCKET_NAME}.${S3_SERVER}:${S3_SERVER_PORT}"
elif [ "${S3_STYLE}" == "path" ]; then
  S3_UPSTREAM="${S3_SERVER}:${S3_SERVER_PORT}"
  S3_HOST_HEADER="${S3_SERVER}:${S3_SERVER_PORT}"
else
  S3_UPSTREAM="${S3_SERVER}:${S3_SERVER_PORT}"
  S3_HOST_HEADER="${S3_BUCKET_NAME}.${S3_SERVER}"
fi

echo "S3 Backend Environment"
# The access key id is not secret, but it is not always in the environment:
# when it comes from a file (GH-67) report where it was read from instead of
# printing a blank. The secret key and session token are never reported.
if [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
  echo "Access Key ID: ${AWS_ACCESS_KEY_ID}"
elif [ -n "${AWS_ACCESS_KEY_ID_FILE:-}" ]; then
  echo "Access Key ID: (read from ${AWS_ACCESS_KEY_ID_FILE})"
else
  echo "Access Key ID: "
fi
echo "Origin: ${S3_SERVER_PROTO}://${S3_UPSTREAM}"
echo "Host Header: ${S3_HOST_HEADER}"
if [ "${S3_SERVER_PROTO}" = "https" ]; then
  echo "Origin TLS Verification: enabled"
else
  echo "Origin TLS Verification: disabled (HTTP origin)"
fi
echo "Origin TLS Trusted Certificate: ${S3_TRUSTED_CERT_PATH}"
echo "Region: ${S3_REGION}"
echo "Addressing Style: ${S3_STYLE}"
echo "AWS Signatures Version: v${AWS_SIGS_VERSION}"
echo "DNS Resolvers: ${DNS_RESOLVERS}"
echo "Directory Listing Enabled: ${ALLOW_DIRECTORY_LIST}"
echo "Directory Listing path prefix: ${DIRECTORY_LISTING_PATH_PREFIX}"
echo "Cache size limit: ${PROXY_CACHE_MAX_SIZE}"
echo "Cache inactive timeout: ${PROXY_CACHE_INACTIVE}"
echo "Slice of slice for byte range requests: ${PROXY_CACHE_SLICE_SIZE}"
echo "Proxy Caching Time for Valid Response: ${PROXY_CACHE_VALID_OK}"
echo "Proxy Caching Time for Not Found Response: ${PROXY_CACHE_VALID_NOTFOUND}"
echo "Proxy Caching Time for Forbidden Response: ${PROXY_CACHE_VALID_FORBIDDEN}"
echo "Proxy Cache Using Stale: ${PROXY_CACHE_USE_STALE}"
echo "Proxy Cache Bypass on Cache-Control no-cache: ${PROXY_CACHE_BYPASS_NO_CACHE}"
echo "Proxy Cache Ignoring S3 Response Headers: ${PROXY_CACHE_IGNORE_HEADERS:-}"
echo "CORS Enabled: ${CORS_ENABLED}"
echo "CORS Allow Private Network Access: ${CORS_ALLOW_PRIVATE_NETWORK_ACCESS}"

set -o nounset   # abort on unbound variable

if [ ! -f /usr/share/keyrings/nginx-archive-keyring.gpg ]; then
  echo "▶ Adding NGINX signing key"
  key_tmp_file="$(mktemp)"
  wget --quiet --max-redirect=3 --output-document="${key_tmp_file}" https://nginx.org/keys/nginx_signing.key
  echo "dd4da5dc599ef9e7a7ac20a87275024b4923a917a306ab5d53fa77871220ecda  ${key_tmp_file}" | sha256sum --check
  gpg --dearmor < "${key_tmp_file}" | tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null
  rm -f "${key_tmp_file}"
fi

if [ ! -f /etc/apt/sources.list.d/nginx.list ]; then
  release="$(grep 'VERSION_CODENAME' /etc/os-release | cut --delimiter='=' --field=2)"
  echo "▶ Adding NGINX package repository"
  echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] \
  http://nginx.org/packages/ubuntu ${release} nginx" \
      | sudo tee /etc/apt/sources.list.d/nginx.list
  apt-get -qq update
fi

to_install=""

if ! dpkg --status nginx 2>/dev/null | grep --quiet Status > /dev/null; then
  to_install="nginx"
fi

if ! dpkg --status nginx-module-njs 2>/dev/null | grep --quiet Status > /dev/null; then
  # find latest njs version because the package manager gets this wrong
  latest_njs_version="$(apt show -a nginx-module-njs 2>/dev/null | grep 'Version:' | cut --delimiter=' ' --field=2 | sort --reverse | head --lines=1)"
  to_install="${to_install} nginx-module-njs=${latest_njs_version}"
fi

if ! dpkg --status nginx-module-xslt 2>/dev/null | grep --quiet Status > /dev/null; then
  to_install="${to_install} nginx-module-xslt"
fi


if [ "${to_install}" != "" ]; then
  echo "▶ Installing ${to_install}"
  apt-get -qq install --yes ${to_install}
  echo "▶ Stopping nginx so that it can be configured as a S3 Gateway"
  systemctl stop nginx
fi

# On a first install the worker-readability check in the validation block above
# could only test as root: the nginx user is created by the nginx package, which
# has only now been installed. Redo it for real, because a root-only secret
# passes a root `test -r` and then fails every single request once the workers
# drop privileges. Aborting here leaves an installed but unconfigured nginx,
# which a re-run after fixing the permissions completes.
if [ "${can_probe_as_nginx_worker}" -eq 0 ] && id -u "${nginx_worker_user}" > /dev/null 2>&1; then
  can_probe_as_nginx_worker=1
  for name in "AWS_ACCESS_KEY_ID" "AWS_SECRET_ACCESS_KEY" "AWS_SESSION_TOKEN"; do
    file_name="${name}_FILE"
    if [ -n "${!file_name:-}" ] && ! isReadableByNginxWorker "${!file_name}"; then
      >&2 echo "${file_name} refers to a file the NGINX worker user (${nginx_worker_user}) cannot read (${!file_name}). Make it readable by that user, for example with chmod 0444."
      failed=1
    fi
  done

  if [ $failed -gt 0 ]; then
    exit 1
  fi
fi

echo "▶ Adding environment variables to NGINX configuration file: /etc/nginx/environment"
cat > "/etc/nginx/environment" << EOF
# Enables or disables directory listing for the S3 Gateway (true=enabled, false=disabled)
ALLOW_DIRECTORY_LIST=${ALLOW_DIRECTORY_LIST:-'false'}
# Enables or disables directory listing for the S3 Gateway (true=enabled, false=disabled)
DIRECTORY_LISTING_PATH_PREFIX=${DIRECTORY_LISTING_PATH_PREFIX:-''}
# AWS Authentication signature version (2=v2 authentication, 4=v4 authentication)
AWS_SIGS_VERSION=${AWS_SIGS_VERSION}
# Name of S3 bucket to proxy requests to
S3_BUCKET_NAME=${S3_BUCKET_NAME}
# Region associated with API
S3_REGION=${S3_REGION}
# SSL/TLS port to connect to
S3_SERVER_PORT=${S3_SERVER_PORT}
# Protocol to used connect to S3 server - 'http' or 'https'
S3_SERVER_PROTO=${S3_SERVER_PROTO}
# CA bundle used to verify HTTPS S3 origin certificates
S3_TRUSTED_CERT_PATH=${S3_TRUSTED_CERT_PATH}
# S3 host to connect to
S3_SERVER=${S3_SERVER}
# The S3 host/path method - 'virtual', 'path' or 'default'
S3_STYLE=${S3_STYLE:-'default'}
# Name of S3 service - 's3' or 's3express'
S3_SERVICE=${S3_SERVICE:-s3}
# Flag (true/false) enabling AWS signatures debug output (default: false)
DEBUG=${DEBUG:-'false'}
# Cache size limit
PROXY_CACHE_MAX_SIZE=${PROXY_CACHE_MAX_SIZE:-'10g'}
# Cached data that are not accessed during the time get removed
PROXY_CACHE_INACTIVE=${PROXY_CACHE_INACTIVE:-'60m'}
# Request slice size
PROXY_CACHE_SLICE_SIZE=${PROXY_CACHE_SLICE_SIZE:-'1m'}
# Proxy caching time for response code 200 and 302
PROXY_CACHE_VALID_OK=${PROXY_CACHE_VALID_OK:-'1h'}
# Proxy caching time for response code 404
PROXY_CACHE_VALID_NOTFOUND=${PROXY_CACHE_VALID_NOTFOUND:-'1m'}
# Proxy caching time for response code 403
PROXY_CACHE_VALID_FORBIDDEN=${PROXY_CACHE_VALID_FORBIDDEN:-'30s'}
# Proxy cache using stale data when error occurs
PROXY_CACHE_USE_STALE=${PROXY_CACHE_USE_STALE:-'error timeout http_500 http_502 http_503 http_504'}
# Bypass the local cache when a client sends Cache-Control: no-cache (1=enabled, 0=disabled)
PROXY_CACHE_BYPASS_NO_CACHE=${PROXY_CACHE_BYPASS_NO_CACHE}
# Space-separated S3 response header fields whose caching effect is ignored
PROXY_CACHE_IGNORE_HEADERS=${PROXY_CACHE_IGNORE_HEADERS:-''}
# Enables or disables CORS for the S3 Gateway (1=enabled, 0=disabled;
# normalized from the documented true/false form above)
CORS_ENABLED=${CORS_ENABLED}
# Configure portion of URL to be removed (optional)
STRIP_LEADING_DIRECTORY_PATH=${STRIP_LEADING_DIRECTORY_PATH:-''}
# Configure portion of URL to be added to the beginning of the requested path (optional)
PREFIX_LEADING_DIRECTORY_PATH=${PREFIX_LEADING_DIRECTORY_PATH:-''}
# Flag (true/false) enabling the return of the index page for directory requests
PROVIDE_INDEX_PAGE=${PROVIDE_INDEX_PAGE:-'false'}
# Flag (true/false) enabling a 302 redirect with a / appended for possible directories
APPEND_SLASH_FOR_POSSIBLE_DIRECTORY=${APPEND_SLASH_FOR_POSSIBLE_DIRECTORY:-'false'}
# Flag (true/false) returning a 404 instead of an empty directory listing
FOUR_O_FOUR_ON_EMPTY_BUCKET=${FOUR_O_FOUR_ON_EMPTY_BUCKET:-'false'}
# Semicolon-delimited list of response header prefixes to strip (lower-case)
HEADER_PREFIXES_TO_STRIP=${HEADER_PREFIXES_TO_STRIP:-''}
# Semicolon-delimited list of response header prefixes allowed through (lower-case)
HEADER_PREFIXES_ALLOWED=${HEADER_PREFIXES_ALLOWED:-''}
# Flag (true/false) disabling the IMDSv1 fallback for EC2 credential retrieval
AWS_EC2_METADATA_V1_DISABLED=${AWS_EC2_METADATA_V1_DISABLED:-'false'}
EOF

# By enabling CORS, we also need to enable the OPTIONS method which
# is not normally used as part of the gateway. The following variable
# defines the set of acceptable headers.
set +o nounset   # don't abort on unbound variable
if [ "${CORS_ENABLED}" == "1" ]; then
    cat >> "/etc/nginx/environment" << EOF
LIMIT_METHODS_TO="GET HEAD OPTIONS"
LIMIT_METHODS_TO_CSV="GET, HEAD, OPTIONS"
EOF
else
    cat >> "/etc/nginx/environment" << EOF
LIMIT_METHODS_TO="GET HEAD"
LIMIT_METHODS_TO_CSV="GET, HEAD"
EOF
fi

# S3_UPSTREAM and S3_HOST_HEADER are computed from S3_STYLE before the
# settings banner above so the logged origin matches the effective values.
cat >> "/etc/nginx/environment" << EOF
S3_UPSTREAM="${S3_UPSTREAM}"
S3_HOST_HEADER="${S3_HOST_HEADER}"
EOF

set -o nounset   # abort on unbound variable


# CORS related variable setup
if [ -z "${CORS_ALLOWED_ORIGIN+x}" ]; then
CORS_ALLOWED_ORIGIN="*"
fi

if [ "${CORS_ALLOW_PRIVATE_NETWORK_ACCESS:-}" != "true" ] && [ "${CORS_ALLOW_PRIVATE_NETWORK_ACCESS:-}" != "false" ]; then
  CORS_ALLOW_PRIVATE_NETWORK_ACCESS=""
fi


cat >> "/etc/nginx/environment" << EOF
CORS_ALLOWED_ORIGIN=${CORS_ALLOWED_ORIGIN}
CORS_ALLOW_PRIVATE_NETWORK_ACCESS=${CORS_ALLOW_PRIVATE_NETWORK_ACCESS}
EOF

# Only include these env vars if we are not using a instance profile credential
# to obtain S3 permissions.
if [ $uses_iam_creds -eq 0 ]; then
  # Write whichever form of each credential was supplied. The file form is
  # checked first, and by value rather than with `-v`: an env-file line with no
  # value leaves the direct variable set but empty, which the validation above
  # deliberately accepts and the njs modules read as "not configured". Keying
  # off `-v` there would emit a lone `AWS_ACCESS_KEY_ID=` line and drop the
  # path, leaving the gateway with no credentials at all.
  if [ -n "${AWS_ACCESS_KEY_ID_FILE:-}" ]; then
    cat >> "/etc/nginx/environment" << EOF
# File holding the AWS Access key
AWS_ACCESS_KEY_ID_FILE=${AWS_ACCESS_KEY_ID_FILE}
EOF
  else
    cat >> "/etc/nginx/environment" << EOF
# AWS Access key
AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
EOF
  fi
  if [ -n "${AWS_SECRET_ACCESS_KEY_FILE:-}" ]; then
    cat >> "/etc/nginx/environment" << EOF
# File holding the AWS Secret access key
AWS_SECRET_ACCESS_KEY_FILE=${AWS_SECRET_ACCESS_KEY_FILE}
EOF
  else
    cat >> "/etc/nginx/environment" << EOF
# AWS Secret access key
AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
EOF
  fi
  if [ -n "${AWS_SESSION_TOKEN_FILE:-}" ]; then
    cat >> "/etc/nginx/environment" << EOF
# File holding the AWS Session Token
AWS_SESSION_TOKEN_FILE=${AWS_SESSION_TOKEN_FILE}
EOF
  elif [[ -v AWS_SESSION_TOKEN ]]; then
    cat >> "/etc/nginx/environment" << EOF
# AWS Session Token
AWS_SESSION_TOKEN=${AWS_SESSION_TOKEN}
EOF
  fi
fi

set +o nounset   # don't abort on unbound variable
if [ -z ${DNS_RESOLVERS+x} ]; then
  cat >> "/etc/default/nginx" << EOF
# DNS resolvers (separated by single spaces) to configure NGINX with
DNS_RESOLVERS=${DNS_RESOLVERS}
EOF
fi
set -o nounset   # abort on unbound variable

# Make sure that only the root user can access the environment variables file
chown root:root /etc/nginx/environment
chmod og-rwx /etc/nginx/environment

cat > /usr/local/bin/template_nginx_config.sh << 'EOF'
#!/usr/bin/env bash

ME=$(basename $0)

auto_envsubst() {
  local template_dir="${NGINX_ENVSUBST_TEMPLATE_DIR:-/etc/nginx/templates}"
  local suffix="${NGINX_ENVSUBST_TEMPLATE_SUFFIX:-.template}"
  local output_dir="${NGINX_ENVSUBST_OUTPUT_DIR:-/etc/nginx/conf.d}"

  local template defined_envs relative_path output_path subdir
  defined_envs=$(printf '${%s} ' $(env | cut -d= -f1))
  [ -d "$template_dir" ] || return 0
  if [ ! -w "$output_dir" ]; then
    echo "$ME: ERROR: $template_dir exists, but $output_dir is not writable"
    return 0
  fi
  find "$template_dir" -follow -type f -name "*$suffix" -print | while read -r template; do
    relative_path="${template#$template_dir/}"
    output_path="$output_dir/${relative_path%$suffix}"
    subdir=$(dirname "$relative_path")
    # create a subdirectory where the template file exists
    mkdir -p "$output_dir/$subdir"
    echo "$ME: Running envsubst on $template to $output_path"
    envsubst "$defined_envs" < "$template" > "$output_path"
  done
}

enable_s3_proxy_ssl() {
  local s3_proxy_ssl_conf="/etc/nginx/conf.d/gateway/s3_proxy_ssl.conf"

  [ "${S3_SERVER_PROTO}" = "https" ] || return 0

  # S3_TRUSTED_CERT_PATH syntax (absolute path, conservative character set)
  # was validated at install time before being written to
  # /etc/nginx/environment; only the file's presence can change between that
  # check and this apply step.
  if [ ! -f "${S3_TRUSTED_CERT_PATH}" ]; then
    echo "S3_TRUSTED_CERT_PATH environment variable error: no file found at the path: ${S3_TRUSTED_CERT_PATH}" >&2
    return 1
  fi

  # proxy_ssl_verify_depth bounds the number of untrusted intermediates
  # rather than trust itself, and the nginx default of 1 rejects
  # otherwise-valid chains carrying two or more intermediate CAs.
  cat >> "${s3_proxy_ssl_conf}" <<CONF
proxy_ssl_verify on;
proxy_ssl_verify_depth 5;
proxy_ssl_trusted_certificate ${S3_TRUSTED_CERT_PATH};
CONF
}

apply_proxy_ignore_headers() {
  local proxy_ignore_headers_conf="/etc/nginx/conf.d/gateway/proxy_ignore_headers.conf"

  # proxy_ignore_headers requires at least one field name, so the directive
  # has to be omitted entirely rather than rendered with an empty value.
  [ -n "${PROXY_CACHE_IGNORE_HEADERS:-}" ] || return 0

  # PROXY_CACHE_IGNORE_HEADERS was checked against the field names nginx
  # accepts at install time before being written to /etc/nginx/environment.
  # Appending rather than overwriting is safe because auto_envsubst re-renders
  # the stub from its template on every start, just above.
  cat >> "${proxy_ignore_headers_conf}" <<CONF
proxy_ignore_headers ${PROXY_CACHE_IGNORE_HEADERS};
CONF
}

# Attempt to read DNS Resolvers from /etc/resolv.conf
if [ -z ${DNS_RESOLVERS+x} ]; then
  export DNS_RESOLVERS="$(cat /etc/resolv.conf | grep nameserver | cut -d' ' -f2 | xargs)"
fi

auto_envsubst
enable_s3_proxy_ssl
apply_proxy_ignore_headers
EOF
chmod +x /usr/local/bin/template_nginx_config.sh

echo "▶ Reconfiguring systemd for S3 Gateway"
mkdir -p /etc/systemd/system/nginx.service.d
cat > /etc/systemd/system/nginx.service.d/override.conf << 'EOF'
[Service]
EnvironmentFile=/etc/nginx/environment
ExecStartPre=/usr/local/bin/template_nginx_config.sh
EOF
systemctl daemon-reload

echo "▶ Creating NGINX configuration for S3 Gateway"
mkdir -p /etc/nginx/include
mkdir -p /etc/nginx/conf.d/gateway
mkdir -p /etc/nginx/templates/gateway

function download() {
  wget --quiet --output-document="$2" "https://raw.githubusercontent.com/nginxinc/nginx-s3-gateway/${branch}/$1"
}

if [ ! -f /etc/nginx/nginx.conf.orig ]; then
  mv /etc/nginx/nginx.conf /etc/nginx/nginx.conf.orig
fi

if [ ! -f /etc/nginx/conf.d/default.conf.orig ]; then
  mv /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.orig
fi

cat > /etc/nginx/nginx.conf << 'EOF'
user  nginx;
worker_processes  auto;

error_log  /var/log/nginx/error.log notice;
pid        /var/run/nginx.pid;

# NJS module used for implementing S3 authentication
load_module modules/ngx_http_js_module.so;
load_module modules/ngx_http_xslt_filter_module.so;

# Preserve S3 environment variables for worker threads
EOF

# Only include these env vars if we are not using a instance profile credential
# to obtain S3 permissions.
if [ $uses_iam_creds -eq 0 ]; then
  # Must agree with the form written to /etc/nginx/environment above, and for
  # the same reason: a set-but-empty AWS_ACCESS_KEY_ID would otherwise select
  # `env AWS_ACCESS_KEY_ID;` and strip the _FILE variable that actually holds
  # the path from the worker processes.
  for name in "AWS_ACCESS_KEY_ID" "AWS_SECRET_ACCESS_KEY"; do
    file_name="${name}_FILE"
    if [ -n "${!file_name:-}" ]; then
      echo "env ${file_name};" >> "/etc/nginx/nginx.conf"
    else
      echo "env ${name};" >> "/etc/nginx/nginx.conf"
    fi
  done
  if [ -n "${AWS_SESSION_TOKEN_FILE:-}" ]; then
    cat >> "/etc/nginx/nginx.conf" << EOF
env AWS_SESSION_TOKEN_FILE;
EOF
  elif [[ -v AWS_SESSION_TOKEN ]]; then
    cat >> "/etc/nginx/nginx.conf" << EOF
env AWS_SESSION_TOKEN;
EOF
  fi
fi

# Keep this list in sync with the env directives in
# common/etc/nginx/nginx.conf - a variable missing here is stripped from the
# nginx worker processes and becomes invisible to the njs modules, silently
# disabling the option it controls.
cat >> /etc/nginx/nginx.conf << 'EOF'
env AWS_CONTAINER_CREDENTIALS_RELATIVE_URI;
env AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE;
env AWS_ROLE_ARN;
env AWS_ROLE_SESSION_NAME;
env AWS_STS_REGIONAL_ENDPOINTS;
env STS_ENDPOINT;
env AWS_REGION;
env AWS_WEB_IDENTITY_TOKEN_FILE;
env AWS_EC2_METADATA_V1_DISABLED;
env S3_BUCKET_NAME;
env S3_SERVER;
env S3_SERVER_PORT;
env S3_SERVER_PROTO;
env S3_REGION;
env AWS_SIGS_VERSION;
env DEBUG;
env S3_STYLE;
env S3_SERVICE;
env ALLOW_DIRECTORY_LIST;
env PROVIDE_INDEX_PAGE;
env APPEND_SLASH_FOR_POSSIBLE_DIRECTORY;
env DIRECTORY_LISTING_PATH_PREFIX;
env PROXY_CACHE_MAX_SIZE;
env PROXY_CACHE_INACTIVE;
env PROXY_CACHE_SLICE_SIZE;
env PROXY_CACHE_VALID_OK;
env PROXY_CACHE_VALID_NOTFOUND;
env PROXY_CACHE_VALID_FORBIDDEN;
env PROXY_CACHE_USE_STALE;
env PROXY_CACHE_BYPASS_NO_CACHE;
env PROXY_CACHE_IGNORE_HEADERS;
env HEADER_PREFIXES_TO_STRIP;
env HEADER_PREFIXES_ALLOWED;
env FOUR_O_FOUR_ON_EMPTY_BUCKET;
# STRIP/PREFIX_LEADING_DIRECTORY_PATH are deliberately not whitelisted, for
# parity with the container image: njs must only see these through nginx
# variables, never process.env.

events {
    worker_connections  1024;
}


http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;

    sendfile        on;
    #tcp_nopush     on;

    keepalive_timeout  65;

    #gzip  on;

    include /etc/nginx/conf.d/*.conf;
}
EOF

download "common/etc/nginx/include/listing.xsl" "/etc/nginx/include/listing.xsl"
download "common/etc/nginx/include/awscredentials.js" "/etc/nginx/include/awscredentials.js"
download "common/etc/nginx/include/awssig2.js" "/etc/nginx/include/awssig2.js"
download "common/etc/nginx/include/awssig4.js" "/etc/nginx/include/awssig4.js"
download "common/etc/nginx/include/s3gateway.js" "/etc/nginx/include/s3gateway.js"
download "common/etc/nginx/include/utils.js" "/etc/nginx/include/utils.js"
download "common/etc/nginx/templates/default.conf.template" "/etc/nginx/templates/default.conf.template"
download "common/etc/nginx/templates/cache.conf.template" "/etc/nginx/templates/cache.conf.template"
download "common/etc/nginx/templates/gateway/v2_headers.conf.template" "/etc/nginx/templates/gateway/v2_headers.conf.template"
download "common/etc/nginx/templates/gateway/v2_js_vars.conf.template" "/etc/nginx/templates/gateway/v2_js_vars.conf.template"
download "common/etc/nginx/templates/gateway/v4_headers.conf.template" "/etc/nginx/templates/gateway/v4_headers.conf.template"
download "common/etc/nginx/templates/gateway/v4_js_vars.conf.template" "/etc/nginx/templates/gateway/v4_js_vars.conf.template"
download "common/etc/nginx/templates/gateway/cors.conf.template" "/etc/nginx/templates/gateway/cors.conf.template"
download "common/etc/nginx/templates/gateway/js_fetch_trusted_certificate.conf.template" "/etc/nginx/templates/gateway/js_fetch_trusted_certificate.conf.template"
download "common/etc/nginx/templates/gateway/s3_proxy_ssl.conf.template" "/etc/nginx/templates/gateway/s3_proxy_ssl.conf.template"
download "common/etc/nginx/templates/gateway/proxy_ignore_headers.conf.template" "/etc/nginx/templates/gateway/proxy_ignore_headers.conf.template"
download "common/etc/nginx/templates/gateway/s3listing_location.conf.template" "/etc/nginx/templates/gateway/s3listing_location.conf.template"
download "common/etc/nginx/templates/gateway/s3_location.conf.template" "/etc/nginx/templates/gateway/s3_location.conf.template"
download "common/etc/nginx/templates/gateway/s3_server.conf.template" "/etc/nginx/templates/gateway/s3_server.conf.template"
download "common/etc/nginx/templates/gateway/s3_location_common.conf.template" "/etc/nginx/templates/gateway/s3_location_common.conf.template"
download "oss/etc/nginx/templates/upstreams.conf.template" "/etc/nginx/templates/upstreams.conf.template"
download "oss/etc/nginx/templates/gateway/server_variables.conf.template" "/etc/nginx/templates/gateway/server_variables.conf.template"
download "oss/etc/nginx/conf.d/instance_credential_cache.conf" "/etc/nginx/conf.d/instance_credential_cache.conf"

# Older standalone installs cached temporary AWS credentials on disk,
# resolving the path exactly as the deleted _credentialsTempFile() did: an
# explicit AWS_CREDENTIALS_TEMP_FILE, else ${TMPDIR}/credentials.json, else
# /tmp/credentials.json. Current installs keep credentials in shared memory,
# so remove a leftover file at every path the old code could have written.
for legacy_credentials_file in \
    ${AWS_CREDENTIALS_TEMP_FILE:+"${AWS_CREDENTIALS_TEMP_FILE}"} \
    ${TMPDIR:+"${TMPDIR}/credentials.json"} \
    /tmp/credentials.json; do
  if [ -f "${legacy_credentials_file}" ] || [ -L "${legacy_credentials_file}" ]; then
    rm -f "${legacy_credentials_file}"
  fi
done

echo "▶ Creating directory for proxy cache"
mkdir -p /var/cache/nginx/s3_proxy
chown nginx:nginx /var/cache/nginx/s3_proxy

echo "▶ Starting NGINX"
systemctl start nginx

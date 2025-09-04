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
  required+=("AWS_ACCESS_KEY_ID" "AWS_SECRET_ACCESS_KEY")
  uses_iam_creds=0
fi

if [[ -v AWS_SESSION_TOKEN ]]; then
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

if [ "${AWS_SIGS_VERSION}" != "2" ] && [ "${AWS_SIGS_VERSION}" != "4" ]; then
  >&2 echo "AWS_SIGS_VERSION contains an invalid value (${AWS_SIGS_VERSION}). Valid values: 2, 4"
  failed=1
fi

if [ $failed -gt 0 ]; then
  exit 1
fi

if [ "${1}" == "" ]; then
  branch="master"
else
  branch="${1}"
fi
echo "Installing using github '${branch}' branch"


echo "S3 Backend Environment"
echo "Access Key ID: ${AWS_ACCESS_KEY_ID}"
echo "Origin: ${S3_SERVER_PROTO}://${S3_BUCKET_NAME}.${S3_SERVER}:${S3_SERVER_PORT}"
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
# Enables or disables CORS for the S3 Gateway (true=enabled, false=disabled)
CORS_ENABLED=${CORS_ENABLED:-'false'}
# Configure portion of URL to be removed (optional)
STRIP_LEADING_DIRECTORY_PATH=${STRIP_LEADING_DIRECTORY_PATH:-''}
# Configure portion of URL to be added to the beginning of the requested path (optional)
PREFIX_LEADING_DIRECTORY_PATH=${PREFIX_LEADING_DIRECTORY_PATH:-''}
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

# This is the primary logic to determine the s3 host used for the
# upstream (the actual proxying action) as well as the `Host` header
#
# It is currently slightly more complex than necessary because we are transitioning
# to a new logic which is defined by "virtual-v2". "virtual-v2" is the recommended setting
# for all deployments.

# S3_UPSTREAM needs the port specified. The port must
# correspond to https/http in the proxy_pass directive.
if [ "${S3_STYLE}" == "virtual-v2" ]; then
  cat >> "/etc/nginx/environment" << EOF
S3_UPSTREAM="${S3_BUCKET_NAME}.${S3_SERVER}:${S3_SERVER_PORT}"
S3_HOST_HEADER="${S3_BUCKET_NAME}.${S3_SERVER}:${S3_SERVER_PORT}"
EOF
elif [ "${S3_STYLE}" == "path" ]; then
  cat >> "/etc/nginx/environment" << EOF
S3_UPSTREAM="${S3_SERVER}:${S3_SERVER_PORT}"
S3_HOST_HEADER="${S3_SERVER}:${S3_SERVER_PORT}"
EOF
else
  cat >> "/etc/nginx/environment" << EOF
S3_UPSTREAM="${S3_SERVER}:${S3_SERVER_PORT}"
S3_HOST_HEADER="${S3_BUCKET_NAME}.${S3_SERVER}"
EOF
fi

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
  cat >> "/etc/nginx/environment" << EOF
# AWS Access key
AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
# AWS Secret access key
AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
EOF
  if [[ -v AWS_SESSION_TOKEN ]]; then
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

# Attempt to read DNS Resolvers from /etc/resolv.conf
if [ -z ${DNS_RESOLVERS+x} ]; then
  export DNS_RESOLVERS="$(cat /etc/resolv.conf | grep nameserver | cut -d' ' -f2 | xargs)"
fi

auto_envsubst
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
  cat >> "/etc/nginx/nginx.conf" << EOF
env AWS_ACCESS_KEY_ID;
env AWS_SECRET_ACCESS_KEY;
EOF
  if [[ -v AWS_SESSION_TOKEN ]]; then
    cat >> "/etc/nginx/nginx.conf" << EOF
env AWS_SESSION_TOKEN;
EOF
  fi
fi

cat >> /etc/nginx/nginx.conf << 'EOF'
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
download "common/etc/nginx/templates/gateway/s3listing_location.conf.template" "/etc/nginx/templates/gateway/s3listing_location.conf.template"
download "common/etc/nginx/templates/gateway/s3_location.conf.template" "/etc/nginx/templates/gateway/s3_location.conf.template"
download "common/etc/nginx/templates/gateway/s3_server.conf.template" "/etc/nginx/templates/gateway/s3_server.conf.template"
download "common/etc/nginx/templates/gateway/s3_location_common.conf.template" "/etc/nginx/templates/gateway/s3_location_common.conf.template"
download "oss/etc/nginx/templates/upstreams.conf.template" "/etc/nginx/templates/upstreams.conf.template"
download "oss/etc/nginx/conf.d/gateway/server_variables.conf" "/etc/nginx/conf.d/gateway/server_variables.conf"

echo "▶ Creating directory for proxy cache"
mkdir -p /var/cache/nginx/s3_proxy
chown nginx:nginx /var/cache/nginx/s3_proxy

echo "▶ Starting NGINX"
systemctl start nginx

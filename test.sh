#!/usr/bin/env bash

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

set -o errexit   # abort on nonzero exit status
set -o pipefail  # don't hide errors within pipes

### Overview
# This script does three things:
# 1. Sets up the test environment using docker-compose and creates test data
# 2. Runs unit tests in the ./test/unit directory which are written in Javascript
# 3. Runs integration tests in ./test/integration which are written in bash
#
# The integration test runner uses a series of flags to test different configuration
# values. See the function definition for `integration_test` in this file
# for details on the parameters and their allowed values.

nginx_server_proto="http"
nginx_server_host="localhost"
nginx_server_port="8989"

test_server="${nginx_server_proto}://${nginx_server_host}:${nginx_server_port}"
test_fail_exit_code=2
no_dep_exit_code=3
build_dep_exit_code=4

script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
test_dir="${script_dir}/test"
test_compose_config="${test_dir}/docker-compose.yaml"
test_compose_project="ngt"

minio_server="http://localhost:9090"
minio_user="AKIAIOSFODNN7EXAMPLE"
minio_passwd="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
minio_name="${test_compose_project}_minio_1"
minio_bucket="bucket-1"
CI=${CI:="false"}

is_windows="0"
if [ -z "${OS}" ] && [ "${OS}" == "Windows_NT" ]; then
  is_windows="1"
elif command -v uname > /dev/null; then
  uname_output="$(uname -s)"
  if [[ "${uname_output}" == *"_NT-"* ]]; then
    is_windows="1"
  fi
fi

p() {
  printf "\033[34;1m▶\033[0m "
  echo "$1"
}

e() {
  >&2 echo "$1"
}

usage() { e "Usage: $0 [--latest-njs <default:false>] [--unprivileged <default:false>] [--type <default:oss|plus>" 1>&2; exit 1; }

for arg in "$@"; do
  shift
  case "$arg" in
    '--help')           set -- "$@" '-h'   ;;
    '--latest-njs')     set -- "$@" '-j'   ;;
    '--unprivileged')   set -- "$@" '-u'   ;;
    '--type')           set -- "$@" '-t'   ;;
    *)                  set -- "$@" "$arg" ;;
  esac
done

while getopts "hjut:" arg; do
    case "${arg}" in
        j)
            njs_latest="1"
            ;;
        u)
            unprivileged="1"
            ;;
        t)
            nginx_type="${OPTARG}"
            ;;
        *)
            usage
            ;;
    esac
done
shift $((OPTIND-1))

startup_message=""

if [ -z "${nginx_type}" ]; then
  nginx_type="oss"
  startup_message="Starting NGINX ${nginx_type} (default)"
elif ! { [ ${nginx_type} == "oss" ] || [ ${nginx_type} == "plus" ]; }; then
    e "Invalid NGINX type: ${nginx_type} - must be either 'oss' or 'plus'"
    usage
else
  startup_message="Starting NGINX ${nginx_type}"
fi

if [ -z "${njs_latest}" ]; then
  njs_latest="0"
  startup_message="${startup_message} with the release NJS module (default)"
elif [ ${njs_latest} -eq 1 ]; then
  startup_message="${startup_message} with the latest NJS module"
else
  startup_message="${startup_message} with the release NJS module"
fi

if [ -z "${unprivileged}" ]; then
  unprivileged="0"
  startup_message="${startup_message} in privileged mode (default)"
elif [ ${unprivileged} -eq 1 ]; then
  startup_message="${startup_message} in unprivileged mode"
else
  startup_message="${startup_message} in privileged mode"
fi

e "${startup_message}"

set -o nounset   # abort on unbound variable

docker_cmd="$(command -v docker || true)"
if ! [ -x "${docker_cmd}" ]; then
  e "required dependency not found: docker not found in the path or not executable"
  exit ${no_dep_exit_code}
fi

if docker compose > /dev/null; then
  docker_compose_cmd="docker compose"
elif command -v docker-compose > /dev/null; then
  docker_compose_cmd="docker-compose"
else
  e "required dependency not found: docker-compose not found in the path or not executable"
  exit ${no_dep_exit_code}
fi
e "Using Docker Compose command: ${docker_compose_cmd}"

curl_cmd="$(command -v curl || true)"
if ! [ -x "${curl_cmd}" ]; then
  e "required dependency not found: curl not found in the path or not executable"
  exit ${no_dep_exit_code}
fi

if command -v mc > /dev/null; then
  mc_cmd="$(command -v mc)"
elif [ -x "${script_dir}/.bin/mc" ]; then
  mc_cmd="${script_dir}/.bin/mc"
else
  e "required dependency not found: mc not found in the path or not executable"
  exit ${no_dep_exit_code}
fi
e "Using MinIO Client: ${mc_cmd}"

if ! [ -x "${mc_cmd}" ]; then
  e "required dependency not found: mc not found in the path or not executable"
  exit ${no_dep_exit_code}
fi

wait_for_it_cmd="$(command -v wait-for-it || true)"
if [ -x "${wait_for_it_cmd}" ]; then
  wait_for_it_installed=1
else
  e "wait-for-it command not available, consider installing to prevent race conditions"
  wait_for_it_installed=0
fi

if [ "${nginx_type}" = "plus" ]; then
  if [ ! -f "./plus/etc/ssl/nginx/nginx-repo.crt" ]; then
    e "NGINX Plus certificate file not found: $(pwd)/plus/etc/ssl/nginx/nginx-repo.crt"
    exit ${no_dep_exit_code}
  fi

    if [ ! -f "./plus/etc/ssl/nginx/nginx-repo.key" ]; then
    e "NGINX Plus key file not found: $(pwd)/plus/etc/ssl/nginx/nginx-repo.key"
    exit ${no_dep_exit_code}
  fi
fi

compose() {
  # Hint to docker-compose the internal port to map for the container
  if [ ${unprivileged} -eq 1 ]; then
    export NGINX_INTERNAL_PORT=8080
  else
    export NGINX_INTERNAL_PORT=80
  fi

  if [ "${nginx_type}" == "plus" ]; then
    if [ -f /etc/nginx/license.jwt ]; then
      NGINX_LICENSE_JWT="$(cat /etc/nginx/license.jwt)"
    elif [ -f license.jwt ]; then
      NGINX_LICENSE_JWT="$(cat license.jwt)"
    else
      e "NGINX Plus license file not found: /etc/nginx/license.jwt or $(pwd)/license.jwt"
      exit ${build_dep_exit_code}
    fi

  else
      NGINX_LICENSE_JWT=""
  fi

  export NGINX_LICENSE_JWT

  ${docker_compose_cmd} -f "${test_compose_config}" -p "${test_compose_project}" "$@"
}

integration_test_data() {

  # Write problematic files to disk if we are not on Windows. Originally,
  # these files were checked in, but that prevented the git repository from
  # being cloned on Windows machines.
  if [ "$is_windows" == "0" ]; then
    echo "Writing weird filename: ${test_dir}/data/bucket-1/a/%@!*()=$#^&|.txt"
    echo 'We are but selling water next to a river.' > "${test_dir}"'/data/bucket-1/a/%@!*()=$#^&|.txt'
  fi

  p "Starting Docker Compose Environment"
  # COMPOSE_COMPATIBILITY=true Supports older style compose filenames with _ vs -
  COMPOSE_COMPATIBILITY=true compose up -d

  if [ "${wait_for_it_installed}" ]; then
    # Hit minio's health check end point to see if it has started up
    for (( i=1; i<=3; i++ ))
    do
      echo "Querying minio server to see if it is ready"
      minio_is_up="$(${curl_cmd} -s -o /dev/null -w '%{http_code}' "${minio_server}"/minio/health/cluster)"
      if [ "${minio_is_up}" = "200" ]; then
        break
      else
        sleep 2
      fi
    done
  fi

  p "Adding test data to container"
  "${mc_cmd}" alias set "$minio_name" "$minio_server" "$minio_user" "$minio_passwd"
  "${mc_cmd}" mb "$minio_name/$minio_bucket"
  echo "Copying contents of ${test_dir}/data/$minio_bucket to Docker container $minio_name"
  for file in "${test_dir}/data/$minio_bucket"/*; do
    "${mc_cmd}" cp -r "${file}" "$minio_name/$minio_bucket"
  done
  echo "Docker diff output:"
  "${docker_cmd}" diff "$minio_name"
}

integration_test() {
  printf "\033[34;1m▶\033[0m"
  printf "\e[1m Integration test suite for v%s signatures\e[22m\n" "$1"
  printf "\033[34;1m▶\033[0m"
  printf "\e[1m Integration test suite with ALLOW_DIRECTORY_LIST=%s\e[22m\n" "$2"
  printf "\033[34;1m▶\033[0m"
  printf "\e[1m Integration test suite with PROVIDE_INDEX_PAGE=%s\e[22m\n" "$3"
  printf "\033[34;1m▶\033[0m"
  printf "\e[1m Integration test suite with APPEND_SLASH_FOR_POSSIBLE_DIRECTORY=%s\e[22m\n" "$4"
  printf "\033[34;1m▶\033[0m"
  printf "\e[1m Integration test suite with STRIP_LEADING_DIRECTORY_PATH=%s\e[22m\n" "$5"
  printf "\033[34;1m▶\033[0m"
  printf "\e[1m Integration test suite with PREFIX_LEADING_DIRECTORY_PATH=%s\e[22m\n" "$6"


  p "Starting Docker Compose Environment"
  # COMPOSE_COMPATIBILITY=true Supports older style compose filenames with _ vs -
  COMPOSE_COMPATIBILITY=true AWS_SIGS_VERSION=$1 ALLOW_DIRECTORY_LIST=$2 PROVIDE_INDEX_PAGE=$3 APPEND_SLASH_FOR_POSSIBLE_DIRECTORY=$4 STRIP_LEADING_DIRECTORY_PATH=$5 PREFIX_LEADING_DIRECTORY_PATH=$6 compose up -d

  if [ "${wait_for_it_installed}" ]; then
    if [ -x "${wait_for_it_cmd}" ]; then
      "${wait_for_it_cmd}" -h "${nginx_server_host}" -p "${nginx_server_port}"
    fi
  fi

  p "Starting HTTP API tests (v$1 signatures)"
  echo "  test/integration/test_api.sh \"$test_server\" \"$test_dir\" $1 $2 $3 $4 $5 $6"
  bash "${test_dir}/integration/test_api.sh" "${test_server}" "${test_dir}" "$1" "$2" "$3" "$4" "$5" "$6";

  # We check to see if NGINX is in fact using the correct version of AWS
  # signatures as it was configured to do.
  sig_versions_found_count=$(compose logs nginx-s3-gateway | grep -c "AWS Signatures Version: v$1\|AWS v$1 Auth")

  if [ "${sig_versions_found_count}" -lt 3 ]; then
    e "NGINX was not detected as using the correct signatures version - examine logs"
    compose logs nginx-s3-gateway
    exit "$test_fail_exit_code"
  fi
}

finish() {
  result=$?

  if [ $result -ne 0 ]; then
    e "Error running tests - outputting container logs"
    compose logs
  fi

  p "Cleaning up Docker compose environment"
  compose stop
  compose rm -f -v
  "${mc_cmd}" alias rm "$minio_name"

  exit ${result}
}
trap finish EXIT ERR SIGTERM SIGINT

### BUILD

if [ "$CI" = "true" ]; then
    echo "Skipping docker image build due to CI=true"
else
  p "Building NGINX S3 gateway Docker image"
  if [ "${nginx_type}" = "plus" ]; then
    if docker buildx > /dev/null 2>&1; then
      p "Building using BuildKit"
      export DOCKER_BUILDKIT=1
      docker buildx build -f "Dockerfile.${nginx_type}" \
        --secret id=nginx-crt,src=plus/etc/ssl/nginx/nginx-repo.crt \
        --secret id=nginx-key,src=plus/etc/ssl/nginx/nginx-repo.key \
        --tag nginx-s3-gateway --tag "nginx-s3-gateway:${nginx_type}" .
    else
      e "Only BuildKit builds are supported with NGINX Plus image"
      exit ${build_dep_exit_code}
    fi
  else
    docker build -f "Dockerfile.${nginx_type}" \
      --tag nginx-s3-gateway --tag "nginx-s3-gateway:${nginx_type}" .
  fi

  if [ ${njs_latest} -eq 1 ]; then
    p "Layering in latest NJS build"
    docker build -f Dockerfile.latest-njs \
      --tag nginx-s3-gateway --tag nginx-s3-gateway:latest-njs-${nginx_type} .
  fi

  if [ ${unprivileged} -eq 1 ]; then
    p "Layering in unprivileged build"
    docker build -f Dockerfile.unprivileged \
      --tag nginx-s3-gateway --tag nginx-s3-gateway:unprivileged-${nginx_type} .
  fi
fi

### UNIT TESTS

runUnitTestWithOutSessionToken() {
  test_code="$1"
  # Temporary hack while njs transitions to supporting -m in the cli tool
  if [ ${njs_latest} -eq 1 ]
    then
      #MSYS_NO_PATHCONV=1 added to resolve automatic path conversion
      # https://github.com/docker/for-win/issues/6754#issuecomment-629702199
      MSYS_NO_PATHCONV=1 "${docker_cmd}" run  \
        --rm                                  \
        -v "$(pwd)/test/unit:/var/tmp"        \
        --workdir /var/tmp                    \
        -e "DEBUG=true"                       \
        -e "S3_STYLE=virtual-v2"                 \
        -e "S3_SERVICE=s3"                    \
        -e "AWS_ACCESS_KEY_ID=unit_test"      \
        -e "AWS_SECRET_ACCESS_KEY=unit_test"  \
        -e "S3_BUCKET_NAME=unit_test"         \
        -e "S3_SERVER=unit_test"              \
        -e "S3_SERVER_PROTO=https"            \
        -e "S3_SERVER_PORT=443"               \
        -e "S3_REGION=test-1"                 \
        -e "AWS_SIGS_VERSION=4"               \
        --entrypoint /usr/bin/njs             \
        nginx-s3-gateway -m -p '/etc/nginx' /var/tmp/"${test_code}"
    else
      #MSYS_NO_PATHCONV=1 added to resolve automatic path conversion
      # https://github.com/docker/for-win/issues/6754#issuecomment-629702199
      MSYS_NO_PATHCONV=1 "${docker_cmd}" run  \
        --rm                                  \
        -v "$(pwd)/test/unit:/var/tmp"        \
        --workdir /var/tmp                    \
        -e "DEBUG=true"                       \
        -e "S3_STYLE=virtual-v2"                 \
        -e "S3_SERVICE=s3"                    \
        -e "AWS_ACCESS_KEY_ID=unit_test"      \
        -e "AWS_SECRET_ACCESS_KEY=unit_test"  \
        -e "S3_BUCKET_NAME=unit_test"         \
        -e "S3_SERVER=unit_test"              \
        -e "S3_SERVER_PROTO=https"            \
        -e "S3_SERVER_PORT=443"               \
        -e "S3_REGION=test-1"                 \
        -e "AWS_SIGS_VERSION=4"               \
        --entrypoint /usr/bin/njs             \
        nginx-s3-gateway -t module -p '/etc/nginx' /var/tmp/"${test_code}"
  fi
}

runUnitTestWithSessionToken() {
  test_code="$1"
  # Temporary hack while njs transitions to supporting -m in the cli tool
  if [ ${njs_latest} -eq 1 ]
    then
      #MSYS_NO_PATHCONV=1 added to resolve automatic path conversion
      # https://github.com/docker/for-win/issues/6754#issuecomment-629702199
      MSYS_NO_PATHCONV=1 "${docker_cmd}" run  \
        --rm                                  \
        -v "$(pwd)/test/unit:/var/tmp"        \
        --workdir /var/tmp                    \
        -e "DEBUG=true"                       \
        -e "S3_STYLE=virtual-v2"                 \
        -e "S3_SERVICE=s3"                    \
        -e "AWS_ACCESS_KEY_ID=unit_test"      \
        -e "AWS_SECRET_ACCESS_KEY=unit_test"  \
        -e "AWS_SESSION_TOKEN=unit_test"      \
        -e "S3_BUCKET_NAME=unit_test"         \
        -e "S3_SERVER=unit_test"              \
        -e "S3_SERVER_PROTO=https"            \
        -e "S3_SERVER_PORT=443"               \
        -e "S3_REGION=test-1"                 \
        -e "AWS_SIGS_VERSION=4"               \
        --entrypoint /usr/bin/njs             \
        nginx-s3-gateway -m -p '/etc/nginx' /var/tmp/"${test_code}"
    else
      #MSYS_NO_PATHCONV=1 added to resolve automatic path conversion
      # https://github.com/docker/for-win/issues/6754#issuecomment-629702199
      MSYS_NO_PATHCONV=1 "${docker_cmd}" run  \
        --rm                                  \
        -v "$(pwd)/test/unit:/var/tmp"        \
        --workdir /var/tmp                    \
        -e "DEBUG=true"                       \
        -e "S3_STYLE=virtual-v2"                 \
        -e "S3_SERVICE=s3"                    \
        -e "AWS_ACCESS_KEY_ID=unit_test"      \
        -e "AWS_SECRET_ACCESS_KEY=unit_test"  \
        -e "AWS_SESSION_TOKEN=unit_test"      \
        -e "S3_BUCKET_NAME=unit_test"         \
        -e "S3_SERVER=unit_test"              \
        -e "S3_SERVER_PROTO=https"            \
        -e "S3_SERVER_PORT=443"               \
        -e "S3_REGION=test-1"                 \
        -e "AWS_SIGS_VERSION=4"               \
        --entrypoint /usr/bin/njs             \
        nginx-s3-gateway -t module -p '/etc/nginx' /var/tmp/"${test_code}"
  fi
}

p "Running unit tests for utils"
runUnitTestWithSessionToken "utils_test.js"

p "Running unit tests with an access key ID and a secret key in Docker image"
runUnitTestWithOutSessionToken "awscredentials_test.js"
runUnitTestWithOutSessionToken "awssig2_test.js"
runUnitTestWithOutSessionToken "awssig4_test.js"
runUnitTestWithOutSessionToken "s3gateway_test.js"

p "Running unit tests with an session token in Docker image"
runUnitTestWithSessionToken "awscredentials_test.js"
runUnitTestWithSessionToken "awssig2_test.js"
runUnitTestWithSessionToken "awssig4_test.js"
runUnitTestWithSessionToken "s3gateway_test.js"

### INTEGRATION TESTS
# The arguments correspond to flags given to the integration test runner
# integration_test 2 0 0 0
# AWS_SIGS_VERSION=$1 : any valid AWS Sigs version. Supported values are `2` or `4`
# ALLOW_DIRECTORY_LIST=$2 : boolean value denoted by `0` or `1`
# PROVIDE_INDEX_PAGE=$3 : boolean value denoted by `0` or `1`
# APPEND_SLASH_FOR_POSSIBLE_DIRECTORY=$4 : boolean value denoted by `0` or `1`
#
# These are various invocations of ./test/integration/test_api.sh
# where the flags represent different configurations for that single test
# file.

integration_test_data

p "Testing API with AWS Signature V2 and allow directory listing off"
integration_test 2 0 0 0 "" ""

compose stop nginx-s3-gateway # Restart with new config

p "Testing API with AWS Signature V2 and allow directory listing on"
integration_test 2 1 0 0 "" ""

compose stop nginx-s3-gateway # Restart with new config

p "Testing API with AWS Signature V2 and static site on"
integration_test 2 0 1 0 "" ""

compose stop nginx-s3-gateway # Restart with new config

p "Testing API with AWS Signature V2 and allow directory listing on and append slash and allow index"
integration_test 2 1 1 1 "" ""

compose stop nginx-s3-gateway # Restart with new config

p "Test API with AWS Signature V4 and allow directory listing off"
integration_test 4 0 0 0 "" ""

compose stop nginx-s3-gateway # Restart with new config

p "Test API with AWS Signature V4 and allow directory listing on and appending /"
integration_test 4 1 0 1 "" ""

compose stop nginx-s3-gateway # Restart with new config

p "Test API with AWS Signature V4 and static site on appending /"
integration_test 4 0 1 1 "" ""

compose stop nginx-s3-gateway # Restart with new config

p "Testing API with AWS Signature V2 and allow directory listing off and prefix stripping on"
integration_test 2 0 0 0 /my-bucket ""

compose stop nginx-s3-gateway # Restart with new config

p "Test API with AWS Signature V4 and prefix leading directory path on"
integration_test 4 0 0 0 "" "/b"

p "Test API with AWS Signature V4 and prefix leading directory path on and prefix stripping on"
integration_test 4 0 0 0 "/tostrip" "/b"

p "Testing API with AWS Signature V2 and prefix leading directory path"
integration_test 2 0 0 0 "" "/b"

p "All integration tests complete"

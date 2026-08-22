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

# Older OSS images cached temporary AWS credentials on disk, resolving the
# path exactly as the deleted _credentialsTempFile() did: an explicit
# AWS_CREDENTIALS_TEMP_FILE, else ${TMPDIR}/credentials.json, else
# /tmp/credentials.json. The current image keeps credentials in shared
# memory, so remove a leftover regular file or symlink at every path the old
# code could have written before nginx starts.
for legacy_credentials_file in \
    ${AWS_CREDENTIALS_TEMP_FILE:+"${AWS_CREDENTIALS_TEMP_FILE}"} \
    ${TMPDIR:+"${TMPDIR}/credentials.json"} \
    /tmp/credentials.json; do
  if [ -f "${legacy_credentials_file}" ] || [ -L "${legacy_credentials_file}" ]; then
    # Never abort container startup over the cleanup: with a persisted /tmp
    # the file can be owned by another uid (e.g. an unprivileged or
    # arbitrary-uid container upgrading from a root-running image), making
    # the sticky-bit unlink fail with EPERM, which `rm -f` does not suppress.
    if rm -f "${legacy_credentials_file}"; then
      echo "Removed legacy temporary credential cache ${legacy_credentials_file}"
    else
      >&2 echo "WARNING: could not remove legacy temporary credential cache ${legacy_credentials_file}; remove it manually"
    fi
  fi
done

/*
 *  Copyright 2026 F5, Inc.
 *
 *  Licensed under the Apache License, Version 2.0 (the "License");
 *  you may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 */

/**
 * Shared unit-test mock of the `instance_credential_cache` njs shared
 * dictionary that oss/etc/nginx/conf.d/instance_credential_cache.conf
 * configures in production. The njs CLI provides no `ngx.shared`, so the
 * suites that exercise credential caching install this mock on
 * `globalThis.ngx` first. Kept in one module so the suites cannot drift in
 * how they emulate the NgxSharedDict get/set contract.
 *
 * @module credential_cache_mock
 * @alias CredentialCacheMock
 */

import awscred from "include/awscredentials.js";

/**
 * Key used by awscredentials.js for the OSS shared-dictionary cache,
 * re-exported from the production module so the tests cannot drift from the
 * key production actually reads.
 * @type {string}
 */
const INSTANCE_CREDENTIAL_CACHE_KEY = awscred.INSTANCE_CREDENTIAL_CACHE_KEY;

/**
 * Builds a minimal NgxSharedDict-alike backed by a plain object: get()
 * returns undefined on a miss and set() is chainable, matching the real
 * shared-dictionary API that awscredentials.js relies on.
 *
 * @returns {object} shared-dictionary mock with get/set/clear
 */
function makeSharedCredentialCache() {
    let values = {};

    return {
        get: function(key) {
            return values[key];
        },
        set: function(key, value) {
            values[key] = value;
            return this;
        },
        clear: function() {
            values = {};
        }
    };
}

/**
 * Installs a fresh, empty credential cache mock on globalThis.ngx.shared so
 * that each test case starts without cached credentials from earlier cases.
 */
function resetSharedCredentialCache() {
    globalThis.ngx.shared = {
        instance_credential_cache: makeSharedCredentialCache()
    };
}

export default {
    INSTANCE_CREDENTIAL_CACHE_KEY,
    makeSharedCredentialCache,
    resetSharedCredentialCache
}

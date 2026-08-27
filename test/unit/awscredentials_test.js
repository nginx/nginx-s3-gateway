#!env njs

/*
 *  Copyright 2023 F5, Inc.
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

import awscred from "include/awscredentials.js";
import utils from "include/utils.js";
import credentialCacheMock from "./credential_cache_mock.js";
import fs from "fs";

globalThis.ngx = {};

/**
 * Mock credentials payload in the shape returned by the ECS and EC2 IMDS
 * credentials endpoints.
 */
const MOCK_AWS_CREDS_RESPONSE = {
    AccessKeyId: 'AN_ACCESS_KEY_ID',
    Expiration: '2017-05-17T15:09:54Z',
    RoleArn: 'TASK_ROLE_ARN',
    SecretAccessKey: 'A_SECRET_ACCESS_KEY',
    Token: 'A_SECURITY_TOKEN',
};

const IMDS_TOKEN_URL = 'http://169.254.169.254/latest/api/token';
const IMDS_SECURITY_CREDS_URL = 'http://169.254.169.254/latest/meta-data/iam/security-credentials/';

/**
 * Relative URI assigned to AWS_CONTAINER_CREDENTIALS_RELATIVE_URI by tests
 * exercising the ECS credential provider path.
 */
const ECS_CREDS_RELATIVE_URI = '/example';

/**
 * Full ECS credentials endpoint URL the module is expected to fetch: the
 * fixed ECS credential base joined with the relative URI above.
 */
const ECS_CREDS_URL = `http://169.254.170.2${ECS_CREDS_RELATIVE_URI}`;

/**
 * Key used by awscredentials.js for the OSS shared-dictionary cache.
 */
const INSTANCE_CREDENTIAL_CACHE_KEY = credentialCacheMock.INSTANCE_CREDENTIAL_CACHE_KEY;

const resetSharedCredentialCache = credentialCacheMock.resetSharedCredentialCache;

/**
 * Deletes every provider-selection env var so that each test opts into
 * exactly one credential provider path.
 */
function clearProviderEnv() {
    resetSharedCredentialCache();
    delete process.env['AWS_ACCESS_KEY_ID'];
    delete process.env['AWS_CONTAINER_CREDENTIALS_RELATIVE_URI'];
    delete process.env['AWS_WEB_IDENTITY_TOKEN_FILE'];
    delete process.env['AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE'];
}

/**
 * Builds a unique temp file path. The prefix must be unique per test so that
 * a same-millisecond run cannot collide with a file created by another test.
 */
function tempFilePath(prefix, extension) {
    const tempDir = process.env['TMPDIR'] ? process.env['TMPDIR'] : '/tmp';
    const uniqId = `${new Date().getTime()}-${Math.floor(Math.random()*101)}`;
    return `${tempDir}/${prefix}-${uniqId}${extension}`;
}

/**
 * Restores an env var to a previously saved value. Deletes the variable when
 * the saved value is undefined - assigning undefined would re-create the key
 * with an undefined value, which breaks 'in'-based presence checks.
 */
function restoreEnv(name, value) {
    if (value === undefined) {
        delete process.env[name];
    } else {
        process.env[name] = value;
    }
}

function removeIfExists(path) {
    if (fs.statSync(path, {throwIfNoEntry: false})) {
        fs.unlinkSync(path);
    }
}

/**
 * Builds a request stub whose return() throws unless the handler reports 200.
 */
function makeExpect200Request() {
    return {
        log: function(msg) {
            console.log(msg);
        },
        error: function(msg) {
            console.log(msg);
        },
        return: function(code) {
            if (code !== 200) {
                throw 'Expected 200 status code, got: ' + code;
            }
        },
    };
}

/**
 * Builds a request stub that records the status code passed to return() on
 * the supplied state object as state.returnedCode.
 */
function makeRecordingRequest(state) {
    return {
        log: function(msg) {
            console.log(msg);
        },
        error: function(msg) {
            console.log(msg);
        },
        return: function(code) {
            state.returnedCode = code;
        },
    };
}


function testReadCredentialsWithAccessSecretKeyAndSessionTokenSet() {
    printHeader('testReadCredentialsWithAccessSecretKeyAndSessionTokenSet');
    let r = {};
    process.env['AWS_ACCESS_KEY_ID'] = 'SOME_ACCESS_KEY';
    process.env['AWS_SECRET_ACCESS_KEY'] = 'SOME_SECRET_KEY';
    if ('AWS_SESSION_TOKEN' in process.env) {
        process.env['AWS_SESSION_TOKEN'] = 'SOME_SESSION_TOKEN';
    }

    try {
        var credentials = awscred.readCredentials(r);
        if (credentials.accessKeyId !== process.env['AWS_ACCESS_KEY_ID']) {
            throw 'static credentials do not match returned value [accessKeyId]';
        }
        if (credentials.secretAccessKey !== process.env['AWS_SECRET_ACCESS_KEY']) {
            throw 'static credentials do not match returned value [secretAccessKey]';
        }
        if ('AWS_SESSION_TOKEN' in process.env) {
            if (credentials.sessionToken !== process.env['AWS_SESSION_TOKEN']) {
                throw 'static credentials do not match returned value [sessionToken]';
            }
        } else {
            if (credentials.sessionToken !== null) {
                throw 'static credentials do not match returned value [sessionToken]';
            }
        }
        if (credentials.expiration !== null) {
            throw 'static credentials do not match returned value [expiration]';
        }

    } finally {
        delete process.env.AWS_ACCESS_KEY_ID;
        delete process.env.AWS_SECRET_ACCESS_KEY;
        if ('AWS_SESSION_TOKEN' in process.env) {
            delete process.env.AWS_SESSION_TOKEN;
        }
    }
}

function testReadCredentialsFromFiles() {
    printHeader('testReadCredentialsFromFiles');

    const accessKeyIdPath = tempFilePath('access-key-id', '');
    const secretAccessKeyPath = tempFilePath('secret-access-key', '');
    const sessionTokenPath = tempFilePath('session-token', '');

    const savedAccessKeyId = process.env['AWS_ACCESS_KEY_ID'];
    const savedSecretAccessKey = process.env['AWS_SECRET_ACCESS_KEY'];
    const savedSessionToken = process.env['AWS_SESSION_TOKEN'];

    /* The trailing newlines are deliberate: a secret file written by an editor
       or by `echo` ends in one, and a credential carrying it would invalidate
       every signature the gateway produces. */
    fs.writeFileSync(accessKeyIdPath, 'FILE_ACCESS_KEY\n');
    fs.writeFileSync(secretAccessKeyPath, 'FILE_SECRET_KEY\n');
    fs.writeFileSync(sessionTokenPath, 'FILE_SESSION_TOKEN\n');

    delete process.env['AWS_ACCESS_KEY_ID'];
    delete process.env['AWS_SECRET_ACCESS_KEY'];
    delete process.env['AWS_SESSION_TOKEN'];
    process.env['AWS_ACCESS_KEY_ID_FILE'] = accessKeyIdPath;
    process.env['AWS_SECRET_ACCESS_KEY_FILE'] = secretAccessKeyPath;
    process.env['AWS_SESSION_TOKEN_FILE'] = sessionTokenPath;
    utils.resetEnvVarFileCache();

    try {
        const credentials = awscred.readCredentials({});
        if (credentials.accessKeyId !== 'FILE_ACCESS_KEY') {
            throw `file credentials do not match returned value [accessKeyId]\nActual:   [${credentials.accessKeyId}]\nExpected: [FILE_ACCESS_KEY]`;
        }
        if (credentials.secretAccessKey !== 'FILE_SECRET_KEY') {
            throw `file credentials do not match returned value [secretAccessKey]\nActual:   [${credentials.secretAccessKey}]\nExpected: [FILE_SECRET_KEY]`;
        }
        if (credentials.sessionToken !== 'FILE_SESSION_TOKEN') {
            throw `file credentials do not match returned value [sessionToken]\nActual:   [${credentials.sessionToken}]\nExpected: [FILE_SESSION_TOKEN]`;
        }
        if (credentials.expiration !== null) {
            throw 'file credentials do not match returned value [expiration]';
        }
    } finally {
        delete process.env['AWS_ACCESS_KEY_ID_FILE'];
        delete process.env['AWS_SECRET_ACCESS_KEY_FILE'];
        delete process.env['AWS_SESSION_TOKEN_FILE'];
        restoreEnv('AWS_ACCESS_KEY_ID', savedAccessKeyId);
        restoreEnv('AWS_SECRET_ACCESS_KEY', savedSecretAccessKey);
        restoreEnv('AWS_SESSION_TOKEN', savedSessionToken);
        utils.resetEnvVarFileCache();
        removeIfExists(accessKeyIdPath);
        removeIfExists(secretAccessKeyPath);
        removeIfExists(sessionTokenPath);
    }
}

function testReadCredentialsWithoutSessionTokenFile() {
    printHeader('testReadCredentialsWithoutSessionTokenFile');

    const accessKeyIdPath = tempFilePath('access-key-id', '');
    const secretAccessKeyPath = tempFilePath('secret-access-key', '');

    const savedAccessKeyId = process.env['AWS_ACCESS_KEY_ID'];
    const savedSecretAccessKey = process.env['AWS_SECRET_ACCESS_KEY'];
    const savedSessionToken = process.env['AWS_SESSION_TOKEN'];

    fs.writeFileSync(accessKeyIdPath, 'FILE_ACCESS_KEY');
    fs.writeFileSync(secretAccessKeyPath, 'FILE_SECRET_KEY');

    delete process.env['AWS_ACCESS_KEY_ID'];
    delete process.env['AWS_SECRET_ACCESS_KEY'];
    delete process.env['AWS_SESSION_TOKEN'];
    process.env['AWS_ACCESS_KEY_ID_FILE'] = accessKeyIdPath;
    process.env['AWS_SECRET_ACCESS_KEY_FILE'] = secretAccessKeyPath;
    utils.resetEnvVarFileCache();

    try {
        const credentials = awscred.readCredentials({});
        if (credentials.sessionToken !== null) {
            throw `session token absent from the configuration did not read as null\nActual:   [${credentials.sessionToken}]`;
        }
    } finally {
        delete process.env['AWS_ACCESS_KEY_ID_FILE'];
        delete process.env['AWS_SECRET_ACCESS_KEY_FILE'];
        restoreEnv('AWS_ACCESS_KEY_ID', savedAccessKeyId);
        restoreEnv('AWS_SECRET_ACCESS_KEY', savedSecretAccessKey);
        restoreEnv('AWS_SESSION_TOKEN', savedSessionToken);
        utils.resetEnvVarFileCache();
        removeIfExists(accessKeyIdPath);
        removeIfExists(secretAccessKeyPath);
    }
}

function testReadCredentialsPrefersEnvVarOverFile() {
    printHeader('testReadCredentialsPrefersEnvVarOverFile');

    const accessKeyIdPath = tempFilePath('access-key-id', '');

    const savedAccessKeyId = process.env['AWS_ACCESS_KEY_ID'];
    const savedSecretAccessKey = process.env['AWS_SECRET_ACCESS_KEY'];

    fs.writeFileSync(accessKeyIdPath, 'FILE_ACCESS_KEY');

    process.env['AWS_ACCESS_KEY_ID'] = 'ENV_ACCESS_KEY';
    process.env['AWS_SECRET_ACCESS_KEY'] = 'ENV_SECRET_KEY';
    process.env['AWS_ACCESS_KEY_ID_FILE'] = accessKeyIdPath;
    utils.resetEnvVarFileCache();

    try {
        const credentials = awscred.readCredentials({});
        if (credentials.accessKeyId !== 'ENV_ACCESS_KEY') {
            throw `file value did not lose to the environment variable\nActual:   [${credentials.accessKeyId}]\nExpected: [ENV_ACCESS_KEY]`;
        }
    } finally {
        delete process.env['AWS_ACCESS_KEY_ID_FILE'];
        restoreEnv('AWS_ACCESS_KEY_ID', savedAccessKeyId);
        restoreEnv('AWS_SECRET_ACCESS_KEY', savedSecretAccessKey);
        utils.resetEnvVarFileCache();
        removeIfExists(accessKeyIdPath);
    }
}

function testReadAndWriteCredentialsFromSharedDict() {
    printHeader('testReadAndWriteCredentialsFromSharedDict');
    let r = {
        variables: {
            cache_instance_credentials_enabled: 0
        }
    };

    resetSharedCredentialCache();
    var expectedCredentials = {
        accessKeyId: 'A',
        secretAccessKey: 'B',
        sessionToken: 'C',
        expiration: '2022-02-15T04:49:08Z'
    };
    awscred.writeCredentials(r, expectedCredentials);

    var credentials = awscred.readCredentials(r);
    if (credentials.accessKeyId !== expectedCredentials.accessKeyId) {
        throw 'JSON test data does not match credentials [accessKeyId]';
    }
    if (credentials.secretAccessKey !== expectedCredentials.secretAccessKey) {
        throw 'JSON test data does not match credentials [secretAccessKey]';
    }
    if (credentials.sessionToken !== expectedCredentials.sessionToken) {
        throw 'JSON test data does not match credentials [sessionToken]';
    }
    if (credentials.expiration !== expectedCredentials.expiration) {
        throw 'JSON test data does not match credentials [expiration]';
    }
}

function testReadCredentialsFromEmptySharedDict() {
    printHeader('testReadCredentialsFromEmptySharedDict');
    let r = {
        variables: {
            cache_instance_credentials_enabled: 0
        }
    };

    resetSharedCredentialCache();
    var credentials = awscred.readCredentials(r);
    if (credentials !== undefined) {
        throw 'Credentials returned when shared credential cache should be empty';
    }
}

function testReadCredentialsFromMalformedSharedDict() {
    printHeader('testReadCredentialsFromMalformedSharedDict');
    let r = {
        variables: {
            cache_instance_credentials_enabled: 0
        }
    };

    r.log = function(msg) {
        console.log(msg);
    };

    resetSharedCredentialCache();
    globalThis.ngx.shared.instance_credential_cache.set(INSTANCE_CREDENTIAL_CACHE_KEY, '{');
    var credentials = awscred.readCredentials(r);
    if (credentials !== undefined) {
        throw 'Malformed shared credential cache value must be ignored';
    }
}

function testReadAndWriteCredentialsFromKeyValStore() {
    printHeader('testReadAndWriteCredentialsFromKeyValStore');

    let accessKeyId = process.env['AWS_ACCESS_KEY_ID'];
    let secretKey = process.env['AWS_SECRET_ACCESS_KEY'];
    let sessionToken = process.env['AWS_SESSION_TOKEN'];
    delete process.env.AWS_ACCESS_KEY_ID;
    delete process.env.AWS_SECRET_ACCESS_KEY;
    delete process.env.AWS_SESSION_TOKEN;
    try {
        let r = {
            variables: {
                cache_instance_credentials_enabled: 1,
                instance_credential_json: null
            }
        };
        let expectedCredentials = {
            accessKeyId: 'AN_ACCESS_KEY_ID',
            secretAccessKey: 'A_SECRET_ACCESS_KEY',
            sessionToken: 'A_SECURITY_TOKEN',
            expiration: '2017-05-17T15:09:54Z',
        };

        awscred.writeCredentials(r, expectedCredentials);
        let credentials = JSON.stringify(awscred.readCredentials(r));
        let expectedJson = JSON.stringify(expectedCredentials);

        if (credentials !== expectedJson) {
            console.log(`EXPECTED:\n${expectedJson}\nACTUAL:\n${credentials}`);
            throw 'Credentials do not match expected value';
        }
    } finally {
        restoreEnv('AWS_ACCESS_KEY_ID', accessKeyId);
        restoreEnv('AWS_SECRET_ACCESS_KEY', secretKey);
        restoreEnv('AWS_SESSION_TOKEN', sessionToken);
    }
}

async function testFetchCredentialsRefreshesExpiredCache() {
    printHeader('testFetchCredentialsRefreshesExpiredCache');
    clearProviderEnv();
    var recordedUrl = null;
    process.env['AWS_CONTAINER_CREDENTIALS_RELATIVE_URI'] = ECS_CREDS_RELATIVE_URI;
    /* Seed the cache with credentials whose expiration is in the past so that
       the freshness short-circuit must not fire. Guards against the expiry
       check comparing to a stale timestamp instead of a live clock. */
    globalThis.ngx.shared.instance_credential_cache.set(INSTANCE_CREDENTIAL_CACHE_KEY, JSON.stringify({
        accessKeyId: 'AN_EXPIRED_ACCESS_KEY_ID',
        secretAccessKey: 'AN_EXPIRED_SECRET_ACCESS_KEY',
        sessionToken: 'AN_EXPIRED_SECURITY_TOKEN',
        expiration: '2017-05-17T15:09:54Z',
    }));
    globalThis.ngx.fetch = function (url) {
        console.log(' fetching mock credentials to replace the expired cache');
        recordedUrl = url;

        return Promise.resolve({
            ok: true,
            json: function () {
                return Promise.resolve(MOCK_AWS_CREDS_RESPONSE);
            }
        });
    };
    var r = makeExpect200Request();

    try {
        await awscred.fetchCredentials(r);

        if (recordedUrl !== ECS_CREDS_URL) {
            throw 'Expired cached credentials were not refreshed. ' +
                `Recorded refresh URL: ${recordedUrl}`;
        }
    } finally {
        delete process.env['AWS_CONTAINER_CREDENTIALS_RELATIVE_URI'];
    }
}

async function testFetchCredentialsUsesFreshCache() {
    printHeader('testFetchCredentialsUsesFreshCache');
    clearProviderEnv();
    process.env['AWS_CONTAINER_CREDENTIALS_RELATIVE_URI'] = ECS_CREDS_RELATIVE_URI;
    /* Expiration far enough in the future to stay comfortably beyond the
       4.5-minute early-refresh offset applied to the expiration. */
    globalThis.ngx.shared.instance_credential_cache.set(INSTANCE_CREDENTIAL_CACHE_KEY, JSON.stringify({
        accessKeyId: 'A_FRESH_ACCESS_KEY_ID',
        secretAccessKey: 'A_FRESH_SECRET_ACCESS_KEY',
        sessionToken: 'A_FRESH_SECURITY_TOKEN',
        expiration: '2100-01-01T00:00:00Z',
    }));
    /* Record instead of throwing from the stub: a throw here would be
       swallowed by fetchCredentials' try/catch and resurface only as an
       unexplained 500, hiding the real cause of a regression. */
    var recordedUrl = null;
    globalThis.ngx.fetch = function (url) {
        recordedUrl = url;

        return Promise.resolve({
            ok: true,
            json: function () {
                return Promise.resolve(MOCK_AWS_CREDS_RESPONSE);
            }
        });
    };
    var state = {};
    var r = makeRecordingRequest(state);

    try {
        await awscred.fetchCredentials(r);

        if (recordedUrl !== null) {
            throw 'Fresh cached credentials must not be refreshed. ' +
                `Attempted fetch URL: ${recordedUrl}`;
        }
        if (state.returnedCode !== 200) {
            throw 'Expected 200 status code, got: ' + state.returnedCode;
        }
    } finally {
        delete process.env['AWS_CONTAINER_CREDENTIALS_RELATIVE_URI'];
    }
}

async function testEcsCredentialRetrieval() {
    printHeader('testEcsCredentialRetrieval');
    clearProviderEnv();
    var recordedUrl = null;
    process.env['AWS_CONTAINER_CREDENTIALS_RELATIVE_URI'] = ECS_CREDS_RELATIVE_URI;
    globalThis.ngx.fetch = function (url) {
        console.log(' fetching mock credentials');
        recordedUrl = url;

        return Promise.resolve({
            ok: true,
            json: function () {
                return Promise.resolve(MOCK_AWS_CREDS_RESPONSE);
            }
        });
    };
    var r = makeExpect200Request();

    try {
        await awscred.fetchCredentials(r);

        if (recordedUrl !== ECS_CREDS_URL) {
            throw `No or wrong ECS credentials fetch URL recorded: ${recordedUrl}`;
        }

        /* The integration ECS mock cannot serve a Token (the S3 origin rejects
           fabricated session tokens), so the Token -> sessionToken -> cache
           seam is pinned here instead. */
        var cached = JSON.parse(globalThis.ngx.shared.instance_credential_cache
            .get(INSTANCE_CREDENTIAL_CACHE_KEY));
        if (cached.sessionToken !== MOCK_AWS_CREDS_RESPONSE.Token) {
            throw 'ECS session token was not cached as sessionToken. ' +
                `Actual: [${cached.sessionToken}]`;
        }
    } finally {
        delete process.env['AWS_CONTAINER_CREDENTIALS_RELATIVE_URI'];
    }
}

async function testEc2CredentialRetrieval() {
    printHeader('testEc2CredentialRetrieval');
    clearProviderEnv();
    var credentialsIssued = false;
    globalThis.ngx.fetch = function (url, options) {
        if (url === IMDS_TOKEN_URL && options && options.method === 'PUT') {
            return Promise.resolve({
                ok: true,
                text: function () {
                    return Promise.resolve('A_TOKEN');
                },
            });
        } else if (url === IMDS_SECURITY_CREDS_URL) {
            if (options && options.headers && options.headers['x-aws-ec2-metadata-token'] === 'A_TOKEN') {
                return Promise.resolve({
                    ok: true,
                    text: function () {
                        return Promise.resolve('A_ROLE_NAME');
                    },
                });
            } else {
                throw 'IMDSv2 token missing or invalid on the security credentials request';
            }
        }  else if (url === IMDS_SECURITY_CREDS_URL + 'A_ROLE_NAME') {
            if (options && options.headers && options.headers['x-aws-ec2-metadata-token'] === 'A_TOKEN') {
                return Promise.resolve({
                    ok: true,
                    json: function () {
                        credentialsIssued = true;
                        return Promise.resolve(MOCK_AWS_CREDS_RESPONSE);
                    },
                });
            } else {
                throw 'IMDSv2 token missing or invalid on the role credentials request';
            }
        } else {
            throw 'Invalid request URL: ' + url;
        }
    };
    var r = makeExpect200Request();

    await awscred.fetchCredentials(r);

    if (!credentialsIssued) {
        throw 'Did not reach the point where EC2 credentials were issued.';
    }
}

async function testEKSPodIdentityCredentialRetrieval() {
    printHeader('testEKSPodIdentityCredentialRetrieval');
    var originalTokenFile = process.env['AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE'];
    clearProviderEnv();
    var tokenFile = tempFilePath('eks-happy-token-unit-test', '');
    var testToken = 'A_TOKEN';
    fs.writeFileSync(tokenFile, testToken);
    process.env['AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE'] = tokenFile;
    var credentialsIssued = false;
    globalThis.ngx.fetch = function(url, options) {
        console.log(' fetching eks pod identity mock credentials');
        if (url === 'http://169.254.170.23/v1/credentials') {
            if (options && options.headers && options.headers['Authorization'] &&
                options.headers['Authorization'].toString() === testToken) {
                return Promise.resolve({
                    ok: true,
                    json: function() {
                        credentialsIssued = true;
                        return Promise.resolve({
                            AccessKeyId: 'AN_ACCESS_KEY_ID',
                            Expiration: '2017-05-17T15:09:54Z',
                            AccountId: 'AN_ACCOUNT_ID',
                            SecretAccessKey: 'A_SECRET_ACCESS_KEY',
                            Token: 'A_SECURITY_TOKEN',
                        });
                    },
                });
            } else {
                throw 'Invalid token passed to the EKS Pod Identity agent';
            }
        } else {
            throw 'Invalid request URL: ' + url;
        }
    };
    var r = makeExpect200Request();

    try {
        await awscred.fetchCredentials(r);

        if (!credentialsIssued) {
            throw 'Did not reach the point where EKS Pod Identity credentials were issued.';
        }
    } finally {
        restoreEnv('AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE', originalTokenFile);
        removeIfExists(tokenFile);
    }
}

async function testEKSPodIdentityCredentialRetrievalNon200Response() {
    printHeader('testEKSPodIdentityCredentialRetrievalNon200Response');
    var originalTokenFile = process.env['AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE'];
    clearProviderEnv();
    var tokenFile = tempFilePath('eks-non200-token-unit-test', '');
    var testToken = 'A_TOKEN';
    fs.writeFileSync(tokenFile, testToken);
    process.env['AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE'] = tokenFile;
    var non200ResponseServed = false;
    var errorBodyParsedAsCredentials = false;
    var state = {returnedCode: null};
    var r = makeRecordingRequest(state);
    globalThis.ngx.fetch = function(url, options) {
        console.log(' fetching eks pod identity mock error response');
        if (url === 'http://169.254.170.23/v1/credentials') {
            if (options && options.headers && options.headers['Authorization'] &&
                options.headers['Authorization'].toString() === testToken) {
                non200ResponseServed = true;
                return Promise.resolve({
                    ok: false,
                    status: 503,
                    json: function() {
                        // A non-200 body must never be parsed as credentials.
                        errorBodyParsedAsCredentials = true;
                        return Promise.resolve({
                            message: 'Service Unavailable',
                        });
                    },
                });
            } else {
                throw 'Invalid token passed to the EKS Pod Identity agent';
            }
        } else {
            throw 'Invalid request URL: ' + url;
        }
    };

    try {
        await awscred.fetchCredentials(r);

        if (!non200ResponseServed) {
            throw 'The mocked non-200 EKS Pod Identity response was never served.';
        }
        if (errorBodyParsedAsCredentials) {
            throw 'A non-200 EKS Pod Identity agent response was parsed as credentials.';
        }
        if (state.returnedCode !== 500) {
            throw 'Expected the credentials fetch to fail with 500, got: ' + state.returnedCode;
        }
        if (globalThis.ngx.shared.instance_credential_cache.get(INSTANCE_CREDENTIAL_CACHE_KEY)) {
            throw 'Credentials must not be cached from a non-200 response.';
        }
    } finally {
        restoreEnv('AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE', originalTokenFile);
        removeIfExists(tokenFile);
    }
}

async function testEc2CredentialRetrievalNon200Response() {
    printHeader('testEc2CredentialRetrievalNon200Response');
    clearProviderEnv();
    var non200ResponseServed = false;
    var errorBodyParsedAsCredentials = false;
    var state = {returnedCode: null};
    var r = makeRecordingRequest(state);
    globalThis.ngx.fetch = function (url, options) {
        if (url === IMDS_TOKEN_URL && options && options.method === 'PUT') {
            return Promise.resolve({
                ok: true,
                text: function () {
                    return Promise.resolve('A_TOKEN');
                },
            });
        } else if (url === IMDS_SECURITY_CREDS_URL) {
            return Promise.resolve({
                ok: true,
                text: function () {
                    return Promise.resolve('A_ROLE_NAME');
                },
            });
        } else if (url === IMDS_SECURITY_CREDS_URL + 'A_ROLE_NAME') {
            non200ResponseServed = true;
            return Promise.resolve({
                ok: false,
                status: 503,
                json: function () {
                    // A non-200 body must never be parsed as credentials.
                    errorBodyParsedAsCredentials = true;
                    return Promise.resolve({
                        message: 'Service Unavailable',
                    });
                },
            });
        } else {
            throw 'Invalid request URL: ' + url;
        }
    };

    await awscred.fetchCredentials(r);

    if (!non200ResponseServed) {
        throw 'The mocked non-200 EC2 credentials response was never served.';
    }
    if (errorBodyParsedAsCredentials) {
        throw 'A non-200 EC2 metadata response was parsed as credentials.';
    }
    if (state.returnedCode !== 500) {
        throw 'Expected the credentials fetch to fail with 500, got: ' + state.returnedCode;
    }
    if (globalThis.ngx.shared.instance_credential_cache.get(INSTANCE_CREDENTIAL_CACHE_KEY)) {
        throw 'Credentials must not be cached from a non-200 response.';
    }
}

async function testEc2CredentialRetrievalIMDSv1Fallback() {
    printHeader('testEc2CredentialRetrievalIMDSv1Fallback');
    clearProviderEnv();
    var credentialsIssued = false;
    var r = makeExpect200Request();
    globalThis.ngx.fetch = function (url, options) {
        if (url === IMDS_TOKEN_URL && options && options.method === 'PUT') {
            // Simulate an IMDSv1-only metadata service rejecting the token request.
            return Promise.resolve({
                ok: false,
                status: 405,
            });
        }
        if (options && options.headers && 'x-aws-ec2-metadata-token' in options.headers) {
            throw 'IMDSv2 token header must not be sent after a rejected token request';
        }
        if (url === IMDS_SECURITY_CREDS_URL) {
            return Promise.resolve({
                ok: true,
                text: function () {
                    return Promise.resolve('A_ROLE_NAME');
                },
            });
        } else if (url === IMDS_SECURITY_CREDS_URL + 'A_ROLE_NAME') {
            return Promise.resolve({
                ok: true,
                json: function () {
                    credentialsIssued = true;
                    return Promise.resolve(MOCK_AWS_CREDS_RESPONSE);
                },
            });
        } else {
            throw 'Invalid request URL: ' + url;
        }
    };

    await awscred.fetchCredentials(r);

    if (!credentialsIssued) {
        throw 'Did not reach the point where EC2 credentials were issued via IMDSv1.';
    }
}

async function testEc2CredentialRetrievalIMDSv1FallbackOnTokenError() {
    printHeader('testEc2CredentialRetrievalIMDSv1FallbackOnTokenError');
    clearProviderEnv();
    var credentialsIssued = false;
    var r = makeExpect200Request();
    globalThis.ngx.fetch = function (url, options) {
        if (url === IMDS_TOKEN_URL && options && options.method === 'PUT') {
            /* Simulate a dropped token response, e.g. the instance's
               HttpPutResponseHopLimit being exhausted by a container
               network hop. */
            return Promise.reject(new Error('connection timed out'));
        }
        if (options && options.headers && 'x-aws-ec2-metadata-token' in options.headers) {
            throw 'IMDSv2 token header must not be sent after a failed token request';
        }
        if (url === IMDS_SECURITY_CREDS_URL) {
            return Promise.resolve({
                ok: true,
                text: function () {
                    return Promise.resolve('A_ROLE_NAME');
                },
            });
        } else if (url === IMDS_SECURITY_CREDS_URL + 'A_ROLE_NAME') {
            return Promise.resolve({
                ok: true,
                json: function () {
                    credentialsIssued = true;
                    return Promise.resolve(MOCK_AWS_CREDS_RESPONSE);
                },
            });
        } else {
            throw 'Invalid request URL: ' + url;
        }
    };

    await awscred.fetchCredentials(r);

    if (!credentialsIssued) {
        throw 'Did not reach the point where EC2 credentials were issued via IMDSv1.';
    }
}

async function testEc2CredentialRetrievalTokenEndpointTransientError() {
    printHeader('testEc2CredentialRetrievalTokenEndpointTransientError');
    clearProviderEnv();
    var imdsv1RequestMade = false;
    var state = {returnedCode: null};
    var r = makeRecordingRequest(state);
    globalThis.ngx.fetch = function (url, options) {
        if (url === IMDS_TOKEN_URL && options && options.method === 'PUT') {
            /* A transient throttle must fail the fetch rather than silently
               downgrading to a token-less IMDSv1 request. */
            return Promise.resolve({
                ok: false,
                status: 429,
            });
        }
        imdsv1RequestMade = true;
        throw 'No request should be made after a transient token endpoint failure: ' + url;
    };

    await awscred.fetchCredentials(r);

    if (imdsv1RequestMade) {
        throw 'A token-less IMDSv1 request was made after a transient token endpoint failure.';
    }
    if (state.returnedCode !== 500) {
        throw 'Expected the credentials fetch to fail with 500, got: ' + state.returnedCode;
    }
    if (globalThis.ngx.shared.instance_credential_cache.get(INSTANCE_CREDENTIAL_CACHE_KEY)) {
        throw 'Credentials must not be cached after a failed token request.';
    }
}

async function testEc2CredentialRetrievalIMDSv1FallbackDisabled() {
    printHeader('testEc2CredentialRetrievalIMDSv1FallbackDisabled');
    clearProviderEnv();
    var originalV1Disabled = process.env['AWS_EC2_METADATA_V1_DISABLED'];
    var imdsv1RequestMade = false;
    var state = {returnedCode: null};
    var r = makeRecordingRequest(state);
    globalThis.ngx.fetch = function (url, options) {
        if (url === IMDS_TOKEN_URL && options && options.method === 'PUT') {
            /* A status that would normally trigger the IMDSv1 fallback. */
            return Promise.resolve({
                ok: false,
                status: 404,
            });
        }
        imdsv1RequestMade = true;
        throw 'No request should be made when the IMDSv1 fallback is disabled: ' + url;
    };

    try {
        process.env['AWS_EC2_METADATA_V1_DISABLED'] = 'true';
        await awscred.fetchCredentials(r);

        if (imdsv1RequestMade) {
            throw 'A token-less IMDSv1 request was made although the fallback is disabled.';
        }
        if (state.returnedCode !== 500) {
            throw 'Expected the credentials fetch to fail with 500, got: ' + state.returnedCode;
        }
        if (globalThis.ngx.shared.instance_credential_cache.get(INSTANCE_CREDENTIAL_CACHE_KEY)) {
            throw 'Credentials must not be cached after a failed token request.';
        }
    } finally {
        restoreEnv('AWS_EC2_METADATA_V1_DISABLED', originalV1Disabled);
    }
}

async function testWebIdentityCredentialRetrievalNon200Response() {
    printHeader('testWebIdentityCredentialRetrievalNon200Response');
    var originalTokenFile = process.env['AWS_WEB_IDENTITY_TOKEN_FILE'];
    var originalRoleArn = process.env['AWS_ROLE_ARN'];
    var originalRoleSessionName = process.env['AWS_ROLE_SESSION_NAME'];
    var originalStsEndpoint = process.env['STS_ENDPOINT'];
    clearProviderEnv();
    var tokenFile = tempFilePath('web-identity-token-unit-test', '');
    fs.writeFileSync(tokenFile, 'A_WEB_IDENTITY_TOKEN');
    var non200ResponseServed = false;
    var errorBodyParsedAsCredentials = false;
    var state = {returnedCode: null};
    var r = makeRecordingRequest(state);
    globalThis.ngx.fetch = function (url) {
        if (url.startsWith('https://sts.unit-test.example.com?')) {
            non200ResponseServed = true;
            return Promise.resolve({
                ok: false,
                status: 400,
                text: function () {
                    return Promise.resolve('{"Error":{"Code":"ExpiredTokenException"}}');
                },
                json: function () {
                    // A non-200 body must never be parsed as credentials.
                    errorBodyParsedAsCredentials = true;
                    return Promise.resolve({});
                },
            });
        } else {
            throw 'Invalid request URL: ' + url;
        }
    };

    try {
        process.env['AWS_WEB_IDENTITY_TOKEN_FILE'] = tokenFile;
        process.env['AWS_ROLE_ARN'] = 'arn:aws:iam::000000000000:role/unit-test';
        process.env['AWS_ROLE_SESSION_NAME'] = 'unit-test';
        process.env['STS_ENDPOINT'] = 'https://sts.unit-test.example.com';
        await awscred.fetchCredentials(r);

        if (!non200ResponseServed) {
            throw 'The mocked non-200 STS response was never served.';
        }
        if (errorBodyParsedAsCredentials) {
            throw 'A non-200 STS response was parsed as credentials.';
        }
        if (state.returnedCode !== 500) {
            throw 'Expected the credentials fetch to fail with 500, got: ' + state.returnedCode;
        }
        if (globalThis.ngx.shared.instance_credential_cache.get(INSTANCE_CREDENTIAL_CACHE_KEY)) {
            throw 'Credentials must not be cached from a non-200 response.';
        }
    } finally {
        restoreEnv('AWS_WEB_IDENTITY_TOKEN_FILE', originalTokenFile);
        restoreEnv('AWS_ROLE_ARN', originalRoleArn);
        restoreEnv('AWS_ROLE_SESSION_NAME', originalRoleSessionName);
        restoreEnv('STS_ENDPOINT', originalStsEndpoint);
        removeIfExists(tokenFile);
    }
}

function testWriteInvalidCredentials() {
    printHeader('testWriteInvalidCredentials');

    let accessKeyId = process.env['AWS_ACCESS_KEY_ID'];
    let secretKey = process.env['AWS_SECRET_ACCESS_KEY'];
    delete process.env.AWS_ACCESS_KEY_ID;
    delete process.env.AWS_SECRET_ACCESS_KEY;
    try {
        let r = {
            variables: {
                cache_instance_credentials_enabled: 1,
                instance_credential_json: null
            }
        };
        let invalidCredentials = [
            null,
            {},
            {accessKeyId: 'AN_ACCESS_KEY_ID'},
            {secretAccessKey: 'A_SECRET_ACCESS_KEY'},
            {accessKeyId: undefined, secretAccessKey: undefined,
                sessionToken: undefined, expiration: undefined},
        ];
        invalidCredentials.forEach(function(credentials) {
            let threw = false;
            try {
                awscred.writeCredentials(r, credentials);
            } catch (e) {
                threw = true;
            }
            if (!threw) {
                throw 'writeCredentials accepted invalid credentials: ' +
                    JSON.stringify(credentials);
            }
        });
        if (r.variables.instance_credential_json !== null) {
            throw 'Invalid credentials were written to the credentials cache.';
        }
    } finally {
        restoreEnv('AWS_ACCESS_KEY_ID', accessKeyId);
        restoreEnv('AWS_SECRET_ACCESS_KEY', secretKey);
    }
}

async function test() {
    await testEc2CredentialRetrieval();
    await testEcsCredentialRetrieval();
    await testFetchCredentialsRefreshesExpiredCache();
    await testFetchCredentialsUsesFreshCache();
    await testEKSPodIdentityCredentialRetrieval();
    await testEKSPodIdentityCredentialRetrievalNon200Response();
    await testEc2CredentialRetrievalNon200Response();
    await testEc2CredentialRetrievalIMDSv1Fallback();
    await testEc2CredentialRetrievalIMDSv1FallbackOnTokenError();
    await testEc2CredentialRetrievalTokenEndpointTransientError();
    await testEc2CredentialRetrievalIMDSv1FallbackDisabled();
    await testWebIdentityCredentialRetrievalNon200Response();
    testReadCredentialsWithAccessSecretKeyAndSessionTokenSet();
    testReadCredentialsFromFiles();
    testReadCredentialsWithoutSessionTokenFile();
    testReadCredentialsPrefersEnvVarOverFile();
    testReadAndWriteCredentialsFromSharedDict();
    testReadCredentialsFromEmptySharedDict();
    testReadCredentialsFromMalformedSharedDict();
    testReadAndWriteCredentialsFromKeyValStore();
    testWriteInvalidCredentials();
}

function printHeader(testName) {
    console.log(`\n## ${testName}`);
}

test();
console.log('Finished unit tests for awscredentials.js');

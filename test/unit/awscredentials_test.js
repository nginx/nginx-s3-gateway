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
 * Deletes every provider-selection env var so that each test opts into
 * exactly one credential provider path.
 */
function clearProviderEnv() {
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

function testReadCredentialsFromFilePath() {
    printHeader('testReadCredentialsFromFilePath');
    let r = {
        variables: {
            cache_instance_credentials_enabled: 0
        }
    };

    var originalCredentialPath = process.env['AWS_CREDENTIALS_TEMP_FILE'];
    var tempDir = (process.env['TMPDIR'] ? process.env['TMPDIR'] : '/tmp');
    var uniqId = `${new Date().getTime()}-${Math.floor(Math.random()*101)}`;
    var tempFile = `${tempDir}/credentials-unit-test-${uniqId}.json`;
    var testData = '{"accessKeyId":"A","secretAccessKey":"B",' +
        '"sessionToken":"C","expiration":"2022-02-15T04:49:08Z"}';
    fs.writeFileSync(tempFile, testData);

    try {
        process.env['AWS_CREDENTIALS_TEMP_FILE'] = tempFile;
        var credentials = awscred.readCredentials(r);
        var testDataAsJSON = JSON.parse(testData);
        if (credentials.accessKeyId !== testDataAsJSON.accessKeyId) {
            throw 'JSON test data does not match credentials [accessKeyId]';
        }
        if (credentials.secretAccessKey !== testDataAsJSON.secretAccessKey) {
            throw 'JSON test data does not match credentials [secretAccessKey]';
        }
        if (credentials.sessionToken !== testDataAsJSON.sessionToken) {
            throw 'JSON test data does not match credentials [sessionToken]';
        }
        if (credentials.expiration !== testDataAsJSON.expiration) {
            throw 'JSON test data does not match credentials [expiration]';
        }
    } finally {
        if (originalCredentialPath) {
            process.env['AWS_CREDENTIALS_TEMP_FILE'] = originalCredentialPath;
        }
        if (fs.statSync(tempFile, {throwIfNoEntry: false})) {
            fs.unlinkSync(tempFile);
        }
    }
}

function testReadCredentialsFromNonexistentPath() {
    printHeader('testReadCredentialsFromNonexistentPath');
    let r = {
        variables: {
            cache_instance_credentials_enabled: 0
        }
    };
    var originalCredentialPath = process.env['AWS_CREDENTIALS_TEMP_FILE'];
    var tempDir = (process.env['TMPDIR'] ? process.env['TMPDIR'] : '/tmp');
    var uniqId = `${new Date().getTime()}-${Math.floor(Math.random()*101)}`;
    var tempFile = `${tempDir}/credentials-unit-test-${uniqId}.json`;

    try {
        process.env['AWS_CREDENTIALS_TEMP_FILE'] = tempFile;
        var credentials = awscred.readCredentials(r);
        if (credentials !== undefined) {
            throw 'Credentials returned when no credentials file should be present';
        }

    } finally {
        if (originalCredentialPath) {
            process.env['AWS_CREDENTIALS_TEMP_FILE'] = originalCredentialPath;
        }
        if (fs.statSync(tempFile, {throwIfNoEntry: false})) {
            fs.unlinkSync(tempFile);
        }
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

async function testEcsCredentialRetrieval() {
    printHeader('testEcsCredentialRetrieval');
    if ('AWS_ACCESS_KEY_ID' in process.env) {
        delete process.env['AWS_ACCESS_KEY_ID'];
    }
    process.env['AWS_CONTAINER_CREDENTIALS_RELATIVE_URI'] = '/example';
    globalThis.ngx.fetch = function (url) {
        console.log(' fetching mock credentials');
        globalThis.recordedUrl = url;

        return Promise.resolve({
            ok: true,
            json: function () {
                return Promise.resolve(MOCK_AWS_CREDS_RESPONSE);
            }
        });
    };
    var r = {
        "headersOut" : {
            "Accept-Ranges": "bytes",
            "Content-Length": 42,
            "Content-Security-Policy": "block-all-mixed-content",
            "Content-Type": "text/plain",
            "X-Amz-Bucket-Region": "us-east-1",
            "X-Amz-Request-Id": "166539E18A46500A",
            "X-Xss-Protection": "1; mode=block"
        },
        log: function(msg) {
            console.log(msg);
        },
        return: function(code) {
            if (code !== 200) {
                throw 'Expected 200 status code, got: ' + code;
            }
        },
    };

    await awscred.fetchCredentials(r);

    if (globalThis.recordedUrl !== 'http://169.254.170.2/example') {
        throw `No or wrong ECS credentials fetch URL recorded: ${globalThis.recordedUrl}`;
    }
}

async function testEc2CredentialRetrieval() {
    printHeader('testEc2CredentialRetrieval');
    if ('AWS_ACCESS_KEY_ID' in process.env) {
        delete process.env['AWS_ACCESS_KEY_ID'];
    }
    if ('AWS_CONTAINER_CREDENTIALS_RELATIVE_URI' in process.env) {
        delete process.env['AWS_CONTAINER_CREDENTIALS_RELATIVE_URI'];
    }
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
                throw 'Invalid token passed: ' + options.headers['x-aws-ec2-metadata-token'];
            }
        }  else if (url === IMDS_SECURITY_CREDS_URL + 'A_ROLE_NAME') {
            if (options && options.headers && options.headers['x-aws-ec2-metadata-token'] === 'A_TOKEN') {
                return Promise.resolve({
                    ok: true,
                    json: function () {
                        globalThis.credentialsIssued = true;
                        return Promise.resolve(MOCK_AWS_CREDS_RESPONSE);
                    },
                });
            } else {
                throw 'Invalid token passed: ' + options.headers['x-aws-ec2-metadata-token'];
            }
        } else {
            throw 'Invalid request URL: ' + url;
        }
    };
    var r = {
        "headersOut" : {
            "Accept-Ranges": "bytes",
            "Content-Length": 42,
            "Content-Security-Policy": "block-all-mixed-content",
            "Content-Type": "text/plain",
            "X-Amz-Bucket-Region": "us-east-1",
            "X-Amz-Request-Id": "166539E18A46500A",
            "X-Xss-Protection": "1; mode=block"
        },
        log: function(msg) {
            console.log(msg);
        },
        return: function(code) {
            if (code !== 200) {
                throw 'Expected 200 status code, got: ' + code;
            }
        },
    };

    await awscred.fetchCredentials(r);

    if (!globalThis.credentialsIssued) {
        throw 'Did not reach the point where EC2 credentials were issued.';
    }
}

async function testEKSPodIdentityCredentialRetrieval() {
    printHeader('testEKSPodIdentityCredentialRetrieval');
    if ('AWS_ACCESS_KEY_ID' in process.env) {
        delete process.env['AWS_ACCESS_KEY_ID'];
    }
    if ('AWS_CONTAINER_CREDENTIALS_RELATIVE_URI' in process.env) {
        delete process.env['AWS_CONTAINER_CREDENTIALS_RELATIVE_URI'];
    }
    if ('AWS_WEB_IDENTITY_TOKEN_FILE' in process.env) {
        delete process.env['AWS_WEB_IDENTITY_TOKEN_FILE'];
    }
    var tempDir = (process.env['TMPDIR'] ? process.env['TMPDIR'] : '/tmp');
    var uniqId = `${new Date().getTime()}-${Math.floor(Math.random()*101)}`;
    var tempFile = `${tempDir}/credentials-unit-test-${uniqId}.json`;
    var testToken = 'A_TOKEN';
    fs.writeFileSync(tempFile, testToken);
    process.env['AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE'] = tempFile;
    globalThis.ngx.fetch = function(url, options) {
        console.log(' fetching eks pod identity mock credentials');
        if (url === 'http://169.254.170.23/v1/credentials') {
            if (options && options.headers && options.headers['Authorization'].toString() === testToken) {
                return Promise.resolve({
                    ok: true,
                    json: function() {
                        globalThis.credentialsIssued = true;
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
                throw 'Invalid token passed: ' + options.headers['Authorization'];
            }
        } else {
            throw 'Invalid request URL: ' + url;
        }
    };
    var r = {
        "headersOut": {
            "Accept-Ranges": "bytes",
            "Content-Length": 42,
            "Content-Security-Policy": "block-all-mixed-content",
            "Content-Type": "text/plain",
            "X-Amz-Bucket-Region": "us-east-1",
            "X-Amz-Request-Id": "166539E18A46500A",
            "X-Xss-Protection": "1; mode=block"
        },
        log: function(msg) {
            console.log(msg);
        },
        return: function(code) {
            if (code !== 200) {
                throw 'Expected 200 status code, got: ' + code;
            }
        },
    };

    try {
        await awscred.fetchCredentials(r);

        if (!globalThis.credentialsIssued) {
            throw 'Did not reach the point where EKS Pod Identity credentials were issued.';
        }
    } finally {
        delete process.env['AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE'];
        removeIfExists(tempFile);
    }
}

async function testEc2CredentialRetrievalNon200Response() {
    printHeader('testEc2CredentialRetrievalNon200Response');
    clearProviderEnv();
    var originalCredentialPath = process.env['AWS_CREDENTIALS_TEMP_FILE'];
    var tempFile = tempFilePath('credentials-unit-test-ec2-non200', '.json');
    var non200ResponseServed = false;
    var errorBodyParsedAsCredentials = false;
    var returnedCode = null;
    var r = {
        log: function(msg) {
            console.log(msg);
        },
        return: function(code) {
            returnedCode = code;
        },
    };
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

    try {
        process.env['AWS_CREDENTIALS_TEMP_FILE'] = tempFile;
        await awscred.fetchCredentials(r);

        if (!non200ResponseServed) {
            throw 'The mocked non-200 EC2 credentials response was never served.';
        }
        if (errorBodyParsedAsCredentials) {
            throw 'A non-200 EC2 metadata response was parsed as credentials.';
        }
        if (returnedCode !== 500) {
            throw 'Expected the credentials fetch to fail with 500, got: ' + returnedCode;
        }
        if (fs.statSync(tempFile, {throwIfNoEntry: false})) {
            throw 'Credentials must not be cached from a non-200 response.';
        }
    } finally {
        restoreEnv('AWS_CREDENTIALS_TEMP_FILE', originalCredentialPath);
        removeIfExists(tempFile);
    }
}

async function testEc2CredentialRetrievalIMDSv1Fallback() {
    printHeader('testEc2CredentialRetrievalIMDSv1Fallback');
    clearProviderEnv();
    var originalCredentialPath = process.env['AWS_CREDENTIALS_TEMP_FILE'];
    var tempFile = tempFilePath('credentials-unit-test-imdsv1-fallback', '.json');
    var credentialsIssued = false;
    var r = {
        log: function(msg) {
            console.log(msg);
        },
        return: function(code) {
            if (code !== 200) {
                throw 'Expected 200 status code, got: ' + code;
            }
        },
    };
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

    try {
        process.env['AWS_CREDENTIALS_TEMP_FILE'] = tempFile;
        await awscred.fetchCredentials(r);

        if (!credentialsIssued) {
            throw 'Did not reach the point where EC2 credentials were issued via IMDSv1.';
        }
    } finally {
        restoreEnv('AWS_CREDENTIALS_TEMP_FILE', originalCredentialPath);
        removeIfExists(tempFile);
    }
}

async function testEc2CredentialRetrievalIMDSv1FallbackOnTokenError() {
    printHeader('testEc2CredentialRetrievalIMDSv1FallbackOnTokenError');
    clearProviderEnv();
    var originalCredentialPath = process.env['AWS_CREDENTIALS_TEMP_FILE'];
    var tempFile = tempFilePath('credentials-unit-test-imdsv1-token-error', '.json');
    var credentialsIssued = false;
    var r = {
        log: function(msg) {
            console.log(msg);
        },
        return: function(code) {
            if (code !== 200) {
                throw 'Expected 200 status code, got: ' + code;
            }
        },
    };
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

    try {
        process.env['AWS_CREDENTIALS_TEMP_FILE'] = tempFile;
        await awscred.fetchCredentials(r);

        if (!credentialsIssued) {
            throw 'Did not reach the point where EC2 credentials were issued via IMDSv1.';
        }
    } finally {
        restoreEnv('AWS_CREDENTIALS_TEMP_FILE', originalCredentialPath);
        removeIfExists(tempFile);
    }
}

async function testEc2CredentialRetrievalTokenEndpointTransientError() {
    printHeader('testEc2CredentialRetrievalTokenEndpointTransientError');
    clearProviderEnv();
    var originalCredentialPath = process.env['AWS_CREDENTIALS_TEMP_FILE'];
    var tempFile = tempFilePath('credentials-unit-test-token-transient', '.json');
    var imdsv1RequestMade = false;
    var returnedCode = null;
    var r = {
        log: function(msg) {
            console.log(msg);
        },
        return: function(code) {
            returnedCode = code;
        },
    };
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

    try {
        process.env['AWS_CREDENTIALS_TEMP_FILE'] = tempFile;
        await awscred.fetchCredentials(r);

        if (imdsv1RequestMade) {
            throw 'A token-less IMDSv1 request was made after a transient token endpoint failure.';
        }
        if (returnedCode !== 500) {
            throw 'Expected the credentials fetch to fail with 500, got: ' + returnedCode;
        }
        if (fs.statSync(tempFile, {throwIfNoEntry: false})) {
            throw 'Credentials must not be cached after a failed token request.';
        }
    } finally {
        restoreEnv('AWS_CREDENTIALS_TEMP_FILE', originalCredentialPath);
        removeIfExists(tempFile);
    }
}

async function testWebIdentityCredentialRetrievalNon200Response() {
    printHeader('testWebIdentityCredentialRetrievalNon200Response');
    clearProviderEnv();
    var originalCredentialPath = process.env['AWS_CREDENTIALS_TEMP_FILE'];
    var tempFile = tempFilePath('credentials-unit-test-web-identity', '.json');
    var tokenFile = tempFilePath('web-identity-token-unit-test', '');
    fs.writeFileSync(tokenFile, 'A_WEB_IDENTITY_TOKEN');
    var non200ResponseServed = false;
    var errorBodyParsedAsCredentials = false;
    var returnedCode = null;
    var r = {
        log: function(msg) {
            console.log(msg);
        },
        return: function(code) {
            returnedCode = code;
        },
    };
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
        process.env['AWS_CREDENTIALS_TEMP_FILE'] = tempFile;
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
        if (returnedCode !== 500) {
            throw 'Expected the credentials fetch to fail with 500, got: ' + returnedCode;
        }
        if (fs.statSync(tempFile, {throwIfNoEntry: false})) {
            throw 'Credentials must not be cached from a non-200 response.';
        }
    } finally {
        restoreEnv('AWS_CREDENTIALS_TEMP_FILE', originalCredentialPath);
        delete process.env['AWS_WEB_IDENTITY_TOKEN_FILE'];
        delete process.env['AWS_ROLE_ARN'];
        delete process.env['AWS_ROLE_SESSION_NAME'];
        delete process.env['STS_ENDPOINT'];
        removeIfExists(tempFile);
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
    await testEKSPodIdentityCredentialRetrieval();
    await testEc2CredentialRetrievalNon200Response();
    await testEc2CredentialRetrievalIMDSv1Fallback();
    await testEc2CredentialRetrievalIMDSv1FallbackOnTokenError();
    await testEc2CredentialRetrievalTokenEndpointTransientError();
    await testWebIdentityCredentialRetrievalNon200Response();
    testReadCredentialsWithAccessSecretKeyAndSessionTokenSet();
    testReadCredentialsFromFilePath();
    testReadCredentialsFromNonexistentPath();
    testReadAndWriteCredentialsFromKeyValStore();
    testWriteInvalidCredentials();
}

function printHeader(testName) {
    console.log(`\n## ${testName}`);
}

test();
console.log('Finished unit tests for awscredentials.js');

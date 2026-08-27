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

import awssig4 from "include/awssig4.js";
import utils from "include/utils.js";

const mod_hmac = require('crypto');


function testBuildSigningKeyHashWithReferenceInputs() {
    printHeader('testBuildSigningKeyHashWithReferenceInputs');
    var kSecret = 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY';
    var date = '20150830';
    var service = 'iam';
    var region = 'us-east-1';
    var expected = 'c4afb1cc5771d871763a393e44b703571b55cc28424d1a5e86da6ed3c154a4b9';
    var signingKeyHash = awssig4._buildSigningKeyHash(kSecret, date, region, service).toString('hex');

    if (signingKeyHash !== expected) {
        throw 'Signing key hash was not created correctly.\n' +
        'Actual:   [' + signingKeyHash + ']\n' +
        'Expected: [' + expected + ']';
    }
}

function testBuildSigningKeyHashWithTestSuiteInputs() {
    printHeader('testBuildSigningKeyHashWithTestSuiteInputs');
    var kSecret = 'pvgoBEA1z7zZKqN9RoKVksKh31AtNou+pspn+iyb';
    var date = '20200811';
    var service = 's3';
    var region = 'us-west-2';
    var expected = 'a48701bfe803103e89051f55af2297dd76783bbceb5eb416dab71e0eadcbc4f6';
    var signingKeyHash = awssig4._buildSigningKeyHash(kSecret, date, region, service).toString('hex');

    if (signingKeyHash !== expected) {
        throw 'Signing key hash was not created correctly.\n' +
        'Actual:   [' + signingKeyHash + ']\n' +
        'Expected: [' + expected + ']';
    }
}

function _runSignatureV4(r) {
    r.log = function(msg) {
        console.log(msg);
    }
    var timestamp = new Date('2020-08-11T19:42:14Z');
    var eightDigitDate = utils.getEightDigitDate(timestamp);
    var amzDatetime = utils.getAmzDatetime(timestamp, eightDigitDate);
    var bucket = 'ez-test-bucket-1'
    var secret = 'pvgoBEA1z7zZKqN9RoKVksKh31AtNou+pspn+iyb'
    var creds = {secretAccessKey: secret, sessionToken: null};
    var region = 'us-west-2';
    var service = 's3';
    var server = 's3-us-west-2.amazonaws.com';

    const req = {
        uri : r.variables.uri_path,
        queryParams : '',
        host: bucket.concat('.', server)
    }
    const canonicalRequest = awssig4._buildCanonicalRequest(r, 
        r.method, req.uri, req.queryParams, req.host, amzDatetime, creds.sessionToken);

    var expected = 'cf4dd9e1d28c74e2284f938011efc8230d0c20704f56f67e4a3bfc2212026bec';
    var signature = awssig4._buildSignatureV4(r, 
        amzDatetime, eightDigitDate, creds, region, service, canonicalRequest);
    
    if (signature !== expected) {
        throw 'V4 signature hash was not created correctly.\n' +
        'Actual:   [' + signature + ']\n' +
        'Expected: [' + expected + ']';
    }
}

function testSignatureV4() {
    printHeader('testSignatureV4');
    // Note: since this is a read-only gateway, host, query parameters and all
    // client headers will be ignored.
    var r = {
        "remoteAddress" : "172.17.0.1",
        "headersIn" : {
            "Connection" : "keep-alive",
            "Accept-Encoding" : "gzip, deflate",
            "Accept-Language" : "en-US,en;q=0.7,ja;q=0.3",
            "Host" : "localhost:8999",
            "User-Agent" : "Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:79.0) Gecko/20100101 Firefox/79.0",
            "DNT" : "1",
            "Cache-Control" : "max-age=0",
            "Accept" : "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
            "Upgrade-Insecure-Requests" : "1"
        },
        "uri" : "/a/c/ramen.jpg",
        "method" : "GET",
        "httpVersion" : "1.1",
        "headersOut" : {},
        "args" : {
            "foo" : "bar"
        },
        "variables" : {
            "request_body": "",
            "uri_path": "/a/c/ramen.jpg"
        },
        "status" : 0
    };

    _runSignatureV4(r);
}

function testSignatureV4Cache() {
    printHeader('testSignatureV4Cache');
    // Note: since this is a read-only gateway, host, query parameters and all
    // client headers will be ignored.
    var r = {
        "remoteAddress" : "172.17.0.1",
        "headersIn" : {
            "Connection" : "keep-alive",
            "Accept-Encoding" : "gzip, deflate",
            "Accept-Language" : "en-US,en;q=0.7,ja;q=0.3",
            "Host" : "localhost:8999",
            "User-Agent" : "Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:79.0) Gecko/20100101 Firefox/79.0",
            "DNT" : "1",
            "Cache-Control" : "max-age=0",
            "Accept" : "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
            "Upgrade-Insecure-Requests" : "1"
        },
        "uri" : "/a/c/ramen.jpg",
        "method" : "GET",
        "httpVersion" : "1.1",
        "headersOut" : {},
        "args" : {
            "foo" : "bar"
        },
        "variables": {
            "cache_signing_key_enabled": 1,
            "request_body": "",
            "uri_path": "/a/c/ramen.jpg"
        },
        "status" : 0
    };

    _runSignatureV4(r);

    if (!"signing_key_hash" in r.variables) {
        throw "Hash key not written to r.variables.signing_key_hash";
    }

    _runSignatureV4(r);
}

function testSignatureV4CacheInvalidatedOnCredentialRotation() {
    printHeader('testSignatureV4CacheInvalidatedOnCredentialRotation');
    /* Regression (GH-122): the signing-key cache was keyed by date alone, so
       when temporary credentials rotate within a day (an AssumeRole refresh,
       an IMDS/ECS rotation) the key derived from the previous secret kept
       signing requests until the UTC date rolled over, failing every one of
       them with SignatureDoesNotMatch. */
    const timestamp = new Date('2020-08-11T19:42:14Z');
    const eightDigitDate = utils.getEightDigitDate(timestamp);
    const amzDatetime = utils.getAmzDatetime(timestamp, eightDigitDate);
    const region = 'us-west-2';
    const service = 's3';
    const canonicalRequest = 'GET\n/\n\nhost:example.com\n\nhost\npayload-hash';
    const r = {
        log: function(msg) {
            console.log(msg);
        },
        variables: {
            cache_signing_key_enabled: 1
        }
    };
    const credsA = {accessKeyId: 'AKIDROTATIONFIRST',
        secretAccessKey: 'first-rotation-secret', sessionToken: null};
    const credsB = {accessKeyId: 'AKIDROTATIONSECOND',
        secretAccessKey: 'second-rotation-secret', sessionToken: null};

    const signatureA = awssig4._buildSignatureV4(r,
        amzDatetime, eightDigitDate, credsA, region, service, canonicalRequest);
    const expectedToken = eightDigitDate + '.' + credsA.accessKeyId + ':';
    if (r.variables.signing_key_hash.indexOf(expectedToken) !== 0) {
        throw 'Cache entry is not bound to the access key id.\n' +
        'Actual:   [' + r.variables.signing_key_hash + ']\n' +
        'Expected: [' + expectedToken + '...]';
    }

    const signatureB = awssig4._buildSignatureV4(r,
        amzDatetime, eightDigitDate, credsB, region, service, canonicalRequest);
    /* Derived without the cache in play: a stale cached key would produce a
       different signature for the rotated secret. */
    const kSigningB = awssig4._buildSigningKeyHash(
        credsB.secretAccessKey, eightDigitDate, region, service);
    const expectedStringToSignB = 'AWS4-HMAC-SHA256\n' + amzDatetime + '\n' +
        eightDigitDate + '/' + region + '/' + service + '/aws4_request\n' +
        mod_hmac.createHash('sha256').update(canonicalRequest).digest('hex');
    const expectedSignatureB = mod_hmac.createHmac('sha256', kSigningB)
        .update(expectedStringToSignB).digest('hex');
    if (signatureB !== expectedSignatureB) {
        throw 'Rotated credentials were signed with a stale cached key.\n' +
        'Actual:   [' + signatureB + ']\n' +
        'Expected: [' + expectedSignatureB + ']';
    }
    if (signatureA === signatureB) {
        throw 'Rotation must produce a different signature for a different secret';
    }
}

function testSignatureV4DebugLogsRedactSecrets() {
    printHeader('testSignatureV4DebugLogsRedactSecrets');
    const logs = [];
    const timestamp = new Date('2020-08-11T19:42:14Z');
    const eightDigitDate = utils.getEightDigitDate(timestamp);
    const amzDatetime = utils.getAmzDatetime(timestamp, eightDigitDate);
    const secret = 'pvgoBEA1z7zZKqN9RoKVksKh31AtNou+pspn+iyb';
    const sessionToken = 'A_SECURITY_TOKEN';
    const region = 'us-west-2';
    const service = 's3';
    const creds = {secretAccessKey: secret, sessionToken: sessionToken};
    const r = {
        method: 'GET',
        variables: {
            cache_signing_key_enabled: 1,
            request_body: ''
        }
    };

    r.log = function(msg) {
        logs.push(msg);
    };

    const canonicalRequest = awssig4._buildCanonicalRequest(r,
        r.method, '/a/c/ramen.jpg', '', 'ez-test-bucket-1.s3-us-west-2.amazonaws.com',
        amzDatetime, sessionToken);
    const signature = awssig4._buildSignatureV4(r, amzDatetime, eightDigitDate,
        creds, region, service, canonicalRequest);
    awssig4._buildSignatureV4(r, amzDatetime, eightDigitDate,
        creds, region, service, canonicalRequest);
    /* Exercise the public entry point too: it logs the assembled
       Authorization header, which must carry a redacted signature. */
    awssig4.signatureV4(r, timestamp, region, service, '/a/c/ramen.jpg', '',
        'ez-test-bucket-1.s3-us-west-2.amazonaws.com', creds);

    const signingKey = awssig4._buildSigningKeyHash(secret, eightDigitDate, region, service);
    const signingKeyHex = signingKey.toString('hex');
    const signingKeyFingerprint = mod_hmac.createHash('sha256')
        .update(signingKey)
        .digest('hex');
    const sessionTokenFingerprint = mod_hmac.createHash('sha256')
        .update(sessionToken)
        .digest('hex');
    const allLogs = logs.join('\n');

    if (allLogs.indexOf(signingKeyHex) !== -1) {
        throw 'Debug logs exposed the raw signing key.\nActual:   [' + allLogs + ']';
    }

    if (allLogs.indexOf(sessionToken) !== -1) {
        throw 'Debug logs exposed the raw session token.\nActual:   [' + allLogs + ']';
    }

    if (allLogs.indexOf('AWS v4 Signing Key Fingerprint: [' +
        signingKeyFingerprint + ']') === -1) {
        throw 'Debug logs did not include the signing key fingerprint.\nActual:   [' + allLogs + ']';
    }

    if (allLogs.indexOf('AWS v4 Session Token Fingerprint: [' +
        sessionTokenFingerprint + ']') === -1) {
        throw 'Debug logs did not include the session token fingerprint.\nActual:   [' + allLogs + ']';
    }

    if (allLogs.indexOf('x-amz-security-token:[REDACTED]') === -1) {
        throw 'Debug canonical request did not redact the session token.\nActual:   [' + allLogs + ']';
    }

    /* The signature authenticates the request until the SigV4 clock skew
       window closes, so neither the standalone signature log line nor the
       assembled Authorization header may contain it. */
    if (allLogs.indexOf(signature) !== -1) {
        throw 'Debug logs exposed the raw request signature.\nActual:   [' + allLogs + ']';
    }

    if (allLogs.indexOf('Signature=[REDACTED]') === -1) {
        throw 'Debug Authorization header did not redact the signature.\nActual:   [' + allLogs + ']';
    }
}

function testSignRequestV4Deterministic() {
    printHeader('testSignRequestV4Deterministic');
    const r = {
        log: function(msg) {
            console.log(msg);
        }
    };
    const timestamp = new Date('2020-08-11T19:42:14Z');
    const creds = {
        accessKeyId: 'AKIDEXAMPLE',
        secretAccessKey: 'pvgoBEA1z7zZKqN9RoKVksKh31AtNou+pspn+iyb',
        sessionToken: null
    };
    const payload = 'Action=AssumeRole' +
        '&RoleArn=arn%3Aaws%3Aiam%3A%3A000000000000%3Arole%2Funit-test' +
        '&RoleSessionName=nginx-s3-gateway&Version=2011-06-15';
    /* Derived independently of the module (python3):
       ph = hashlib.sha256(payload.encode()).hexdigest()
       creq = 'POST\n/\n\nhost:sts.amazonaws.com\n' +
              'x-amz-content-sha256:' + ph + '\nx-amz-date:20200811T194214Z\n' +
              '\nhost;x-amz-content-sha256;x-amz-date\n' + ph
       sts = 'AWS4-HMAC-SHA256\n20200811T194214Z\n' +
             '20200811/us-east-1/sts/aws4_request\n' + sha256(creq)
       key = HMAC-chain('AWS4'+secret, '20200811', 'us-east-1', 'sts',
             'aws4_request'); signature = HMAC(key, sts) */
    const expectedPayloadHash =
        'b818483d6616f22f446591f85c8e6d8bfb0de11563bbe8bb9abf134c944d00d0';
    const expectedAuthHeader = 'AWS4-HMAC-SHA256 ' +
        'Credential=AKIDEXAMPLE/20200811/us-east-1/sts/aws4_request,' +
        'SignedHeaders=host;x-amz-content-sha256;x-amz-date,' +
        'Signature=f09691137c2452c6b53f6810a1a07ed46f32a55ad3619e19da462a0dd338d8f3';

    const signed = awssig4.signRequestV4(r, timestamp, 'us-east-1', 'sts',
        'POST', '/', '', 'sts.amazonaws.com', payload, creds);

    if (signed.amzDatetime !== '20200811T194214Z') {
        throw 'signRequestV4 produced the wrong x-amz-date value.\n' +
        'Actual:   [' + signed.amzDatetime + ']';
    }
    if (signed.payloadHash !== expectedPayloadHash) {
        throw 'signRequestV4 produced the wrong payload hash.\n' +
        'Actual:   [' + signed.payloadHash + ']\n' +
        'Expected: [' + expectedPayloadHash + ']';
    }
    if (signed.authHeader !== expectedAuthHeader) {
        throw 'signRequestV4 produced the wrong Authorization header.\n' +
        'Actual:   [' + signed.authHeader + ']\n' +
        'Expected: [' + expectedAuthHeader + ']';
    }
}

function testSignRequestV4WithSessionToken() {
    printHeader('testSignRequestV4WithSessionToken');
    const logs = [];
    const r = {
        log: function(msg) {
            logs.push(msg);
        }
    };
    const sessionToken = 'A_SECURITY_TOKEN';
    const creds = {
        accessKeyId: 'AKIDEXAMPLE',
        secretAccessKey: 'pvgoBEA1z7zZKqN9RoKVksKh31AtNou+pspn+iyb',
        sessionToken: sessionToken
    };

    const signed = awssig4.signRequestV4(r, new Date('2020-08-11T19:42:14Z'),
        'us-east-1', 'sts', 'POST', '/', '', 'sts.amazonaws.com',
        'Action=AssumeRole&Version=2011-06-15', creds);

    if (signed.authHeader.indexOf(
        'SignedHeaders=host;x-amz-content-sha256;x-amz-date;x-amz-security-token,') < 0) {
        throw 'Session-token source credentials must sign the ' +
        'x-amz-security-token header.\nActual: [' + signed.authHeader + ']';
    }
    const allLogs = logs.join('\n');
    if (allLogs.indexOf(sessionToken) !== -1) {
        throw 'Debug logs exposed the raw session token.\nActual:   [' + allLogs + ']';
    }
    const signature = signed.authHeader.split('Signature=')[1];
    if (allLogs.indexOf(signature) !== -1) {
        throw 'Debug logs exposed the raw request signature.\nActual:   [' + allLogs + ']';
    }
}

function testSignRequestV4DoesNotTouchSigningKeyCache() {
    printHeader('testSignRequestV4DoesNotTouchSigningKeyCache');
    /* The Plus signing-key cache is keyed by date alone, so an sts-scoped
       key written there would poison every subsequent S3 signature. Seed a
       cache entry and prove signRequestV4 neither reads nor replaces it. */
    const seededCacheEntry = '20200811:"an-s3-scoped-signing-key"';
    const r = {
        log: function(msg) {
            console.log(msg);
        },
        variables: {
            cache_signing_key_enabled: 1,
            signing_key_hash: seededCacheEntry
        }
    };

    const signed = awssig4.signRequestV4(r, new Date('2020-08-11T19:42:14Z'),
        'us-east-1', 'sts', 'POST', '/', '', 'sts.amazonaws.com',
        'Action=AssumeRole&Version=2011-06-15',
        {accessKeyId: 'AKIDEXAMPLE',
            secretAccessKey: 'pvgoBEA1z7zZKqN9RoKVksKh31AtNou+pspn+iyb',
            sessionToken: null});

    if (r.variables.signing_key_hash !== seededCacheEntry) {
        throw 'signRequestV4 overwrote the signing key cache: [' +
            r.variables.signing_key_hash + ']';
    }
    /* Had the seeded cache entry been read, the signature would not match
       one derived from the real secret. */
    const expectedSuffix = ',Signature=' + (function() {
        const eightDigitDate = '20200811';
        const key = awssig4._buildSigningKeyHash(
            'pvgoBEA1z7zZKqN9RoKVksKh31AtNou+pspn+iyb', eightDigitDate,
            'us-east-1', 'sts');
        const payloadHash = mod_hmac.createHash('sha256')
            .update('Action=AssumeRole&Version=2011-06-15').digest('hex');
        const canonicalRequest = 'POST\n/\n\n' +
            'host:sts.amazonaws.com\n' +
            'x-amz-content-sha256:' + payloadHash + '\n' +
            'x-amz-date:20200811T194214Z\n\n' +
            'host;x-amz-content-sha256;x-amz-date\n' + payloadHash;
        const stringToSign = 'AWS4-HMAC-SHA256\n20200811T194214Z\n' +
            eightDigitDate + '/us-east-1/sts/aws4_request\n' +
            mod_hmac.createHash('sha256').update(canonicalRequest).digest('hex');
        return mod_hmac.createHmac('sha256', key)
            .update(stringToSign).digest('hex');
    })();
    if (!signed.authHeader.endsWith(expectedSuffix)) {
        throw 'signRequestV4 did not derive the signing key from the ' +
            'credentials (cached key used?).\nActual: [' + signed.authHeader + ']';
    }
}

async function test() {
    testBuildSigningKeyHashWithReferenceInputs();
    testBuildSigningKeyHashWithTestSuiteInputs();
    testSignatureV4();
    testSignatureV4Cache();
    testSignatureV4CacheInvalidatedOnCredentialRotation();
    testSignatureV4DebugLogsRedactSecrets();
    testSignRequestV4Deterministic();
    testSignRequestV4WithSessionToken();
    testSignRequestV4DoesNotTouchSigningKeyCache();
}

function printHeader(testName) {
    console.log(`\n## ${testName}`);
}

test();
console.log('Finished unit tests for awssig4.js');

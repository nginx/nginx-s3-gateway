#!env njs

/*
 *  Copyright 2020 F5 Networks
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

import awscred from "include/awscredentials.js"
import awssig4 from "include/awssig4.js";
import credentialCacheMock from "./credential_cache_mock.js";
import s3gateway from "include/s3gateway.js";

globalThis.ngx = {};

const resetSharedCredentialCache = credentialCacheMock.resetSharedCredentialCache;

var fakeRequest = {
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
    "status" : 0
};

fakeRequest.log = function(msg) {
    console.log(msg);
}

function testEncodeURIComponent() {
    printHeader('testEncodeURIComponent');
    function testPureAsciiAlphaNum() {
        console.log('  ## testPureAsciiAlphaNum');
        let alphaNum = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
        let encoded = s3gateway._encodeURIComponent(alphaNum);
        if (alphaNum !== alphaNum) {
            throw 'Incorrect encoding applied to string.\n' +
            `Actual:   [${encoded}]\n` +
            `Expected: [${expected}]`;
        }
    }
    function testUnicodeText() {
        console.log('  ## testUnicodeText');
        let unicode = 'これは　This is ASCII системы  חן ';
        let expected = '%E3%81%93%E3%82%8C%E3%81%AF%E3%80%80This%20is%20ASCII%20%D1%81%D0%B8%D1%81%D1%82%D0%B5%D0%BC%D1%8B%20%20%D7%97%D7%9F%20';
        let encoded = s3gateway._encodeURIComponent(unicode);
        if (expected !== encoded) {
            throw 'Incorrect encoding applied to string.\n' +
            `Actual:   [${encoded}]\n` +
            `Expected: [${expected}]`;
        }
    }
    function testDiceyCharactersInText() {
        console.log('  ## testDiceyCharactersInText');

        let diceyCharacters = '%@!*()=+$#^&|\\/';
        for (let i = 0; i < diceyCharacters.length; i++) {
            let char = diceyCharacters[i];
            let encoded = s3gateway._encodeURIComponent(char);
            let expected = `%${char.charCodeAt(0).toString(16).toUpperCase()}`;
            if (encoded !== expected) {
                throw 'Incorrect encoding applied to string.\n' +
                `Actual:   [${encoded}]\n` +
                `Expected: [${expected}]`;
            }
        }
    }

    testPureAsciiAlphaNum();
    testUnicodeText();
    testDiceyCharactersInText();
}

function testSplitCachedValues() {
    printHeader('testSplitCachedValues');
    var eightDigitDate = "20200811"
    var kSigningHash = "{\"type\":\"Buffer\",\"data\":[164,135,1,191,232,3,16,62,137,5,31,85,175,34,151,221,118,120,59,188,235,94,180,22,218,183,30,14,173,203,196,246]}"
    var cached = eightDigitDate + ":" + kSigningHash;
    var fields = awssig4._splitCachedValues(cached);

    if (fields.length !== 2) {
        throw 'Unexpected array length returned.\n' +
        'Actual:   [' + fields.length + ']\n' +
        'Expected: [2]';
    }

    if (fields[0] !== eightDigitDate) {
        throw 'Eight digit date field not extracted correctly.\n' +
        'Actual:   [' + fields[0] + ']\n' +
        'Expected: [' + eightDigitDate + ']';
    }

    if (fields[1] !== kSigningHash) {
        throw 'kSigningHash field not extracted correctly.\n' +
        'Actual:   [' + fields[1] + ']\n' +
        'Expected: [' + kSigningHash + ']';
    }
}

function testEditHeaders() {
    printHeader('testEditHeaders');

    const r = {
        "headersOut": {
            "Accept-Ranges": "bytes",
            "Content-Length": 42,
            "Content-Security-Policy": "block-all-mixed-content",
            "Content-Type": "text/plain",
            "X-Amz-Bucket-Region": "us-east-1",
            "X-Amz-Request-Id": "166539E18A46500A",
            "X-Xss-Protection": "1; mode=block"
        },
        "variables": {
            "uri_path": "/a/c/ramen.jpg"
        },
    }

    r.log = function(msg) {
        console.log(msg);
    }

    s3gateway.editHeaders(r);
    
    for (const key in r.headersOut) {
        if (key.toLowerCase().indexOf("x-amz", 0) >= 0) {
            throw "x-amz header not stripped from headers correctly";
        }
    }
}

function testEditHeadersWithAllowedPrefixes() {
    printHeader('testEditHeadersWithAllowedPrefixes');

    process.env['HEADER_PREFIXES_ALLOWED'] = 'x-amz-'
    const r = {
        "headersOut": {
            "Accept-Ranges": "bytes",
            "Content-Length": 42,
            "Content-Security-Policy": "block-all-mixed-content",
            "Content-Type": "text/plain",
            "X-Amz-Bucket-Region": "us-east-1",
            "X-Amz-Request-Id": "166539E18A46500A",
            "X-Xss-Protection": "1; mode=block"
        },
        "variables": {
            "uri_path": "/a/c/ramen.jpg"
        },
    }

    r.log = function(msg) {
        console.log(msg);
    }

    s3gateway.editHeaders(r);
    
    let found_headers_x_amz_ = 0
    for (const key in r.headersOut) {
        if (key.toLowerCase().indexOf("x-amz", 0) == 0) {
            found_headers_x_amz_++;
        }
    }

    if (found_headers_x_amz_ != 2)
        throw "x-amz header stripped from headers, should allow those 2 headers";

    delete process.env['HEADER_PREFIXES_ALLOWED']
        
}


function testEditHeadersHeadDirectory() {
    printHeader('testEditHeadersHeadDirectory');
    let r = {
        "method": "HEAD",
        "headersOut" : {
            "Content-Security-Policy": "block-all-mixed-content",
                "Content-Type": "application/xml",
                "Server": "AmazonS3",
                "X-Amz-Bucket-Region": "us-east-1",
                "X-Amz-Request-Id": "166539E18A46500A",
                "X-Xss-Protection": "1; mode=block"
        },
    "variables": {
            "uri_path": "/a/c/"
        },
    }

    r.log = function(msg) {
        console.log(msg);
    }

    s3gateway.editHeaders(r);

    if (r.headersOut.length > 0) {
        throw "all headers were not stripped from request";
    }
}

function testIsHeaderToBeStripped() {
    printHeader('testIsHeaderToBeStripped');
    // if (s3gateway._isHeaderToBeStripped('cache-control', [])) {
    //     throw "valid header should not be stripped";
    // }
    // if (!s3gateway._isHeaderToBeStripped('x-amz-request-id', [])) {
    //     throw "x-amz header should always be stripped";
    // }
    if (!s3gateway._isHeaderToBeStripped('x-goog-storage-class',
        ['x-goog'])) {
        throw "x-goog-storage-class header should be stripped";
    }
}

function testIsHeaderToBeAllowed() {
    printHeader('testIsHeaderToBeAllowed');

    if (!s3gateway._isHeaderToBeAllowed('x-amz-abc', ['x-amz-'])) {
        throw "x-amz-abc header should be allowed";
    }

    if (s3gateway._isHeaderToBeAllowed('x-amz-xyz',['x-amz-abc'])) {
        throw "x-amz-xyz header should be stripped";
    }
}

function testHasExtension() {
    printHeader('testHasExtension');

    // Only a dot in the final path segment counts as an extension. Dots in
    // intermediate directories must not suppress the trailing-slash redirect
    // (see issue #522).
    const pathsWithExtension = [
        '/ramen.jpg',
        '/a/c/ramen.jpg',
        '/foo.foo/bar.baz',
        '/foo/bar.tar.gz',
        // Dotfiles and trailing dots are treated as having an extension
        '/.hidden',
        '/foo.'
    ];
    const pathsWithoutExtension = [
        '/',
        '/foo',
        '/foo/bar',
        '/foo.foo/',
        '/foo.foo/bar',
        '/foo.foo/bar/baz'
    ];

    pathsWithExtension.forEach(function(path) {
        console.log(`  ## testHasExtension: ${path}`);
        if (!s3gateway._hasExtension(path)) {
            throw `Path [${path}] should be detected as having an extension`;
        }
    });

    pathsWithoutExtension.forEach(function(path) {
        console.log(`  ## testHasExtension: ${path}`);
        if (s3gateway._hasExtension(path)) {
            throw `Path [${path}] should not be detected as having ` +
                'an extension';
        }
    });
}

function testTrailslashControl() {
    printHeader('testTrailslashControl');

    // trailslashControl reads APPEND_SLASH_FOR_POSSIBLE_DIRECTORY into a
    // module-level const at import time, so the flag must be present in the
    // unit test runner environment (the unit_test_env list in
    // test/run_unit_tests.sh sets it). Fail fast with a setup error rather
    // than a misleading assertion failure when it is missing.
    if (process.env['APPEND_SLASH_FOR_POSSIBLE_DIRECTORY'] !== 'true') {
        throw 'testTrailslashControl requires ' +
            'APPEND_SLASH_FOR_POSSIBLE_DIRECTORY=true in the unit test ' +
            'runner environment (see test/run_unit_tests.sh)';
    }

    const testCases = [
        // Extension-less paths that look like possible directories get the
        // append-slash redirect, even under a dotted directory (issue #522)
        ['/dir.name/file', '@trailslash'],
        ['/foo/bar', '@trailslash'],
        // Query params and anchors are ignored for classification
        ['/foo/bar?baz=1', '@trailslash'],
        // Percent-encoded dots are decoded before classification, so this
        // is a file, not a possible directory
        ['/dir/file%2Ejpg', '@error404'],
        // Sequences that are invalid UTF-8 must not throw; they are decoded
        // byte-wise the same way nginx builds $uri
        ['/foo%C3', '@trailslash'],
        // ... including when they appear alongside an encoded dot, which
        // must still be visible to the extension check
        ['/dir/file%2Ejpg%C3', '@error404'],
        ['/file.jpg', '@error404'],
        // An encoded trailing slash decodes to a directory (matching the
        // decoded $uri), so it is not redirected
        ['/foo%2F', '@error404'],
        // Directories fall through to the 404 handler
        ['/dir/', '@error404']
    ];

    testCases.forEach(function(testCase) {
        const uriPath = testCase[0];
        const expected = testCase[1];
        let redirectedTo = null;
        const r = {
            variables: {
                uri_path: uriPath
            },
            internalRedirect: function(target) {
                redirectedTo = target;
            }
        };
        console.log(`  ## testTrailslashControl: ${uriPath} => ${expected}`);
        s3gateway.trailslashControl(r);
        if (redirectedTo !== expected) {
            throw `Path [${uriPath}] should have been redirected to ` +
                `[${expected}] but was [${redirectedTo}]`;
        }
    });
}

function testTrailslashRedirectUri() {
    printHeader('testTrailslashRedirectUri');
    const testCases = [
        ['/statichost', '/statichost'],
        ['//statichost', '/statichost'],
        ['/\\evil.example/foo', '/%5Cevil.example/foo'],
        ['/foo\\bar', '/foo%5Cbar'],
        ['/foo?bar', '/foo%3Fbar'],
        ['/foo#bar', '/foo%23bar'],
        ['/foo%bar', '/foo%25bar'],
        ['/foo bar', '/foo%20bar'],
        ['/foo\r\nX-Evil: yes', '/foo%0D%0AX-Evil%3A%20yes']
    ];

    testCases.forEach(function(testCase) {
        const uri = testCase[0];
        const expected = testCase[1];
        const actual = s3gateway.trailslashRedirectUri({uri: uri});
        console.log(`  ## testTrailslashRedirectUri: ${uri} => ${expected}`);
        if (actual !== expected) {
            throw `Redirect URI [${uri}] was sanitized to [${actual}], expected [${expected}]`;
        }
    });

    /* nginx exposes $uri to njs as a Unicode string in which invalid UTF-8
       bytes are already U+FFFD, so production encodes from the raw byte
       view instead - S3 keys are arbitrary bytes and must round-trip. */
    const rawByteCases = [
        [[0x2F, 0x64, 0x69, 0x72, 0xC3], '/dir%C3'],
        [[0x2F, 0x2F, 0x64, 0x69, 0x72, 0xFF], '/dir%FF'],
        [[0x2F, 0x66, 0x6F, 0x6F, 0x5C, 0x62, 0x61, 0x72], '/foo%5Cbar'],
        [[0x2F, 0x66, 0x6F, 0x6F, 0x0D, 0x0A], '/foo%0D%0A']
    ];

    rawByteCases.forEach(function(testCase) {
        const rawUri = Buffer.from(testCase[0]);
        const expected = testCase[1];
        const actual = s3gateway.trailslashRedirectUri(
            {rawVariables: {uri: rawUri}});
        console.log(`  ## testTrailslashRedirectUri (raw): => ${expected}`);
        if (actual !== expected) {
            throw `Raw redirect URI was sanitized to [${actual}], expected [${expected}]`;
        }
    });
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

function testS3uri() {
    printHeader('testS3uri');

    const savedStyle = process.env['S3_STYLE'];
    const bucket = process.env['S3_BUCKET_NAME'];

    // uri_full_path is the client-facing path from $request_uri; uri_path is
    // that path after the STRIP/PREFIX_LEADING_DIRECTORY_PATH map. They are
    // identical unless one of those variables is configured.
    function makeRequest(uriPath, uriFullPath) {
        const r = {
            "method": "GET",
            "variables": {
                "uri_path": uriPath,
                "uri_full_path": uriFullPath === undefined ?
                    uriPath : uriFullPath,
                "forIndexPage": "true"
            }
        };
        r.log = function(msg) {
            console.log(msg);
        };
        return r;
    }

    function check(style, opts, uriPath, expected, uriFullPath) {
        process.env['S3_STYLE'] = style;
        const actual = s3gateway.s3uri(makeRequest(uriPath, uriFullPath), opts);
        if (actual !== expected) {
            throw `Unexpected s3uri result for S3_STYLE=${style} ` +
                `uri_path=${uriPath}` +
                `\nActual:   [${actual}]` +
                `\nExpected: [${expected}]`;
        }
    }

    try {
        // Virtual-hosted styles never carry the bucket name in the path, so
        // preserveBasePath is a no-op for them.
        check('virtual-v2', undefined, '/a/c/ramen.jpg', '/a/c/ramen.jpg');
        check('virtual-v2', { preserveBasePath: true }, '/a/c/ramen.jpg',
            '/a/c/ramen.jpg');

        // Path style prepends the bucket name by default...
        check('path', undefined, '/a/c/ramen.jpg',
            `/${bucket}/a/c/ramen.jpg`);
        // ...but not for gateway-relative URIs such as the loadContent()
        // index page probe, which re-enters the gateway and would otherwise
        // gain the bucket name a second time (GH-210).
        check('path', { preserveBasePath: true }, '/a/c/ramen.jpg',
            '/a/c/ramen.jpg');

        // Directory URIs, shaped like the requests loadContent() probes
        // with. The runner env leaves PROVIDE_INDEX_PAGE unset, so no index
        // page suffix is appended here.
        check('path', undefined, '/a/c/', `/${bucket}/a/c/`);
        check('path', { preserveBasePath: true }, '/a/c/', '/a/c/');

        // When PREFIX_LEADING_DIRECTORY_PATH rewrites the request path,
        // uri_path carries the prefix but uri_full_path does not. A
        // gateway-relative URI must be the client-facing path - the front
        // door re-applies the rewrite on re-entry, so a uri_path-based probe
        // would gain the prefix a second time (GH-575). Default opts keep
        // building the S3-addressed URI from the rewritten uri_path.
        check('virtual-v2', { preserveBasePath: true }, '/b/a/c/', '/a/c/',
            '/a/c/');
        check('path', { preserveBasePath: true }, '/b/a/c/', '/a/c/',
            '/a/c/');
        check('virtual-v2', undefined, '/b/a/c/', '/b/a/c/', '/a/c/');
        check('path', undefined, '/b/a/c/', `/${bucket}/b/a/c/`, '/a/c/');
    } finally {
        restoreEnv('S3_STYLE', savedStyle);
    }
}

function testS3ReqParamsForSigV2() {
    printHeader('testS3ReqParamsForSigV2');

    const savedStyle = process.env['S3_STYLE'];
    const bucket = process.env['S3_BUCKET_NAME'];

    // The module-level ALLOW_LISTING/PROVIDE_INDEX_PAGE constants are false
    // in the unit-test environment (captured at import time), so every case
    // below exercises the object-path branch of s3uri(). The listing-query
    // branch ('?delimiter=...' stripping and the bucket-root fallback) is
    // exercised by the v2 + directory-listing integration leg.
    function makeRequest(uriPath, forIndexPage) {
        const r = {
            "method": "GET",
            "variables": {
                "uri_path": uriPath,
                "uri_full_path": uriPath,
                "forIndexPage": forIndexPage === undefined ?
                    "true" : forIndexPage
            }
        };
        r.log = function(msg) {
            console.log(msg);
        };
        return r;
    }

    function check(style, uriPath, expected, forIndexPage) {
        process.env['S3_STYLE'] = style;
        const params = s3gateway._s3ReqParamsForSigV2(
            makeRequest(uriPath, forIndexPage), bucket);
        if (params.uri !== expected) {
            throw `Unexpected signed v2 resource for S3_STYLE=${style} ` +
                `uri_path=${uriPath}` +
                `\nActual:   [${params.uri}]` +
                `\nExpected: [${expected}]`;
        }
        if (!params.httpDate || !params.httpDate.endsWith(' GMT')) {
            throw `Missing or malformed httpDate: [${params.httpDate}]`;
        }
    }

    try {
        // Canonical input passes through unchanged (pre-GH-578 behavior).
        check('virtual-v2', '/a/c/ramen.jpg', `/${bucket}/a/c/ramen.jpg`);

        // GH-578: the signed resource must be the canonically re-encoded
        // path that proxy_pass sends, never the raw client bytes.
        check('virtual-v2', '/a/plus+plus.txt',
            `/${bucket}/a/plus%2Bplus.txt`);                 // raw '+'
        check('virtual-v2', '/%61.txt', `/${bucket}/a.txt`); // over-encoded
        check('virtual-v2', '/a/plus%2bplus.txt',
            `/${bucket}/a/plus%2Bplus.txt`);                 // lowercase hex
        check('virtual-v2', '/a/%25%40!*()%3D%24%23%5E%26%7C.txt',
            `/${bucket}/a/%25%40%21%2A%28%29%3D%24%23%5E%26%7C.txt`);
        check('virtual-v2', '/системы/system.txt',
            `/${bucket}/%D1%81%D0%B8%D1%81%D1%82%D0%B5%D0%BC%D1%8B/system.txt`);

        // Directories: with PROVIDE_INDEX_PAGE false at import, s3uri()
        // proxies the escaped directory path itself and the signature must
        // follow it for both $forIndexPage states (the js_var default
        // 'true', and 'false' as @s3Directory sets it).
        check('virtual-v2', '/a/c/', `/${bucket}/a/c/`, 'true');
        check('virtual-v2', '/a/c/', `/${bucket}/a/c/`, 'false');

        // SigV2's CanonicalizedResource always begins with '/<bucket>':
        // path style carries it inside s3uri() itself, virtual styles have
        // it prepended - both must yield the same signed resource.
        check('path', '/a/plus+plus.txt', `/${bucket}/a/plus%2Bplus.txt`);
        check('path', '/%61.txt', `/${bucket}/a.txt`);
    } finally {
        restoreEnv('S3_STYLE', savedStyle);
    }
}

function testEscapeURIPathPreservesDoubleSlashes() {
    printHeader('testEscapeURIPathPreservesDoubleSlashes');
    var doubleSlashed = '/testbucketer2/foo3//bar3/somedir/license';
    var actual = s3gateway._escapeURIPath(doubleSlashed);
    var expected = '/testbucketer2/foo3//bar3/somedir/license';

    if (actual !== expected) {
        throw 'URI Path escaping is stripping slashes'
    }
}

async function testEcsCredentialRetrieval() {
    printHeader('testEcsCredentialRetrieval');
    resetSharedCredentialCache();
    delete process.env['AWS_ACCESS_KEY_ID'];
    process.env['AWS_CONTAINER_CREDENTIALS_RELATIVE_URI'] = '/example';
    globalThis.ngx.fetch = function (url) {
        console.log('  fetching mock credentials');
        globalThis.recordedUrl = url;

        return Promise.resolve({
            ok: true,
            json: function () {
                return Promise.resolve({
                    AccessKeyId: 'AN_ACCESS_KEY_ID',
                    Expiration: '2017-05-17T15:09:54Z',
                    RoleArn: 'TASK_ROLE_ARN',
                    SecretAccessKey: 'A_SECRET_ACCESS_KEY',
                    Token: 'A_SECURITY_TOKEN',
                });
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
    resetSharedCredentialCache();
    delete process.env['AWS_ACCESS_KEY_ID'];
    delete process.env['AWS_CONTAINER_CREDENTIALS_RELATIVE_URI'];
    globalThis.ngx.fetch = function (url, options) {
        if (url === 'http://169.254.169.254/latest/api/token' && options && options.method === 'PUT') {
            return Promise.resolve({
                ok: true,
                text: function () {
                    return Promise.resolve('A_TOKEN');
                },
            });
        } else if (url === 'http://169.254.169.254/latest/meta-data/iam/security-credentials/') {
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
        }  else if (url === 'http://169.254.169.254/latest/meta-data/iam/security-credentials/A_ROLE_NAME') {
            if (options && options.headers && options.headers['x-aws-ec2-metadata-token'] === 'A_TOKEN') {
                return Promise.resolve({
                    ok: true,
                    json: function () {
                        globalThis.credentialsIssued = true;
                        return Promise.resolve({
                            AccessKeyId: 'AN_ACCESS_KEY_ID',
                            Expiration: '2017-05-17T15:09:54Z',
                            RoleArn: 'TASK_ROLE_ARN',
                            SecretAccessKey: 'A_SECRET_ACCESS_KEY',
                            Token: 'A_SECURITY_TOKEN',
                        });
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
        throw 'Did not reach the point where EC2 credentials were issues.';
    }
}

function printHeader(testName) {
    console.log(`\n## ${testName}`);
}

async function test() {
    testEncodeURIComponent();
    testSplitCachedValues();
    testIsHeaderToBeStripped();
    testEditHeaders();
    testEditHeadersHeadDirectory();
    testHasExtension();
    testTrailslashControl();
    testTrailslashRedirectUri();
    testS3uri();
    testS3ReqParamsForSigV2();
    testEscapeURIPathPreservesDoubleSlashes();
    await testEcsCredentialRetrieval();
    await testEc2CredentialRetrieval();
}

test();
console.log('Finished unit tests for s3gateway.js');

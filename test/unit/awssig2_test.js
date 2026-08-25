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

import awssig2 from "include/awssig2.js";


/*
 * Golden signatures below were computed outside this codebase with:
 *   printf 'GET\n\n\nTue, 11 Aug 2020 19:42:14 GMT\n<req_uri>' | \
 *     openssl dgst -sha1 -hmac 'pvgoBEA1z7zZKqN9RoKVksKh31AtNou+pspn+iyb' \
 *     -binary | base64
 */
function _runSignatureV2(r, req_uri, expected) {
    r.log = function(msg) {
        console.log(msg);
    }
    const timestamp = new Date('2020-08-11T19:42:14Z');
    const accessKey = 'test-access-key-1';
    const secret = 'pvgoBEA1z7zZKqN9RoKVksKh31AtNou+pspn+iyb'
    const creds = {
        accessKeyId:accessKey, secretAccessKey: secret, sessionToken: null
    };

    const httpDate = timestamp.toUTCString();
    let signature = awssig2.signatureV2(r, req_uri, httpDate, creds);

    if (signature !== expected) {
        throw 'V2 signature hash was not created correctly.\n' +
        'Actual:   [' + signature + ']\n' +
        'Expected: [' + expected + ']';
    }
}

function testSignatureV2() {
    printHeader('testSignatureV2');
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
            "uri_path": "/a/c/ramen.jpg"
        },
        "status" : 0
    };

    _runSignatureV2(r, '/test-bucket-1/a/c/ramen.jpg',
        'AWS test-access-key-1:VviSS4cFhUC6eoB4CYqtRawzDrc=');
    // The URI-encoded resource enters the string-to-sign verbatim (GH-578:
    // the caller must pass the canonically re-encoded path that is proxied
    // upstream, never the raw client bytes).
    _runSignatureV2(r, '/test-bucket-1/a/plus%2Bplus.txt',
        'AWS test-access-key-1:EQjACHhosMdSvkpL2jgtmVwTgXo=');
}

async function test() {
    testSignatureV2();
}

function printHeader(testName) {
    console.log(`\n## ${testName}`);
}

test();
console.log('Finished unit tests for awssig2.js');

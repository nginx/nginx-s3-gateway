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

/**
 * @module awssig4
 * @alias AwsSig4
 */

/**
 * @typedef {Object} SignedRequestHeaders
 * @property {string} authHeader - HTTP Authorization header value
 * @property {string} amzDatetime - value for the x-amz-date request header
 * @property {string} payloadHash - value for the x-amz-content-sha256 request header
 */

import utils from "./utils.js";

const mod_hmac = require('crypto');

/**
 * Constant defining the headers being signed.
 * @type {string}
 */
const DEFAULT_SIGNED_HEADERS = 'host;x-amz-content-sha256;x-amz-date';

/**
 * Placeholder used in debug logs for secret values that must not be emitted.
 * @type {string}
 */
const DEBUG_REDACTED_VALUE = '[REDACTED]';

/**
 * Name of the signed header carrying the AWS session token. Shared between
 * canonical request construction and debug-log redaction so that the
 * redaction always byte-matches the signed header.
 * @type {string}
 */
const X_AMZ_SECURITY_TOKEN_HEADER = 'x-amz-security-token';

/**
 * Create HTTP Authorization header for authenticating with an AWS compatible
 * v4 API.
 *
 * @param r {NginxHTTPRequest} HTTP request object
 * @param timestamp {Date} timestamp associated with request (must fall within a skew)
 * @param region {string} API region associated with request
 * @param service {string} service code (for example, s3, lambda)
 * @param uri {string} The URI-encoded version of the absolute path component URL to create a canonical request
 * @param queryParams {string} The URL-encoded query string parameters to create a canonical request
 * @param host {string} HTTP host header value
 * @param credentials {Credentials} Credential object with AWS credentials in it (AccessKeyId, SecretAccessKey, SessionToken)
 * @returns {string} HTTP Authorization header value
 */
function signatureV4(r, timestamp, region, service, uri, queryParams, host, credentials) {
    const eightDigitDate = utils.getEightDigitDate(timestamp);
    const amzDatetime = utils.getAmzDatetime(timestamp, eightDigitDate);
    const canonicalRequest = _buildCanonicalRequest(r,
        r.method, uri, queryParams, host, amzDatetime, credentials.sessionToken);
    const signature = _buildSignatureV4(r, amzDatetime, eightDigitDate,
        credentials, region, service, canonicalRequest);
    const authHeader = _buildAuthHeader(
        r, credentials, eightDigitDate, region, service, signature);

    /* The signature authenticates this exact request until the SigV4 clock
       skew window closes, so it must never appear in logs - redact it the
       same way the canonical request redacts the session token. */
    if (utils.debugEnabled) {
        utils.debug_log(r, 'AWS v4 Auth header: [' +
            authHeader.replace(signature, DEBUG_REDACTED_VALUE) + ']');
    }

    return authHeader;
}

/**
 * Create the Authorization header and companion signed header values for a
 * request the gateway originates itself (such as the STS AssumeRole call),
 * as opposed to a proxied client request: every request component is an
 * explicit parameter rather than being read from r.
 *
 * The signing-key cache used by signatureV4 is deliberately bypassed here:
 * its entries are not scoped by region or service (see _buildSignatureV4),
 * so caching a key derived for one region/service pair would poison the
 * signatures of every other pair sharing the cache entry.
 *
 * @see {@link https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html | Create a signed AWS API request}
 * @param r {NginxHTTPRequest} HTTP request object (used only for debug logging)
 * @param timestamp {Date} timestamp associated with request (must fall within a skew)
 * @param region {string} API region associated with request
 * @param service {string} service code (for example, sts)
 * @param method {string} HTTP method of the request being signed
 * @param uri {string} URI-encoded absolute path component of the request
 * @param queryParams {string} URL-encoded query string parameters ('' when none)
 * @param host {string} HTTP Host header value (hostname[:port])
 * @param payload {string} exact request body being sent
 * @param credentials {Credentials} Credential object with AWS credentials in it (AccessKeyId, SecretAccessKey, SessionToken)
 * @returns {SignedRequestHeaders} header values for the signed request
 */
function signRequestV4(r, timestamp, region, service, method, uri, queryParams,
    host, payload, credentials) {
    const eightDigitDate = utils.getEightDigitDate(timestamp);
    const amzDatetime = utils.getAmzDatetime(timestamp, eightDigitDate);
    /* Hashing the payload here rather than in the caller guarantees the
       x-amz-content-sha256 header value always byte-matches the hash inside
       the canonical request. */
    const payloadHash = mod_hmac.createHash('sha256')
        .update(payload)
        .digest('hex');
    const canonicalRequest = _buildCanonicalRequest(r,
        method, uri, queryParams, host, amzDatetime, credentials.sessionToken,
        payloadHash);

    if (utils.debugEnabled) {
        utils.debug_log(r, 'AWS v4 signed request canonical request: [' +
            _canonicalRequestForDebug(canonicalRequest, credentials.sessionToken) + ']');
    }

    const canonicalRequestHash = mod_hmac.createHash('sha256')
        .update(canonicalRequest)
        .digest('hex');
    const stringToSign = _buildStringToSign(
        amzDatetime, eightDigitDate, region, service, canonicalRequestHash);
    const kSigningHash = _buildSigningKeyHash(
        credentials.secretAccessKey, eightDigitDate, region, service);
    const signature = mod_hmac.createHmac('sha256', kSigningHash)
        .update(stringToSign).digest('hex');
    const authHeader = _buildAuthHeader(
        r, credentials, eightDigitDate, region, service, signature);

    /* Same redaction contract as signatureV4: the raw signature must never
       reach the logs. */
    if (utils.debugEnabled) {
        utils.debug_log(r, 'AWS v4 signed request Auth header: [' +
            authHeader.replace(signature, DEBUG_REDACTED_VALUE) + ']');
    }

    return {
        authHeader: authHeader,
        amzDatetime: amzDatetime,
        payloadHash: payloadHash
    };
}

/**
 * Creates a canonical request that will later be signed
 *
 * @see {@link https://docs.aws.amazon.com/general/latest/gr/sigv4-create-canonical-request.html | Creating a Canonical Request}
 * @param method {string} HTTP method
 * @param uri {string} URI associated with request
 * @param queryParams {string} query parameters associated with request
 * @param host {string} HTTP Host header value
 * @param amzDatetime {string} ISO8601 timestamp string to sign request with
 * @param sessionToken {string|undefined} AWS session token if present
 * @param payloadHash {string|undefined} hex SHA-256 hash of the request body;
 *        callers signing a proxied client request omit it and get the hash of
 *        the client request body, while callers signing a request the gateway
 *        originates itself pass the hash of the body they are about to send
 * @returns {string} string with concatenated request parameters
 * @private
 */
function _buildCanonicalRequest(r,
    method, uri, queryParams, host, amzDatetime, sessionToken, payloadHash) {
    const contentHash = payloadHash === undefined
        ? awsHeaderPayloadHash(r) : payloadHash;
    let canonicalHeaders = 'host:' + host + '\n' +
                           'x-amz-content-sha256:' + contentHash + '\n' +
                           'x-amz-date:' + amzDatetime + '\n';

    if (sessionToken && sessionToken.length > 0) {
        canonicalHeaders += X_AMZ_SECURITY_TOKEN_HEADER + ':' + sessionToken + '\n'
    }

    let canonicalRequest = method + '\n';
    canonicalRequest += uri + '\n';
    canonicalRequest += queryParams + '\n';
    canonicalRequest += canonicalHeaders + '\n';
    canonicalRequest += _signedHeaders(r, sessionToken) + '\n';
    canonicalRequest += contentHash;
    return canonicalRequest;
}

/**
 * Creates a signature for use authenticating against an AWS compatible API.
 *
 * @see {@link https://docs.aws.amazon.com/general/latest/gr/signature-version-4.html | AWS V4 Signing Process}
 * @param r {NginxHTTPRequest} HTTP request object
 * @param amzDatetime {string} ISO8601 timestamp string to sign request with
 * @param eightDigitDate {string} date in the form of 'YYYYMMDD'
 * @param creds {object} AWS credentials
 * @param region {string} API region associated with request
 * @param service {string} service code (for example, s3, lambda)
 * @param canonicalRequest {string} string with concatenated request parameters
 * @returns {string} hex encoded hash of signature HMAC value
 * @private
 */
function _buildSignatureV4(
    r, amzDatetime, eightDigitDate, creds, region, service, canonicalRequest) {
    /* Fingerprinting and redaction hash and copy request-sized strings, so
       skip that work entirely on the hot path unless debug logging is on. */
    if (utils.debugEnabled) {
        if (creds.sessionToken && creds.sessionToken.length > 0) {
            utils.debug_log(r, 'AWS v4 Session Token Fingerprint: [' +
                _debugFingerprint(creds.sessionToken) + ']');
        }

        utils.debug_log(r, 'AWS v4 Auth Canonical Request: [' +
            _canonicalRequestForDebug(canonicalRequest, creds.sessionToken) + ']');
    }

    const canonicalRequestHash = mod_hmac.createHash('sha256')
        .update(canonicalRequest)
        .digest('hex');

    utils.debug_log(r, 'AWS v4 Auth Canonical Request Hash: [' + canonicalRequestHash + ']');

    const stringToSign = _buildStringToSign(
        amzDatetime, eightDigitDate, region, service, canonicalRequestHash);

    utils.debug_log(r, 'AWS v4 Auth Signing String: [' + stringToSign + ']');

    let kSigningHash;

    /* If we have a keyval zone and key defined for caching the signing key hash,
     * then signing key caching will be enabled. By caching signing keys we can
     * accelerate the signing process because we will have four less HMAC
     * operations that have to be performed per incoming request. The signing
     * key expires every day, so our cache key can persist for 24 hours safely.
     */
    if ("variables" in r && r.variables.cache_signing_key_enabled == 1) {
        // cached value is in the format: [eightDigitDate].[accessKeyId]:[signingKeyHash]
        /* The validity token binds the entry to the access key id as well as
           the date: temporary credentials (AssumeRole, IMDS, ECS, web
           identity) rotate within a day, and a key derived from the previous
           secret would otherwise keep signing requests until the UTC date
           rolls over, failing every one of them with SignatureDoesNotMatch
           (GH-122). The access key id is the observable proxy for the secret
           it was issued with; neither it nor the date can contain the ':'
           separator _splitCachedValues splits on. */
        const cacheValidityToken = eightDigitDate + '.' + creds.accessKeyId;
        const cached = "signing_key_hash" in r.variables ? r.variables.signing_key_hash : "";
        const fields = _splitCachedValues(cached);
        const cacheIsValid = fields.length === 2 && fields[0] === cacheValidityToken;

        // If true, use cached value
        if (cacheIsValid) {
            utils.debug_log(r, 'AWS v4 Using cached Signing Key Hash');
            /* We are forced to JSON encode the string returned from the HMAC
             * operation because it is in a very specific format that include
             * binary data and in order to preserve that data when persisting
             * we encode it as JSON. By doing so we can gracefully decode it
             * when reading from the cache. */
            kSigningHash = Buffer.from(JSON.parse(fields[1]));
        // Otherwise, generate a new signing key hash and store it in the cache
        } else {
            kSigningHash = _buildSigningKeyHash(creds.secretAccessKey, eightDigitDate, region, service);
            utils.debug_log(r, 'Writing signing key cache entry for: [' + cacheValidityToken + ']');
            r.variables.signing_key_hash = cacheValidityToken + ':' + JSON.stringify(kSigningHash);
        }
    // Otherwise, don't use caching at all (like when we are using NGINX OSS)
    } else {
        kSigningHash = _buildSigningKeyHash(creds.secretAccessKey, eightDigitDate, region, service);
    }

    if (utils.debugEnabled) {
        utils.debug_log(r, 'AWS v4 Signing Key Fingerprint: [' +
            _debugFingerprint(kSigningHash) + ']');
    }

    const signature = mod_hmac.createHmac('sha256', kSigningHash)
        .update(stringToSign).digest('hex');

    /* The raw signature is replayable secret material (see signatureV4), so
       only a fingerprint of it may reach the debug log. */
    if (utils.debugEnabled) {
        utils.debug_log(r, 'AWS v4 Signature Fingerprint: [' +
            _debugFingerprint(signature) + ']');
    }

    return signature;
}

/**
 * Creates a non-reusable fingerprint for secret values included in debug logs.
 *
 * @param value {NjsStringOrBuffer} secret value
 * @returns {string} SHA-256 fingerprint
 * @private
 */
function _debugFingerprint(value) {
    return mod_hmac.createHash('sha256')
        .update(value)
        .digest('hex');
}

/**
 * Redacts the session token before logging the canonical request. The original
 * canonical request is still used to calculate the signature.
 *
 * @param canonicalRequest {string} canonical request used for signing
 * @param sessionToken {string|undefined} AWS session token if present
 * @returns {string} canonical request safe for debug logs
 * @private
 */
function _canonicalRequestForDebug(canonicalRequest, sessionToken) {
    if (!sessionToken || sessionToken.length === 0) {
        return canonicalRequest;
    }

    return canonicalRequest.replace(
        X_AMZ_SECURITY_TOKEN_HEADER + ':' + sessionToken + '\n',
        X_AMZ_SECURITY_TOKEN_HEADER + ':' + DEBUG_REDACTED_VALUE + '\n');
}

/**
 * Creates a string to sign by concatenating together multiple parameters required
 * by the signatures algorithm.
 *
 * @see {@link https://docs.aws.amazon.com/general/latest/gr/sigv4-create-string-to-sign.html | String to Sign}
 * @param amzDatetime {string} ISO8601 timestamp string to sign request with
 * @param eightDigitDate {string} date in the form of 'YYYYMMDD'
 * @param region {string} region associated with server API
 * @param service {string} service code (for example, s3, lambda)
 * @param canonicalRequestHash {string} hex encoded hash of canonical request string
 * @returns {string} a concatenated string of the passed parameters formatted for signatures
 * @private
 */
function _buildStringToSign(amzDatetime, eightDigitDate, region, service, canonicalRequestHash) {
    return 'AWS4-HMAC-SHA256\n' +
        amzDatetime + '\n' +
        eightDigitDate + '/' + region + '/' + service + '/aws4_request\n' +
        canonicalRequestHash;
}

/**
 * Assembles the HTTP Authorization header value from a computed signature
 * and its credential scope. Shared by signatureV4 and signRequestV4 so the
 * header format cannot drift between the proxied-request and
 * gateway-originated signing paths.
 *
 * @param r {NginxHTTPRequest} HTTP request object
 * @param credentials {Credentials} Credential object with AWS credentials in it (AccessKeyId, SecretAccessKey, SessionToken)
 * @param eightDigitDate {string} date in the form of 'YYYYMMDD'
 * @param region {string} API region associated with request
 * @param service {string} service code (for example, s3, sts)
 * @param signature {string} hex encoded SigV4 signature
 * @returns {string} HTTP Authorization header value
 * @private
 */
function _buildAuthHeader(r, credentials, eightDigitDate, region, service, signature) {
    return 'AWS4-HMAC-SHA256 Credential='
        .concat(credentials.accessKeyId, '/', eightDigitDate, '/', region, '/', service, '/aws4_request,',
            'SignedHeaders=', _signedHeaders(r, credentials.sessionToken), ',Signature=', signature);
}

/**
 * Creates a string containing the headers that need to be signed as part of v4
 * signature authentication.
 *
 * @param r {NginxHTTPRequest} HTTP request object
 * @param sessionToken {string|undefined} AWS session token if present
 * @returns {string} semicolon delimited string of the headers needed for signing
 * @private
 */
function _signedHeaders(r, sessionToken) {
    let headers = DEFAULT_SIGNED_HEADERS;
    if (sessionToken && sessionToken.length > 0) {
        headers += ';' + X_AMZ_SECURITY_TOKEN_HEADER;
    }
    return headers;
}

/**
 * Creates a signing key HMAC. This value is used to sign the request made to
 * the API.
 *
 * @param kSecret {string} secret access key
 * @param eightDigitDate {string} date in the form of 'YYYYMMDD'
 * @param region {string} region associated with server API
 * @param service {string} name of service that request is for e.g. s3, lambda
 * @returns {ArrayBuffer} signing HMAC
 * @private
 */
function _buildSigningKeyHash(kSecret, eightDigitDate, region, service) {
    const kDate = mod_hmac.createHmac('sha256', 'AWS4'.concat(kSecret))
        .update(eightDigitDate).digest();
    const kRegion = mod_hmac.createHmac('sha256', kDate)
        .update(region).digest();
    const kService = mod_hmac.createHmac('sha256', kRegion)
        .update(service).digest();
    const kSigning = mod_hmac.createHmac('sha256', kService)
        .update('aws4_request').digest();

    return kSigning;
}

/**
 * Splits the cached values into an array with two elements or returns an
 * empty array if the input string is invalid. The first element contains
 * the validity token (eight digit date plus access key id) and the second
 * element contains a JSON string of the kSigningHash.
 *
 * @param cached {string} input string to parse
 * @returns {Array<string>} array containing the validity token and kSigningHash or empty
 * @private
 */
function _splitCachedValues(cached) {
    const matchedPos = cached.indexOf(':', 0);
    // Do a sanity check on the position returned, if it isn't sane, return
    // an empty array and let the caller logic process it.
    if (matchedPos < 0 || matchedPos + 1 > cached.length) {
        return []
    }

    const eightDigitDate = cached.substring(0, matchedPos);
    const kSigningHash = cached.substring(matchedPos + 1);

    return [eightDigitDate, kSigningHash]
}

/**
 * Outputs the timestamp used to sign the request, so that it can be added to
 * the 'x-amz-date' header and sent by NGINX. The output format is
 * ISO 8601: YYYYMMDD'T'HHMMSS'Z'.
 * @see {@link https://docs.aws.amazon.com/general/latest/gr/sigv4-date-handling.html | Handling dates in Signature Version 4}
 *
 * @param _r {NginxHTTPRequest} HTTP request object (not used, but required for NGINX configuration)
 * @returns {string} ISO 8601 timestamp
 */
function awsHeaderDate(_r) {
    return utils.getAmzDatetime(
        utils.Now(),
        utils.getEightDigitDate(utils.Now())
    );
}

/**
 * Return a payload hash in the header
 *
 * @param r {NginxHTTPRequest} HTTP request object
 * @returns {string} payload hash
 */
function awsHeaderPayloadHash(r) {
    const reqBody = r.variables.request_body ? r.variables.request_body: '';
    const payloadHash = mod_hmac.createHash('sha256', 'utf8')
        .update(reqBody)
        .digest('hex');
    return payloadHash;
}

export default {
    awsHeaderDate,
    awsHeaderPayloadHash,
    signRequestV4,
    signatureV4,
    // These functions do not need to be exposed, but they are exposed so that
    // unit tests can run against them.
    _buildCanonicalRequest,
    _buildSignatureV4,
    _buildSigningKeyHash,
    _splitCachedValues
}

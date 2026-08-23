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
 * @module awscredentials
 * @alias AwsCredentials
 */

/**
 * @typedef {Object} Credentials
 * @property {string} accessKeyId - AWS access key ID
 * @property {string} secretAccessKey - AWS secret access key
 * @property {string | null} sessionToken - AWS session token
 * @property {string | null} expiration - Expiration timestamp of the credentials
 */

import utils from "./utils.js";

const fs = require('fs');

/**
 * The current moment as a timestamp. This timestamp will be used across
 * functions in order for there to be no variations in signatures.
 *
 * This constant exists solely for signature-timestamp stability and is stable
 * per njs VM context, not per wall-clock moment. Never use it for freshness
 * or expiry decisions: if module scope persists across requests (e.g. the
 * QuickJS engine with context reuse), it freezes at context-creation time.
 * @type {Date}
 */
const NOW = new Date();

/**
 * Constant base URI to fetch credentials together with the credentials relative URI, see
 * https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-iam-roles.html for more details.
 * @type {string}
 */
const ECS_CREDENTIAL_BASE_URI = 'http://169.254.170.2';

/**
 * URL to EC2 Instance Metadata Service (IMDS) token endpoint
 * @see {@link https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instancedata-data-retrieval.html| EC2 Instance Metadata Service}
 * @type {string}
 */
const EC2_IMDS_TOKEN_ENDPOINT = 'http://169.254.169.254/latest/api/token';

/**
 * URL to EC2 Instance Metadata Service (IMDS) security credentials endpoint
 * @type {string}
 */
const EC2_IMDS_SECURITY_CREDENTIALS_ENDPOINT = 'http://169.254.169.254/latest/meta-data/iam/security-credentials/';

/**
 * URL to EKS Pod Identity Agent credentials endpoint
 * @type {string}
 */
const EKS_POD_IDENTITY_AGENT_CREDENTIALS_ENDPOINT = 'http://169.254.170.23/v1/credentials'

/**
 * Offset to the expiration of credentials, when they should be considered expired and refreshed. The maximum
 * time here can be 5 minutes, the IMDS and ECS credentials endpoint will make sure that each returned set of credentials
 * is valid for at least another 5 minutes.
 *
 * To make sure we always refresh the credentials instead of retrieving the same again, keep credentials until 4:30 minutes
 * before they really expire.
 *
 * @type {number}
 */
const maxValidityOffsetMs = 4.5 * 60 * 1000;

/**
 * Key used for OSS temporary credential caching in the njs shared dictionary.
 * @type {string}
 */
const INSTANCE_CREDENTIAL_CACHE_KEY = 'instance_credentials';

/**
 * Name of the njs shared dictionary zone that caches OSS temporary
 * credentials. Must byte-match the zone declared in
 * oss/etc/nginx/conf.d/instance_credential_cache.conf.
 * @type {string}
 */
const INSTANCE_CREDENTIAL_CACHE_ZONE = 'instance_credential_cache';


/**
 * Get the current session token from either the instance profile credential
 * cache or environment variables.
 *
 * @param r {NginxHTTPRequest} HTTP request object (not used, but required for NGINX configuration)
 * @returns {string} current session token or empty string
 */
function sessionToken(r) {
    const credentials = readCredentials(r);
    /* The cache entry can expire between the auth_request credential check
       and this evaluation (the Plus keyval zone carries a timeout; the OSS
       shared dict deliberately does not, see
       oss/etc/nginx/conf.d/instance_credential_cache.conf), so tolerate a
       missing entry instead of crashing the request with a TypeError. */
    if (credentials === undefined) {
        return '';
    }
    if (credentials.sessionToken) {
        return credentials.sessionToken;
    }
    return '';
}

/**
 * Get the instance profile credentials needed to authenticate against S3 from
 * a backend cache. If the credentials cannot be found, then return undefined.
 * @param r {NginxHTTPRequest} HTTP request object (not used, but required for NGINX configuration)
 * @returns {Credentials|undefined} AWS instance profile credentials or undefined
 */
function readCredentials(r) {
    if ('AWS_ACCESS_KEY_ID' in process.env && 'AWS_SECRET_ACCESS_KEY' in process.env) {
        let sessionToken = 'AWS_SESSION_TOKEN' in process.env ?
            process.env['AWS_SESSION_TOKEN'] : null;
        if (sessionToken !== null && sessionToken.length === 0) {
            sessionToken = null;
        }
        return {
            accessKeyId: process.env['AWS_ACCESS_KEY_ID'],
            secretAccessKey: process.env['AWS_SECRET_ACCESS_KEY'],
            sessionToken: sessionToken,
            expiration: null
        };
    }
    if ("variables" in r && r.variables.cache_instance_credentials_enabled == 1) {
        return _readCredentialsFromKeyValStore(r);
    } else {
        return _readCredentialsFromSharedDict(r);
    }
}

/**
 * Read credentials from the NGINX Keyval store. If it is not found, then
 * return undefined.
 *
 * @param r {NginxHTTPRequest} HTTP request object (not used, but required for NGINX configuration)
 * @returns {Credentials|undefined} AWS instance profile credentials or undefined
 * @private
 */
function _readCredentialsFromKeyValStore(r) {
    const cached = r.variables.instance_credential_json;

    if (!cached) {
        return undefined;
    }

    try {
        return JSON.parse(cached);
    } catch (e) {
        utils.debug_log(r, `Error parsing JSON value from r.variables.instance_credential_json: ${e}`);
        return undefined;
    }
}

/**
 * Read credentials from the OSS njs shared dictionary. If they are not found,
 * then return undefined.
 *
 * @param r {NginxHTTPRequest} HTTP request object (used for debug logging)
 * @returns {Credentials|undefined} AWS instance profile credentials or undefined
 * @private
 */
function _readCredentialsFromSharedDict(r) {
    const cached = _instanceCredentialSharedDict().get(INSTANCE_CREDENTIAL_CACHE_KEY);

    if (!cached) {
        return undefined;
    }

    try {
        return JSON.parse(cached);
    } catch (e) {
        utils.debug_log(r, `Error parsing JSON value from ngx.shared.${INSTANCE_CREDENTIAL_CACHE_ZONE}: ${e}`);
        return undefined;
    }
}

/**
 * Write the instance profile credentials to a caching backend.
 *
 * @param r {NginxHTTPRequest} HTTP request object (not used, but required for NGINX configuration)
 * @param credentials {Credentials} AWS instance profile credentials
 */
function writeCredentials(r, credentials) {
    /* Do not bother writing credentials if we are running in a mode where we
       do not need instance credentials. */
    if (process.env['AWS_ACCESS_KEY_ID'] && process.env['AWS_SECRET_ACCESS_KEY']) {
        return;
    }

    /* Guard against caching malformed credentials (such as an error response
       body that was mistakenly parsed as credentials) - field values are
       deliberately not logged so that secrets cannot leak into logs. */
    if (!credentials || !credentials.accessKeyId || !credentials.secretAccessKey) {
        throw 'Cannot write invalid credentials: missing accessKeyId or secretAccessKey';
    }

    if ("variables" in r && r.variables.cache_instance_credentials_enabled == 1) {
        _writeCredentialsToKeyValStore(r, credentials);
    } else {
        _writeCredentialsToSharedDict(credentials);
    }
}

/**
 * Write the instance profile credentials to the NGINX Keyval store.
 *
 * @param r {NginxHTTPRequest} HTTP request object (not used, but required for NGINX configuration)
 * @param credentials {{accessKeyId: (string), secretAccessKey: (string), sessionToken: (string), expiration: (string)}} AWS instance profile credentials
 * @private
 */
function _writeCredentialsToKeyValStore(r, credentials) {
    r.variables.instance_credential_json = JSON.stringify(credentials);
}

/**
 * Write the instance profile credentials to the OSS njs shared dictionary.
 *
 * @param credentials {Credentials} AWS instance profile credentials
 * @private
 */
function _writeCredentialsToSharedDict(credentials) {
    _instanceCredentialSharedDict().set(INSTANCE_CREDENTIAL_CACHE_KEY, JSON.stringify(credentials));
}

/**
 * Get the OSS shared dictionary used to cache temporary credentials.
 *
 * The OSS image configures this zone with js_shared_dict_zone. Keeping the
 * lookup behind a helper produces a clear failure when a custom NGINX config
 * omits that required zone instead of silently falling back to disk.
 *
 * @returns {NgxSharedDict} shared dictionary used for credential caching
 * @private
 */
function _instanceCredentialSharedDict() {
    if (typeof ngx === 'undefined' || !("shared" in ngx) ||
        !(INSTANCE_CREDENTIAL_CACHE_ZONE in ngx.shared)) {
        throw `NGINX shared dictionary ${INSTANCE_CREDENTIAL_CACHE_ZONE} is unavailable`;
    }

    return ngx.shared[INSTANCE_CREDENTIAL_CACHE_ZONE];
}

/**
 * Get the credentials needed to create AWS signatures in order to authenticate
 * to AWS service. If the gateway is being provided credentials via an instance
 * profile credential as provided over the metadata endpoint, this function will:
 * 1. Try to read the credentials from cache
 * 2. Determine if the credentials are stale
 * 3. If the cached credentials are missing or stale, it gets new credentials
 *    from the metadata endpoint.
 * 4. If new credentials were pulled, it writes the credentials back to the
 *    cache.
 *
 * If the gateway is not using instance profile credentials, then this function
 * quickly exits.
 *
 * @param r {NginxHTTPRequest} HTTP request object
 * @returns {Promise<void>}
 */
async function fetchCredentials(r) {
    /* If we are not using an AWS instance profile to set our credentials we
       exit quickly and don't write a credentials file. */
    if (utils.areAllEnvVarsSet(['AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY'])) {
        r.return(200);
        return;
    }

    let current;

    try {
        current = readCredentials(r);
    } catch (e) {
        /* A failing credential cache turns every request into a 500, so
           surface it at error level rather than only under DEBUG (a custom
           NGINX configuration missing the cache zone lands here). */
        r.error(`Could not read credentials: ${e}`);
        r.return(500);
        return;
    }

    if (current) {
        // If AWS returns a Unix timestamp it will be in seconds, but in Date constructor we should provide timestamp in milliseconds
        // In some situations (including EC2 and Fargate) current.expiration will be an RFC 3339 string - see https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/iam-roles-for-amazon-ec2.html#instance-metadata-security-credentials
        const expireAt = typeof current.expiration == 'number' ? current.expiration * 1000 : current.expiration
        const exp = new Date(expireAt).getTime() - maxValidityOffsetMs;
        /* Use a live clock rather than NOW: NOW is stable per njs VM context
           for signature consistency, so it goes stale for expiry checks
           whenever module scope outlives a single request. */
        if (new Date().getTime() < exp) {
            r.return(200);
            return;
        }
    }

    let credentials;

    utils.debug_log(r, 'Cached credentials are expired or not present, requesting new ones');

    if (utils.areAllEnvVarsSet('AWS_CONTAINER_CREDENTIALS_RELATIVE_URI')) {
        const relative_uri = process.env['AWS_CONTAINER_CREDENTIALS_RELATIVE_URI'] || '';
        const uri = ECS_CREDENTIAL_BASE_URI + relative_uri;
        try {
            credentials = await _fetchEcsRoleCredentials(uri);
        } catch (e) {
            utils.debug_log(r, `Could not load ECS task role credentials: ${e}`);
            r.return(500);
            return;
        }
    }
    else if (utils.areAllEnvVarsSet('AWS_WEB_IDENTITY_TOKEN_FILE')) {
        try {
            credentials = await _fetchWebIdentityCredentials(r)
        } catch (e) {
            utils.debug_log(r, `Could not assume role using web identity: ${e}`);
            r.return(500);
            return;
        }
    } 
    else if (utils.areAllEnvVarsSet('AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE')) {
        try {
            credentials = await _fetchEKSPodIdentityCredentials(r)
        } catch (e) {
            utils.debug_log(r, `Could not assume role using EKS pod identity: ${e}`);
            r.return(500);
            return;
        }
    } else {
        try {
            credentials = await _fetchEC2RoleCredentials(r);
        } catch (e) {
            utils.debug_log(r, `Could not load EC2 task role credentials: ${e}`);
            r.return(500);
            return;
        }
    }
    try {
        writeCredentials(r, credentials);
    } catch (e) {
        /* Cache write failures also 500 every request, so they too must be
           visible at the default error log level, not only under DEBUG. */
        r.error(`Could not write credentials: ${e}`);
        r.return(500);
        return;
    }
    r.return(200);
}

/**
 * Throws when a credentials-endpoint response has a non-2xx status so that
 * error response bodies are never parsed as credentials.
 *
 * @param resp {Response} response object returned by ngx.fetch
 * @param endpointName {string} human-readable endpoint name for the error
 * @private
 */
function _checkResponseOk(resp, endpointName) {
    if (!resp.ok) {
        throw `${endpointName} response was not ok (status: ${resp.status}).`;
    }
}

/**
 * Get the credentials needed to generate AWS signatures from the ECS
 * (Elastic Container Service) metadata endpoint.
 *
 * @param credentialsUri {string} endpoint to get credentials from
 * @returns {Promise<Credentials>}
 * @private
 */
async function _fetchEcsRoleCredentials(credentialsUri) {
    const resp = await ngx.fetch(credentialsUri);
    _checkResponseOk(resp, 'ECS credentials endpoint');
    const creds = await resp.json();

    return {
        accessKeyId: creds.AccessKeyId,
        secretAccessKey: creds.SecretAccessKey,
        sessionToken: creds.Token,
        expiration: creds.Expiration,
    };
}

/**
 * Get the credentials needed to generate AWS signatures from the EC2
 * metadata endpoint.
 *
 * @param r {NginxHTTPRequest} HTTP request object
 * @returns {Promise<Credentials>}
 * @private
 */
async function _fetchEC2RoleCredentials(r) {
    /* Standard AWS SDK setting: when true, never fall back to IMDSv1 -
       credential retrieval fails closed when an IMDSv2 token cannot be
       obtained.
       See: https://docs.aws.amazon.com/sdkref/latest/guide/feature-imds-credentials.html */
    const imdsV1Disabled = utils.parseBoolean(
        process.env['AWS_EC2_METADATA_V1_DISABLED'] || 'false');
    let tokenResp = null;
    let imdsV1FallbackReason = null;
    try {
        tokenResp = await ngx.fetch(EC2_IMDS_TOKEN_ENDPOINT, {
            headers: {
                'x-aws-ec2-metadata-token-ttl-seconds': '21600',
            },
            method: 'PUT',
        });
    } catch (e) {
        /* A network error or timeout on the token request falls back to
           IMDSv1 below, matching AWS SDK behavior. This covers instances
           whose HttpPutResponseHopLimit is too low for the gateway's network
           position (e.g. running inside a container behind a bridge network),
           where the token response is dropped but IMDSv1 GETs succeed. */
        if (imdsV1Disabled) {
            throw `IMDSv2 token request failed (${e}) and IMDSv1 fallback ` +
                'is disabled by AWS_EC2_METADATA_V1_DISABLED.';
        }
        imdsV1FallbackReason = `the IMDSv2 token request failed (${e})`;
        utils.debug_log(r, `EC2 IMDS token request failed (${e}), falling back to IMDSv1`);
    }
    /* Fall back to IMDSv1 (no session token) when the IMDSv2 token request is
       rejected with 403/404/405, matching AWS SDK behavior with IMDSv1-only
       metadata services such as older metadata emulators. Other failure
       statuses (e.g. 429/5xx throttling on an IMDSv2-required instance) are
       fatal so that the root cause is surfaced instead of the misleading 401
       a token-less request would produce. */
    const headers = {};
    if (tokenResp) {
        if (tokenResp.ok) {
            headers['x-aws-ec2-metadata-token'] = await tokenResp.text();
        } else if (imdsV1Disabled) {
            throw `IMDS token endpoint response was not ok (status: ${tokenResp.status}) ` +
                'and IMDSv1 fallback is disabled by AWS_EC2_METADATA_V1_DISABLED.';
        } else if (tokenResp.status === 403 || tokenResp.status === 404 ||
                   tokenResp.status === 405) {
            imdsV1FallbackReason = `the IMDS token endpoint returned status ${tokenResp.status}`;
            utils.debug_log(r, `EC2 IMDS token endpoint returned status ${tokenResp.status}, falling back to IMDSv1`);
        } else {
            _checkResponseOk(tokenResp, 'IMDS token endpoint');
        }
    }
    let resp = await ngx.fetch(EC2_IMDS_SECURITY_CREDENTIALS_ENDPOINT, {
        headers: headers,
    });
    if (!resp.ok && imdsV1FallbackReason) {
        /* Without this attribution, an IMDSv2-required instance surfaces only
           the 401 from the token-less GET, hiding the token failure that
           caused the downgrade. */
        throw `Security credentials endpoint response was not ok (status: ${resp.status}) ` +
            `after falling back to IMDSv1 because ${imdsV1FallbackReason}; ` +
            'the instance may require IMDSv2.';
    }
    _checkResponseOk(resp, 'Security credentials endpoint');
    /* This _might_ get multiple possible roles in other scenarios, however,
       EC2 supports attaching one role only.It should therefore be safe to take
       the whole output, even given IMDS _might_ (?) be able to return multiple
       roles. */
    const credName = await resp.text();
    if (credName === "") {
        throw 'No credentials available for EC2 instance';
    }
    resp = await ngx.fetch(EC2_IMDS_SECURITY_CREDENTIALS_ENDPOINT + credName, {
        headers: headers,
    });
    _checkResponseOk(resp, 'EC2 role credentials endpoint');
    const creds = await resp.json();

    return {
        accessKeyId: creds.AccessKeyId,
        secretAccessKey: creds.SecretAccessKey,
        sessionToken: creds.Token,
        expiration: creds.Expiration,
    };
}

/**
 * Get the credentials needed to generate AWS signatures from the EKS Pod Identity Agent
 * endpoint.
 *
 * @returns {Promise<Credentials>}
 * @private
 */
async function _fetchEKSPodIdentityCredentials() {
    /* Trim the token so a trailing newline in a hand-created token file does
       not produce an invalid Authorization header value; tokens themselves
       never contain whitespace. */
    const token = fs.readFileSync(process.env['AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE']).toString().trim();
    let resp = await ngx.fetch(EKS_POD_IDENTITY_AGENT_CREDENTIALS_ENDPOINT, {
        headers: {
            'Authorization': token,
        },
    });
    _checkResponseOk(resp, 'EKS Pod Identity credentials endpoint');
    const creds = await resp.json();

    return {
        accessKeyId: creds.AccessKeyId,
        secretAccessKey: creds.SecretAccessKey,
        sessionToken: creds.Token,
        expiration: creds.Expiration,
    };
}
/**
 * Get the credentials by assuming calling AssumeRoleWithWebIdentity with the environment variable
 * values ROLE_ARN, AWS_WEB_IDENTITY_TOKEN_FILE and AWS_ROLE_SESSION_NAME
 *
 * @returns {Promise<Credentials>}
 * @private
 */
async function _fetchWebIdentityCredentials(r) {
    const arn = process.env['AWS_ROLE_ARN'];
    const name = process.env['AWS_ROLE_SESSION_NAME'];

    let sts_endpoint = process.env['STS_ENDPOINT'];
    if (!sts_endpoint) {
        /* On EKS, the ServiceAccount can be annotated with
           'eks.amazonaws.com/sts-regional-endpoints' to control
           the usage of regional endpoints. We are using the same standard
           environment variable here as the AWS SDK. This is with the exception
           of replacing the value `legacy` with `global` to match what EKS sets
           the variable to.
           See: https://docs.aws.amazon.com/sdkref/latest/guide/feature-sts-regionalized-endpoints.html
           See: https://docs.aws.amazon.com/eks/latest/userguide/configure-sts-endpoint.html */
        const sts_regional = process.env['AWS_STS_REGIONAL_ENDPOINTS'] || 'global';
        if (sts_regional === 'regional') {
            /* STS regional endpoints can be derived from the region's name.
               See: https://docs.aws.amazon.com/general/latest/gr/sts.html */
            const region = process.env['AWS_REGION'];
            if (region) {
                sts_endpoint = `https://sts.${region}.amazonaws.com`;
            } else {
                throw 'Missing required AWS_REGION env variable';
            }
        } else {
            // This is the default global endpoint
            sts_endpoint = 'https://sts.amazonaws.com';
        }
    }

    /* Trim the token so a trailing newline in a hand-created token file is
       not percent-encoded into the token value (STS would reject it); JWTs
       and OAuth tokens never contain leading or trailing whitespace. */
    const token = fs.readFileSync(process.env['AWS_WEB_IDENTITY_TOKEN_FILE']).toString().trim();

    /* Percent-encode the values - IAM role session names may legally contain
       '+' and '=', and web identity tokens that are not base64url-encoded
       JWTs (e.g. OAuth access tokens) may contain characters that corrupt
       query-string parsing when left unencoded. */
    const params = `Version=2011-06-15&Action=AssumeRoleWithWebIdentity&RoleArn=${encodeURIComponent(arn)}&RoleSessionName=${encodeURIComponent(name)}&WebIdentityToken=${encodeURIComponent(token)}`;

    const response = await ngx.fetch(sts_endpoint + "?" + params, {
        headers: {
            "Accept": "application/json"
        },
        method: 'GET',
    });
    if (!response.ok) {
        /* Cap the amount of the error body kept so that an unexpectedly large
           error document cannot balloon the thrown message; real STS error
           bodies are far smaller than this. */
        const errorBody = (await response.text()).slice(0, 1024);
        throw `STS endpoint response was not ok (status: ${response.status}, body: ${errorBody}).`;
    }

    const resp = await response.json();
    const creds = resp.AssumeRoleWithWebIdentityResponse.AssumeRoleWithWebIdentityResult.Credentials;

    return {
        accessKeyId: creds.AccessKeyId,
        secretAccessKey: creds.SecretAccessKey,
        sessionToken: creds.SessionToken,
        expiration: creds.Expiration,
    };
}

/**
 * Get the timestamp used across functions in order for there to be no
 * variations in signatures.
 *
 * The returned value is the module-level NOW constant, which is stable per
 * njs VM context rather than the current wall-clock moment. Never use it for
 * freshness or expiry decisions - see the note on NOW.
 *
 * @returns {Date} signature-stable timestamp for the current VM context
 */
function Now() {
    return NOW;
}

export default {
    INSTANCE_CREDENTIAL_CACHE_KEY,
    Now,
    fetchCredentials,
    readCredentials,
    sessionToken,
    writeCredentials
}

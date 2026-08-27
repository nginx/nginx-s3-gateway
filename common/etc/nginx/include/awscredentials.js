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

import awssig4 from "./awssig4.js";
import utils   from "./utils.js";

const fs = require('fs');
const mod_xml = require('xml');

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
 * Default IAM role session name used when AWS_ROLE_SESSION_NAME is not set.
 * The default is applied here rather than in the entrypoint scripts because
 * variable assignments there cannot reach the nginx master process (the
 * scripts are executed by the base image entrypoint, not sourced). AWS
 * constrains RoleSessionName to 2-64 characters matching [\w+=,.@-].
 * @see {@link https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRole.html | AssumeRole}
 * @type {string}
 */
const DEFAULT_ROLE_SESSION_NAME = 'nginx-s3-gateway';

/**
 * STS API version sent with the AssumeRole and AssumeRoleWithWebIdentity
 * calls.
 * @type {string}
 */
const STS_API_VERSION = '2011-06-15';

/**
 * The STS global endpoint, used when neither STS_ENDPOINT nor the regional
 * endpoint model selects a more specific one.
 * @see {@link https://docs.aws.amazon.com/general/latest/gr/sts.html | AWS STS endpoints}
 * @type {string}
 */
const STS_GLOBAL_ENDPOINT = 'https://sts.amazonaws.com';

/**
 * SigV4 credential-scope region for requests to the STS global endpoint, and
 * the fallback signing region for a custom STS_ENDPOINT when AWS_REGION is
 * not set.
 * @see {@link https://docs.aws.amazon.com/general/latest/gr/sts.html | AWS STS endpoints}
 * @type {string}
 */
const STS_DEFAULT_SIGNING_REGION = 'us-east-1';

/**
 * Maximum number of characters of an STS error response body retained in
 * thrown error messages, so that an unexpectedly large error document cannot
 * balloon the message; real STS error bodies are far smaller than this.
 * @type {number}
 */
const STS_ERROR_BODY_MAX_LENGTH = 1024;

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
 * Get the long-lived credentials that were configured statically, either in
 * the AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN
 * environment variables or in the files named by their '_FILE' companions
 * (GH-67). If no static credentials are configured, then return undefined and
 * leave the caller to use one of the instance credential providers.
 *
 * @returns {Credentials|undefined} statically configured credentials or undefined
 * @private
 */
function _readStaticCredentials() {
    const accessKeyId = utils.readEnvVarOrFile('AWS_ACCESS_KEY_ID');
    const secretAccessKey = utils.readEnvVarOrFile('AWS_SECRET_ACCESS_KEY');

    if (!accessKeyId || !secretAccessKey) {
        return undefined;
    }

    const sessionToken = utils.readEnvVarOrFile('AWS_SESSION_TOKEN');

    return {
        accessKeyId: accessKeyId,
        secretAccessKey: secretAccessKey,
        sessionToken: sessionToken ? sessionToken : null,
        expiration: null
    };
}

/**
 * Reports whether the gateway is configured to obtain S3 credentials by
 * calling STS AssumeRole signed with the statically configured credentials
 * (GH-122). Active when AWS_ROLE_ARN holds a value (a set-but-empty
 * variable, e.g. from a bare compose pass-through key, counts as unset), no
 * web identity token file is configured (web identity keeps precedence - on
 * EKS both variables are injected together), and static credentials exist to
 * sign the STS request with. Without static credentials the role ARN is
 * ignored and the instance credential providers apply as before.
 *
 * @returns {boolean} true when AssumeRole mode is active
 * @private
 */
function _isAssumeRoleMode() {
    if (!process.env['AWS_ROLE_ARN']) {
        return false;
    }
    /* Same presence semantics as the provider ladder in fetchCredentials. */
    if (utils.areAllEnvVarsSet('AWS_WEB_IDENTITY_TOKEN_FILE')) {
        return false;
    }
    return _readStaticCredentials() !== undefined;
}

/**
 * Get the instance profile credentials needed to authenticate against S3 from
 * a backend cache. If the credentials cannot be found, then return undefined.
 * @param r {NginxHTTPRequest} HTTP request object (not used, but required for NGINX configuration)
 * @returns {Credentials|undefined} AWS instance profile credentials or undefined
 */
function readCredentials(r) {
    /* In AssumeRole mode the static credentials only sign the STS call; S3
       requests must be signed with the assumed temporary credentials from
       the cache instead (GH-122). */
    if (!_isAssumeRoleMode()) {
        const staticCredentials = _readStaticCredentials();
        if (staticCredentials !== undefined) {
            return staticCredentials;
        }
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
       do not need instance credentials. In AssumeRole mode the assumed
       temporary credentials must be cached even though static credentials
       are configured (GH-122). */
    if (_readStaticCredentials() !== undefined && !_isAssumeRoleMode()) {
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
       exit quickly and don't write a credentials file. In AssumeRole mode
       the static credentials are only the input to the STS call, so the
       fetch-and-cache flow below still applies (GH-122). */
    if (_readStaticCredentials() !== undefined && !_isAssumeRoleMode()) {
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

    /* AssumeRole leads the ladder: it is the only provider reachable while
       static credentials are configured (matching the AWS SDKs, where
       environment credentials win), and _isAssumeRoleMode already yields to
       web identity when both are configured. */
    if (_isAssumeRoleMode()) {
        try {
            credentials = await _fetchAssumeRoleCredentials(r);
        } catch (e) {
            utils.debug_log(r, `Could not assume role using static credentials: ${e}`);
            r.return(500);
            return;
        }
    }
    else if (utils.areAllEnvVarsSet('AWS_CONTAINER_CREDENTIALS_RELATIVE_URI')) {
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
 * Resolve the STS endpoint URL and the region used in the SigV4 credential
 * scope for signed requests to it: an explicit STS_ENDPOINT wins (signed
 * with AWS_REGION, falling back to us-east-1); otherwise
 * AWS_STS_REGIONAL_ENDPOINTS='regional' derives the endpoint from AWS_REGION
 * (required in that mode); otherwise the global endpoint, whose credential
 * scope AWS requires to be us-east-1.
 *
 * On EKS, the ServiceAccount can be annotated with
 * 'eks.amazonaws.com/sts-regional-endpoints' to control the usage of
 * regional endpoints. We are using the same standard environment variable
 * here as the AWS SDK. This is with the exception of replacing the value
 * `legacy` with `global` to match what EKS sets the variable to.
 *
 * @see {@link https://docs.aws.amazon.com/sdkref/latest/guide/feature-sts-regionalized-endpoints.html | STS regionalized endpoints}
 * @see {@link https://docs.aws.amazon.com/eks/latest/userguide/configure-sts-endpoint.html | Configure the STS endpoint on EKS}
 * @see {@link https://docs.aws.amazon.com/general/latest/gr/sts.html | AWS STS endpoints}
 * @returns {{endpoint: string, region: string}} STS endpoint URL and signing region
 * @private
 */
function _getStsEndpoint() {
    const configuredRegion = process.env['AWS_REGION'];
    const endpoint = process.env['STS_ENDPOINT'];
    if (endpoint) {
        return {
            endpoint: endpoint,
            region: configuredRegion ? configuredRegion : STS_DEFAULT_SIGNING_REGION
        };
    }
    const stsRegional = process.env['AWS_STS_REGIONAL_ENDPOINTS'] || 'global';
    if (stsRegional === 'regional') {
        /* STS regional endpoints can be derived from the region's name. */
        if (!configuredRegion) {
            throw 'Missing required AWS_REGION env variable';
        }
        return {
            endpoint: `https://sts.${configuredRegion}.amazonaws.com`,
            region: configuredRegion
        };
    }
    return {
        endpoint: STS_GLOBAL_ENDPOINT,
        region: STS_DEFAULT_SIGNING_REGION
    };
}

/**
 * Split an HTTP(S) endpoint URL into the host (hostname[:port], exactly as
 * it must appear in the signed Host header) and the URI-encoded absolute
 * path used in the canonical request ('/' when the URL has no path).
 *
 * @param endpoint {string} endpoint URL, e.g. https://sts.amazonaws.com
 * @returns {{host: string, path: string}} host and path components
 * @private
 */
function _parseStsEndpointUrl(endpoint) {
    const schemeSeparator = '://';
    const schemeEnd = endpoint.indexOf(schemeSeparator);
    if (schemeEnd < 0) {
        throw `STS endpoint is not an absolute http(s) URL (${endpoint})`;
    }
    const hostAndPath = endpoint.slice(schemeEnd + schemeSeparator.length);
    const pathStart = hostAndPath.indexOf('/');
    if (pathStart === 0) {
        throw `STS endpoint has an empty host (${endpoint})`;
    }
    if (pathStart < 0) {
        return { host: hostAndPath, path: '/' };
    }
    return {
        host: hostAndPath.slice(0, pathStart),
        path: hostAndPath.slice(pathStart)
    };
}

/**
 * Extract temporary credentials from an XML AssumeRoleResponse document.
 * XML is parsed rather than JSON because XML is what STS returns by default
 * and the only format S3-compatible stores implement.
 *
 * @see {@link https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRole.html | AssumeRole}
 * @param responseBody {string} XML response body from the STS endpoint
 * @returns {Credentials} temporary credentials of the assumed role session
 * @private
 */
function _parseAssumeRoleResponse(responseBody) {
    let doc;
    try {
        doc = mod_xml.parse(responseBody);
    } catch (e) {
        throw `Unable to parse STS AssumeRole response as XML: ${e}`;
    }

    const response = doc.AssumeRoleResponse;
    const result = response ? response.AssumeRoleResult : undefined;
    const credentials = result ? result.Credentials : undefined;
    if (!credentials || !credentials.AccessKeyId || !credentials.SecretAccessKey ||
        !credentials.SessionToken || !credentials.Expiration) {
        /* The body is deliberately not included in the message: a
           wrong-but-2xx response could still contain credential material. */
        throw 'STS AssumeRole response is missing the ' +
            'AssumeRoleResponse/AssumeRoleResult/Credentials elements';
    }

    return {
        accessKeyId: credentials.AccessKeyId.$text,
        secretAccessKey: credentials.SecretAccessKey.$text,
        sessionToken: credentials.SessionToken.$text,
        expiration: credentials.Expiration.$text,
    };
}

/**
 * Get temporary credentials by calling AssumeRole on the STS endpoint,
 * authenticating with the statically configured credentials (GH-122).
 * Unlike AssumeRoleWithWebIdentity this call must be SigV4-signed, and it is
 * sent the way the AWS SDKs send it - a form-encoded POST - because
 * S3-compatible stores only implement that form.
 *
 * @see {@link https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRole.html | AssumeRole}
 * @param r {NginxHTTPRequest} HTTP request object (used only for debug logging)
 * @returns {Promise<Credentials>}
 * @private
 */
async function _fetchAssumeRoleCredentials(r) {
    const arn = process.env['AWS_ROLE_ARN'];
    const sessionName = process.env['AWS_ROLE_SESSION_NAME'] || DEFAULT_ROLE_SESSION_NAME;
    const sourceCredentials = _readStaticCredentials();
    const sts = _getStsEndpoint();
    const url = _parseStsEndpointUrl(sts.endpoint);

    /* Percent-encode the values - role ARNs contain ':' and '/', and IAM
       role session names may legally contain '+' and '='. The parameters
       must stay sorted by name: the signature covers the exact body bytes. */
    const body = 'Action=AssumeRole' +
        `&RoleArn=${encodeURIComponent(arn)}` +
        `&RoleSessionName=${encodeURIComponent(sessionName)}` +
        `&Version=${STS_API_VERSION}`;

    /* A fresh timestamp rather than utils.Now(): that constant is frozen per
       njs VM context for S3 signature stability, and a stale timestamp here
       would drift outside the SigV4 clock-skew window and be rejected. */
    const signed = awssig4.signRequestV4(r, new Date(), sts.region, 'sts',
        'POST', url.path, '', url.host, body, sourceCredentials);

    const headers = {
        'Authorization': signed.authHeader,
        'Content-Type': 'application/x-www-form-urlencoded',
        'X-Amz-Content-Sha256': signed.payloadHash,
        'X-Amz-Date': signed.amzDatetime
    };
    /* Statically configured temporary source credentials (role chaining)
       carry a session token, which is a signed header and must be sent. */
    if (sourceCredentials.sessionToken) {
        headers['X-Amz-Security-Token'] = sourceCredentials.sessionToken;
    }

    utils.debug_log(r, `Fetching credentials via STS AssumeRole from ${sts.endpoint}`);

    const response = await ngx.fetch(sts.endpoint, {
        body: body,
        headers: headers,
        method: 'POST',
    });
    if (!response.ok) {
        const errorBody = (await response.text()).slice(0, STS_ERROR_BODY_MAX_LENGTH);
        throw `STS AssumeRole response was not ok (status: ${response.status}, body: ${errorBody}).`;
    }

    return _parseAssumeRoleResponse(await response.text());
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
    const name = process.env['AWS_ROLE_SESSION_NAME'] || DEFAULT_ROLE_SESSION_NAME;
    const sts_endpoint = _getStsEndpoint().endpoint;

    /* Trim the token so a trailing newline in a hand-created token file is
       not percent-encoded into the token value (STS would reject it); JWTs
       and OAuth tokens never contain leading or trailing whitespace. */
    const token = fs.readFileSync(process.env['AWS_WEB_IDENTITY_TOKEN_FILE']).toString().trim();

    /* Percent-encode the values - IAM role session names may legally contain
       '+' and '=', and web identity tokens that are not base64url-encoded
       JWTs (e.g. OAuth access tokens) may contain characters that corrupt
       query-string parsing when left unencoded. */
    const params = `Version=${STS_API_VERSION}&Action=AssumeRoleWithWebIdentity&RoleArn=${encodeURIComponent(arn)}&RoleSessionName=${encodeURIComponent(name)}&WebIdentityToken=${encodeURIComponent(token)}`;

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
        const errorBody = (await response.text()).slice(0, STS_ERROR_BODY_MAX_LENGTH);
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
 * Delegates to utils.Now() - the constant moved there so that awssig4.js can
 * read it without importing this module (njs cannot resolve circular
 * imports). The export stays because removing an exported key is a breaking
 * change for custom configurations.
 *
 * @returns {Date} signature-stable timestamp for the current VM context
 */
function Now() {
    return utils.Now();
}

export default {
    INSTANCE_CREDENTIAL_CACHE_KEY,
    Now,
    fetchCredentials,
    readCredentials,
    sessionToken,
    writeCredentials,
    // These functions do not need to be exposed, but they are exposed so that
    // unit tests can run against them.
    _isAssumeRoleMode,
    _getStsEndpoint,
    _parseAssumeRoleResponse,
    _parseStsEndpointUrl,
    _readStaticCredentials
}

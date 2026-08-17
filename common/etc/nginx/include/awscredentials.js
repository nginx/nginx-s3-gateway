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
 * Get the current session token from either the instance profile credential
 * cache or environment variables.
 *
 * @param r {NginxHTTPRequest} HTTP request object (not used, but required for NGINX configuration)
 * @returns {string} current session token or empty string
 */
function sessionToken(r) {
    const credentials = readCredentials(r);
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
        return _readCredentialsFromFile();
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
 * Read the contents of the credentials file into memory. If it is not
 * found, then return undefined.
 *
 * @returns {Credentials|undefined} AWS instance profile credentials or undefined
 * @private
 */
function _readCredentialsFromFile() {
    const credsFilePath = _credentialsTempFile();

    try {
        const creds = fs.readFileSync(credsFilePath);
        return JSON.parse(creds);
    } catch (e) {
        /* Do not throw an exception in the case of when the
           credentials file path is invalid in order to signal to
           the caller that such a file has not been created yet. */
        if (e.code === 'ENOENT') {
            return undefined;
        }
        throw e;
    }
}

/**
 * Returns the path to the credentials temporary cache file.
 *
 * @returns {string} path on the file system to credentials cache file
 * @private
 */
function _credentialsTempFile() {
    if (process.env['AWS_CREDENTIALS_TEMP_FILE']) {
        return process.env['AWS_CREDENTIALS_TEMP_FILE'];
    }
    if (process.env['TMPDIR']) {
        return `${process.env['TMPDIR']}/credentials.json`
    }

    return '/tmp/credentials.json';
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

    if (!credentials) {
        throw `Cannot write invalid credentials: ${JSON.stringify(credentials)}`;
    }

    if ("variables" in r && r.variables.cache_instance_credentials_enabled == 1) {
        _writeCredentialsToKeyValStore(r, credentials);
    } else {
        _writeCredentialsToFile(credentials);
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
 * Write the instance profile credentials to a file on the file system. This
 * file will be quite small and should end up in the file cache relatively
 * quickly if it is repeatedly read.
 *
 * @param credentials {Credentials} AWS instance profile credentials
 * @private
 */
function _writeCredentialsToFile(credentials) {
    fs.writeFileSync(_credentialsTempFile(), JSON.stringify(credentials));
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
        utils.debug_log(r, `Could not read credentials: ${e}`);
        r.return(500);
        return;
    }

    if (current) {
        // If AWS returns a Unix timestamp it will be in seconds, but in Date constructor we should provide timestamp in milliseconds
        // In some situations (including EC2 and Fargate) current.expiration will be an RFC 3339 string - see https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/iam-roles-for-amazon-ec2.html#instance-metadata-security-credentials
        const expireAt = typeof current.expiration == 'number' ? current.expiration * 1000 : current.expiration
        const exp = new Date(expireAt).getTime() - maxValidityOffsetMs;
        if (NOW.getTime() < exp) {
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
            utils.debug_log(r, 'Could not load ECS task role credentials: ' + JSON.stringify(e));
            r.return(500);
            return;
        }
    }
    else if (utils.areAllEnvVarsSet('AWS_WEB_IDENTITY_TOKEN_FILE')) {
        try {
            credentials = await _fetchWebIdentityCredentials(r)
        } catch (e) {
            utils.debug_log(r, 'Could not assume role using web identity: ' + JSON.stringify(e));
            r.return(500);
            return;
        }
    } 
    else if (utils.areAllEnvVarsSet('AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE')) {
        try {
            credentials = await _fetchEKSPodIdentityCredentials(r)
        } catch (e) {
            utils.debug_log(r, 'Could not assume role using EKS pod identity: ' + JSON.stringify(e));
            r.return(500);
            return;
        }
    } else {
        try {
            credentials = await _fetchEC2RoleCredentials();
        } catch (e) {
            utils.debug_log(r, 'Could not load EC2 task role credentials: ' + JSON.stringify(e));
            r.return(500);
            return;
        }
    }
    try {
        writeCredentials(r, credentials);
    } catch (e) {
        utils.debug_log(r, `Could not write credentials: ${e}`);
        r.return(500);
        return;
    }
    r.return(200);
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
    if (!resp.ok) {
        throw 'Credentials endpoint response was not ok.';
    }
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
 * @returns {Promise<Credentials>}
 * @private
 */
async function _fetchEC2RoleCredentials() {
    const tokenResp = await ngx.fetch(EC2_IMDS_TOKEN_ENDPOINT, {
        headers: {
            'x-aws-ec2-metadata-token-ttl-seconds': '21600',
        },
        method: 'PUT',
    });
    const token = await tokenResp.text();
    let resp = await ngx.fetch(EC2_IMDS_SECURITY_CREDENTIALS_ENDPOINT, {
        headers: {
            'x-aws-ec2-metadata-token': token,
        },
    });
    /* This _might_ get multiple possible roles in other scenarios, however,
       EC2 supports attaching one role only.It should therefore be safe to take
       the whole output, even given IMDS _might_ (?) be able to return multiple
       roles. */
    const credName = await resp.text();
    if (credName === "") {
        throw 'No credentials available for EC2 instance';
    }
    resp = await ngx.fetch(EC2_IMDS_SECURITY_CREDENTIALS_ENDPOINT + credName, {
        headers: {
            'x-aws-ec2-metadata-token': token,
        },
    });
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
    const token = fs.readFileSync(process.env['AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE']);
    let resp = await ngx.fetch(EKS_POD_IDENTITY_AGENT_CREDENTIALS_ENDPOINT, {
        headers: {
            'Authorization': token,
        },
    });
if (!resp.ok) {
    throw `Credentials endpoint response was not ok (status: ${resp.status}).`;
}
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

    const token = fs.readFileSync(process.env['AWS_WEB_IDENTITY_TOKEN_FILE']);

    const params = `Version=2011-06-15&Action=AssumeRoleWithWebIdentity&RoleArn=${arn}&RoleSessionName=${name}&WebIdentityToken=${token}`;

    const response = await ngx.fetch(sts_endpoint + "?" + params, {
        headers: {
            "Accept": "application/json"
        },
        method: 'GET',
    });

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
 * Get the current timestamp. This timestamp will be used across functions in
 * order for there to be no variations in signatures.
 *
 * @returns {Date} The current moment as a timestamp
 */
function Now() {
    return NOW;
}

export default {
    Now,
    fetchCredentials,
    readCredentials,
    sessionToken,
    writeCredentials
}

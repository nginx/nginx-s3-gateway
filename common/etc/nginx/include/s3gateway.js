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

/**
 * @module s3gateway
 * @alias S3Gateway
 */

/**
 * @typedef {Object} S3ReqParams
 * @property {string} uri - URI to use for S3 request
 * @property {string|undefined} httpDate - RFC2616 timestamp used to sign the request
 * @property {string|undefined} host - S3 host to use for request
 * @property {string|undefined} queryParams - query parameters to use with S3 request
 */

import awscred from "./awscredentials.js";
import awssig2 from "./awssig2.js";
import awssig4 from "./awssig4.js";
import utils from "./utils.js";

_requireEnvVars('S3_BUCKET_NAME');
_requireEnvVars('S3_SERVER');
_requireEnvVars('S3_SERVER_PROTO');
_requireEnvVars('S3_SERVER_PORT');
_requireEnvVars('S3_REGION');
_requireEnvVars('AWS_SIGS_VERSION');
_requireEnvVars('S3_STYLE');


/**
 * Flag indicating debug mode operation. If true, additional information
 * about signature generation will be logged.
 * @type {boolean}
 */
const ALLOW_LISTING = utils.parseBoolean(process.env['ALLOW_DIRECTORY_LIST']);
/**
 * Flag indicating if index pages should be provided for directories.
 * @type {boolean}
 * */
const PROVIDE_INDEX_PAGE = utils.parseBoolean(process.env['PROVIDE_INDEX_PAGE']);
/**
 * Flag that when enabled checks if requesting a folder is without trailing slash, and return 302
 * appending a slash to it when using for static site hosting.
 * @type {boolean}
 * */
const APPEND_SLASH = utils.parseBoolean(process.env['APPEND_SLASH_FOR_POSSIBLE_DIRECTORY']);
/**
 * Flag indicating if 404 should be returned when requesting an empty bucket.
 * @type {boolean}
 * */
const FOUR_O_FOUR_ON_EMPTY_BUCKET = utils.parseBoolean(process.env['FOUR_O_FOUR_ON_EMPTY_BUCKET']);
/**
 * Additional header prefixes to strip from the response before sending to the
 * client. This is useful for removing headers that may contain sensitive
 * information.
 * @type {Array<String>}
 * */
const ADDITIONAL_HEADER_PREFIXES_TO_STRIP = utils.parseArray(process.env['HEADER_PREFIXES_TO_STRIP']);

/**
 * Additional header prefixes to allow from the response before sending to the
 * client. This is opposite to HEADER_PREFIXES_TO_STRIP.
 * @type {Array<String>}
 * */
const ADDITIONAL_HEADER_PREFIXES_ALLOWED = utils.parseArray(process.env['HEADER_PREFIXES_ALLOWED']);

/**
 * Default filename for index pages to be read off of the backing object store.
 * @type {string}
 * */
const INDEX_PAGE = "index.html";

/**
 * Constant defining the service requests are being signed for.
 * @type {string}
 */
const SERVICE = process.env['S3_SERVICE'] || "s3";

/**
 * Transform the headers returned from S3 such that there isn't information
 * leakage about S3 and do other tasks needed for appropriate gateway output.
 * @param r {NginxHTTPRequest} HTTP request
 */
function editHeaders(r) {
    const isDirectoryHeadRequest =
        ALLOW_LISTING &&
        r.method === 'HEAD' &&
        _isDirectory(decodeURIComponent(r.variables.uri_path));

    /* Strips all x-amz- (if x-amz- is not in ADDITIONAL_HEADER_PREFIXES_ALLOWED) headers from the output HTTP headers so that the
     * requesters to the gateway will not know you are proxying S3. */
    if ('headersOut' in r) {
        for (const key in r.headersOut) {
            const headerName = key.toLowerCase()
            /* We delete all headers when it is a directory head request because
             * none of the information is relevant for passing on via a gateway. */
            if (isDirectoryHeadRequest) {
                delete r.headersOut[key];
            } else if (
                !_isHeaderToBeAllowed(headerName, ADDITIONAL_HEADER_PREFIXES_ALLOWED)
                && _isHeaderToBeStripped(headerName, ADDITIONAL_HEADER_PREFIXES_TO_STRIP)
            ) {
                delete r.headersOut[key];
            }
        }

        /* Transform content type returned on HEAD requests for directories
         * if directory listing is enabled. If you change the output format
         * for the XSL stylesheet from HTML to something else, you will
         * want to change the content type below. */
        if (isDirectoryHeadRequest) {
            r.headersOut['Content-Type'] = 'text/html; charset=utf-8'
        }
    }
}

/**
 * Determines if a given HTTP header should be removed before being
 * sent on to the requesting client.
 * @param headerName {string} Lowercase HTTP header name
 * @param additionalHeadersToStrip {Array<string>} array of additional headers to remove
 * @returns {boolean} true if header should be removed
 */
function _isHeaderToBeStripped(headerName, additionalHeadersToStrip) {
    if (headerName.indexOf('x-amz-', 0) >= 0) {
        return true;
    }

    for (let i = 0; i < additionalHeadersToStrip.length; i++) {
        const headerToStrip = additionalHeadersToStrip[i];
        if (headerName.indexOf(headerToStrip, 0) >= 0) {
            return true;
        }
    }

    return false;
}

/**
 * Determines if a given HTTP header should be force allowed from requesting client.
 * @param headerName {string} Lowercase HTTP header name
 * @param additionalHeadersToAllow {Array<string>} array of additional headers to allow
 * @returns {boolean} true if header should be removed
 */
function _isHeaderToBeAllowed(headerName, additionalHeadersToAllow) {

    for (let i = 0; i < additionalHeadersToAllow.length; i++) {
        const headerToAllow = additionalHeadersToAllow[i];
        if (headerName.indexOf(headerToAllow, 0) >= 0) {
            return true;
        }
    }

    return false;
}

/**
 * Outputs the timestamp used to sign the request, so that it can be added to
 * the 'Date' header and sent by NGINX.
 *
 * @param r {NginxHTTPRequest} HTTP request object (not used, but required for NGINX configuration)
 * @returns {string} RFC2616 timestamp
 */
function s3date(r) {
    return awscred.Now().toUTCString();
}

/**
 * Creates an AWS authentication signature based on the global settings and
 * the passed request parameter.
 *
 * @param r {NginxHTTPRequest} HTTP request object
 * @returns {string} AWS authentication signature
 */
function s3auth(r) {
    const bucket = process.env['S3_BUCKET_NAME'];
    const region = process.env['S3_REGION'];
    const host = r.variables.s3_host;
    const sigver = process.env['AWS_SIGS_VERSION'];

    let signature;

    const credentials = awscred.readCredentials(r);
    /* The cache entry can expire between the auth_request credential check
       and this evaluation (the Plus keyval zone carries a timeout; the OSS
       shared dict deliberately does not, see
       oss/etc/nginx/conf.d/instance_credential_cache.conf). Fail with a
       clear message instead of a TypeError deep in the signing code; the
       next request refetches and recovers. */
    if (credentials === undefined) {
        throw 'AWS credentials are unavailable; the cached credentials may have expired mid-request';
    }
    if (sigver == '2') {
        let req = _s3ReqParamsForSigV2(r, bucket);
        signature = awssig2.signatureV2(r, req.uri, req.httpDate, credentials);
    } else {
        let req = _s3ReqParamsForSigV4(r, bucket, host);
        signature = awssig4.signatureV4(r, awscred.Now(), region, SERVICE,
            req.uri, req.queryParams, req.host, credentials);
    }

    return signature;
}

/**
 * Generate request parameters for AWS signature version 2
 *
 * @see {@link https://docs.aws.amazon.com/AmazonS3/latest/userguide/auth-request-sig-v2.html | AWS signature version 2}
 * @param r {NginxHTTPRequest} HTTP request object
 * @param bucket {string} S3 bucket associated with request
 * @returns {S3ReqParams} s3ReqParams object (host, method, uri, queryParams)
 * @private
 */
function _s3ReqParamsForSigV2(r, bucket) {
    /* If the source URI is a directory, we are sending to S3 a query string
     * local to the root URI, so this is what we need to encode within the
     * string to sign. For example, if we are requesting /bucket/dir1/ from
     * nginx, then in S3 we need to request /?delimiter=/&prefix=dir1/
     * Thus, we can't put the path /dir1/ in the string to sign. */
    let uri = _isDirectory(r.variables.uri_path) ? '/' : r.variables.uri_path;
    // To return index pages + index.html
    if (utils.parseBoolean(r.variables.forIndexPage) && _isDirectory(r.variables.uri_path)){
        uri = r.variables.uri_path + INDEX_PAGE
    }

    return {
        uri: '/' + bucket + uri,
        httpDate: s3date(r)
    };
}

/**
 * Generate request parameters for AWS signature version 4
 *
 * @see {@link https://docs.aws.amazon.com/general/latest/gr/signature-version-4.html | AWS V4 Signing Process}
 * @param r {NginxHTTPRequest} HTTP request object
 * @param bucket {string} S3 bucket associated with request
 * @param host {string} S3 host associated with request
 * @returns {S3ReqParams} s3ReqParams object (host, uri, queryParams)
 * @private
 */
function _s3ReqParamsForSigV4(r, bucket, host) {
    const baseUri = s3BaseUri(r);
    const computed_url = !utils.parseBoolean(r.variables.forIndexPage)
        ? r.variables.uri_path
        : r.variables.uri_path + INDEX_PAGE;
    const queryParams = _s3DirQueryParams(computed_url, r.method);
    let uri;
    if (queryParams.length > 0) {
        if (baseUri.length > 0) {
            uri = baseUri;
        } else {
            uri = '/';
        }
    } else {
        uri = s3uri(r);
    }
    return {
        host: host,
        uri: uri,
        queryParams: queryParams
    };
}

/**
 * Build the base file path for a S3 request URI. This function allows for
 * path style S3 URIs to be created that do not use a subdomain to specify
 * the bucket name.
 *
 * @param r {NginxHTTPRequest} HTTP request object (not used, but required for NGINX configuration)
 * @returns {string} start of the file path for the S3 object URI
 */
function s3BaseUri(r) {
    const bucket = process.env['S3_BUCKET_NAME'];
    // Valid S3_STYLE values are 'virtual', 'virtual-v2' and 'path'; anything
    // else behaves as virtual-style. Read per call (like S3_BUCKET_NAME
    // above) rather than into an import-time const so unit tests can
    // exercise both addressing styles within a single run.
    const s3Style = process.env['S3_STYLE'];
    let basePath;

    if (s3Style === 'path') {
        utils.debug_log(r, 'Using path style uri : ' + '/' + bucket);
        basePath = '/' + bucket;
    } else {
        basePath = '';
    }

    return basePath;
}

/**
 * Returns the s3 path given the incoming request
 *
 * @param r {NginxHTTPRequest} HTTP request
 * @param opts {Object} Additional options for assembling the s3 URI
 * @param opts.preserveBasePath {boolean} If true, produce a URI addressed to
 *   this gateway rather than directly to S3: the bucket name is not prepended
 *   for path-style configurations (the gateway prepends it itself when
 *   proxying - GH-210), and the path is built from the client-facing request
 *   path ($uri_full_path) instead of the rewritten $uri_path, because the
 *   gateway re-applies the STRIP/PREFIX_LEADING_DIRECTORY_PATH rewrite to
 *   every incoming request (GH-575).
 * @returns {string} uri for s3 request
 */
function s3uri(r, opts) {
    if (!opts) {
        opts = { preserveBasePath: false };
    }

    let basePath;
    let path;
    let uriPath;

    if (opts.preserveBasePath) {
        // Gateway-addressed URIs always come from index-page probing, where
        // $forIndexPage is true (the js_var default; only @s3Directory sets
        // it false and never routes back to @s3PreListing), so the
        // directory-listing query branch below cannot run here. The
        // preserveBasePath conjunct on that branch enforces this
        // structurally - a probe must never become a "?delimiter=..."
        // listing URI.
        basePath = '';
        uriPath = r.variables.uri_full_path;
    } else {
        basePath = s3BaseUri(r);
        uriPath = r.variables.uri_path;
    }

    // Create query parameters only if directory listing is enabled.
    // Gateway-addressed URIs (preserveBasePath) are index-page probes and
    // must never become listing queries - see the invariant comment above.
    if (ALLOW_LISTING && !opts.preserveBasePath &&
        !utils.parseBoolean(r.variables.forIndexPage)) {
        const queryParams = _s3DirQueryParams(uriPath, r.method);
        if (queryParams.length > 0) {
            path = `${basePath}?${queryParams}`;
        } else {
            path = _escapeURIPath(`${basePath}${uriPath}`);
        }
    } else {
        // This is a path that will resolve to an index page
        if (PROVIDE_INDEX_PAGE  && _isDirectory(uriPath) ) {
            uriPath += INDEX_PAGE;
        }
        path = _escapeURIPath(`${basePath}${uriPath}`);
    }

    utils.debug_log(r, `S3 Request URI: ${r.method} ${path}`);
    return path;
}

/**
 * Create and encode the query parameters needed to query S3 for an object
 * listing.
 *
 * @param uriPath request URI path
 * @param method request HTTP method
 * @returns {string} query parameters to use with S3 request
 * @private
 */
function _s3DirQueryParams(uriPath, method) {
    if (!_isDirectory(uriPath) || method !== 'GET') {
        return '';
    }

    /* Return if static website. We don't want to list the files in the
       directory, we want to append the index page and get the fil. */
    if (uriPath.endsWith(INDEX_PAGE)){
        return '';
    }

    let path = 'delimiter=%2F'

    if (uriPath !== '/') {
        let decodedUriPath = decodeURIComponent(uriPath);
        let without_leading_slash = decodedUriPath.charAt(0) === '/' ?
            decodedUriPath.substring(1, decodedUriPath.length) : decodedUriPath;
        path += '&prefix=' + _encodeURIComponent(without_leading_slash);
    }

    return path;
}

/**
 * Redirects the request to the appropriate location. If the request is not
 * a read (GET/HEAD) request, then we reject the request outright by returning
 * a HTTP 405 error with a list of allowed methods.
 *
 * @param r {NginxHTTPRequest} HTTP request object
 */
function redirectToS3(r) {
    // This is a read-only S3 gateway, so we do not support any other methods
    if (!(r.method === 'GET' || r.method === 'HEAD')) {
        utils.debug_log(r, 'Invalid method requested: ' + r.method);
        r.internalRedirect("@error405");
        return;
    }

    const uriPath = r.variables.uri_path;
    const isDirectoryListing = ALLOW_LISTING && _isDirectory(uriPath);

    if (isDirectoryListing && (r.method === 'GET' || r.method === 'HEAD')) {
        r.internalRedirect("@s3PreListing");
    } else if (PROVIDE_INDEX_PAGE === true) {
        r.internalRedirect("@s3");
    } else if (!ALLOW_LISTING && !PROVIDE_INDEX_PAGE && uriPath === "/") {
       r.internalRedirect("@error404");
    } else {
        if (r.headersIn["Range"]) {
            r.internalRedirect("@s3_sliced");
        } else {
           r.internalRedirect("@s3"); 
        }
        
    }
}

function trailslashControl(r) {
    if (APPEND_SLASH) {
        // For the purposes of understanding whether this is a directory,
        // consider the uri without query params or anchors. The $uri_path
        // map already strips query params from $request_uri, so this is
        // defensive and otherwise only strips raw anchors. njs
        // String.split(regex) is disproportionately expensive, so find and
        // slice instead - this runs on every 404.
        let path = r.variables.uri_path;
        const separatorIdx = path.search(/[?#]/);
        if (separatorIdx !== -1) {
            path = path.slice(0, separatorIdx);
        }

        // Classify the percent-decoded path so that encoded dots (%2E) are
        // visible to the extension check, approximating the decoded $uri
        // that the @trailslash redirect helper sanitizes. Decode byte-wise the
        // way nginx builds $uri: decodeURIComponent() would throw URIError
        // on sequences nginx accepts (e.g. invalid UTF-8 such as %C3) and
        // then misclassify any encoded dots elsewhere in the same path.
        // Unlike $uri, the result is deliberately not normalized
        // (dot-segments and duplicate slashes are kept) - the decoded path
        // is used for classification only, never emitted in the redirect.
        if (path.indexOf('%') !== -1) {
            path = path.replace(/%([0-9A-Fa-f]{2})/g, function (_match, hex) {
                return String.fromCharCode(parseInt(hex, 16));
            });
        }

        if (!_isDirectory(path) && !_hasExtension(path)) {
            return r.internalRedirect("@trailslash");
        }
    }
        r.internalRedirect("@error404");
}

/**
 * Build the viewer-facing path used for slash-appending redirects.
 *
 * NGINX's normalized `$uri` is the right public path to preserve, but it is
 * percent-decoded. Encode it again before putting it in a Location header so
 * decoded delimiters, control bytes, and backslashes stay path data rather
 * than becoming browser- or header-significant syntax. Collapsing leading
 * slashes keeps a relative Location from becoming a scheme-relative
 * authority redirect.
 *
 * The encoding works on the raw bytes of `$uri` when nginx provides them:
 * `r.uri` is a Unicode string in which bytes that are not valid UTF-8 have
 * already been replaced with U+FFFD, so only the byte view round-trips every
 * S3 key (keys are arbitrary bytes). Unit-test stubs may supply only a
 * string `uri`.
 *
 * @param r {NginxHTTPRequest} HTTP request object
 * @returns {string} safe redirect path without the appended trailing slash
 */
function trailslashRedirectUri(r) {
    let path;

    if ("rawVariables" in r && r.rawVariables.uri) {
        path = _encodePathBytes(r.rawVariables.uri);
    } else {
        path = _escapeURIPathComponents(r.uri || '/');
    }

    return ('/' + path).replace(/^\/+/, '/');
}

/**
 * Percent-encodes every byte of a URI path that is not an unreserved URI
 * character or the path separator. The output alphabet matches
 * _encodeURIComponent, so this produces identical results to the
 * string-based encoders for any valid-UTF-8 input while preserving invalid
 * byte sequences byte-for-byte.
 *
 * @param pathBytes {Buffer} raw bytes of the URI path
 * @returns {string} path with every non-unreserved byte percent-encoded
 * @private
 */
function _encodePathBytes(pathBytes) {
    let encoded = '';

    for (let i = 0; i < pathBytes.length; i++) {
        const byte = pathBytes[i];
        const isUnreserved =
            (byte >= 0x41 && byte <= 0x5A) || // A-Z
            (byte >= 0x61 && byte <= 0x7A) || // a-z
            (byte >= 0x30 && byte <= 0x39) || // 0-9
            byte === 0x2D || byte === 0x2E || // - .
            byte === 0x5F || byte === 0x7E || // _ ~
            byte === 0x2F;                    // / path separator

        if (isUnreserved) {
            encoded += String.fromCharCode(byte);
        } else {
            encoded += '%' + (byte < 0x10 ? '0' : '') +
                byte.toString(16).toUpperCase();
        }
    }

    return encoded;
}

/**
 * Checks if there is an index.html file in the directory.
 * Redirects appropriately. Before that, it checks if
 * directory listing is enforced or not.
 *
 * @param {Object} r - The HTTP request object.
 */
async function loadContent(r) {
    if (!PROVIDE_INDEX_PAGE) {
        r.internalRedirect("@s3Directory");
        return;
    }
    // This URI is addressed to the gateway itself, not to S3: both the
    // loopback probe below and the internalRedirect on success re-enter
    // this server's `location ~ /index\.html$`, which prepends the bucket
    // name when proxying path-style requests to S3 (GH-210) and re-applies
    // the STRIP/PREFIX_LEADING_DIRECTORY_PATH request-path rewrite (GH-575).
    // preserveBasePath therefore yields the client-facing path with no
    // bucket name - anything already rewritten here would be rewritten a
    // second time on re-entry.
    const uri = s3uri(r, { preserveBasePath: true });

    let reply = await ngx.fetch(
        `http://127.0.0.1:80${uri}`
    );

    if (reply.status === 200) {
        utils.debug_log(r, `Found index file, redirecting to: ${uri}`);
        r.internalRedirect(uri);
    } else if (reply.status === 404) {
        // As there was no index file found, just list the contents of the directory
        r.internalRedirect("@s3Directory");
    } else {
        r.internalRedirect("@error500");
    }
}

/**
 * Processes the directory listing output as returned from S3. If
 * FOUR_O_FOUR_ON_EMPTY_BUCKET is enabled, this function will corrupt the
 * XML output by inserting the string 'junk' into the output thereby causing
 * nginx to return a 404 for empty directory listings.
 *
 * If anyone finds a better way to do this, please submit a PR.
 *
 * @param r {NginxHTTPRequest} HTTP request object (not used, but required for NGINX configuration)
 * @param data {NjsStringOrBuffer} chunked data buffer
 * @param flags {NginxHTTPSendBufferOptions} contains field that indicates that a chunk is last
 */
function filterListResponse(r, data, flags) {
    if (FOUR_O_FOUR_ON_EMPTY_BUCKET) {
        let indexIsEmpty = utils.parseBoolean(r.variables.indexIsEmpty);

        if (indexIsEmpty && data.indexOf('<Contents') >= 0) {
            r.variables.indexIsEmpty = false;
            indexIsEmpty = false;
        }

        if (indexIsEmpty && data.indexOf('<CommonPrefixes') >= 0) {
            r.variables.indexIsEmpty = false;
            indexIsEmpty = false;
        }

        if (flags.last && indexIsEmpty) {
            r.sendBuffer('junk', flags);
        } else {
            r.sendBuffer(data, flags);
        }
    } else {
        r.sendBuffer(data, flags);
    }
}

/**
 * Adds additional encoding to a URI component
 *
 * @param string {string} string to encode
 * @returns {string} an encoded string
 * @private
 */
function _encodeURIComponent(string) {
    return encodeURIComponent(string)
        .replace(/[!*'()]/g, (c) =>
            `%${c.charCodeAt(0).toString(16).toUpperCase()}`);
}

/**
 * Escapes the path portion of a URI without escaping the path separator
 * characters (/).
 *
 * @param uri {string} unescaped URI
 * @returns {string} URI with each path component separately escaped
 * @private
 */
function _escapeURIPath(uri) {
    // Check to see if the URI path was already encoded. If so, we decode it.
    const decodedUri = (uri.indexOf('%') >= 0) ? decodeURIComponent(uri) : uri;
    return _escapeURIPathComponents(decodedUri);
}

/**
 * Percent-encodes each component of a decoded path without touching the
 * path separator characters (/).
 *
 * @param path {string} path with decoded components
 * @returns {string} path with each component separately escaped
 * @private
 */
function _escapeURIPathComponents(path) {
    const components = [];

    path.split('/').forEach(function (item, i) {
        components[i] = _encodeURIComponent(item);
    });

    return components.join('/');
}

/**
 * Determines if a given path is a directory based on whether or not the last
 * character in the path is a forward slash (/).
 *
 * @param path {string} path to parse
 * @returns {boolean} true if path is a directory
 * @private
 */
function _isDirectory(path) {
    if (!path) return false;

    return path.slice(-1) === '/';
}

/**
 * Determines if the final segment of a path contains a dot, which the
 * gateway treats as a file extension. Only the final segment is considered,
 * so a dot in an intermediate directory (e.g. /foo.foo/bar) does not count
 * as an extension. Dotfiles (/.hidden) and segments with a trailing dot
 * (/foo.) do count as having an extension, and the final segment must be
 * preceded by a slash (a bare 'foo.jpg' returns false).
 *
 * @param path {string} path to parse
 * @returns {boolean} true if the last path segment has an extension
 * @private
 */
function _hasExtension(path) {
    return /\/[^\/]*\.[^.\/]*$/.test(path);
}

/**
 * Checks to see if the given environment variable is present. If not, an error
 * is thrown.
 * @param envVarName {string} environment variable to check for
 * @private
 */
function _requireEnvVars(envVarName) {
    const isSet = envVarName in process.env;

    if (!isSet) {
        throw(`Required environment variable ${envVarName} is missing`);
    }
}

export default {
    s3date,
    s3auth,
    s3uri,
    trailslashControl,
    trailslashRedirectUri,
    redirectToS3,
    editHeaders,
    filterListResponse,
    loadContent,
    // These functions do not need to be exposed, but they are exposed so that
    // unit tests can run against them.
    _s3ReqParamsForSigV2,
    _s3ReqParamsForSigV4,
    _encodeURIComponent,
    _escapeURIPath,
    _hasExtension,
    _isHeaderToBeStripped
};

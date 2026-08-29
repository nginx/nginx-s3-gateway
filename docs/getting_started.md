# Getting Started Guide

## Contents

[Configuration](#configuration)  
[Running as a Systemd Service](#running-as-a-systemd-service)  
[Running in Containers](#running-in-containers)  
[Supplying Credentials from Files (Docker Secrets)](#supplying-credentials-from-files-docker-secrets)  
[Fetching S3 Credentials via STS AssumeRole](#fetching-s3-credentials-via-sts-assumerole)  
[Running Using AWS Instance Profile Credentials](#running-using-aws-instance-profile-credentials)  
[Running on EKS with IAM roles for service accounts](#running-on-eks-with-iam-roles-for-service-accounts)  
[Running on EKS with EKS Pod Identities](#running-on-eks-with-eks-pod-identities)  
[Troubleshooting](#troubleshooting)  

## Configuration

The following environment variables are used to configure the gateway when
running as a Container or as a Systemd service.

| Name                                  | Required? | Allowed Values                                                                                                                                        | Default                                             | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| ------------------------------------- | --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ALLOW_DIRECTORY_LIST`                | Yes       | `true`, `false`                                                                                                                                       | `false`                                             | Flag enabling directory listing                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `AWS_SIGS_VERSION`                    | Yes       | 2, 4                                                                                                                                                  |                                                     | AWS Signatures API version. Signature v2 cannot authenticate temporary credentials: the session token is not part of a v2 signature, so `AWS_SESSION_TOKEN`, dynamic credential sources (EC2/ECS/EKS roles), and STS AssumeRole (`AWS_ROLE_ARN`) require `4`. The container refuses to start when `AWS_SIGS_VERSION=2` is combined with a session token or `AWS_ROLE_ARN`, or when no static credentials are configured; static credentials win over any dynamic source, so `2` with static credentials boots even when a dynamic source is also present.                                                                                                                                                                                                            |
| `AWS_ACCESS_KEY_ID`                   | Yes       |                                                                                                                                                       |                                                     | Access key                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `AWS_SECRET_ACCESS_KEY`               | Yes       |                                                                                                                                                       |                                                     | Secret access key                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `AWS_SESSION_TOKEN`                   | No        |                                                                                                                                                       |                                                     | Session token. Requires `AWS_SIGS_VERSION=4`: v2 signatures do not cover the session token, and S3 rejects such requests with `SignatureDoesNotMatch`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `AWS_ACCESS_KEY_ID_FILE`              | No        |                                                                                                                                                       |                                                     | Path to a file holding the access key, for use with container secret stores such as Docker secrets. Mutually exclusive with `AWS_ACCESS_KEY_ID`. See [Supplying Credentials from Files](#supplying-credentials-from-files-docker-secrets)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `AWS_SECRET_ACCESS_KEY_FILE`          | No        |                                                                                                                                                       |                                                     | Path to a file holding the secret access key, for use with container secret stores such as Docker secrets. Mutually exclusive with `AWS_SECRET_ACCESS_KEY`. See [Supplying Credentials from Files](#supplying-credentials-from-files-docker-secrets)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `AWS_SESSION_TOKEN_FILE`              | No        |                                                                                                                                                       |                                                     | Path to a file holding the session token, for use with container secret stores such as Docker secrets. Mutually exclusive with `AWS_SESSION_TOKEN`. Requires `AWS_SIGS_VERSION=4` (see `AWS_SESSION_TOKEN`). See [Supplying Credentials from Files](#supplying-credentials-from-files-docker-secrets)                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `S3_BUCKET_NAME`                      | Yes       |                                                                                                                                                       |                                                     | Name of S3 bucket to proxy requests to                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `S3_REGION`                           | Yes       |                                                                                                                                                       |                                                     | Region associated with API                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `S3_SERVER_PORT`                      | Yes       |                                                                                                                                                       |                                                     | SSL/TLS port to connect to                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `S3_SERVER_PROTO`                     | Yes       | `http`, `https`                                                                                                                                       |                                                     | Protocol to used connect to S3 server                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `S3_TRUSTED_CERT_PATH`                | No        |                                                                                                                                                       | `/etc/ssl/certs/ca-certificates.crt`                | CA bundle used to verify HTTPS S3 origin certificates. Set this to a mounted CA bundle when proxying to a private or self-signed S3-compatible endpoint. This setting is separate from `JS_TRUSTED_CERT_PATH`, which only applies to credential retrieval.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `S3_SERVER`                           | Yes       |                                                                                                                                                       |                                                     | S3 host to connect to                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `S3_STYLE`                            | Yes       | `virtual-v2`, `virtual`, `path`, `default`                                                                                                            | `default`                                           | The S3 host/path method. <br><br>`virtual` and `virtual-v2` represent the method that uses DNS-style bucket+hostname:port. The `default` is the same as `virtual`. In the future, the `default` value will become `virtual-v2`. See [Choosing a `S3_STYLE` Setting](#choosing-a-s3_style-setting) below for details. <br><br>`path` is a method that appends the bucket name as the first directory in the URI's path. This method is used by many S3 compatible services. See this [AWS blog article](https://aws.amazon.com/blogs/aws/amazon-s3-path-deprecation-plan-the-rest-of-the-story/) for further information.                                                                                                                                             |
| `S3_SERVICE`                          | Yes       | `s3`, `s3express`                                                                                                                                     | `s3`                                                | Configures the gateway to interface with either normal S3 buckets or S3 Express One Zone                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| `DEBUG`                               | No        | `true`, `false`                                                                                                                                       | `false`                                             | Flag enabling AWS signatures debug output                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `APPEND_SLASH_FOR_POSSIBLE_DIRECTORY` | No        | `true`, `false`                                                                                                                                       | `false`                                             | Flag enabling the return of a relative 302 with a `/` appended to the path. This is independent of the behavior selected in `ALLOW_DIRECTORY_LIST` or `PROVIDE_INDEX_PAGE`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `DIRECTORY_LISTING_PAGE_SIZE`         | No        | positive integers up to `2147483647`                                                                                                                  |                                                     | In `ALLOW_DIRECTORY_LIST=true` mode, the number of entries requested per listing page (the S3 `max-keys` parameter). Unset sends no `max-keys` parameter, so pages hold up to S3's 1000-key maximum; S3 caps larger values at 1000. See [Paginated Listings](#paginated-listings)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `DIRECTORY_LISTING_PATH_PREFIX`       | No        |                                                                                                                                                       |                                                     | In `ALLOW_DIRECTORY_LIST=true` mode [adds defined prefix to links](#configuring-directory-listing)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `FOUR_O_FOUR_ON_EMPTY_BUCKET`         | No        | `true`, `false`                                                                                                                                       | `false`                                             | In `ALLOW_DIRECTORY_LIST=true` mode, return `404 Not Found` instead of an empty directory listing when a bucket or path prefix contains no objects                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `DNS_RESOLVERS`                       | No        |                                                                                                                                                       |                                                     | DNS resolvers (separated by single spaces) to configure NGINX with                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `PROXY_CACHE_MAX_SIZE`                | No        |                                                                                                                                                       | `10g`                                               | Limits cache size                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `PROXY_CACHE_INACTIVE`                | No        |                                                                                                                                                       | `60m`                                               | Cached data that are not accessed during the time specified by the parameter get removed from the cache regardless of their freshness                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `PROXY_CACHE_SLICE_SIZE`              | No        |                                                                                                                                                       | `1m`                                                | For requests with a `Range` header included, determines the size of the chunks in which the file is fetched. Values much smaller than the requests can lead to inefficiencies due to reading and writing many files. See [below for more details](#byte-range-requests-and-caching)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `PROXY_CACHE_VALID_OK`                | No        |                                                                                                                                                       | `1h`                                                | Sets caching time for response code 200 and 302                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `PROXY_CACHE_VALID_NOTFOUND`          | No        |                                                                                                                                                       | `1m`                                                | Sets caching time for response code 404. A cached error is shared by every client that requests the same object with the same request method — see [Caching of Error Responses](#caching-of-error-responses)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `PROXY_CACHE_VALID_FORBIDDEN`         | No        |                                                                                                                                                       | `30s`                                               | Sets caching time for response code 403, which is delivered to clients as a sanitized `404` on every hit. A cached `403` is shared by every client that requests the same object with the same request method; set `0s` to not cache `403`s at all (caching headers returned by the origin still take priority). See [Caching of Error Responses](#caching-of-error-responses)                                                                                                                                                                                                                                                                                                                                                                                       |
| `PROXY_CACHE_USE_STALE`               | No        |                                                                                                                                                       | `error timeout http_500 http_502 http_503 http_504` | Sets conditions under which stale cached data can be used. See the [`proxy_cache_use_stale` directive docs](https://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_cache_use_stale) for more details                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `PROXY_CACHE_BYPASS_NO_CACHE`         | No        | `true`, `false`                                                                                                                                       | `false`                                             | When `true`, a request whose `Cache-Control` header contains the `no-cache` directive (for example a browser hard refresh) bypasses the local cache and fetches a fresh copy from S3. Off by default because clients can use it to drive up S3 request costs. See [Bypassing the Local Cache with Cache-Control: no-cache](#bypassing-the-local-cache-with-cache-control-no-cache)                                                                                                                                                                                                                                                                                                                                                                                   |
| `PROXY_CACHE_IGNORE_HEADERS`          | No        | `X-Accel-Redirect`, `X-Accel-Expires`, `X-Accel-Limit-Rate`, `X-Accel-Buffering`, `X-Accel-Charset`, `Expires`, `Cache-Control`, `Set-Cookie`, `Vary` |                                                     | A space-separated list of S3 response header fields whose caching effect is ignored, so that the `PROXY_CACHE_VALID_*` settings alone decide how long a response is cached. Needed for origins such as Google Cloud Storage that return `Cache-Control: private, max-age=0`, which otherwise disables the cache entirely. See [Caching Objects from Origins that Send Cache-Control](#caching-objects-from-origins-that-send-cache-control)                                                                                                                                                                                                                                                                                                                          |
| `ACCESS_LOG_CACHE_STATUS`             | No        | `true`, `false`                                                                                                                                       | `false`                                             | When `true`, each access-log line gains a final `"$upstream_cache_status"` field (`HIT`, `MISS`, `EXPIRED`, `STALE`, `UPDATING`, `REVALIDATED`, `BYPASS`, or `"-"` for requests that never consulted the cache, such as `/health` or locally answered errors). Off by default so existing log parsers see unchanged lines. See [Measuring Cache Effectiveness](#measuring-cache-effectiveness)                                                                                                                                                                                                                                                                                                                                                                       |
| `PROVIDE_INDEX_PAGE`                  | No        | `true`, `false`                                                                                                                                       | `false`                                             | Flag which returns the index page if there is one when requesting a directory.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| `JS_TRUSTED_CERT_PATH`                | No        |                                                                                                                                                       |                                                     | Enables the `js_fetch_trusted_certificate` directive when retrieving AWS credentials and sets the path (on the container) to the specified path                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `HEADER_PREFIXES_TO_STRIP`            | No        |                                                                                                                                                       |                                                     | A list of HTTP header prefixes that exclude headers from client responses. List should be specified in lower-case and a semicolon (;) should be used to as a delimiter between values. For example: x-goog-;x-something-. Headers starting with x-amz- will be stripped by default for security reasons unless explicitly added in HEADER_PREFIXES_ALLOWED.                                                                                                                                                                                                                                                                                                                                                                                                          |
| `HEADER_PREFIXES_ALLOWED`             | No        |                                                                                                                                                       |                                                     | A list of allowed prefixes for HTTP headers that are returned to the client in responses. List should be specified in lower-case and a semicolon (;) should be used to as a delimiter between values. For example: x-amz-;x-something-. It is NOT recommended to return x-amz- headers for security reasons. Think carefully about what is allowed here.                                                                                                                                                                                                                                                                                                                                                                                                             |
| `CORS_ENABLED`                        | No        | `true`, `false`                                                                                                                                       | `false`                                             | Flag that enables CORS headers on GET and HEAD requests and enables pre-flight OPTIONS requests. If enabled, this will add CORS headers for "fully open" cross domain requests by default, meaning all domains are allowed, similar to the settings show in [this example](https://enable-cors.org/server_nginx.html). The advertised `Access-Control-Allow-Methods` mirrors the read-only method policy the gateway enforces (`GET, HEAD, OPTIONS`), and the method-rejection (`405`) and sanitized-`404` responses carry `Access-Control-Allow-Origin` so cross-origin scripts observe the real status. CORS settings can be fine-tuned by overwriting the [`cors.conf.template`](/common/etc/nginx/templates/gateway/cors.conf.template) file.                    |
| `CORS_ALLOWED_ORIGIN`                 | No        |                                                                                                                                                       |                                                     | Value to set to be returned from the CORS `Access-Control-Allow-Origin` header, including on the method-rejection (`405`) and sanitized-`404` responses. This value is only used if CORS is enabled. (default: \*)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `STRIP_LEADING_DIRECTORY_PATH`        | No        |                                                                                                                                                       |                                                     | Removes a portion of the path in the requested URL (if configured). Useful when deploying to an ALB under a folder (eg. `www.mysite.com/somepath`). Trailing slashes are trimmed from the value (`/somepath` and `/somepath/` are equivalent), so a trailing slash does not anchor the match to a path-segment boundary: `/somepath` also matches `/somepathextra`. The value is a regex fragment, so a boundary can be required explicitly, e.g. `/somepath(?=/\|$)`.                                                                                                                                                                                                                                                                                               |
| `PREFIX_LEADING_DIRECTORY_PATH`       | No        |                                                                                                                                                       |                                                     | Prefix to prepend to all S3 object paths. Useful to serve only a subset of an S3 bucket. When used in combination with `STRIP_LEADING_DIRECTORY_PATH`, this allows the leading path to be replaced, rather than just removed. When directory listing is enabled, this prefix is stripped from generated links and the "Index of" heading so that listings reflect the client-facing path (see [Configuring Directory Listing](#configuring-directory-listing)). The value is normalized to a leading slash with all trailing slashes removed (`/b`, `/b/`, and `b` are equivalent); `/` or an empty value disables the prefix. Values containing a single quote or a literal `$` are rejected at startup because the value is rendered into the NGINX configuration. |
| `CORS_ALLOW_PRIVATE_NETWORK_ACCESS`   | No        | `true`, `false`                                                                                                                                       |                                                     | Flag that enables responding to the CORS OPTIONS pre-flight request header `Access-Control-Request-Private-Network` with the `Access-Control-Allow-Private-Network` header. If the value is "true", responds with "true", if "false" responds with "false". If the environment variable is blank/not set, does not respond with any header. This value is only used if CORS is enabled. See [Private Network Access: introducing preflights](https://developer.chrome.com/blog/private-network-access-preflight/) for more information about this header.                                                                                                                                                                                                            |
| `IPV6_ENABLED`                        | No        | `true`, `false`                                                                                                                                       |                                                     | Controls whether the gateway also listens on IPv6 (`[::]`). When blank/not set, IPv6 is enabled automatically only if the runtime kernel supports it (`/proc/net/if_inet6` exists), so IPv4-only hosts and clusters keep working. Set to `true` or `false` to force the listener on or off regardless of detection. Container images only — the standalone install does not run the entrypoint scripts and listens on IPv4 only.                                                                                                                                                                                                                                                                                                                                     |

If you are using [AWS instance profile credentials](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_switch-role-ec2.html),
you will need to omit the `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and `AWS_SESSION_TOKEN` variables from
the configuration.

When `S3_SERVER_PROTO=https`, the gateway verifies the S3 origin certificate by default using
`S3_TRUSTED_CERT_PATH`. Public AWS endpoints work with the default system CA bundle. For a
private or self-signed S3-compatible endpoint, mount the appropriate CA bundle into the
container and set `S3_TRUSTED_CERT_PATH` to that absolute path. `JS_TRUSTED_CERT_PATH` remains
separate because it controls TLS trust only for njs credential-fetch requests.

When running with Docker, the above environment variables can be set in a file
with the `--env-file` flag. When running as a Systemd service, the environment
variables are specified in the `/etc/nginx/environment` file. An example of
the format of the file can be found in the [settings.example](/settings.example)
file.

There are few optional environment variables that can be used.

- `AWS_ROLE_ARN` - (optional) When set together with `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` (and without
  `AWS_WEB_IDENTITY_TOKEN_FILE`), the gateway does not sign S3 requests with the static credentials directly.
  Instead it calls [STS `AssumeRole`](https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRole.html) with
  them and signs S3 requests with the returned temporary credentials, refreshing them automatically before they
  expire. Requires `AWS_SIGS_VERSION=4`. See
  [Fetching S3 Credentials via STS AssumeRole](#fetching-s3-credentials-via-sts-assumerole).
- `AWS_ROLE_SESSION_NAME` - (optional) Role session name for the STS `AssumeRole` and `AssumeRoleWithWebIdentity`
  calls. The default value is `nginx-s3-gateway`. AWS restricts the value to 2-64 characters of `[\w+=,.@-]`.
- `STS_ENDPOINT` - (optional) Overrides the STS endpoint to be used in applicable setups. This is not required when
  running on EKS. See the EKS portion of the guide below for more details. Also honored by
  [STS AssumeRole mode](#fetching-s3-credentials-via-sts-assumerole), where it points at an S3-compatible store's
  own STS API.
- `AWS_STS_REGIONAL_ENDPOINTS` - (optional) Allows for a regional STS endpoint to be
  selected for the web identity and AssumeRole calls. When the regional model is selected
  then the STS endpoint generated will be coded to the current AWS region. This
  environment variable will be ignored if `STS_ENDPOINT` is set. Valid options are:
  `global` (default) or `regional`.

### Choosing a `S3_STYLE` Setting

**If you are using AWS S3 or S3 Express One Zone, use `virtual-v2`.** We are maintaining `virtual` temporarily until we
hear from the community that `virtual-v2` does not cause issues - or we introduce a versioning system that allows us to
safely flag breaking changes.
Until then, `virtual` works as before, and `default` still causes the `virtual` behavior to be used.

**`virtual-v2` is not expected to be a breaking change** but we are being cautious.

A full reference for S3 addressing styles may be found in [AWS's virtual hosting documentation](https://docs.aws.amazon.com/AmazonS3/latest/userguide/VirtualHosting.html)

Here is the difference between `virtual` and `virtual-v2`:

#### virtual

- Proxied endpoint: `S3_SERVER:S3_SERVER_PORT`
- `Host` header: `S3_BUCKET_NAME.S3_SERVER`
- `host` field in the [S3 V4 `CanonicalHeaders`](https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html): `S3_BUCKET_NAME.S3_SERVER`

#### virtual-v2

All items are set to the same value:

- Proxied endpoint: `S3_BUCKET_NAME.S3_SERVER:S3_SERVER_PORT`
- `Host` header: `S3_BUCKET_NAME.S3_SERVER:S3_SERVER_PORT`
- `host` field in the [S3 V4 `CanonicalHeaders`](https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html): `S3_BUCKET_NAME.S3_SERVER:S3_SERVER_PORT`

#### path

`path` style routing does not prepend the bucket name to the host, and includes it as the first segment in the request
path. AWS is actively trying to move away from this method. Some S3 compatible object stores may require that you use
this setting - but try to avoid it if your object store works with `virtual-v2`.

### Configuring Directory Listing

Listing of S3 directories ([folders](https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-folders.html)) is supported when the
`ALLOW_DIRECTORY_LIST` environment variable is set to `1`. Directory listing
output can be customized by changing the
[XSL stylesheet](https://www.w3schools.com/xml/xsl_intro.asp): [`common/etc/nginx/include/listing.xsl`](/common/etc/nginx/include/listing.xsl).
If you are not using AWS S3 as your backend, you may see some inconsistency in
the behavior with how directory listing works with HEAD requests. Additionally,
due to limitations in proxy response processing, invalid S3 folder requests will
result in log messages like:

```text
 libxml2 error: "Extra content at the end of the document"
```

Another limitation is that when using v2 signatures with HEAD requests, the
gateway will not return 200 for valid folders.

When `PREFIX_LEADING_DIRECTORY_PATH` is set, listing pages are generated
relative to the exposed subtree: the configured prefix is stripped from every
link and from the `Index of` heading, and the root of the exposed subtree
renders no `..` entry. This is required for the links to work — the gateway
prepends the prefix to every incoming request, so a link containing it would
have it prepended a second time when followed. `DIRECTORY_LISTING_PATH_PREFIX`
is applied after this stripping, so the two settings compose.

#### Paginated Listings

S3 returns at most 1000 keys per listing call. When a directory holds more
entries than one response can carry, the listing page ends with a `Next page`
link that requests the same URL with a `marker` query parameter (for example
`/some/dir/?marker=file1042.txt`). The marker is an opaque continuation value
returned by the object store — for AWS S3 it is the last entry of the current
page, while some S3-compatible backends append an internal hint to it — made
relative to the directory being listed, and it is the only query parameter the
gateway forwards to S3: everything else in a request's query string is still
stripped. A malformed marker restarts the listing from the first page; a
marker past the last entry renders the empty-listing page (or a `404` when
`FOUR_O_FOUR_ON_EMPTY_BUCKET` is enabled).

`DIRECTORY_LISTING_PAGE_SIZE` controls how many entries each page requests
(S3's `max-keys` parameter); when unset, no `max-keys` parameter is sent and
pages hold up to the 1000-key maximum. Each page is a distinct S3 request and
is cached independently. Because the marker is client-supplied, every distinct
marker value creates its own cache entry and its own signed `LIST` request
upstream — on publicly reachable deployments, consider rate limiting listing
URLs if S3 request cost or cache churn is a concern. As with all marker
pagination, entries created or deleted between page requests may be skipped or
appear twice.

#### Prefixing List Results

The gateway can be configured to prefix all list results with a given string.
This is useful if you are proxying the gateway itself and wish to relocate
the path of the files returned from the listing.
Using the `DIRECTORY_LISTING_PATH_PREFIX` environment variable will allow
one to add that prefix in listing page's header and links.

For example, if one configures to `DIRECTORY_LISTING_PATH_PREFIX='main/'` and
then uses HAProxy to proxy the gateway with the
`http-request set-path %[path,regsub(^/main,/)]` setting, the architecture
will look like the following:

![Architecture diagram of HAProxy stripping a path prefix in front of the gateway](./img/nginx-s3-gateway-directory-listing-path-prefix.png)

### Static Site Hosting

When `PROVIDE_INDEX_PAGE` environment variable is set to 1, the gateway will
transform `/some/path/` to `/some/path/index.html` when retrieving from S3.  
Default of "index.html" can be edited in `s3gateway.js`.
It will also return a relative redirect from `/some/path` to `/some/path/`
when S3 returns 404 on `/some/path` if
`APPEND_SLASH_FOR_POSSIBLE_DIRECTORY` is set. Relative redirects preserve the
viewer-visible path for direct and reverse-proxy deployments without relying
on request `Host` or forwarded-protocol headers. `path` has to
look like a possible directory: it must not end with a slash, and its final
path segment must not contain a dot. Only the final segment is checked, so a
dot in an intermediate directory (e.g. `/dir.name/file`) does not prevent
the redirect, while any dot in the final segment (e.g. `/file.jpg`,
`/releases/v1.2.3`, `/.hidden`, `/reports.`) is treated as a file extension
and is not redirected. The path is percent-decoded before this check, so an
encoded dot (`%2E`) counts as a dot and an encoded slash (`%2F`) counts as a
directory separator (e.g. `/foo%2F` is treated as a directory and is not
redirected).  

### Hosting a Bucket as a Subfolder on an ALB

The `STRIP_LEADING_DIRECTORY_PATH` environment variable allows one to host an
S3 bucket in a subfolder on an ALB. For example, if you wanted to expose the
root of a bucket under the path `www.mysite.com/somepath`, you would set this
variable to `/somepath`.

### Path Normalization

Runs of duplicate literal slashes in a request path are collapsed into a single slash before the gateway signs and
proxies the request, on every code path (object fetch, index-page probing, and directory listing):
`/pathFoo//file.txt` is served as the S3 key `pathFoo/file.txt`, and `GET /pathFoo//sub///` lists the prefix
`pathFoo/sub/`. S3 keys are flat strings, so a forwarded duplicate slash could only ever match a key that literally
contains consecutive slashes; every other double-slash request failed upstream and surfaced as a sanitized `404`.
Collapsing happens before `STRIP_LEADING_DIRECTORY_PATH`/`PREFIX_LEADING_DIRECTORY_PATH` rewriting, so a
duplicate-slash spelling follows the same strip/prefix rewrite as its canonical form.

Only literal slashes are collapsed. A percent-encoded slash (`%2F`) is object-key data, not a path separator, so a
key that genuinely contains consecutive slashes (e.g. `b//e.txt`) remains addressable by encoding the extra slash:
`GET /b/%2Fe.txt`. Because all duplicate-slash spellings of a path normalize to one S3 request URI, they share one
cache entry (see [Byte-Range Requests and Caching](#byte-range-requests-and-caching)).

## Byte-Range Requests and Caching

The gateway caches [byte-range](https://developer.mozilla.org/en-US/docs/Web/HTTP/Range_requests) (requests sent with a
`Range` header) requests differently than normal requests.

The gateway is configured to cache such requests in chunks of size `PROXY_CACHE_SLICE_SIZE`. If you don't provide this
configuration value it will default to 1 megabyte.

This means that if you request 2.5 megabytes of a 1 gigabyte file, the gateway will cache 3 megabytes and nothing else.

Setting your slice size too small can have performance impacts since NGINX performs a subrequest for each slice. For
more details see the [official reference](http://nginx.org/en/docs/http/ngx_http_slice_module.html).

You may make byte-range requests and normal requests for the same file and NGINX will automatically handle them
differently. The caches for file chunks and normal file requests are separate on disk.

Cache entries are keyed by the effective S3 request identity, not by the viewer's `Host` header. Requests sent through
different frontend hostnames, or through different gateway URL aliases that resolve to the same S3 URI after
`STRIP_LEADING_DIRECTORY_PATH`, `PREFIX_LEADING_DIRECTORY_PATH`, or static-site index handling, share one cache entry.
This prevents clients from fragmenting the cache by varying `Host` while still keeping different origins, S3 hosts,
request methods, and byte-range slices separate.

## Caching of Error Responses

Error responses from the origin are cached just like successful ones: an upstream `404` is cached for
`PROXY_CACHE_VALID_NOTFOUND` (default `1m`) and an upstream `403` for `PROXY_CACHE_VALID_FORBIDDEN` (default `30s`).
Because cache entries are keyed by the effective S3 request identity (see
[Byte-Range Requests and Caching](#byte-range-requests-and-caching)), a cached error is shared exactly like a cached
object: percent-encoding variants of an object URL normalize to the same key and duplicate literal slashes are
collapsed (see [Path Normalization](#path-normalization)) — except that with `ALLOW_DIRECTORY_LIST`
or `PROVIDE_INDEX_PAGE` enabled, a directory's trailing slash must be sent literally (`/dir%2F` is keyed as an object
request, separately from `/dir/`) — and the viewer's `Host` header is not part of the key, so whichever request reaches
the origin first decides what every client using the same request method sees for that object until the entry expires
(a cached `GET` error is not returned to `HEAD` probes such as `curl -I`).

The cache stores the origin's real status code, while
[error sanitization](#disable-default-404-error-message) runs at delivery time — so a cached upstream `403` is
re-collapsed to a sanitized `404` on every hit. During a transient upstream auth failure (rotated credentials,
container clock skew), this turns a brief window of `403`s into up to `PROXY_CACHE_VALID_FORBIDDEN` of
confident-looking `404`s for all clients: objects appear deleted rather than access appearing broken. The reverse also
holds — a previously cached `200` masks a new upstream `403` or `404` until it expires (`PROXY_CACHE_VALID_OK`,
default `1h`); if the origin instead fails with connection errors, timeouts, or `5xx` responses, the default
`PROXY_CACHE_USE_STALE` keeps serving the stale `200` even past that expiry, for as long as the entry stays in the
cache. With error sanitization enabled (the default), a cached error is held as a status-only entry in the cache's
shared memory zone and never appears as a file under `/var/cache/nginx/s3_proxy`, so an empty cache directory does
not prove that no error is being served from the cache.

Caching `403`s is intentional: it shields the origin from request storms against denied objects. Deployments that
prefer origin pressure over masking can lower `PROXY_CACHE_VALID_FORBIDDEN`, or set it to `0s` to not cache `403`s at
all, so every request reaches the origin. As with all `PROXY_CACHE_VALID_*` settings, caching headers returned by the
origin take priority — see
[Caching Objects from Origins that Send Cache-Control](#caching-objects-from-origins-that-send-cache-control).

The slice cache defines no validity for `403` or `404`, so the gateway's own settings never cache an error response
to a ranged request that the slice cache serves (caching headers returned by the origin, which take priority, still
can). Note that not every ranged request is sliced: with `PROVIDE_INDEX_PAGE` enabled, or on directory-listing paths,
`Range` requests bypass the slice cache entirely and their error responses are cached as described above.

## Bypassing the Local Cache with Cache-Control: no-cache

By default the gateway ignores the client's `Cache-Control` request header and serves cached objects until the
corresponding `PROXY_CACHE_VALID_*` time expires.

Setting `PROXY_CACHE_BYPASS_NO_CACHE=true` makes the gateway honor the `no-cache` request directive from
[RFC 9111](https://www.rfc-editor.org/rfc/rfc9111.html#section-5.2.1.4): a request whose `Cache-Control` header
contains a `no-cache` token (sent by browsers on a hard refresh such as Ctrl+F5) bypasses the local cache and
fetches a fresh copy from S3. The fresh response also replaces the cache entry it bypassed, so subsequent normal
requests for that entry are served the updated content. The bypass applies to byte-range requests served from
the slice cache as well.

A bypassing request only refreshes the canonical S3 cache entries it actually touches. Cache entries are scoped per
request method and per cache zone: full-body `GET` responses, `HEAD` responses, and each slice of a byte-range response
are cached independently, so for example a hard-refreshed `GET` does not refresh the `HEAD` entry or any cached slices
for the same object. If two viewer-visible URLs resolve to the same effective S3 URI, a bypass through either URL
refreshes the shared entry. In particular, a `no-cache` byte-range request re-fetches only the slices covered by its
`Range` header — if the object changed in S3, the remaining slices keep the previous version until they expire, and
NGINX's slice module aborts responses that would mix slices from two object versions (`etag mismatch in slice response`
in the error log). A bypassing request also cannot fall back to stale content: `PROXY_CACHE_USE_STALE` only applies to
requests served through the cache, so during an S3 outage a hard refresh returns an error even when a usable cached copy
exists.

The match is token-aware and case-insensitive. Only a syntactically valid `no-cache` directive triggers a bypass — for
example `Cache-Control: no-cache` or `Cache-Control: max-age=0, no-cache`. The following do *not* trigger a bypass:
`max-age=0` alone, `no-store`, the legacy `Pragma: no-cache` header, or `no-cache` appearing as a substring of another
token.

> [!WARNING]
> Enabling this feature lets any client force requests through to S3 by sending a header, defeating the cache. On a
> publicly reachable gateway this can be abused to increase your S3 request costs and origin load (this is the same
> reason CDNs such as CloudFront ignore the viewer's `Cache-Control` header). Bypassing requests also skip
> `proxy_cache_lock`, so N concurrent `no-cache` requests for the same object each open their own S3 fetch instead of
> being collapsed into one. Enable it only when clients are trusted, or pair it with
> [rate limiting](https://nginx.org/en/docs/http/ngx_http_limit_req_module.html).

Note for systemd/standalone installs: the installer normalizes this setting, and the value stored in
`/etc/nginx/environment` must be `1` (enabled) or `0` (disabled); any other value hand-edited into that file disables
the feature.

## Caching Objects from Origins that Send Cache-Control

NGINX honors the caching headers an origin returns, and they take priority over `PROXY_CACHE_VALID_*`. If the object
store returns a `Cache-Control` or `Expires` value that forbids caching — or a `Set-Cookie` header, or `Vary: *` — the
gateway re-fetches the object on every request and `/var/cache/nginx/s3_proxy` stays empty. See the
[`proxy_cache_valid` directive docs](https://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_cache_valid) for
the precedence rules.

This is the default behavior on Google Cloud Storage. Cloud Storage synthesizes a `Cache-Control` value for objects
that carry no `Cache-Control` metadata of their own, and it returns `private, max-age=0` (or
`no-cache, no-store, max-age=0` for objects encrypted with a customer-managed key) for anything that is not publicly
readable. Because the gateway always authenticates its requests, every object looks non-public. See the
[Cloud Storage metadata documentation](https://cloud.google.com/storage/docs/metadata#cache-control).

`PROXY_CACHE_IGNORE_HEADERS` disables NGINX's processing of the response header fields you list, leaving
`PROXY_CACHE_VALID_OK`, `PROXY_CACHE_VALID_NOTFOUND` and `PROXY_CACHE_VALID_FORBIDDEN` as the only thing that decides
how long a response is cached. It takes a **space**-separated list of the field names accepted by the
[`proxy_ignore_headers` directive](https://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_ignore_headers):
`X-Accel-Redirect`, `X-Accel-Expires`, `X-Accel-Limit-Rate`, `X-Accel-Buffering`, `X-Accel-Charset`, `Expires`,
`Cache-Control`, `Set-Cookie` and `Vary`. Field names are matched case-insensitively, and an unrecognized field stops
the gateway at startup with an error rather than being silently dropped. Leaving the variable unset (the default)
omits the directive entirely and preserves the behavior described above.

Note that the delimiter differs from `HEADER_PREFIXES_TO_STRIP` and `HEADER_PREFIXES_ALLOWED`, which are
semicolon-separated. `PROXY_CACHE_IGNORE_HEADERS` follows `PROXY_CACHE_USE_STALE` and uses spaces, matching the
argument syntax of the NGINX directive it configures.

The setting applies to the whole gateway: normal responses, directory listings, and the separate byte-range slice
cache described in [Byte-Range Requests and Caching](#byte-range-requests-and-caching).

### Configuring the Gateway for Google Cloud Storage

```text
docker run --env-file ./settings --publish 80:80 --name nginx-s3-gateway \
    --env S3_SERVER=storage.googleapis.com \
    --env PROXY_CACHE_IGNORE_HEADERS="Cache-Control Expires" \
    --env HEADER_PREFIXES_TO_STRIP="x-goog-;x-guploader-uploadid;cache-control" \
    ghcr.io/nginxinc/nginx-s3-gateway/nginx-oss-s3-gateway:latest
```

`PROXY_CACHE_IGNORE_HEADERS` changes only what the *gateway* caches. The origin's `Cache-Control` header is still
forwarded to the client, so browsers and any downstream CDN keep seeing `private, max-age=0` and will not cache
either. Adding `cache-control` to `HEADER_PREFIXES_TO_STRIP` removes it from client responses; the `x-goog-` and
`x-guploader-uploadid` prefixes strip the Cloud Storage headers that would otherwise identify the origin.

> [!WARNING]
> Ignoring `Cache-Control` and `Expires` discards the origin's stated freshness policy for every object, including
> objects whose `Cache-Control` metadata was set deliberately. Once ignored, the only bound on staleness is
> `PROXY_CACHE_VALID_*`, so a client can be served a stale object for up to `PROXY_CACHE_VALID_OK` after it changes in
> the bucket. Ignoring `Set-Cookie` is riskier still: a response carrying a cookie becomes cacheable and can be
> replayed to other clients. Add `Set-Cookie` to the list only when you are certain the origin never sets per-user
> cookies.

## Measuring Cache Effectiveness

By default the gateway's access log uses a combined-log-compatible format that does not record whether a request was
served from the local cache. Setting `ACCESS_LOG_CACHE_STATUS=true` appends
[`$upstream_cache_status`](https://nginx.org/en/docs/http/ngx_http_upstream_module.html#var_upstream_cache_status) as a
final quoted field to every access-log line, so hit rates can be computed from the logs alone without exposing the
status to clients:

```text
172.17.0.1 - - [29/Aug/2026:12:00:00 +0000] "GET /a.txt HTTP/1.1" 200 42 "-" "curl/8.5.0" "-" "HIT"
```

The field is not just `HIT` or `MISS` — log consumers must expect the full value set: `MISS`, `HIT`, `EXPIRED`,
`STALE`, `UPDATING`, `REVALIDATED` and `BYPASS`, plus `"-"` for requests that never consulted the cache (the unproxied
`/health` and `/soap` endpoints, and errors the gateway answers locally). The gateway enables `proxy_cache_revalidate`
and `proxy_cache_background_update`, and defaults `PROXY_CACHE_USE_STALE` to serving stale content on origin errors,
so `STALE`, `UPDATING` and `REVALIDATED` all occur in normal operation, and `BYPASS` appears whenever
[`PROXY_CACHE_BYPASS_NO_CACHE`](#bypassing-the-local-cache-with-cache-control-no-cache) lets a request through the
cache.

Two behaviors to keep in mind when interpreting the field:

- A byte-range request served through the slice cache logs the status of its **first** slice only. The remaining
  slices are fetched in subrequests, which produce no access-log lines of their own, so a request that mixes cached
  and uncached slices still logs a single status.
- Directory listings and index-page requests log a real cache status: their handler redirects internally into a
  proxying location in the main-request context.

The field records the same variable as the commented-out `add_header X-Cache-Status $upstream_cache_status;` in
[`default.conf.template`][default-conf-template], which exposes the status to *clients* instead and remains available
unchanged.

Off by default, the rendered format is byte-identical to the previous static one, so existing log parsers are
unaffected until the option is switched on. Deployments that override the gateway's templates directory with a copy
that lacks `gateway/logging.conf.template` will fail at startup on the missing include; deployments that mount their
own complete `nginx.conf` keep their own logging configuration, and this option has no effect for them.

## Usage with AWS S3 Express One Zone

The gateway may be used to proxy files in the AWS S3 Express One Zone product (also called Directory Buckets).

To do so, be sure that `S3_STYLE` is set to `virtual-v2`. Additionally, the `S3_SERVER` configuration must be set a
combination of the bucket name and the
[Zonal Endpoint](https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-express-networking.html#s3-express-endpoints).

### Directory Bucket Names

See the [official documentation](https://docs.aws.amazon.com/AmazonS3/latest/userguide/directory-bucket-naming-rules.html) for the most up to date rules on Directory Bucket naming.

Directory Buckets must have names matching this format:

```text
bucket-base-name--azid--x-s3
```

For example:

```text
bucket-base-name--usw2-az1--x-s3
```

### Final Configuration

The bucket name must be prepended to the zonal endpoint like this

```text
bucket-base-name--usw2-az1--x-s3.s3express-usw2-az1.us-west-2.amazonaws.com
```

The above is the value that must be provided to the `S3_SERVER` variable.
Additionally, the `S3_BUCKET_NAME` must be set to the full bucket name with the suffix:

```text
bucket-base-name--usw2-az1--x-s3
```

Buckets created in the AWS UI don't require manual specification of a suffix but it must be included in the gateway configuration.

### Trying it Out

A sample Terraform script to provision a bucket is provided in `/deployments/s3_express`.

## Running as a Systemd Service

An [install script](/standalone_ubuntu_oss_install.sh) for the gateway shows
how to install NGINX from a package repository, checkout the gateway source,
and configure it using the supplied environment variables.

To run the script copy it to your destination system, load the environment
variables mentioned in the [configuration section](#configuration) into memory,
and then execute the script. The script takes one optional parameter that
specifies the name of the branch to download files from.

For example:

```shell-session
sudo env $(cat settings.example) ./standalone_ubuntu_oss_install.sh
```

## Running in Containers

### Running the Public Open Source NGINX Container Image

The latest builds of the gateway (that use open source NGINX) are available on
the project's Github [package repository](https://github.com/nginxinc/nginx-s3-gateway/pkgs/container/nginx-s3-gateway%2Fnginx-oss-s3-gateway).

To run with the public open source image, replace the `settings` file specified
below with a file containing your settings, and run the following command:

```text
docker run --env-file ./settings --publish 80:80 --name nginx-s3-gateway \
    ghcr.io/nginxinc/nginx-s3-gateway/nginx-oss-s3-gateway:latest
```

If you would like to run with the latest njs version, run:

```text
docker run --env-file ./settings --publish 80:80 --name nginx-s3-gateway \
    ghcr.io/nginxinc/nginx-s3-gateway/nginx-oss-s3-gateway:latest-njs-oss
```

Alternatively, if you would like to pin your version to a specific point in
time release, find the version with an embedded date and run:

```text
docker run --env-file ./settings --publish 80:80 --name nginx-s3-gateway \
    ghcr.io/nginxinc/nginx-s3-gateway/nginx-oss-s3-gateway:latest-njs-oss-20220310
```

#### Running Unprivileged Container Images

Unprivileged container images run NGINX as a non-root user and listen on port **8080** internally (instead of port 80).
This provides enhanced security by not requiring privileged ports.

To run an unprivileged image, use the `unprivileged-oss` tag and map to port **8080**:

```text
docker run --env-file ./settings --publish 80:8080 --name nginx-s3-gateway \
    ghcr.io/nginxinc/nginx-s3-gateway/nginx-oss-s3-gateway:unprivileged-oss-20250718
```

Alternatively, you can map host port 8080 to container port 8080 to avoid requiring elevated privileges on the host:

```text
docker run --env-file ./settings --publish 8080:8080 --name nginx-s3-gateway \
    ghcr.io/nginxinc/nginx-s3-gateway/nginx-oss-s3-gateway:unprivileged-oss-20250718
```

### Building the Public Open Source NGINX Container Image

The `GNUmakefile` (GNU Make 4.x) is the supported interface for building the
gateway. To build the NGINX OSS container image, run the following from the
project root directory:

```text
make build
```

This tags the image as `nginx-s3-gateway` and `nginx-s3-gateway:oss` (the
underlying Dockerfile is `Dockerfile.oss`). Alternatively, if you would like
to use the latest version of [njs](https://nginx.org/en/docs/njs/), you can
layer a build of njs from the latest source on top of the image above:

```text
make build-latest-njs
```

After building, you can run the image by issuing the following command and
replacing the path to the `settings` file with a file containing your specific
environment variables.

```text
docker run --env-file ./settings --publish 80:80 --name nginx-s3-gateway \
    nginx-s3-gateway:oss
```

In the same way, if you want to use NGINX OSS container image as a non-root, unprivileged user,
you can build it as follows:

```text
make build-unprivileged
```

And run the image binding the container port 8080 to 80 in the host like:

```text
docker run --env-file ./settings --publish 80:8080 --name nginx-s3-gateway \
    nginx-s3-gateway:unprivileged-oss
```

It is worth noting that due to the way the startup scripts work, even the unprivileged container will not work with a
read-only root filesystem or a specific uid/gid set other then the default of `101`.

### Building the NGINX Plus Container Image

In order to build the NGINX Plus container image, copy your NGINX Plus
repository certificate and key (`nginx-repo.crt` and `nginx-repo.key`) into
the `plus/etc/ssl/nginx/` directory, and set up access to the official NGINX
Plus Docker image repository (`docker login private-registry.nginx.com`), as
[per the documentation](https://docs.nginx.com/nginx/admin-guide/installing-nginx/installing-nginx-docker/#use-official-nginx-plus-docker-images).

To build, run the following from the project root directory:

```text
make build NGINX_TYPE=plus
```

This tags the image as `nginx-s3-gateway` and `nginx-s3-gateway:plus` (the
underlying Dockerfile is `Dockerfile.plus`). Alternatively, if you would like
to use the latest version of [njs](https://nginx.org/en/docs/njs/) with NGINX
Plus, you can layer a build of njs from the latest source on top of the image
above:

```text
make build-latest-njs NGINX_TYPE=plus
```

After building, you can run the image by issuing the following command and
replacing the path to the `settings` file with a file containing your specific
environment variables.

```text
docker run --env-file ./settings --publish 80:80 --name nginx-plus-s3-gateway \
    nginx-s3-gateway:plus
```

## Supplying Credentials from Files (Docker Secrets)

Environment variables are readable by anything that can run `docker inspect` or read `/proc/<pid>/environ`, so
container secret stores mount each secret as a read-only file instead. To use one, set the `_FILE` companion of a
credential variable to the path of that file rather than setting the credential variable itself:

| Instead of              | Set                          |
| ----------------------- | ---------------------------- |
| `AWS_ACCESS_KEY_ID`     | `AWS_ACCESS_KEY_ID_FILE`     |
| `AWS_SECRET_ACCESS_KEY` | `AWS_SECRET_ACCESS_KEY_FILE` |
| `AWS_SESSION_TOKEN`     | `AWS_SESSION_TOKEN_FILE`     |

With Docker Compose or Docker Swarm:

```yaml
services:
  nginx-s3-gateway:
    image: ghcr.io/nginx/nginx-s3-gateway/nginx-oss-s3-gateway:latest
    environment:
      AWS_ACCESS_KEY_ID_FILE: /run/secrets/aws_access_key_id
      AWS_SECRET_ACCESS_KEY_FILE: /run/secrets/aws_secret_access_key
      # ... the remaining settings as usual
    secrets:
      - aws_access_key_id
      - aws_secret_access_key

secrets:
  aws_access_key_id:
    file: ./secrets/aws_access_key_id
  aws_secret_access_key:
    file: ./secrets/aws_secret_access_key
```

Notes:

- A credential variable and its `_FILE` companion are mutually exclusive. Setting both is a configuration error and
  the container refuses to start.
- Leading and trailing whitespace is stripped from the file contents, so a secret file that ends in a newline works.
  A file that is empty or contains only whitespace is rejected at start up, because an empty credential would
  otherwise fail much later as an opaque `403 Access Denied` from the S3 origin.
- The file must be readable by the `nginx` worker user, which is not root. Docker Swarm mounts its secrets
  world-readable (mode `0444`) by default, so this works out of the box. Docker Compose instead bind-mounts a
  file-based secret with the host file's own owner and permissions, so a secret file created under the usual `0600`
  umask - like a hand-mounted `0400 root:root` file - is unreadable inside the container; `chmod 0444` it on the host.
  The container checks this on start up as the worker user rather than as root, so a file it cannot read is reported
  by name at start up instead of turning every proxied request into a `500`.
- The value is read on demand and memoized for the lifetime of the njs VM context. After rotating a secret file,
  reload NGINX (`nginx -s reload`) or restart the container to guarantee the new value is picked up.
- This is not specific to containers: the same variables work for the
  [Systemd service](#running-as-a-systemd-service) install, which records the path in `/etc/nginx/environment`
  rather than the secret itself.

## Fetching S3 Credentials via STS AssumeRole

When a fixed IAM user (or an S3-compatible store account) should not access the bucket directly but is allowed to
assume a role that can, set `AWS_ROLE_ARN` alongside the static credentials:

```text
AWS_ACCESS_KEY_ID=AKIA...            # or AWS_ACCESS_KEY_ID_FILE=...
AWS_SECRET_ACCESS_KEY=...            # or AWS_SECRET_ACCESS_KEY_FILE=...
AWS_ROLE_ARN=arn:aws:iam::123456789012:role/s3-read-only
AWS_SIGS_VERSION=4
```

On the first proxied request the gateway sends a SigV4-signed
[`AssumeRole`](https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRole.html) call (a form-encoded `POST`,
exactly as the AWS SDKs send it) to the STS endpoint, caches the returned temporary credentials in memory (never on
disk), and signs S3 requests with them. The credentials are refreshed shortly before they expire by a single elected
request, while concurrent requests continue to be served with the still-valid cached credentials. Notes:

- The STS endpoint is chosen the same way as for EKS web identity: `STS_ENDPOINT` when set, otherwise
  `https://sts.<AWS_REGION>.amazonaws.com` when `AWS_STS_REGIONAL_ENDPOINTS=regional`, otherwise the global
  `https://sts.amazonaws.com` endpoint. For an S3-compatible store that implements the STS API (RustFS, for
  example), point `STS_ENDPOINT` at the store itself, e.g. `STS_ENDPOINT=https://my-store:9000`.
- The `AssumeRole` request is signed with `AWS_REGION` when set, otherwise with `S3_REGION`, otherwise with
  `us-east-1`. AWS validates that the signature's region matches the endpoint it is sent to, so when `STS_ENDPOINT`
  points at an AWS endpoint in a different region than the bucket, set `AWS_REGION` to the endpoint's region.
  S3-compatible stores generally do not enforce the signature's region.
- `AWS_ROLE_SESSION_NAME` customizes the session name (default `nginx-s3-gateway`).
- Requires `AWS_SIGS_VERSION=4`: `AssumeRole` always returns a session token, which v2 signatures cannot cover;
  the container refuses to start otherwise.
- If `AWS_WEB_IDENTITY_TOKEN_FILE` is also set (as EKS does), the static credentials win outright and neither STS
  call is made - remove the static credentials to use
  [web identity](#running-on-eks-with-iam-roles-for-service-accounts) instead.
- A non-empty `AWS_ROLE_ARN` with neither static credentials nor a web identity token file fails startup
  validation: the role could not be assumed and would otherwise be silently ignored. Add the static pair or remove
  the variable. (Set-but-empty values count as unset, so an empty pass-through key is harmless.)
- When `STS_ENDPOINT` uses HTTPS with a private CA, set `JS_TRUSTED_CERT_PATH` - credential calls verify against
  it, not `S3_TRUSTED_CERT_PATH`.

## Running Using AWS Instance Profile Credentials

[AWS instance profiles](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/iam-roles-for-amazon-ec2.html#ec2-instance-profile)
allow you to assign a role to a compute so that other AWS services can trust
the instance without having to store authentication keys in the compute
instance. This is useful for the gateway because it allows us to run the
gateway without storing an unchanging `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and
`AWS_SESSION_TOKEN` in a file on disk or in an easily read environment variable.

Instance profiles work by providing credentials to the instance via the
[AWS Metadata API](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instancedata-data-retrieval.html).
When the API is queried, it provides the keys allowed to the instance. Those
keys regularly expire, so services using them must refresh frequently.

This mode requires `AWS_SIGS_VERSION=4`: instance credentials always include a
session token, which v2 signatures cannot cover; the container refuses to
start otherwise.

The gateway caches these temporary credentials in memory only: OSS uses an njs
shared dictionary and NGINX Plus uses keyval. Current versions do not write
temporary AWS credentials to disk.

Credential refreshes are single-flighted: when the cached credentials enter the
4.5-minute pre-expiry refresh margin, one request wins an atomic sentinel in a
dedicated shared-memory zone (`credential_refresh_lock`, declared in its own
`conf.d` file shared by both flavors) and fetches new credentials, while every
other request keeps using the cached, still-valid set. If the elected refresh
fails, the cached credentials continue to be served and the refresh re-arms
every 30 seconds until they actually expire. Requests block on the fetch only
when no still-valid cached credentials exist: a cold start, or credentials
already past their actual expiry (for example, after a provider outage that
outlasts the refresh margin).

On startup the container removes any legacy
credential cache left behind by an older OSS image, checking every path the old
code could have written: `AWS_CREDENTIALS_TEMP_FILE`, `${TMPDIR}/credentials.json`,
and `/tmp/credentials.json`. If you dropped a custom `TMPDIR` or
`AWS_CREDENTIALS_TEMP_FILE` setting from the environment before upgrading,
remove that file from the persisted volume manually.

### Running in EC2 with an IAM Policy

Following the [AWS documentation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/iam-roles-for-amazon-ec2.html#permission-to-pass-iam-roles)
we can create a IAM role and launch an instance associated with it. On that
instance, if we run the gateway as a Systemd service there are no additional
steps. We just run the install script without specifying the
`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and `AWS_SESSION_TOKEN` environment variables.

However, if we want to run the gateway as a container instance on that
EC2 instance, then we will need to run the following command using the AWS
CLI tool to allow the metadata endpoint to be accessed from within a container.

```text
aws ec2 modify-instance-metadata-options --instance-id <instance id> \
    --http-put-response-hop-limit 3 --http-endpoint enabled
```

After that has been run we can start the container normally and omit the
`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and `AWS_SESSION_TOKEN` environment variables.

Note: when the IMDSv2 token request fails with a network error or is rejected
with a 403/404/405 status, the gateway automatically retries without a session
token (IMDSv1), matching AWS SDK behavior. This lets the gateway work on
instances where the hop limit was not raised, but only when the instance still
allows IMDSv1 (`HttpTokens=optional`); each credential refresh then waits for
the token request to time out first — but only in the single request performing
that refresh; concurrent requests keep being served with the cached credentials
until they actually expire. Instances enforcing IMDSv2
(`HttpTokens=required`) still require the hop limit change above.

To disable the IMDSv1 fallback entirely so that credential retrieval fails
closed when an IMDSv2 token cannot be obtained, set the standard AWS SDK
environment variable `AWS_EC2_METADATA_V1_DISABLED=true`.

### Running in ECS with an IAM Policy

The commands below all reference the [`deployments/ecs/cloudformation/s3gateway.cf`](/deployments/ecs/cloudformation/s3gateway.yaml) file. This file will need to be
modified. Like every instance credential provider, ECS container credentials
require `AWS_SIGS_VERSION=4`; the container refuses to start otherwise.

- Update the following 4 parameters in the `Parameters` section of the CloudFormation file for your specific AWS account:
  - `NewBucketName` - any S3 bucket name. Remember that S3 bucket names must be globally unique
  - `VpcId` - Any VPC ID on your AWS account
  - `Subnet1` - Any subnet ID that's in the VPC used above
  - `Subnet2` - Any subnet ID that's in the VPC used above
- Run the following command to deploy the stack (this assumes you have the AWS CLI & credentials setup correctly on
  your host machine and you are running in the project root directory):

  ```sh
  aws cloudformation create-stack \
    --stack-name nginx-s3-gateway \
    --capabilities CAPABILITY_NAMED_IAM \
    --template-body file://deployments/ecs/cloudformation/s3gateway.yaml
  ```

- Wait for the CloudFormation Stack deployment to complete
  (can take about 3-5 minutes)
  - You can query the stack status with this command:

    ```sh
    aws cloudformation describe-stacks \
      --stack-name nginx-s3-gateway \
      --query "Stacks[0].StackStatus"
    ```

- Wait until the query above shows `"CREATE_COMPLETE"`
- Run the following command to get the URL used to access the service:

  ```sh
  aws cloudformation describe-stacks \
    --stack-name nginx-s3-gateway \
    --query "Stacks[0].Outputs[0].OutputValue"
  ```

  - Upload a file to the bucket first to prevent getting a `404` when visiting
    the URL in your browser

  ```sh
  # i.e.
  aws s3 cp README.md s3://<bucket_name>
  ```

- View the container logs in CloudWatch from the AWS web console
- Run the following command to delete the stack and all resources:

  ```sh
  aws cloudformation delete-stack \
    --stack-name nginx-s3-gateway
  ```

## Running on EKS with IAM roles for service accounts

If you are planning to use the container image on an EKS cluster, you can use a
[service account](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html) which can
assume a role using
[AWS Security Token Service](https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRoleWithWebIdentity.html).

- Create a new
  [AWS IAM OIDC Provider](https://docs.aws.amazon.com/eks/latest/userguide/enable-iam-roles-for-service-accounts.html).
  If you are using AWS EKS Cluster, then the IAM OIDC Provider should already be created as the part of cluster
  creation. So validate it before you create the new IAM OIDC Provider.
- Configuring a [Kubernetes service account to assume an IAM role](https://docs.aws.amazon.com/eks/latest/userguide/associate-service-account-role.html)
- [Annotate the Service Account](https://docs.aws.amazon.com/eks/latest/userguide/cross-account-access.html) using IAM Role create in the above step.
- [Configure your pods, Deployments, etc to use the Service Account](https://docs.aws.amazon.com/eks/latest/userguide/pod-configuration.html)
- As soon as the pods/deployments are updated, you will see the couple of Env Variables listed below in the pods.
  - `AWS_ROLE_ARN` - Contains IAM Role ARN
  - `AWS_WEB_IDENTITY_TOKEN_FILE` - Contains the token which will be used to create temporary credentials using AWS
    Security Token Service.
- You must also set the `AWS_REGION` and `JS_TRUSTED_CERT_PATH` environment variables as shown below in addition to the
  normal environment variables listed in the Configuration section.
- Requires `AWS_SIGS_VERSION=4`: web identity credentials always include a session token, which v2 signatures cannot
  cover; the container refuses to start otherwise.

The following is a minimal set of resources to deploy:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: nginx-s3-gateway
  annotations:
    eks.amazonaws.com/role-arn: "<role-arn>"
    # See https://docs.aws.amazon.com/eks/latest/userguide/configure-sts-endpoint.html
    eks.amazonaws.com/sts-regional-endpoints: "true"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-s3-gateway
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx-s3-gateway
  template:
    metadata:
      labels:
        app: nginx-s3-gateway
    spec:
      serviceAccountName: nginx-s3-gateway
      containers:
        - name: nginx-s3-gateway
          image: "ghcr.io/nginxinc/nginx-s3-gateway/nginx-oss-s3-gateway:latest-20220916"
          imagePullPolicy: IfNotPresent
          env:
            - name: S3_BUCKET_NAME
              value: "<bucket>"
            - name: S3_SERVER
              value: "s3.<aws region>.amazonaws.com"
            - name: S3_SERVER_PROTO
              value: "https"
            - name: S3_SERVER_PORT
              value: "443"
            - name: S3_STYLE
              value: "virtual"
            - name: S3_REGION
              value: "<aws region>"
            - name: AWS_REGION
              value: "<aws region>"
            - name: AWS_SIGS_VERSION
              value: "4"
            - name: ALLOW_DIRECTORY_LIST
              value: "false"
            - name: PROVIDE_INDEX_PAGE
              value: "false"
            - name: JS_TRUSTED_CERT_PATH
              value: "/etc/ssl/certs/Amazon_Root_CA_1.pem"

          ports:
            - name: http
              containerPort: 80
              protocol: TCP
          livenessProbe:
            httpGet:
              path: /health
              port: http
          readinessProbe:
            httpGet:
              path: /health
              port: http
```

**Note:** If using an unprivileged container image (e.g., `unprivileged-oss-YYYYMMDD`), change `containerPort: 80` to
`containerPort: 8080` as unprivileged containers listen on port 8080.

## Running on EKS with EKS Pod Identities

An alternative way to use the container image on an EKS cluster is to use a service account which can assume a role
using [Pod Identities](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html).

- Installing the [Amazon EKS Pod Identity Agent](https://docs.aws.amazon.com/eks/latest/userguide/pod-id-agent-setup.html) on the cluster
- Configuring a [Kubernetes service account to assume an IAM role with EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-id-association.html)
- [Configure your pods, Deployments, etc to use the Service Account](https://docs.aws.amazon.com/eks/latest/userguide/pod-configuration.html)
- As soon as the pods/deployments are updated, you will see the couple of Env Variables listed below in the pods.
  - `AWS_CONTAINER_CREDENTIALS_FULL_URI` - Contains the URI of the EKS Pod Identity Agent that will provide the credentials
  - `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE` - Contains the token which will be used to create temporary credentials
    using the EKS Pod Identity Agent.
- Requires `AWS_SIGS_VERSION=4`: pod identity credentials always include a session token, which v2 signatures cannot
  cover; the container refuses to start otherwise.

The minimal set of resources to deploy is the same than for
[Running on EKS with IAM roles for service accounts](#running-on-eks-with-iam-roles-for-service-accounts), except
there is no need to annotate the service account:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: nginx-s3-gateway
```

## Troubleshooting

### Disable default `404` error message

The default behavior of the container is to return a `404` error message for any non-`200` response code. This is
implemented as a security feature to sanitize any error response from the S3 bucket being proxied. For container
debugging purposes, this sanitization can be turned off by commenting out the `error_page` line shown below within
[`s3_location_common.conf.template`][s3-location-common-template] (the object-proxying path — its list omits `404`,
which is routed to trailing-slash handling instead) and all three equivalent `error_page` lines in
[`default.conf.template`][default-conf-template] (directory listings and index pages, whose lists do include `404`).
The templates are re-rendered on every container start, so rather than rebuilding the image you can bind-mount an
edited copy of a template over its path under `/etc/nginx/templates/`.

[default-conf-template]: https://github.com/nginxinc/nginx-s3-gateway/blob/main/common/etc/nginx/templates/default.conf.template
[s3-location-common-template]: https://github.com/nginxinc/nginx-s3-gateway/blob/main/common/etc/nginx/templates/gateway/s3_location_common.conf.template

```bash
error_page 400 401 402 403 405 406 407 408 409 410 411 412 413 414 415 416 417 418 420 422 423 424 426 428 429 431 444 449 450 451 500 501 502 503 504 505 506 507 508 509 510 511 =404 @error404;
```

Leave the adjacent `proxy_intercept_errors on;` directive in place: in `s3_location_common.conf.template` it also
drives the `error_page 404 @trailslashControl;` line below it, and commenting it out breaks the trailing-slash
redirects behind static-site index navigation. Also note that the `error_page` lists in `default.conf.template`
additionally collapse the access-phase method rejections described below (GH-551) into the sanitized `404`, so
disabling them changes those responses too.

Sanitization applies at delivery time, including on cache hits, so a cached upstream error keeps being delivered as
the sanitized `404` until its cache entry expires. An error cached before you disabled sanitization is stored
status-only (no S3 error body), so its S3 error message stays unavailable until the entry expires — see
[Caching of Error Responses](#caching-of-error-responses).

Note that not every `404` originates from S3. On the object paths it
proxies, the read-only gateway rejects non-read request methods (anything
other than `GET`/`HEAD`, plus `OPTIONS` when CORS is enabled) before
fetching credentials or contacting S3, and without consulting the local
filesystem (GH-496). On most paths the rejection is an immediate `405`
with an `Allow` header; on `*/index.html` paths it is denied in the access
phase and deliberately collapsed to the same sanitized `404` by the
`error_page` configuration shown above. With CORS enabled, both rejection
responses carry the `Access-Control-Allow-Origin` header, so for requests
the browser sends without a preflight, a cross-origin script observes the
real `405` or `404` status instead of an opaque network error; a
preflighted request for a rejected method fails at the preflight itself,
because `Access-Control-Allow-Methods` does not advertise it. (The
unproxied `/health` and `/soap` endpoints answer every method with their
fixed `200` and `404`.)

### Error `403 Access Denied` for AWS Accounts with MFA Enabled

The REST authentication method used in this container does not work with AWS IAM roles that have MFA enabled for
authentication. Please use AWS IAM role credentials that do not have MFA enabled.

### Objects are never written to the cache

If `/var/cache/nginx/s3_proxy` stays empty no matter how often an object is requested, the origin is most likely
returning a `Cache-Control` or `Expires` header that forbids caching — the default for authenticated reads on Google
Cloud Storage. Set `ACCESS_LOG_CACHE_STATUS=true` (see
[Measuring Cache Effectiveness](#measuring-cache-effectiveness)) and confirm that every access-log line ends in
`"MISS"` — or, to expose the same variable to clients instead, uncomment
`add_header X-Cache-Status $upstream_cache_status;` in [`default.conf.template`][default-conf-template] — then see
[Caching Objects from Origins that Send Cache-Control](#caching-objects-from-origins-that-send-cache-control).

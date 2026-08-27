# Development Guide

## Integrating with AWS Signature

Update the following files when enhancing `nginx-s3-gateway` to integrate with AWS signature whenever AWS releases a
new version of signature or you have a new PR:

- NGINX Proxy: [`/etc/nginx/conf.d/default.conf`](/common/etc/nginx/templates/default.conf.template)
- AWS Credentials Lib: [`/etc/nginx/include/awscredentials.js`](/common/etc/nginx/include/awscredentials.js)
- AWS Signature Lib per version:
  - [`/etc/nginx/include/awssig2.js`](/common/etc/nginx/include/awssig2.js)
  - [`/etc/nginx/include/awssig4.js`](/common/etc/nginx/include/awssig4.js)
- S3 Integration Lib: [`/etc/nginx/include/s3gateway.js`](/common/etc/nginx/include/s3gateway.js)
- Common Lib for all of NJS: [`/etc/nginx/include/utils.js`](/common/etc/nginx/include/utils.js)

![AWS signature flow across the njs modules](./img/nginx-s3-gateway-signature-flow.png)

## Extending the Gateway

### Extending gateway configuration via container images

#### `conf.d` Directory

On the container image, all files with the extension `.conf` in the
directory `/etc/nginx/conf.d` will be loaded into the configuration
of the base `http` block within the main NGINX configuration.

This allows for extension of the configuration by adding additional
configuration files into the container image extending the base
gateway image.

#### Stub Files

The NGINX configuration templates render into `/etc/nginx/conf.d` when the
container starts. The gateway ships three empty stub files in the `gateway/`
subdirectory that exist purely as extension points:

- [`/etc/nginx/conf.d/gateway/s3_server.conf`](/common/etc/nginx/templates/gateway/s3_server.conf.template)
- [`/etc/nginx/conf.d/gateway/s3_location.conf`](/common/etc/nginx/templates/gateway/s3_location.conf.template)
- [`/etc/nginx/conf.d/gateway/s3listing_location.conf`](/common/etc/nginx/templates/gateway/s3listing_location.conf.template)

Each of these files can be overwritten in a container image that inherits
from the S3 Gateway container image, so that additional NGINX configuration
directives can be inserted into the gateway configuration.

Two similarly located files in the same directory are *not* extension points
— the entrypoint writes their contents at container start:

- [`/etc/nginx/conf.d/gateway/s3_proxy_ssl.conf`](/common/etc/nginx/templates/gateway/s3_proxy_ssl.conf.template)
  receives the upstream TLS verification directives whenever
  `S3_SERVER_PROTO=https`. To verify a private or self-signed S3 origin
  against a custom CA bundle, set `S3_TRUSTED_CERT_PATH` instead of editing
  this file.
- [`/etc/nginx/conf.d/gateway/proxy_ignore_headers.conf`](/common/etc/nginx/templates/gateway/proxy_ignore_headers.conf.template)
  receives a `proxy_ignore_headers` directive when
  `PROXY_CACHE_IGNORE_HEADERS` is set, and stays empty otherwise. Set that
  variable instead of editing this file.

### Examples

In the [examples/ directory](/examples), there are `Dockerfile` examples that
show how to extend the base functionality of the NGINX S3 Gateway by adding
additional modules.

- [Enabling Brotli Compression in Docker](/examples/brotli-compression)
- [Enabling GZip Compression in Docker](/examples/gzip-compression)
- [Installing Modsecurity in Docker](/examples/modsecurity)

## Testing

The `GNUmakefile` (GNU Make 4.x) is the only supported interface for build and
test workflows. The test logic lives in `test/run_unit_tests.sh` and
`test/run_integration_tests.sh`, which make drives; the legacy `test.sh`
script is deprecated and only forwards to the equivalent make targets — do
not invoke it directly.

Automated tests require `docker`, `docker compose`, `curl`, `md5sum` (or `md5`
on macOS), and [`mc`](https://min.io/docs/minio/linux/reference/minio-mc.html) (used
as a generic S3 client against the RustFS test origin) to be
installed; run `make check-tools` to verify all prerequisites are present.

To build the gateway image and run the full unit and integration test suite:

```text
$ make test                  # NGINX OSS (default)
$ make test NGINX_TYPE=plus  # NGINX Plus
```

NGINX Plus builds require your NGINX repository certificates
(`nginx-repo.crt` and `nginx-repo.key`) in the `plus/etc/ssl/nginx`
directory, a `docker login private-registry.nginx.com` (the Plus base image
is pulled from NGINX's private registry), and a `license.jwt` in the
repository root or at `/etc/nginx/license.jwt` for the integration tests.

Other useful targets:

- `make retest` — rerun tests against the already-built image. Note that unit
  tests import the njs modules baked into the image, so after editing
  `common/etc/nginx/include/*.js` use `make test` to rebuild first.
- `make test-unit` / `make test-integration` — run just the unit or just the
  integration half of the suite against the already-built image.
- `make test-latest-njs` / `make test-unprivileged` — build and test the
  image variants.
- `make test-matrix` — reproduce the CI matrix locally.
- `make test S3_STYLE=path` (or `virtual` / `virtual-v2`) — reproduce a single
  CI matrix leg; plain `make test` covers only the default `virtual-v2` style.
- `make lint` — run the linters (checkmake + shellcheck).

Run `make help` for the full target list.

Agent users can also run an adaptive live smoke test of the gateway via the
skill in `.claude/skills/smoke-test/`, which exercises features the fixed
integration matrix does not cover.

### Adding tests

Unit tests live in `test/unit/` and run under the njs CLI inside the built
image. New files are discovered automatically: `test/run_unit_tests.sh` runs
every `test/unit/*_test.js` file twice — once with and once without
`AWS_SESSION_TOKEN` — so no wiring is needed. Environment variables that a
module under test reads at import time belong in the `unit_test_env` list in
that runner.

Integration tests live in `test/integration/` and are driven by
`test/run_integration_tests.sh`, which starts the compose environment
(`test/docker-compose.yaml`, with the
`test/docker-compose.dynamic-credentials.yaml` override supplying an ECS
credential-endpoint mock for the dynamic-credentials phase and the
`test/docker-compose.secret-file-credentials.yaml` override supplying the
static credentials as mounted secret files), seeds the RustFS S3 origin with
the fixtures in `test/data/`, and invokes the test scripts across a matrix of
gateway configurations, including HTTPS origins with TLS verification and a
CORS-enabled phase. New
shell scripts under `test/` and `test/integration/` are picked up by
`make lint` automatically and must pass `shellcheck --severity=warning`.

The make targets guard against image/target mismatches: the variant targets
(`retest-latest-njs`, `retest-unprivileged`) verify the floating
`nginx-s3-gateway` tag actually points at the matching variant image, and the
non-variant targets verify the inverse, failing with an actionable error
instead of a confusing test failure.

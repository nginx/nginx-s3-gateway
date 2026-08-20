# Development Guide

## Integrating with AWS Signature

Update the following files when enhancing `nginx-s3-gateway` to integrate with AWS signature whenever AWS releases a new version of signature or you have a new PR:

- NGINX Proxy: [`/etc/nginx/conf.d/default.conf`](/common/etc/nginx/templates/default.conf.template)
- AWS Credentials Lib: [`/etc/nginx/include/awscredentials.js`](/common/etc/nginx/include/awscredentials.js)
- AWS Signature Lib per version:
  - [`/etc/nginx/include/awssig2.js`](/common/etc/nginx/include/awssig2.js)
  - [`/etc/nginx/include/awssig4.js`](/common/etc/nginx/include/awssig4.js)

- S3 Integration Lib: [`/etc/nginx/include/s3gateway.js`](/common/etc/nginx/include/s3gateway.js)
- Common Lib for all of NJS: [`/etc/nginx/include/utils.js`](/common/etc/nginx/include/utils.js)

![](./img/nginx-s3-gateway-signature-flow.png)

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

* [`/etc/nginx/conf.d/gateway/s3_server.conf`](/common/etc/nginx/templates/gateway/s3_server.conf.template)
* [`/etc/nginx/conf.d/gateway/s3_location.conf`](/common/etc/nginx/templates/gateway/s3_location.conf.template)
* [`/etc/nginx/conf.d/gateway/s3listing_location.conf`](/common/etc/nginx/templates/gateway/s3listing_location.conf.template)

Each of these files can be overwritten in a container image that inherits
from the S3 Gateway container image, so that additional NGINX configuration
directives can be inserted into the gateway configuration.

### Examples

In the [examples/ directory](/examples), there are `Dockerfile` examples that 
show how to extend the base functionality of the NGINX S3 Gateway by adding
additional modules.

* [Enabling Brotli Compression in Docker](/examples/brotli-compression)
* [Enabling GZip Compression in Docker](/examples/gzip-compression)
* [Installing Modsecurity in Docker](/examples/modsecurity)

## Testing

The `GNUmakefile` (GNU Make 4.x) is the only supported interface for build and
test workflows. The legacy `test.sh` script still exists underneath, but it is
being migrated away from — do not invoke it directly.

Automated tests require `docker`, `docker compose`, `curl`, `md5sum` (or `md5`
on macOS), and `mc` (the
[MinIO client](https://min.io/docs/minio/linux/reference/minio-mc.html)) to be
installed; run `make check-tools` to verify all prerequisites are present.

To build the gateway image and run the full unit and integration test suite:

```
$ make test                  # NGINX OSS (default)
$ make test NGINX_TYPE=plus  # NGINX Plus
```

NGINX Plus builds require your NGINX repository certificates in the
`plus/etc/ssl/nginx` directory and a `license.jwt`.

Other useful targets:

* `make retest` — rerun tests against the already-built image. Note that unit
  tests import the njs modules baked into the image, so after editing
  `common/etc/nginx/include/*.js` use `make test` to rebuild first.
* `make test-latest-njs` / `make test-unprivileged` — build and test the
  image variants.
* `make test-matrix` — reproduce the CI matrix locally.
* `make lint` — run the linters (checkmake + shellcheck).

Run `make help` for the full target list.

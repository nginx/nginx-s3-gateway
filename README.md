[![NGINX S3 Gateway CI/CD](https://github.com/nginxinc/nginx-s3-gateway/actions/workflows/s3-gateway.yml/badge.svg)](https://github.com/nginxinc/nginx-s3-gateway/actions/workflows/s3-gateway.yml)
[![OpenSSF Scorecard](https://api.securityscorecards.dev/projects/github.com/nginxinc/nginx-s3-gateway/badge)](https://securityscorecards.dev/viewer/?uri=github.com/nginxinc/nginx-s3-gateway)
[![Project Status: Active – The project has reached a stable, usable state and is being actively developed.](https://www.repostatus.org/badges/latest/active.svg)](https://www.repostatus.org/#active)
[![Community Support](https://badgen.net/badge/support/community/cyan?icon=awesome)](/SUPPORT.md)
[![Community Forum](https://img.shields.io/badge/community-forum-009639?logo=discourse&link=https%3A%2F%2Fcommunity.nginx.org)](https://community.nginx.org)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/license/apache-2-0)
[![Contributor Covenant](https://img.shields.io/badge/Contributor%20Covenant-2.1-4baaaa.svg)](/CODE_OF_CONDUCT.md)

# NGINX S3 Gateway

## Introduction

This project provides a working configuration of NGINX configured to act as
an authenticating and caching gateway for to AWS S3 or another S3 compatible
service. This allows you to proxy a private S3 bucket without requiring users
to authenticate to it. Within the proxy layer, additional functionality can be
configured such as:

- Listing the contents of a S3 bucket, with marker-based pagination for
  directories holding more entries than one S3 response can carry
- Providing an authentication gateway using an alternative authentication
  system to S3
- Caching frequently accessed S3 objects for lower latency delivery and
  protection against S3 outages
- For internal/micro services that can't authenticate against the S3 API
  (e.g. don't have libraries available) the gateway can provide a means
  to accessing S3 objects without authentication
- Compressing objects ([gzip](examples/gzip-compression), [brotli](examples/brotli-compression)) from gateway to end user
- Protecting S3 bucket from arbitrary public access and traversal
- Rate limiting S3 objects
- Protecting a S3 bucket with a [WAF](examples/modsecurity)
- Serving static assets from a S3 bucket alongside a dynamic application
  endpoints all in a single RESTful directory structure

All such functionality can be enabled within a standard NGINX configuration
because this project is nothing other than NGINX with additional configuration
that allows for proxying S3. It can be used as-is if the predefined
configuration is sufficient, or it can serve as a base example for a more
customized configuration.

If the predefined configuration does not meet your needs, it is best to borrow
from the patterns in this project and build your own configuration. For example,
if you want to enable SSL/TLS and compression in your NGINX S3 gateway
configuration, you will need to look at other documentation because this
project does not enable those features of NGINX.

## Usage

This project can be run as a stand-alone container or as a Systemd service.
Both modes use the same NGINX configuration and are functionally equal in terms
features. However, in the case of running as a Systemd service, other services
can be configured that additional functionality such as [certbot](https://certbot.eff.org/)
for [Let's Encrypt](https://letsencrypt.org/) support.

## Getting Started

Refer to the [Getting Started Guide](docs/getting_started.md) for how to build
and run the gateway.

## Directory Structure and File Descriptions

```text
common/                          contains files used by both NGINX OSS and Plus configurations
  etc/nginx/include/
    awscredentials.js            common library to read and write credentials
    awssig2.js                   common library to build AWS signature 2
    awssig4.js                   common library to build AWS signature 4 and get a session token
    s3gateway.js                 common library to integrate the s3 storage from NGINX OSS and Plus
    utils.js                     common library to be reused by all of NJS codebases
deployments/                     contains files used for deployment technologies such as
                                 CloudFormation
docs/                            contains documentation about the project
examples/                        contains additional `Dockerfile` examples that extend the base
                                 configuration
jsdoc                            JSDoc configuration files
oss/                             contains files used solely in NGINX OSS configurations
plus/                            contains files used solely in NGINX Plus configurations
test/                            contains the test runner scripts (run_unit_tests.sh and
                                 run_integration_tests.sh, both driven by make) plus the njs
                                 unit tests and bash integration tests they execute
Dockerfile.oss                   Dockerfile that configures NGINX OSS to act as a S3 gateway
Dockerfile.plus                  Dockerfile that builds a NGINX Plus instance that is configured
                                 equivelently to NGINX OSS - instance is configured to act as a
                                 S3 gateway with NGINX Plus additional features enabled
Dockerfile.latest-njs            Dockerfile that inherits from the last build of the gateway and
                                 then builds and installs the latest version of njs from source
Dockerfile.unprivileged          Dockerfiles that inherits from the last build of the gateway and
                                 makes the necessary modifications to allow running the container
                                 as a non root, unprivileged user.
GNUmakefile                      entry point for all build, test, and lint workflows - run
                                 `make help` for the full target list
package.json                     Node.js package file used only for generating JSDoc
settings.example                 Docker env file example
standalone_ubuntu_oss_install.sh install script that will install the gateway as a Systemd service
test.sh                          deprecated wrapper that forwards to the equivalent make
                                 targets - do not invoke directly
```

## Development

Refer to the [Development Guide](docs/development.md) for more information about
extending or testing the gateway.

## Contributing

Please see the [contributing guide](/CONTRIBUTING.md) for guidelines on how to best contribute to this project.

## License

[Apache License, Version 2.0](/LICENSE)

&copy; [F5, Inc.](https://www.f5.com/) 2020 - 2025

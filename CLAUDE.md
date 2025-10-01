# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

NGINX S3 Gateway is a containerized NGINX configuration that acts as an authenticating and caching gateway to AWS S3 or S3-compatible services. It uses NGINX with NJS (NGINX JavaScript) modules to implement AWS Signature v2/v4 authentication.

## Architecture

### Directory Structure

- `common/` - Shared configuration files for both OSS and Plus
  - `etc/nginx/include/s3gateway.js` - Core NJS module implementing S3 authentication (AWS Sig v2/v4)
  - `etc/nginx/templates/` - NGINX config templates processed by Docker entrypoint
  - `docker-entrypoint.sh` - Main entrypoint script that processes templates with env vars
- `oss/` - NGINX OSS-specific configs
- `plus/` - NGINX Plus-specific configs with advanced caching features
- `test/` - Testing infrastructure
  - `unit/` - NJS unit tests
  - `integration/` - Integration tests against Minio
- `examples/` - Extension examples (brotli, gzip, modsecurity)
- `deployments/` - CloudFormation and ECS deployment configs

### Key Components

**S3 Gateway NJS Module** (`common/etc/nginx/include/s3gateway.js`):
- Implements AWS Signature v2 and v4 signing algorithms
- Handles credential retrieval from environment or EC2/ECS instance metadata
- Provides functions called from NGINX config to sign S3 requests
- Supports directory listing via XSL transformation
- Static site hosting with index.html transformation

**NGINX Configuration Flow**:
1. `nginx.conf` - Main config loading NJS modules and preserving env vars
2. `templates/default.conf.template` - Server block with S3 proxy configuration
3. `templates/gateway/v{2,4}_*.conf.template` - Version-specific signing configs
4. Templates are processed by entrypoint, substituting environment variables

**Docker Entrypoint**:
- Validates required environment variables
- Sets DNS resolvers dynamically
- Processes `.template` files to generate final NGINX configs

## Build and Test Commands

### Building

```bash
# Build NGINX OSS version
docker build -f Dockerfile.oss --tag nginx-s3-gateway:oss .

# Build NGINX Plus version (requires nginx-repo.crt/key in plus/etc/ssl/nginx/)
DOCKER_BUILDKIT=1 docker build -f Dockerfile.buildkit.plus \
  --secret id=nginx-crt,src=plus/etc/ssl/nginx/nginx-repo.crt \
  --secret id=nginx-key,src=plus/etc/ssl/nginx/nginx-repo.key \
  --tag nginx-plus-s3-gateway:plus .

# Build with latest NJS from source
docker build -f Dockerfile.latest-njs --tag nginx-s3-gateway:latest-njs-oss .
```

### Testing

```bash
# Run all tests (unit + integration) for NGINX OSS
./test.sh oss

# Test with latest NJS
./test.sh latest-njs-oss

# Test NGINX Plus
./test.sh plus

# Run only unit tests
docker run --rm -v "$(pwd)/test/unit:/var/tmp" --workdir /var/tmp \
  -e S3_BUCKET_NAME=test -e S3_SERVER=test -e S3_REGION=test \
  -e AWS_SIGS_VERSION=4 --entrypoint /usr/bin/njs \
  nginx-s3-gateway -t module -p '/etc/nginx' /var/tmp/s3gateway_test.js
```

**Test Dependencies**: docker, docker-compose, curl, md5sum, wait-for-it (optional)

**Test Workflow**:
- `test.sh` builds Docker image, runs unit tests via NJS, then starts docker-compose with Minio
- Integration tests verify AWS Sig v2/v4, directory listing, index pages, and slash appending
- Tests run against local Minio server (http://localhost:9090)

### Running

```bash
# Run with environment file
docker run --env-file ./settings --publish 80:80 nginx-s3-gateway:oss

# Required environment variables (see settings.example):
# S3_BUCKET_NAME, S3_ACCESS_KEY_ID, S3_SECRET_KEY, S3_SERVER,
# S3_SERVER_PORT, S3_SERVER_PROTO, S3_REGION, AWS_SIGS_VERSION, S3_STYLE
```

## Configuration System

All configuration is via environment variables (see `settings.example`):

**Core S3 Settings**:
- `AWS_SIGS_VERSION` - Set to 2 or 4 for signature version
- `S3_STYLE` - `virtual` (DNS-style bucket.host) or `path` (host/bucket/)
- `S3_ACCESS_KEY_ID` / `S3_SECRET_KEY` - Omit to use instance profile credentials

**Feature Flags**:
- `ALLOW_DIRECTORY_LIST` - Enable S3 directory listing
- `PROVIDE_INDEX_PAGE` - Transform `/path/` to `/path/index.html`
- `APPEND_SLASH_FOR_POSSIBLE_DIRECTORY` - 302 redirect to add trailing slash

**Caching**:
- `PROXY_CACHE_VALID_OK`, `PROXY_CACHE_VALID_NOTFOUND`, `PROXY_CACHE_VALID_FORBIDDEN`

Environment variables are preserved via `env` directives in `nginx.conf` and accessed in NJS via `process.env`.

## Development Patterns

### Adding New Features

1. Modify `common/etc/nginx/include/s3gateway.js` for NJS logic changes
2. Update `common/etc/nginx/templates/*.template` for NGINX config changes
3. Add unit tests to `test/unit/s3gateway_test.js`
4. Add integration tests to `test/integration/test_api.sh`
5. Update both OSS and Plus configs if behavior differs

### AWS Signature Implementation

The gateway signs requests to S3 in NJS before proxying:
- Credentials from env vars or fetched from EC2/ECS metadata endpoints
- HMAC-SHA256 signing using `crypto` module
- Signature inserted as `Authorization` header or query parameters (v2 style)
- Requests proxied to S3 via upstream defined in templates

### Instance Profile Credentials

When `S3_ACCESS_KEY_ID`/`S3_SECRET_KEY` are omitted:
- Gateway queries EC2 metadata API (169.254.169.254) or ECS credentials endpoint
- Credentials cached in NGINX Plus via `keyval_zone` or fetched per-request in OSS
- Must set `http-put-response-hop-limit 3` when running in containers on EC2

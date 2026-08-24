# Smoke-test phase specifications

Pinned checklist as of 2026-08. Discovery (SKILL.md Step 1) wins on any
conflict: verify fixture names against `test/data/<bucket>/`, ports and
credentials against `test/docker-compose.yaml`, and settings against
`docs/getting_started.md` before trusting a pinned value.

Conventions used below:

- `BASE` = the gateway's host URL (currently `http://localhost:8989`).
- "recreate with X" = Step 3 of SKILL.md with the listed exports/overlay,
  then wait on `/health` and confirm the startup banner.
- Every phase inherits the Step 2 baseline exports unless it overrides
  them; settings marked *(overlay)* have no compose pass-through key.
- Tags: **HOLE** = never covered by the fixed integration suite;
  **pin #N** = regression assertion for a fixed GitHub issue (see
  `references/regressions.md`).

---

## P0: Baseline sanity

Env: Step 2 defaults (v4 signatures, listing off, index off).

1. `GET BASE/health` → 200. **HOLE** — the suite never requests it.
2. Gateway logs contain the startup banner block `S3 Backend
   Environment:` with `AWS Signatures Version: v4` and an `Addressing
   Style:` matching the export; the secret access key value from the
   compose file must NOT appear anywhere in the logs.
3. `GET BASE/a.txt` → 200; body byte-identical to
   `test/data/bucket-1/a.txt` (compare with `cmp`).
4. `HEAD BASE/a.txt` → 200 with `Content-Length` equal to the fixture's
   size on disk.
5. `GET BASE/a.txt` with `Range: bytes=0-9` → 206 with a 10-byte body.
6. `GET BASE/no-such-object` → 404; the body must be the gateway's
   sanitized error page — it must not contain origin XML (`<Error>`,
   request-id fields) or the bucket name.
7. `GET BASE/b//e.txt` → 404. Double slashes are preserved as distinct
   object-key bytes; `b//e.txt` is not `b/e.txt` (pinned suite behavior).
8. `GET BASE/soap` → 404 (the SOAP API location is blocked).

Covers: `/health` HOLE, sanitized-404 contract, double-slash pin.

---

## P1: Directory listing, index pages, special characters

Recreate with `ALLOW_DIRECTORY_LIST=true
APPEND_SLASH_FOR_POSSIBLE_DIRECTORY=true`.

1. `GET BASE/` → 200 HTML listing; entries must match the top level of
   `test/data/bucket-1/` read at run time (e.g. `a.txt`, `a/`, `b/`).
2. `GET BASE/b/` → 200 listing containing `e.txt` and `c/`.
3. `GET BASE/b` → 302 with a **relative** `Location: /b/`
   (`absolute_redirect off`); query strings must survive the redirect
   (`GET BASE/b?x=1` → `Location: /b/?x=1`).
4. Percent-encoded special-character keys → 200 with correct bodies:
   - `GET BASE/a/plus%2Bplus.txt` — and verify the *raw* form
     `BASE/a/plus+plus.txt` also returns 200 (`+` must not decay to
     space in the object key).
   - the Unicode fixtures (Cyrillic/Japanese/Hebrew names under `a/`,
     `b/`, and the Cyrillic directory), percent-encoded byte-wise.
   - the generated `a/%@!*()=$#^&|.txt` object (encode every reserved
     byte, e.g. `%25%40%21%2A%28%29%3D%24%23%5E%26%7C`).
   - `системы/%bad%file%name%` — literal `%` bytes must be sent as
     `%25`.
5. Listing pages must link those names correctly: entry hrefs are
   **root-relative** (`/b/c/`, percent-encoded), so resolve them against
   `BASE` — not against the listing page's path — and expect 200. This
   catches escaping bugs in the listing XSLT rather than in object
   fetching.

Recreate with `PROVIDE_INDEX_PAGE=true` (listing still on):

6. `GET BASE/statichost/` → 200; body identical to
   `test/data/bucket-1/statichost/index.html`.
7. `GET BASE/statichost/noindexdir/` → directory has no `index.html`;
   with listing on this falls back to a listing — expect 200 HTML
   containing `noindex.html`. Recreate with `ALLOW_DIRECTORY_LIST=false
   PROVIDE_INDEX_PAGE=true` and expect 404 instead.
8. `GET BASE/statichost/noindexdir/multipledir/` → 200 (nested index).

*(overlay)* Recreate with listing on plus
`DIRECTORY_LISTING_PATH_PREFIX: "files/"`:

9. `GET BASE/` → 200; listing hrefs are prefixed with `files/` while
   `GET BASE/a.txt` (un-prefixed) still returns 200 — the prefix
   rewrites only the rendered links, for gateways published behind an
   outer path-adding proxy. **HOLE** — the suite never sets this and
   the compose file has no key for it.

Covers: listing-prefix HOLE, append-slash contract, URI-escaping surface.

---

## P2: Path rewriting (strip / prefix leading directory path)

Recreate with `STRIP_LEADING_DIRECTORY_PATH=/tostrip`:

1. `GET BASE/tostrip/a.txt` → 200, body of `a.txt`.
2. `GET BASE/a.txt` → 200 (paths without the prefix pass through).
3. Characterize the documented-but-surprising unanchored match:
   `GET BASE/tostripextra/a.txt` — record actual behavior; classify as
   `expected-behavior` unless it contradicts `docs/getting_started.md`.

Recreate with `PREFIX_LEADING_DIRECTORY_PATH=/b ALLOW_DIRECTORY_LIST=true`:

4. `GET BASE/e.txt` → 200 (origin key `b/e.txt`); `GET BASE/c/d.txt` →
   200 (`b/c/d.txt`).
5. `GET BASE/` → 200 listing whose hrefs must NOT leak the prefix: it
   contains `c/` and `e.txt` links, no `/b/…` links, and no parent
   (`../`) link at the root. `GET BASE/c/` → listing that DOES contain
   the parent link. **pin #577**
6. Recreate with the trailing-slash form `PREFIX_LEADING_DIRECTORY_PATH=/b/`
   → probes 4–5 behave identically. **pin #576**

Recreate with `STRIP_LEADING_DIRECTORY_PATH=/tostrip
PREFIX_LEADING_DIRECTORY_PATH=/b`:

7. `GET BASE/tostrip/e.txt` → 200 (strip then prefix compose).

Recreate with `PREFIX_LEADING_DIRECTORY_PATH=/statichost
PROVIDE_INDEX_PAGE=true`:

8. `GET BASE/` → 200; body identical to `statichost/index.html` (the
   index probe must not double-apply the prefix). **pin #577**

Startup validation:

9. Recreate with `PREFIX_LEADING_DIRECTORY_PATH="/bad'value"` → the
   gateway container must exit; logs name the rejected character. Same
   for a value containing `$`. Classify as `expected-behavior` when the
   rejection is clean; a hang or a silent start is a `defect`. Restore
   a clean environment afterwards.

Covers: #577/#575/#576/#480 pins, strip/prefix composition.

---

## P3: Addressing styles × signature versions

The suite's CI matrix runs the two virtual-host styles (`virtual`,
`virtual-v2`) with both signature versions; path style never runs. This
phase covers the path-style hole and cross-checks the v2 combinations.

Recreate with `S3_STYLE=path AWS_SIGS_VERSION=4 ALLOW_DIRECTORY_LIST=true`
(**HOLE** — path style is never a matrix leg). Note: path style keeps the
bucket out of the upstream hostname, so it also works for buckets that
lack a virtual-host DNS alias on the compose network.

1. Banner shows `Addressing Style: path`; `GET BASE/a.txt` → 200.
2. `GET BASE/b/` → 200 listing; a Unicode key → 200.

Recreate with `S3_STYLE=virtual AWS_SIGS_VERSION=2
ALLOW_DIRECTORY_LIST=true` (cross-check, not a hole — the suite runs
several v2 legs, including with listing, under both matrix styles):

3. `GET BASE/a.txt` → 200; `GET BASE/b/` → 200 listing.
4. Special-character keys in their **pre-normalized** (fully
   percent-encoded) form → 200. The RAW forms (`a/plus+plus.txt`, raw
   `!*()`) fail under v2 with a sanitized 404: v2 signs the client's
   raw URI bytes while sending the gateway-normalized URI upstream, so
   the origin sees SignatureDoesNotMatch (confirmed live 2026-08; v4 is
   unaffected because it signs the normalized form). This is known open
   issue GH-578 — do not re-report it as a new defect while it is open.
   Probe raw forms LAST or on a fresh cache — the cache key is the
   normalized URI, so a raw-form failure (an upstream 403, cached under
   `PROXY_CACHE_VALID_FORBIDDEN`, 30s) masks encoded-form requests, and
   a prior encoded-form 200 masks the raw-form failure for
   `PROXY_CACHE_VALID_OK` (the shared-entry masking itself is GH-579).
5. `HEAD BASE/b/` — the suite pins HEAD on a directory as 404 (an
   origin behavior, not v2-specific); record actual status as
   `expected-behavior`.

Recreate with `S3_STYLE=virtual-v2 AWS_SIGS_VERSION=2`:

6. `GET BASE/a.txt` → 200.

Covers: path-style HOLE, v2 combination cross-checks.

---

## P4: Method policy and CORS

CORS off (Step 2 defaults — the compose file interpolates
`CORS_ENABLED:-false`):

1. `OPTIONS BASE/a.txt` → 405 with `Allow: GET, HEAD` **exactly** and no
   `Access-Control-Allow-Origin` header. **pin #574**
2. `PUT BASE/a.txt`, `DELETE BASE/a.txt`, `POST BASE/a.txt` → 405 each.
3. `POST BASE/gh496-does-not-exist` → 405 — the rejection happens in the
   rewrite phase and must not depend on whether the object exists.
4. `POST BASE/gh551-writeguard/index.html` → 404, not 405: index-page
   paths collapse the rejection to a sanitized 404. **pin #574**
5. `GET BASE/a.txt` with `Origin: http://smoke.example` → 200 with no
   CORS headers.

Recreate with `CORS_ENABLED=true CORS_ALLOWED_ORIGIN=http://smoke.example`:

6. Preflight `OPTIONS BASE/a.txt` with `Origin: http://smoke.example`
   and `Access-Control-Request-Method: GET` → 204;
   `Access-Control-Allow-Origin: http://smoke.example` and
   `Access-Control-Allow-Methods: GET, HEAD, OPTIONS`. **pin #574**
7. `GET BASE/a.txt` with the Origin header → 200 with
   `Access-Control-Allow-Origin` present **exactly once** (count with
   `grep -ci`).
8. `GET BASE/no-such-object` with the Origin header → 404 carrying the
   ACAO header; `PUT BASE/a.txt` with it → 405 carrying ACAO exactly
   once (error responses participate in CORS). **pin #574**
9. Preflight from a different origin (`Origin: http://other.example`) →
   the response still carries the **configured** value
   (`Access-Control-Allow-Origin: http://smoke.example`). The gateway
   never reads the request `Origin`; it emits `CORS_ALLOWED_ORIGIN`
   verbatim and leaves mismatch enforcement to the browser — an ACAO
   header on a wrong-origin preflight is `expected-behavior`, not a
   defect.

*(overlay)* Recreate with CORS on plus
`CORS_ALLOW_PRIVATE_NETWORK_ACCESS: "true"`:

10. Preflight with `Access-Control-Request-Private-Network: true` →
    response has `Access-Control-Allow-Private-Network: true`; with the
    overlay value `"false"` → header value `false`; with it unset →
    header absent. **HOLE**

Covers: #574 pins, private-network-access HOLE.

---

## P5: Proxy cache

Cache-hit evidence technique: overwrite the object at the origin (CLI
copy of different content) after warming, then re-request — an unchanged
body proves the response came from the cache. The gateway's cache resets
on every recreate, so order within each block matters.

Baseline (Step 2 defaults; `PROXY_CACHE_VALID_OK` is 1h):

1. Warm `GET BASE/cache-bypass/enabled.txt` → 200. Overwrite the object
   at the origin. `GET` again → OLD body (cache hit).
2. Same request with `Cache-Control: no-cache` → still the OLD body
   (bypass is off by default — the header must not bust the cache).

Recreate with `PROXY_CACHE_BYPASS_NO_CACHE=true`:

3. Warm → overwrite at origin → `GET` with `Cache-Control: no-cache` →
   NEW body; then `GET` without the header → NEW body (the bypass also
   refreshed the cache entry). **pin (suite parity)**

Ignored headers (**pin #566**): seed an object whose origin response
carries `Cache-Control: private,max-age=0` — no space after the comma;
the CLI's copy-time attribute flag breaks on it (see the suite's
cache-ignore-headers fixtures):

4. Default env: warm → overwrite → `GET` → NEW body (the origin header
   suppressed caching).
5. Recreate with `PROXY_CACHE_IGNORE_HEADERS="Cache-Control Expires"`:
   warm → overwrite → `GET` → OLD body (header ignored, entry cached).
6. Recreate with `PROXY_CACHE_IGNORE_HEADERS="X-Bogus"` → startup must
   abort with a clear message naming the invalid field
   (`00-check-for-required-env.sh` allowlists the fields;
   `25-set-proxy-ignore-headers.sh` only renders the directive);
   `expected-behavior`. Restore a clean environment.

Stale serving (**HOLE** — `PROXY_CACHE_USE_STALE` has no compose key and
no suite coverage). *(overlay)* Recreate with
`PROXY_CACHE_VALID_OK: "5s"` so entries expire quickly:

7. Warm an object; wait ~6 s; stop the origin service
   (`docker compose … stop <origin service>`); `GET` → 200 with the
   cached body — the default `PROXY_CACHE_USE_STALE` includes
   `error`/`timeout`.
8. *(overlay)* Same sequence with `PROXY_CACHE_USE_STALE: "off"` → 404,
   not 5xx: the upstream 502 is collapsed by the sanitized-404
   `error_page` design. The signal is the contrast with probe 7's 200.
9. Restart the origin, wait for its healthcheck, and re-verify
   `GET BASE/a.txt` → 200 before any later phase runs.

Slice cache:

10. Recreate with `TEST_PROXY_CACHE_SLICE_SIZE=10` exported: `Range:
    bytes=0-9` on `cache-bypass/sliced.txt` → 206 (sliced upstream
    path); then `Range: bytes=10-19` → 206 with the correct bytes
    (each slice is fetched and cached independently). A plain `GET`
    without a `Range` header never enters `@s3_sliced` — the njs router
    only redirects there when `Range` is present — so it proves nothing
    about the slice cache.

Covers: #566 pin, USE_STALE HOLE, bypass contract, slice integrity.

---

## P6: Response header prefix stripping / allowlisting

Seed a fresh object carrying user metadata (an `x-amz-meta-…` response
header) — the origin CLI sets it via a copy-time attribute flag.

1. Step 2 defaults: `GET` the object with `curl -sI` → the
   `x-amz-meta-…` header must be ABSENT (`x-amz-` prefixed headers are
   stripped by default) and no other `x-amz-*` headers leak.
2. *(overlay)* `HEADER_PREFIXES_ALLOWED: "x-amz-meta-"` → the metadata
   header IS present; other `x-amz-*` headers (request ids) remain
   stripped. **HOLE**
3. *(overlay)* `HEADER_PREFIXES_TO_STRIP:
   "x-xss-;strict-transport-;content-security-"` → those origin-emitted
   headers disappear from responses in addition to the defaults. Pick
   only *generic* origin headers: nginx **special** headers
   (`Server`, `Last-Modified` — dedicated fields, not list entries)
   cannot be stripped by the njs header filter and probing them only
   produces phantom failures (verified live 2026-08). That silent
   limitation is itself a doc gap worth reporting. **HOLE**

Covers: header-prefix HOLEs (unit-only coverage today).

---

## P7: Empty-bucket behavior and IPv6 listen directives

Create a second, empty bucket at the origin (CLI make-bucket). Virtual
addressing only has DNS for the seeded bucket's hostname on the compose
network, so pair the override with path style. *(overlay)*
`S3_BUCKET_NAME: "<empty bucket>"` plus exports `S3_STYLE=path
ALLOW_DIRECTORY_LIST=true`:

1. `GET BASE/` → 200 with the "No Files Available for Listing" page.
2. *(overlay)* add `FOUR_O_FOUR_ON_EMPTY_BUCKET: "true"` → `GET BASE/`
   → 404. **HOLE**

IPv6 (cross-check, not a hole — the suite covers both probes via
`integration_test_listen_directives` in `run_integration_tests.sh` and
`test/integration/test_entrypoint_ipv6.sh`):

3. With `IPV6_ENABLED` unset/empty (auto-detect): read the rendered
   config (`docker exec <gateway container> grep -c 'listen.*\[::\]'
   /etc/nginx/conf.d/default.conf` — the directive is indented with
   MULTIPLE spaces, so never anchor the pattern on a single space) —
   the `listen [::]:…` directive must be present iff the kernel
   supports IPv6, and the startup banner's `IPv6 Listen:` line must
   agree with the rendered state.
4. Recreate with `IPV6_ENABLED=true`, then `IPV6_ENABLED=false`:
   rendered directive and banner must track the setting per
   `docs/getting_started.md`; record any disagreement.

Covers: FOUR_O_FOUR HOLE, IPv6 banner/config consistency cross-check.

---

## P8 (extended): Credential sources

Replicate the suite's two credential phases — read their functions in
`test/run_integration_tests.sh` for the exact overlay files, profiles,
and mock configuration; do not improvise the mock.

Container-metadata mock (overlay
`test/docker-compose.dynamic-credentials.yaml`):

1. Launch with the static credential variables scrubbed from the
   compose command line (`env -u AWS_ACCESS_KEY_ID -u
   AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN docker compose …`) so the
   only credential path is the mock endpoint.
2. `GET BASE/a.txt` → 200 (credentials fetched and used); a second GET
   → 200 without a second fetch logged (the shared-memory cache).
3. `docker compose … exec -T nginx-s3-gateway ls /tmp/credentials.json`
   → must NOT exist (the legacy file cache is gone). **pin #565**

Secret files (overlay `test/docker-compose.secret-file-credentials.yaml`;
secret files on the host must be readable by the worker user — see the
suite's function for the exact permissions dance). Launch with the SAME
`env -u` scrub as probe 1: the overlay's `AWS_*: null` keys mean
"inherit from the shell", so any real credentials exported in the
invoking shell would silently override the secret files and leak into
the test gateway:

4. `GET BASE/a.txt` → 200 with credentials supplied via `AWS_*_FILE`.
5. `docker compose … exec -T nginx-s3-gateway env` → the secret VALUE
   must not appear. **pin #573**
6. Characterize the validation: both `AWS_SECRET_ACCESS_KEY` and
   `AWS_SECRET_ACCESS_KEY_FILE` set (non-empty) → startup must fail
   with a message naming the conflict; an unreadable or empty secret
   file → startup must fail cleanly. `expected-behavior` when clean.

Covers: #573/#565 pins, credential-cache behavior.

---

## P9 (extended): TLS verification of the origin

Replicate the suite's TLS phase (`integration_test_proxy_ssl` and its
helpers): generate a throwaway CA and an origin server certificate into
a scratch directory, export EVERY `TEST_…` variable the compose file
consumes (grep it for `TEST_`: `TEST_TLS_CERT_DIR`,
`TEST_S3_SERVER_PROTO`, `TEST_S3_TRUSTED_CERT_PATH`, `TEST_S3_SERVER`,
`TEST_S3_SERVER_PORT`, plus the origin service's certs-dir and
healthcheck-protocol variables), and restart the origin serving HTTPS.
Missing the healthcheck-protocol variable is fatal to the whole phase:
the origin's healthcheck keeps probing plain HTTP, the service never
reports healthy, and the gateway — which depends on that condition —
never starts.

1. Gateway trusting only the default CA bundle → `GET BASE/a.txt` →
   non-200, and gateway logs contain `upstream SSL certificate verify
   error`. **pin #565**
2. Gateway with the throwaway CA as its trusted certificate → 200, and
   a `Range` request → 206 (the sliced path verifies TLS too).
3. Path-style gateway pointed at the origin's mismatch network alias
   (set `TEST_S3_SERVER` to the alias the suite's helper uses — a name
   the certificate does not cover) → logs contain
   `upstream SSL certificate does not match`. **pin #565**
4. Tear the TLS configuration down completely afterwards (certificates
   live only in the scratch directory; unset the `TEST_…` exports and
   recreate the origin on plain HTTP).

Covers: #565 pins, TLS trust and hostname verification.

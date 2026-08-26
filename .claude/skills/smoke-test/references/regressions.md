# Pinned regression assertion sets

Assertion sets for fixed GitHub issues. Used two ways: the `regressions`
and `issue <N>` dispatch modes run them directly, and the root-cause
classification protocol checks new failures against them before calling
anything a new defect. Probe conventions are the same as in
`references/phases.md` (`BASE`, recreate, overlay).

Each set names its fix commit; `git log <commit> -1` shows the full
context if a probe's intent is unclear.

## #88 — duplicate literal slashes collapse before signing and proxying

Fix commit: the commit that added this entry. The raw `$request_uri`
bytes flowed into the S3 key and the ListObjectsV2 prefix, so a `//` in
a request path could only match a key literally containing consecutive
slashes and everything else surfaced as a sanitized 404 or an empty
listing.

Step 2 defaults (listing off, index off), fresh recreate (slash
spellings share one cache entry keyed on the normalized `$s3uri` —
probe raw forms first, same masking caveat as #578):

1. `GET BASE/b//e.txt` → 200, body of `b/e.txt`;
   `GET BASE/b//c///d.txt` → 200, body of `b/c/d.txt`.
2. `GET BASE/b/%2Fe.txt` → 404 (a percent-encoded slash is object-key
   data, never collapsed — the escape hatch for keys containing `//`).
3. `GET BASE//` → 404 — the collapsed root must hit `redirectToS3`'s
   root guard, never proxy a signed bucket-root GET (an object-listing
   leak while listing is disabled).

With `ALLOW_DIRECTORY_LIST=true`:

4. `GET BASE/b//c///` → 200 listing with heading `Index of /b/c/` and
   an `href="/b/c/d.txt"` entry (the v4 signer derives the listing
   params from an independent read of the path, so the signed and
   proxied prefixes must both be the collapsed form).
5. `GET BASE//` → 200 root listing.

With `AWS_SIGS_VERSION=2 ALLOW_DIRECTORY_LIST=true` (fresh recreate):

6. Probes 1 and 4 again — v2 signs the `s3uri()`-derived resource, so
   the collapsed form must authenticate; logs contain zero
   `SignatureDoesNotMatch` occurrences.

With `STRIP_LEADING_DIRECTORY_PATH=/my-bucket` (fresh recreate):

7. `GET BASE//my-bucket//a.txt` → 200, body of `test/data/bucket-1/a.txt`.
   The collapse runs before the STRIP/PREFIX map chooses its rewrite arm
   (`$uri_full_path` is js_set-derived and pre-collapsed), so a doubled
   slash at the stripped prefix cannot bypass the strip and address the
   unstripped S3 key.

## #578 — SigV2 signs the same normalized URI it proxies

Fix commit: the commit that added this entry (PR #582). The v2 signer
signed the raw client URI bytes while proxying the canonically
re-encoded `$s3uri`, so every non-canonical encoding variant failed
upstream with SignatureDoesNotMatch, surfaced as a sanitized 404.

With `S3_STYLE=virtual AWS_SIGS_VERSION=2 ALLOW_DIRECTORY_LIST=true`,
on a **fresh recreate** (cold cache — encoding variants share one
cache entry keyed on the normalized `$s3uri`, so a canonical-form
warm-up masks a signing regression; that masking is GH-579), raw
forms first:

1. `GET BASE/a/plus+plus.txt` → 200 (raw `+`).
2. `GET BASE/%61.txt` → 200 (over-encoded `a.txt`).
3. `GET BASE/b/c/%3d` → 200, body of `b/c/=` (lowercase hex; uses its
   own object so probe 1's entry cannot serve it).
4. `GET BASE/a/%25%40!*()%3D%24%23%5E%26%7C.txt` → 200 (raw `!*()`).
5. Gateway logs contain zero `SignatureDoesNotMatch` occurrences.
6. `GET BASE/b/` → 200 listing (the CanonicalizedResource still
   excludes the delimiter/prefix listing parameters).

With `S3_STYLE=path AWS_SIGS_VERSION=2 ALLOW_DIRECTORY_LIST=true`
(fresh recreate; now a CI matrix leg — #581):

7. `GET BASE/a/plus+plus.txt` → 200 and `GET BASE/` → 200 listing
   (the signed listing resource is now the spec-correct `/<bucket>`,
   previously `/<bucket>/`).

Session-token corollary (v2 never signs `X-Amz-Security-Token`;
`AWS_SESSION_TOKEN` has no compose pass-through key — use an overlay):

8. `AWS_SIGS_VERSION=2` plus a non-empty `AWS_SESSION_TOKEN` (or
   `AWS_SESSION_TOKEN_FILE`) → the container exits; logs contain
   `cannot be used with AWS_SIGS_VERSION=2`.
9. `AWS_SIGS_VERSION=2`, static keys, and a **set-but-empty**
   `AWS_SESSION_TOKEN` → starts normally (empty counts as absent,
   matching the njs modules).

## #577 (also #480, #575, #576) — PREFIX_LEADING_DIRECTORY_PATH hygiene

Fix commit: `432d78c`. The prefix leaked into listing links and
headings, the index-page loopback probe applied it twice, and a
trailing-slash value produced double-slash object keys.

With `PREFIX_LEADING_DIRECTORY_PATH=/b ALLOW_DIRECTORY_LIST=true`:

1. `GET BASE/e.txt` → 200 (origin key `b/e.txt`).
2. `GET BASE/` → listing links say `c/` and `e.txt` — no `/b/…` href,
   no `../` parent link at the root, heading shows `/` not `/b`.
3. `GET BASE/c/` → listing contains the `../` parent link.

With `PREFIX_LEADING_DIRECTORY_PATH=/b/` (trailing slash): probes 1–3
behave identically (#576).

With `PREFIX_LEADING_DIRECTORY_PATH=/statichost PROVIDE_INDEX_PAGE=true`:

4. `GET BASE/` → 200, body of `statichost/index.html` (no
   double-application by the loopback probe) (#480).

Startup validation:

5. A value containing `'` or `$` → container exits with a message
   naming the rejected character.

## #574 — uniform non-read method rejection and the CORS contract

Fix commit: `5bb75e2` (GH-496, GH-551 lineage).

CORS off:

1. `OPTIONS BASE/a.txt` → 405, `Allow: GET, HEAD` exactly, no
   `Access-Control-Allow-Origin`.
2. `POST BASE/gh496-does-not-exist` → 405 (rewrite-phase rejection —
   must not depend on object existence).
3. `POST BASE/gh551-writeguard/index.html` → 404 (index-page paths
   collapse to a sanitized 404, not 405).

CORS on (`CORS_ENABLED=true CORS_ALLOWED_ORIGIN=<origin>`):

4. Preflight `OPTIONS` with matching `Origin` +
   `Access-Control-Request-Method: GET` → 204 with the exact origin in
   `Access-Control-Allow-Origin` and
   `Access-Control-Allow-Methods: GET, HEAD, OPTIONS`.
5. 405 and sanitized-404 responses carry `Access-Control-Allow-Origin`
   **exactly once** (no duplicate header).

## #573 — credentials from files (Docker secrets)

Fix commit: `5b08afb` (GH-67). Uses the secret-file compose overlay —
see P8 in `references/phases.md` for the setup.

1. `GET BASE/a.txt` → 200 with credentials supplied only via
   `AWS_*_FILE`.
2. `docker compose … exec -T nginx-s3-gateway env` → the secret value
   is absent.
3. Both the direct variable and its `_FILE` twin set (non-empty) →
   startup fails naming the conflict; unreadable or whitespace-only
   secret file → startup fails cleanly.

## #566 — PROXY_CACHE_IGNORE_HEADERS

Fix commit: `63e54ef`. See P5 probes 4–6 in `references/phases.md`.

1. Origin `Cache-Control: private, max-age=0` suppresses caching when
   the setting is unset.
2. `PROXY_CACHE_IGNORE_HEADERS="Cache-Control Expires"` → the same
   response IS cached.
3. An unknown field name → startup aborts with a message naming it.

## #565 — origin TLS verification, cache key, in-memory credentials

Fix commit: `251e1e1`. TLS setup per P9 in `references/phases.md`.

1. Untrusted HTTPS origin → request fails and logs contain
   `upstream SSL certificate verify error`.
2. Hostname mismatch (path style against the origin's mismatch alias)
   → logs contain `upstream SSL certificate does not match`.
3. Trusted CA → 200, and a `Range` request → 206.
4. Cache entries are shared across differing viewer `Host` headers
   (send the same GET with two `Host:` values; the second is a hit —
   the cache key deliberately excludes the viewer host).
5. `/tmp/credentials.json` does not exist in the gateway container.

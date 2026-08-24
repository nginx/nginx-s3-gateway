# Pinned regression assertion sets

Assertion sets for fixed GitHub issues. Used two ways: the `regressions`
and `issue <N>` dispatch modes run them directly, and the root-cause
classification protocol checks new failures against them before calling
anything a new defect. Probe conventions are the same as in
`references/phases.md` (`BASE`, recreate, overlay).

Each set names its fix commit; `git log <commit> -1` shows the full
context if a probe's intent is unclear.

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

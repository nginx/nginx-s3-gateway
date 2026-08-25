# Root-cause playbook

Read this when a probe fails. Work the evidence ladder top-down (cheap
first), localize with the symptom table, then run the classification
protocol before recording the finding.

## Evidence ladder

1. **Re-run the probe with `curl -v`** (add `--raw` for byte-level body
   issues). Capture status, every response header, and the body.
2. **Gateway logs.** The error log goes to stdout at `info`, and the
   test stack sets `DEBUG: "true"` in the compose file, so njs
   `debug_log` output is already there:
   `docker compose -f test/docker-compose.yaml -p ngt logs nginx-s3-gateway`.
   Signature/credential debug lines are redacted to SHA-256
   fingerprints — compare fingerprints across requests, never expect
   raw secrets.
3. **Startup banner** (`S3 Backend Environment:` block near the top of
   the logs). If the banner disagrees with the settings you exported,
   the failure is an environment-delivery problem (bare pass-through
   key, overlay not applied), not a gateway defect.
4. **Rendered configuration**:
   `docker compose … exec -T nginx-s3-gateway sh -c 'cat /etc/nginx/conf.d/*.conf'`
   plus any files under `/etc/nginx/conf.d/gateway/`. The templates in
   `common/etc/nginx/templates/` are rendered by the entrypoint; the
   rendered output is what nginx actually runs.
5. **Container environment**: `docker compose … exec -T nginx-s3-gateway env`
   — confirms what the process actually received (and, for secret-file
   probes, what it must not have received).
6. **Origin-side isolation.** Use the origin CLI to `ls`/`stat` the
   object: if the origin does not have the key you expect, the failure
   is seeding or key-mapping, not response handling. Origin container
   logs show whether the gateway's request arrived and with what path.
7. **Hypothesis tests.** For njs-level suspicions, run `make test-unit`
   or invoke the in-image njs CLI directly against a module function
   (see AGENTS.md "Unit testing rules" for the runner invocation and
   its fixed environment). For template-level suspicions, diff the
   rendered config against the template.
8. **Fresh-image check.** If the working tree is newer than the image,
   `make build` and re-run the minimal reproduction. Only a failure
   that reproduces on a freshly built image counts against the code.

## Symptom → component map

| Symptom | Look at |
|---------|---------|
| Container exits at startup / restart loop | Entrypoint validation: `common/docker-entrypoint.d/00-check-for-required-env.sh` (required/deprecated/conflicting vars **and** the `PROXY_CACHE_IGNORE_HEADERS` field allowlist), `01-set-defaults.envsh` (style/upstream derivation). `25-set-proxy-ignore-headers.sh` only renders the directive — it validates nothing. Often an *expected* rejection — check the log message against the docs before calling it a defect. |
| 403 with `SignatureDoesNotMatch` in origin logs | `common/etc/nginx/include/awssig4.js` / `awssig2.js`; URI escaping in `s3gateway.js` (`_escapeURIPath`, `_encodeURIComponent`); `S3_STYLE`/Host-header mismatch (`01-set-defaults.envsh`); container clock skew. |
| Unexpected 404 | First isolate with the origin CLI (does the key exist?); then the strip/prefix rewrite and object-key/URI construction in `s3gateway.js` (`s3uri`, `s3BaseUri`, `_escapeURIPath`); then percent-encoding of raw key bytes. Remember the sanitized-404 design: many origin errors are *deliberately* collapsed to 404 by `error_page … =404` in the templates — a 404 may be masking a 403/500, so check the origin's actual response code in its logs. |
| Wrong body or wrong headers on success | Rendered locations in `common/etc/nginx/templates/default.conf.template` and `gateway/s3_location_common.conf.template`; listing HTML issues → `common/etc/nginx/include/listing.xsl` and the XSLT params (`rootPath`, `prefixPath`). |
| 405 / `Allow` / CORS anomalies | The `$method_not_allowed` map and `@error405` in `default.conf.template`; `gateway/cors.conf.template`; `LIMIT_METHODS_TO*` derivation in `01-set-defaults.envsh`. |
| Redirect anomalies (append-slash, trailing slash) | `@trailslashControl`/`@trailslash` in the templates; `trailslashRedirectUri`/`_encodePathBytes` in `s3gateway.js`; `absolute_redirect off` at server scope. |
| Cache anomalies | Rendered `proxy_cache*` directives in `default.conf.template`: the server-scope cache block and the `@s3_sliced` location each define a `proxy_cache_key` (deliberately not keyed on the viewer `Host`) that must stay in sync apart from `$slice_range`. `cache.conf.template` holds only the two `proxy_cache_path` zone declarations. |
| Credential failures (500s, fetch errors) | `common/etc/nginx/include/awscredentials.js`; `readEnvVarOrFile` in `utils.js`; for overlay phases, whether the static-credential scrub actually removed the variables (evidence ladder step 5). |
| TLS failures to the origin | `23-enable_s3_proxy_ssl.sh` output (`gateway/s3_proxy_ssl.conf`), the trusted-cert path mount, and the exact nginx error line (`verify error` vs `does not match` distinguish trust from hostname). |

## Classification protocol

Every failed probe becomes a FINDING (format in SKILL.md Step 5). It may
be classified `defect` only after ALL of:

1. **Minimal reproduction** — a fresh gateway recreate plus the fewest
   requests that show the failure, reproduced twice.
2. **Not documented behavior** — the settings table and prose in
   `docs/getting_started.md` (and code comments at the suspect site) do
   not describe the observed behavior as intended.
3. **Not already known** — no match in `references/regressions.md`,
   `git log --oneline -S '<relevant symbol>'`, or
   `gh issue list --repo nginx/nginx-s3-gateway --search '<keywords>'`
   (check open AND recently closed issues).
4. **Reproduces on a fresh image** when the working tree is newer than
   the tested image.

Anything that fails a gate is classified accordingly: `environment`
(stack, seeding, ports, stale image, overlay not applied),
`expected-behavior` (documented or deliberately validated), or
`coverage-gap` (behavior is fine but nothing in the fixed suite would
catch its regression — worth reporting so a test can be added).

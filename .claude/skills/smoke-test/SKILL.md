---
name: smoke-test
description: Stand up the gateway's live integration stack and run an
  adaptive, AI-driven smoke test of all major gateway features, root-causing
  any failure to the responsible njs module, config template, or entrypoint
  script. Use when asked to smoke test the gateway, verify a feature against
  a live stack, probe for regressions, or reproduce a reported gateway issue.
---

# Gateway Smoke Test

Bring up the compose stack the integration suite uses (gateway + the
S3-compatible object-store origin), probe the gateway's features with live
HTTP requests, reconfigure the gateway between phases, root-cause every
failure, and emit a structured findings report.

Prime directive: **discover, don't assume.** The compose file, the
GNUmakefile, and `docs/getting_started.md` are the source of truth for
services, ports, credentials, and settings. The reference files in this
skill pin a starting checklist; when discovery disagrees with a pinned
value, discovery wins. Never hardcode or name the origin's implementation
technology — describe it as "the S3-compatible origin" and derive every
detail from the compose file.

## Scope

Determine what to run based on `$ARGUMENTS`:

| Argument | Mode |
|----------|------|
| *(empty)* | Full sweep: phases P0–P7 in order, report at the end |
| `quick` | P0 baseline + P1 content/listing only (~2 minutes) |
| `extended` | Full sweep plus P8 credential overlays and P9 TLS origin |
| `holes` | P0, then only probes tagged HOLE in `references/phases.md` |
| `regressions` | P0, then every pinned set in `references/regressions.md` |
| `issue <N>` or `#<N>` | P0, then the pinned set for issue N; if N is not pinned, read the issue with `gh issue view` and design probes from it |
| `<area>` | P0, then the matching phase(s) — see the area map below |

Area keyword → phase map: `listing`/`index` → P1; `paths` → P2;
`signatures`/`styles` → P3; `methods`/`cors` → P4; `cache` → P5;
`headers` → P6; `buckets`/`ipv6` → P7; `creds` → P8; `tls` → P9.
Unrecognized argument → ask the user, don't guess.

---

## Step 1: Discover the environment

All read-only. Do this in every mode.

1. Read `test/docker-compose.yaml`. Record: the gateway service name and
   host port mapping; the origin service name, image, internal/host ports,
   root credentials, region, and bucket name; which gateway `environment:`
   keys are **bare pass-through** (a bare key whose variable is unset in
   the invoking shell reaches the container as an *empty string that
   overrides the image's `ENV` default* — every one of these must be
   exported explicitly); which keys use `${VAR:-default}` interpolation;
   and which documented gateway settings have **no compose key at all**
   (those need the overlay technique in Step 3).
2. Run `make help` (or read the `GNUmakefile`) to confirm current target
   names. The GNUmakefile is the only supported build/test interface.
3. Read the environment-variable table in `docs/getting_started.md` and
   diff it against the checklist in `references/phases.md`. Any setting in
   the docs that no phase covers gets an improvised probe and, if it
   misbehaves, a `coverage-gap` finding.
4. Find the data-seeding function in `test/run_integration_tests.sh`
   (search for the bucket name). It names the origin's CLI client command,
   the alias/bucket setup, and the data directory (`test/data/<bucket>/`).
   Read it — **never source or execute that script**; it runs the whole
   suite at import time and arms exit traps.
5. Preflight:
   - `docker image inspect nginx-s3-gateway` — if missing, run
     `make build`.
   - Compare the image's `Created` timestamp against the newest commit
     touching `common/`, `oss/`, or `Dockerfile.*`
     (`git log -1 --format=%cI -- common oss Dockerfile.*`). If the image
     is older, warn and run `make build`: tests against a stale image
     probe the baked-in code, not the working tree.
   - Check the discovered host ports. If a port is held by a container
     from another project, **abort with a clear message**. If leftover
     containers from this stack's compose project exist, tear them down
     first (Step 6 teardown command).

---

## Step 2: Stand up and seed

Substitute discovered values throughout; the commands below reflect the
compose file at the time this skill was written.

```bash
cd "$(git rev-parse --show-toplevel)"
export COMPOSE_COMPATIBILITY=true NGINX_INTERNAL_PORT=80
# Every bare pass-through key gets an explicit value — never rely on shell
# inheritance (bare key + unset var = empty string inside the container):
export AWS_SIGS_VERSION=4 ALLOW_DIRECTORY_LIST=false \
  PROVIDE_INDEX_PAGE=false APPEND_SLASH_FOR_POSSIBLE_DIRECTORY=false \
  STRIP_LEADING_DIRECTORY_PATH="" PREFIX_LEADING_DIRECTORY_PATH="" \
  STATIC_SITE_HOSTING="" PROXY_CACHE_BYPASS_NO_CACHE=false \
  PROXY_CACHE_IGNORE_HEADERS="" IPV6_ENABLED=""
docker compose -f test/docker-compose.yaml -p ngt up -d
```

Seed by replicating the discovered recipe: register a CLI alias for the
origin using the credentials from the compose file, create the bucket
(ignore-existing), copy every entry under `test/data/<bucket>/` into it,
and write the runtime-generated special-character object the suite's data
function creates. If the CLI client is not installed on the host, run its
container image attached to the stack's network (`--network ngt_default`).

Readiness gate: poll `http://localhost:8989/health` until it returns 200
(timeout ~30 s). This also exercises the gateway's health endpoint, which
the fixed suite never requests.

Assert idioms (inline; do not source suite helpers):

```bash
# Status assert:
curl -s -o /dev/null -w '%{http_code}' <url>
# Log assert — capture first; piping `compose logs` into `grep -q` dies
# with SIGPIPE under pipefail exactly when the match is found:
logs="$(docker compose -f test/docker-compose.yaml -p ngt logs nginx-s3-gateway 2>&1)"
grep -qF '<expected text>' <<< "$logs"
```

---

## Step 3: Reconfigure between phases

Recreate only the gateway; the origin and its seeded data stay up, and the
gateway's proxy cache (container-local) resets, keeping cache phases
deterministic:

```bash
<changed exports> docker compose -f test/docker-compose.yaml -p ngt \
  up -d --force-recreate nginx-s3-gateway
```

For settings with **no compose pass-through key** (for example
`DIRECTORY_LISTING_PATH_PREFIX`, `FOUR_O_FOUR_ON_EMPTY_BUCKET`,
`HEADER_PREFIXES_TO_STRIP`, `HEADER_PREFIXES_ALLOWED`,
`PROXY_CACHE_USE_STALE`, `CORS_ALLOW_PRIVATE_NETWORK_ACCESS`, or an
`S3_BUCKET_NAME` override), write a minimal overlay to a scratch directory
(session scratchpad or `mktemp -d` — never the repo) and stack it with a
second `-f`; compose merges `environment:` maps by key:

```yaml
# <scratch>/overlay.yaml
services:
  nginx-s3-gateway:
    environment:
      FOUR_O_FOUR_ON_EMPTY_BUCKET: "true"
```

```bash
docker compose -f test/docker-compose.yaml -f <scratch>/overlay.yaml \
  -p ngt up -d --force-recreate nginx-s3-gateway
```

After every recreate: wait on `/health`, then check the startup banner in
the gateway logs (`S3 Backend Environment:` block — addressing style,
signature version, IPv6 listen state) to confirm the settings you intended
actually took effect before probing. A probe against a misconfigured
gateway produces phantom findings.

---

## Step 4: Run the phases in scope

Read only the `## P<N>` sections of `references/phases.md` selected by the
dispatch table. Phase index:

| Phase | Focus |
|-------|-------|
| P0 | Baseline: health, startup banner, GET/HEAD, Range, 404 sanitization |
| P1 | Directory listing, index pages, append-slash, special-char keys |
| P2 | Path rewriting: strip/prefix leading directory path |
| P3 | Addressing styles × signature versions |
| P4 | Method policy (405 contract) and CORS |
| P5 | Proxy cache: hits, bypass, ignored headers, stale serving, slices |
| P6 | Header prefix stripping/allowlisting |
| P7 | Empty-bucket behavior and IPv6 listen directives |
| P8 | (extended) Credential sources: metadata-mock and secret-file overlays |
| P9 | (extended) TLS verification of the origin |

The listed probes are the floor, not the ceiling. If a response looks
anomalous — an unexpected header, a suspicious log line, a body that is
almost right — chase it with follow-up probes before moving on.

---

## Step 5: Root-cause failures

On any failed probe, read `references/root-cause.md` and follow it:
collect evidence up the ladder, localize to a component with the symptom
table, then run the classification protocol. Record a finding for every
failure, but do not classify a finding as `defect` until it has a minimal
reproduction on a fresh recreate **and** has been checked against
documented behavior, `git log`, open issues, and
`references/regressions.md`.

```text
FINDING: <short title>
PHASE: <P0..P9 or regression id>
FILE: <suspected component path, or n/a>
EVIDENCE: <probe command; expected vs actual; log/config excerpt>
CLASSIFICATION: defect | environment | expected-behavior | coverage-gap
SEVERITY: critical | major | minor | info
```

---

## Step 6: Tear down, report, draft issues

Teardown runs unconditionally — after success, failure, or abort. The
`--profile` flag is required: the dynamic-credentials overlay adds a
`depends_on` for a profile-gated service, and compose rejects the merged
project as invalid without it:

```bash
docker compose --profile dynamic-credentials \
  -f test/docker-compose.yaml \
  -f test/docker-compose.dynamic-credentials.yaml \
  -p ngt down --volumes --remove-orphans
```

Also remove any CLI alias you registered and delete scratch overlays,
certificates, and secret files.

Print the report in the conversation (offer to save a copy to the scratch
directory only if asked; never write it into the repo):

```text
## Smoke Test Report: <scope> — <date>

### Environment
- Gateway image: <tag/id, created <date>>; stack: compose project ngt
- Origin: <service name and image as discovered from the compose file>

### Phase results
| Phase | Env variant | Probes | Pass | Fail | Notes |
|-------|-------------|--------|------|------|-------|

### Findings
<FINDING blocks, severity-ordered>

### Summary
- Phases run: N/N; probes: N (N pass, N fail)
- Findings: N (N defect, N environment, N expected-behavior, N coverage-gap)
- Verdict: PASS | PASS WITH FINDINGS | FAIL
```

Then, for each finding classified `defect`, draft a ready-to-file GitHub
issue (title; body with reproduction commands, expected vs actual
behavior, root cause, suspected component file, gateway image/commit) for
`gh issue create --repo nginx/nginx-s3-gateway`. Present the drafts and
file nothing without explicit per-issue user approval.

---

## Guardrails

- Do NOT use or mention `test.sh`; the GNUmakefile is the only supported
  build/test interface.
- Do NOT source or execute `test/run_integration_tests.sh` — it runs the
  entire suite at import time. Read it only.
- Do NOT skip teardown. The Step 6 `down --volumes --remove-orphans`
  command runs even when a phase aborts or the user interrupts.
- Do NOT pass bare compose environment keys — export an explicit value for
  every pass-through key, empty string only when emptiness is intended.
- Do NOT probe a stale image. After any source edit, `make build` before
  the next probe; retesting without a rebuild exercises the baked-in copy.
- Do NOT run `make test-matrix` or `make test-matrix-plus` unless the user
  explicitly asks; the smoke test is not the CI matrix.
- Do NOT modify repository files. Overlays, certificates, and generated
  secrets live in the scratch directory.
- Do NOT name the origin's implementation technology in probes, findings,
  or reports — use details discovered from the compose file.
- Do NOT classify a finding as `defect` or draft an issue without a
  minimal reproduction plus checks against `docs/getting_started.md`,
  `git log`, `gh issue list --search`, and `references/regressions.md`;
  never file an issue without the user's approval.
- Do NOT continue when the discovered host ports are held by containers
  from another project — abort and tell the user which ports are busy.

# AGENTS.md

Guidance for AI coding agents working in this repository.

## Project overview

NGINX S3 Gateway configures NGINX (OSS or Plus) as an authenticating, caching
proxy in front of S3-compatible object stores. There is no application server:
the "code" is NGINX configuration plus [njs (NGINX JavaScript)](https://github.com/nginx/njs) modules, packaged
as Docker images.

## Layout

- `common/etc/nginx/include/` — the njs modules (`s3gateway.js`, `awssig2.js`,
  `awssig4.js`, `awscredentials.js`, `utils.js`). Most logic changes happen here.
- `common/etc/nginx/templates/` — NGINX config templates that bind to the njs
  exports (`js_set`, `js_content`, `js_body_filter`).
- `common/docker-entrypoint.d/` — container entrypoint shell scripts.
- `common/etc/nginx/gateway_env_lib.sh` — shared POSIX `sh` helpers (boolean
  parsing/validation) sourced, never executed, by the entrypoint scripts; the
  standalone installer carries a synced copy that `make lint` verifies
  (`envlib-sync-check`).
- `oss/`, `plus/` — NGINX config specific to OSS and Plus flavors; keep the two
  functionally equivalent when changing one.
- `test/unit/` — njs unit tests; `test/integration/` — bash integration tests
  (eight of the ten `test_entrypoint_*.sh` scripts share
  `test/integration/entrypoint_test_lib.sh`; `test_entrypoint_ipv6.sh` and
  `test_entrypoint_output_settings.sh` invoke `docker run` directly).
- `Dockerfile.oss`, `Dockerfile.plus`, `Dockerfile.latest-njs`,
  `Dockerfile.unprivileged` — base images and variants.
- `examples/`, `deployments/`, `docs/` — usage examples, deploy templates, docs.

## Build, test, lint

The `GNUmakefile` (GNU Make 4.x) is the **only supported interface** for build
and test workflows. The test logic lives in `test/run_unit_tests.sh` and
`test/run_integration_tests.sh`, which make drives; the legacy `test.sh` is a
deprecated wrapper that only forwards to the equivalent make targets — never
invoke or recommend it. Run `make help` for the full target list,
`make check-tools` to verify prerequisites (docker, docker compose, curl,
and the AWS CLI).

- `make build` — build the gateway image (`NGINX_TYPE=oss` default, or `plus`).
- `make test` — build, then run the full unit + integration suite.
- `make retest` — rerun tests against the already-built image (fast iteration,
  but see the staleness warning below).
- `make test-unit` / `make test-integration` — run just one half of the suite
  against the already-built image.
- `make test-matrix` — reproduce the CI matrix locally.
- `make lint` — checkmake + shellcheck + rumdl (Markdown).
- `make lint-md` / `make fmt-md` — report or auto-fix Markdown issues with
  `rumdl` (config in `.rumdl.toml`) without running the other linters.
- `make docs` — generate JSDoc reference documentation.

Notes:

- **Staleness warning**: unit tests import the njs modules baked into the image
  (`/etc/nginx/include/`), not the working tree — only `test/unit/` is
  bind-mounted. After editing `common/etc/nginx/include/*.js`, run `make test`
  (rebuilds first); `make retest` would test the stale copy.
- Integration tests spin up a RustFS S3 origin via `test/docker-compose.yaml` (compose
  project `ngt`) and hit the gateway on `localhost:8989`.
- `S3_STYLE` (`virtual`, `virtual-v2`, or `path`) selects the S3 addressing
  style under test; CI runs all three.
- The `latest-njs` variant runs the njs CLI with `-m` instead of `-t module`
  (transitional flag fork while njs migrates its CLI).
- NGINX Plus builds/tests require repo certs in `plus/etc/ssl/nginx/` and a
  `license.jwt` — skip Plus targets if you don't have them.
- An agent-driven smoke-test skill lives at `.claude/skills/smoke-test/` — it
  stands up the integration stack from `test/docker-compose.yaml`, probes every
  major gateway feature live, and root-causes failures. See its `SKILL.md` for
  invocation modes (full sweep, `quick`, `holes`, `regressions`, `issue <N>`,
  or a feature area).

## JavaScript rules (njs, not Node.js)

The modules run on the **njs engine**: ECMAScript 5.1 strict mode plus a
limited set of ES6+ extensions (see
<https://nginx.org/en/docs/njs/compatibility.html>). It is NOT Node.js: there
are no npm packages at runtime, no Node stdlib, and no JS-owned event loop.
Everything in `package.json` is dev-only tooling (jsdoc, njs-types).

Language subset — allowed (all in use today):

- `const`/`let` (never `var` in modules; `const` preferred, `let` only when
  reassigned), function declarations, `async`/`await` (never top-level),
  Promises, template literals, `for (let i = 0; ...)` and `for ... in` loops.

Forbidden (unsupported by the njs engine, or unused by project convention):

- `class`, destructuring, spread, default parameters, generators, `for...of`,
  `Map`/`Set`, optional chaining `?.`, nullish coalescing `??`, `.then()`
  chains, arrow functions (one legacy arrow exists in `s3gateway.js` — do not
  add more).

Module structure, top to bottom:

1. Apache-2.0 license header (`Copyright 2023 F5, Inc.` form).
2. `@module` / `@alias` JSDoc block.
3. `@typedef` blocks for shared structures.
4. ES `import`s of first-party modules — relative path with `.js` extension,
   **default imports only** (njs rejects named and namespace imports).
5. `const mod_x = require('...')` for njs built-ins (`crypto`, `fs`, `xml`).
6. Documented module-level constants.
7. Functions.
8. A single `export default { ... }` map at the bottom of the file.

Other rules:

- Configuration is read from `process.env['UPPER_SNAKE']` (bracket notation)
  into module-level `const`s **at import time**. This has a direct testing
  consequence — see "Unit testing rules". `ngx` is used only for `ngx.fetch`.
- **`console.log` is not allowed in gateway modules.** All logging goes through
  `utils.debug_log(r, msg)`, which guards on the `DEBUG` env var and on
  `"log" in r` so stub requests without a log method stay safe. `console.log`
  is permitted only in `test/unit/` files, where it is the test-output
  mechanism.
- **No magic string literals**: extract repeated or meaningful literals (e.g.
  `index.html`) into documented module-level constants. Variable names carry
  units where relevant (e.g. `maxValidityOffsetMs`).
- Comments explain **why**, not what, and link to the relevant AWS
  documentation for protocol/signing behavior. No lingering TODOs: replace a
  TODO with an explanation plus a tracking issue, and delete TODOs your change
  resolves.
- Naming: camelCase functions and locals; `_`-prefixed + `@private` for
  internal functions; UPPER_SNAKE module constants; AWS spec names (`kSecret`,
  `kDate`, `kSigning`...) are correct in signing code. `debug_log` is a
  grandfathered snake_case exception.
- Errors are **thrown as strings** (`throw 'message'` or a template literal),
  never `new Error()` — consistent project-wide.
- Formatting: 4-space indent, single-quoted strings, double-quoted import
  specifiers, semicolons. No linter enforces JS style — review does.
- NGINX config binds to exported names (e.g. `js_set $s3auth s3gateway.s3auth`
  in `common/etc/nginx/templates/default.conf.template`), so renaming or
  removing an exported key is a breaking config change — update the templates
  in lockstep.
- **Duck-typed environment guards**: production code must tolerate stub request
  objects by feature-testing (`"variables" in r`, `"log" in r`,
  `"headersOut" in r`) instead of assuming a full nginx request. The same
  guards distinguish NGINX Plus (keyval store) from OSS, and production from
  unit tests — do not break them.

## JSDoc conventions

Structures and njs types are defined and referenced through JSDoc; docs are
generated with `make docs` (config in `jsdoc/conf.json`).

- Every exported function gets a JSDoc block. House `@param` style is
  **name-first**: `@param r {NginxHTTPRequest} HTTP request object` — not the
  mainstream `{type} name` order. Use `@returns` (plural), and `@private` on
  internal functions.
- Shared structures are defined once as `@typedef {Object} Name` with
  `@property {type} field - description` lines, placed right after the
  `@module` block (existing examples: `Credentials` in `awscredentials.js`,
  `S3ReqParams` in `s3gateway.js`). Reference them by bare name (e.g.
  `{Credentials}`) from any module — JSDoc processes all files in one pass.
- njs runtime types are referenced by bare name (`NginxHTTPRequest`,
  `NjsStringOrBuffer`, `Response`...). They resolve because `jsdoc/conf.json`
  includes `./node_modules/njs-types` via the `better-docs/typescript` plugin.
  Do not add `/// <reference>` directives or a tsconfig.
- Module headers pair `@module <lowercase>` with `@alias <PascalCase>`
  (`utils`/`Utils`, `awssig4`/`AwsSig4`, ...).
- Params that nginx requires but the function ignores: underscore-prefix them
  and document as `(not used, but required for NGINX configuration)`.
- Use `@see {@link <url> | Title}` for AWS specification references.

## Unit testing rules

Unit tests run under the **njs CLI** (`/usr/bin/njs`) inside the built image.
Per the nginx docs, nginx objects are not available in the CLI: there is no
`ngx`, no request object `r`, and no nginx variables. Everything
nginx-provided must be hand-mocked.

- **Run tests only through make** (`make test` / `make retest` /
  `make test-unit`). Under the hood `test/run_unit_tests.sh` runs each test
  file via
  `docker run --entrypoint /usr/bin/njs nginx-s3-gateway -t module -p '/etc/nginx' /var/tmp/<file>`
  with a fixed env list (`AWS_ACCESS_KEY_ID=unit_test`,
  `S3_BUCKET_NAME=unit_test`, `DEBUG=true`, `S3_REGION=test-1`,
  `AWS_SIGS_VERSION=4`, ...). Every suite runs twice — with and without
  `AWS_SESSION_TOKEN` — so tests must pass in both modes, branching with
  `if ('AWS_SESSION_TOKEN' in process.env)` where behavior differs.
- **Mock `ngx` via `globalThis`**: declare `globalThis.ngx = {};` at the top of
  the file, then assign `globalThis.ngx.fetch = function (url, options) {...}`
  per test, returning Response-alikes
  (`{ok: true, status: 200, json/text: function() { return Promise.resolve(...); }}`).
  Unexpected URLs or arguments should `throw` a string — the throw is the
  assertion. Record observations in closure variables; do not write them onto
  `globalThis` (an older `s3gateway_test.js` style — don't copy it).
- **Mock `r` as a plain object literal** containing only the fields the code
  under test touches (`variables`, `headersIn`, `headersOut`, `uri`, `method`,
  ...). Attach behavior after construction:
  `r.log = function(msg) { console.log(msg); }` — required whenever the code
  path logs, because the suite runs with `DEBUG=true` and `utils.debug_log`
  calls `r.log` when present. For `r.return`, use the factory-helper pattern
  from `awscredentials_test.js` (`makeExpect200Request()`,
  `makeRecordingRequest(state)`). Fake the Plus keyval store by pre-seeding
  `r.variables = { cache_instance_credentials_enabled: 1, instance_credential_json: null }`.
  Fake the OSS shared-dict credential cache with
  `test/unit/credential_cache_mock.js` (`resetSharedCredentialCache()`) rather
  than hand-rolling an `ngx.shared` stub.
- **`process.env` is real and mutable** in the njs CLI: mutate it directly and
  restore in `finally`, using a `restoreEnv(name, saved)` helper that `delete`s
  the key when the saved value was `undefined` (assigning `undefined` re-creates
  the key and breaks `'in'` presence checks). Caveat: env vars captured into
  module constants at **import time** cannot be changed from inside a test —
  they must be present in the runner's env list before the module loads.
- **Test skeleton** (no framework): `#!env njs` shebang → license header →
  `import mod from "include/<mod>.js"` (resolved by the `-p /etc/nginx` module
  path) → test functions named `test<Thing>` that start with
  `printHeader('<name>')` → one `async function test()` calling each case in
  sequence → `test();` → closing
  `console.log('Finished unit tests for <mod>.js');`. Assertions are
  `if (mismatch) throw 'msg\nActual:   [..]\nExpected: [..]';`.
- **Testing private functions**: add them to the module's `export default`
  under the standing comment "These functions do not need to be exposed, but
  they are exposed so that unit tests can run against them."
- **Wiring a new test file**: automatic — `test/run_unit_tests.sh` globs
  `test/unit/*_test.js`, so a new `<name>_test.js` file is discovered and run
  in both session-token modes without any wiring. Env vars that the module
  under test reads at import time go in the single `unit_test_env` list in
  that runner.

## Adding a configuration option (env var)

A new environment variable is never just a code change. The full checklist:

1. Read it in the njs module (import-time `const` unless it must be
   re-evaluated per request).
2. Document it in `docs/getting_started.md` (the environment-variable table).
3. Add presence/validity checks to
   `common/docker-entrypoint.d/00-check-for-required-env.sh`. If the setting
   is a boolean, add its name to the `validateBooleanVar` loop there (and to
   the matching loop in `standalone_ubuntu_oss_install.sh`) instead of
   writing a new case block — the spelling grammar lives in
   `common/etc/nginx/gateway_env_lib.sh` and `utils.js#parseBoolean`, pinned
   against each other by `test_entrypoint_boolean_validation.sh`.
4. Add it to the env list in `standalone_ubuntu_oss_install.sh`.
5. Add a pass-through entry in `test/docker-compose.yaml`; if unit tests need
   it, add it to the `unit_test_env` list in `test/run_unit_tests.sh` too.
6. Add integration coverage — new settings without tests are historically
   blocked in review.

## Architecture rules

- Shared helpers belong in `utils.js`; AWS signature-version logic lives in its
  own `awssigN.js` file (one per version); credential handling in
  `awscredentials.js`; S3 proxy/listing logic in `s3gateway.js`. See
  `docs/development.md` for the signature flow.
- The gateway deliberately exposes only GET and HEAD (plus OPTIONS for CORS) —
  a security posture, not an oversight. Do not widen verb support casually.
- Entry-point scripts run under `sh`, not bash: use `.`, never `source`, and
  keep the syntax POSIX. Use spaces, not commas, to separate values in
  env-var lists.
- No whitespace or reformatting churn in PRs: revert changes outside the lines
  you mean to touch. The one sanctioned exception is Markdown: `rumdl` (config
  in `.rumdl.toml`, run via `make lint-md` / `make fmt-md`) is the project's
  formatter for `.md` files, so its changes are expected, not churn.

## Git and PR conventions

- Conventional Commits format (`fix:`, `feat:`, `ci:`, `build:` ...), imperative
  mood, subject ≤72 chars — changelogs are generated from these.
- Shell scripts must pass `shellcheck --severity=warning`; new scripts under
  `test/` (the runners), `test/integration/`, and `common/docker-entrypoint.d/`
  are linted automatically.
- checkmake lints the GNUmakefile and does not follow backslash continuations —
  keep `.PHONY` declarations on a single line.
- Config/behavior changes usually need matching updates in both `oss/` and
  `plus/`, plus documentation in `docs/getting_started.md` if user-facing.

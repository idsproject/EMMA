---
name: ids-emma-rails-to-go
description: Translate the EMMA Ruby on Rails 8 application into behavior-equivalent Go services under go/, one slice of the section 7 order per run (slice chosen through additionalPlanContext), following idsproject/iris code style and the IDS gateway (Tyk) deployment conventions.
---

# EMMA Rails-to-Go (IDS Network relaunch)

Translate the EMMA server application (source: uvalib/emma; Ruby 3.4.1, Rails 8.0.2, PostgreSQL) to
idiomatic Go that is behavior-equivalent to the Rails app at the HTTP boundary.
Companion source: uvalib/emma-ia (Python, Internet Archive submission processor).
Target Go version: the same as idsproject/iris (go.mod `go 1.26.6`, currently 1.26).

Context: EMMA was shut down by UVA about a year ago. IDS Network is relaunching
it. There is no production database, no user accounts and no stored files to
migrate. The Go system starts empty.

Every run translates exactly ONE slice from section 7. The slice is named in
`additionalPlanContext`. The authoritative requirements are in
`references/transformation-definition.md` (Draft v0.6); where any other file
disagrees, that file wins, and sections marked CRITICAL are mandatory. This
SKILL.md carries all of its sections; reread the reference file whenever a
detail here seems incomplete.

## Reference files (read with read_skill_resource)

- `references/00-README.md`: index of the reference material.
- `references/transformation-definition.md`: authoritative requirements, all sections.
- `references/iris-reference.go.txt`: idsproject/iris source, the Go code style to follow.
  Copy its layout, naming, error handling, logging, migrate subcommand, response
  envelope (`util/response.go`), Makefile and `.golangci.yaml` lint settings.
- `references/gateway-reference.txt`: idsproject/ids-gateway compose file, Tyk API
  definitions (`apps-src/*.json`) and policies. Shows how services sit behind Tyk,
  the `X-Gateway-Auth` secret, health checks, the `migrate` one-shot services
  (`x-migrations-table`, `search_path` in `DB_URL`) and env var names.
- `references/iris-emma-integration-spec.md`: CONTEXT ONLY. Do NOT generate
  anything from it (no deposit API, no `deposits` table, no IRIS org, no
  `internal/integrations/iris` code). It exists only so the translation leaves
  `internal/integrations/` empty and adds the hooks the spec needs
  (`orgs.ids_*` columns, keyed API routing).

## Entry Criteria

1. The repository root is the EMMA Rails app: `Gemfile` with `gem 'rails', '~> 8'`,
   `.ruby-version` `ruby-3.4.1`, and `app/`, `config/routes.rb`, `db/schema.rb`,
   `config/locales/`, `sig/`, `test/system/` present.
2. Git is clean enough to review the slice as one change set.
3. `additionalPlanContext` names exactly one slice from section 7 (see Step 1),
   either as a new slice or as `rework slice <id>` with a list of problems.
4. Every slice that comes before the requested slice in the section 7 order has
   status `done` in `go/TRANSLATION_PROGRESS.md`, set by a maintainer after
   running its pending checks (Step 5), and the build command passes on the
   current tree (not required for slice 1).
5. In scope (read): `app/**` except `app/assets/**` source, `lib/**`, `config/**`,
   `db/schema.rb`, `sig/**`, `test/**`, `app/assets/builds/**` (copied),
   `app/assets/javascripts/**` and `test/system/**` (read for selectors only).
   In scope (write): `go/**` only.

## Implementation Steps

### Step 1. Select the slice for this run

1. Read `additionalPlanContext`. Accept a slice id or its name, case-insensitive:
   `1` Foundation, `1a` EMMA Unified Index, `2` Auth, `3` Orgs and enrollment,
   `4` Search, `5` Uploads, `6` Manifests and bulk, `7` Downloads and partners,
   `8` Remaining tools.
2. If it names no slice, more than one slice, or an unknown slice: make no code
   changes, report the list above, and stop.
3. The order is fixed: 1, 1a, 2, 3, 4, 5, 6, 7, 8. Read `go/TRANSLATION_PROGRESS.md`
   (absent before slice 1). If an earlier slice does not have status `done`
   (the status a maintainer sets, see Step 5), or the requested slice already
   has status `done` or `built, validation pending`, make no code changes,
   report which slice is next and which pending checks block it, and stop.
   Exception: a rework run (item 5).
4. Translate only the requested slice. Code belonging to later slices must not be
   written. Code from earlier slices may be edited only to wire in the new slice
   (route registration, `data.Models` fields, `deps` fields, config fields,
   migrations) or to fix a defect the new slice exposes; list every such edit in
   the report.
5. Rework run: `additionalPlanContext` contains the word `rework`, names one
   slice (`rework slice <id>`), and lists the problems found. Allow the run only
   if that slice's status in `go/TRANSLATION_PROGRESS.md` is
   `built, validation pending`. Then:
   - Fix only the listed problems, and only in that slice's code. Do not
     re-translate the slice, add features, or touch other slices' code except
     where a listed problem requires it (report each such edit).
   - Skip Step 2 except what the listed problems need; run Steps 4 and 5 for
     the changed code.
   - Keep the status `built, validation pending`.
   - Record the rework in `go/TRANSLATION_PROGRESS.md` under that slice: date,
     each listed problem, what changed for it (files and a one-line summary),
     problems not fixed and why, and checks rerun with their results.
   If the slice's status is anything else (not started, or `done`), or no
   problems are listed, make no code changes, report why, and stop. Without the
   word `rework`, items 2 and 3 apply unchanged.

### Step 2. Inventory the slice

1. List every Rails source file the slice covers (controllers, concerns, models,
   records, services, decorators, helpers, views, jobs, channels, mailers, locale
   keys, routes in `config/routes.rb`, `sig/**` signatures, tests in
   `test/controllers`, `test/models`, `test/system`, fixtures in `test/fixtures`).
2. For every view or partial in the slice, first list the element ids, classes,
   `data-*` attributes, form field names and nesting relationships that
   `app/assets/javascripts/**` or `test/system/**` select on. Write the list to
   `go/docs/selectors/<slice-id>.md`. Treat these as fixed (section 4a item 1).
3. List the ENV vars the slice reads via `config/env_vars.rb` and
   `config/locales/env_var.en.yml`, with defaults.
4. Map each Rails construct to its Go replacement using section 3. Do not
   substitute other libraries.

### Step 3. Translate, applying sections 1 to 6 and 9 below to every file

Use `sig/**` RBS files as authoritative type information when inferring Go types,
and `db/schema.rb` as authoritative table and column types for the sqlc schema.
Carry each Ruby YARD comment over as the Go doc comment. Commit generated code
(`templ generate` output `*_templ.go`, sqlc output) so the build command works
without generators.

### Step 4. Tests

1. Translate assertions from `test/controllers` and `test/models` for the slice
   into Go table-driven tests in the matching package (section 8).
2. For each JSON/XML endpoint in the slice, record Rails responses for the
   fixtures in `test/fixtures` into golden files under `go/testdata/golden/<slice-id>/`
   and assert the Go responses match byte for byte after normalizing timestamps and ids.
3. Tests that need PostgreSQL read `DB_URL` and call `t.Skip` when it is unset, so
   `go test ./...` passes in environments without a database.

### Step 5. Validate and record

1. Run `cd go && go build ./... && go vet ./... && go test ./...` until it passes.
2. Run the section 8 parity, index-contract and accessibility checks for the slice.
   If Ruby, PostgreSQL, a browser or axe is not available, do not mark those
   checks as passed: list each one as pending in the report.
3. Append the slice to `go/TRANSLATION_PROGRESS.md` with: slice id and name, date,
   Rails files translated, Go packages added, edits to earlier slices, checks
   passed, checks pending, and `TODO(Qn)` markers added for section 9 questions.
4. Never mark a slice `done` while any section 8 check is pending. The
   keyboard-only pass is a manual checkpoint, so it is always pending when the
   transformation finishes. Set the status to `built, validation pending` and
   list every pending check with the command or procedure to run it.
5. Only a maintainer changes the status to `done`, after running the pending
   checks outside the transformation. The transformation never edits a status
   from `built, validation pending` to `done`.

### Slice contents (section 7, with the Go targets each slice must produce)

Run the transformation slice by slice. Each slice must build and pass its
validation before the next one starts.

1. **Foundation**: config, i18n loader, DB pool, migrations, sessions, CSRF,
   flash, layout, static assets, gateway checks (4b), health_controller,
   metrics_controller.
   Go targets: `go/go.mod` (module `github.com/idsproject/emma`), `cmd/emma/main.go`
   with `migrate` subcommand, `app/` (Application, routes, server),
   `internal/config` (every ENV var and default from config/env_vars.rb),
   `internal/i18n` with `config/locales/**` copied verbatim to `go/locales/`,
   `internal/data` pool and migrations for the full schema of section 2
   (including River's migrations, the scs postgresstore `sessions` table and the
   `orgs.ids_school_id`/`ids_library_id` columns), sessions, CSRF, flash, method
   override, Turbolinks and format negotiation middleware (section 4), the
   layout templ component with skip-nav, static files from `app/assets/builds`
   (and `public/`) at the URL paths the Rails layout uses, gateway middleware
   and `/healthz` (4b), HealthController routes (4g), MetricsController with
   `prometheus/client_golang`, the `paths` package skeleton, `util/response.go`,
   `.golangci.yaml`, `Makefile`, and `internal/integrations/` holding only a
   `.gitkeep`.
1a. **EMMA Unified Index** (section 4d): built and tested against the
   unmodified Rails app before slice 4 starts.
   Go targets: `cmd/emma-index/main.go` with `migrate`, its own `index` schema
   migrations, the search interface with the PostgreSQL backend, Search and
   Ingest API handlers.
2. **Auth**: users, roles, OIDC sign-in and local sign-in, account_controller,
   user session controllers, authz (ability.rb).
   Go targets: `internal/auth/oidc`, local Devise-equivalent handlers, the
   create-first-administrator CLI command, `internal/authz`, test sign-in (section 8).
3. **Orgs and enrollment**: org, enrollment models and controllers, mailers.
   Includes the administrator-only `ids_school_id`/`ids_library_id` org form fields.
4. **Search**: records/search, search_service, search_controller,
   search_call_controller, search decorators and views.
5. **Uploads**: upload model, Shrine-compatible S3 storage, upload_workflow
   state machine, upload_controller, ingest_service, submission_service.
   Includes `services/awss3` and `GET /upload/records`.
6. **Manifests and bulk**: manifest, manifest_item, submit/lookup jobs,
   ActionCable channels.
   Includes `internal/cable` and the River workers for these jobs.
7. **Downloads and partners**: download model, partner packages (section 4c),
   download_controller, emma-ia worker (section 4e).
   The emma-ia source is not in this repository: look for an `emma-ia/` checkout
   next to or inside the repository, or a path given in `additionalPlanContext`.
   If none is found, translate the rest of the slice and report `jobs/iasubmit`
   as blocked on the missing source.
8. **Remaining tools**: tool_controller, data_controller, sys_controller (reduced per section 4g),
   about/help/home.
   Includes local content under `go/internal/views/content/` (4f) and Math
   Detective behind `MD_ENABLED`.

## Requirements (carried from references/transformation-definition.md)

### 1. Objective

Translate the EMMA server application from Ruby on Rails to idiomatic Go. The Go
service must behave like the Rails code in this repository: same URL routes,
same HTTP methods, same response status codes and same JSON/XML payload shapes.
Because nothing is being migrated, the Go service owns a fresh PostgreSQL
schema derived from db/schema.rb (minus the tables listed in section 2).
HTML output does NOT need to match Rails byte for byte. It must be functionally
equivalent and conform to WCAG 2.2 Level AA (see section 4a). The existing browser
JavaScript bundle (app/assets/javascripts, roughly 50k lines using jQuery, Select2,
rails-ujs, Turbolinks and @rails/actioncable) is NOT being rewritten in this phase
and must keep working unmodified against the Go server.

Do not redesign features. Do not "improve" behavior. Where Rails behavior is
implicit (callbacks, default scopes, CSRF, flash, param coercion), make it
explicit in Go and preserve it.

Deliberate differences from the Rails app: the Go service runs behind the IDS
gateway (section 4b); campus sign-in moves from Shibboleth headers to OpenID
Connect and is off at launch (section 3, auth rows); and the search/ingest
index that UVA ran as a separate service is rebuilt as part of this project
(section 4d).

### 2. Out of scope for this transformation

- app/assets/** (JavaScript and SCSS). Copy the compiled output from
  app/assets/builds and serve it as static files.
- Data migration. There is no legacy data. Create the schema with Go
  migrations (golang-migrate, matching the gateway stack) derived from
  db/schema.rb. Table and column names stay the same; tables owned by
  replaced libraries change to the replacement's own schema (good_job tables
  become River's tables; the `sessions` table uses the scs postgresstore schema).
- Bookshare and HathiTrust. Both are already `active: false` in
  config/locales/repository.en.yml. Keep their entries in the locale files but
  generate no Go code for them.
- pipeline/ and package/ (CodeBuild/Docker). These are rewritten by hand later.
- sig/ (RBS type signatures). Use as reference input only (see section 6).
- Unused tables. Do not generate Go models, queries or repositories for these
  tables. They have no ActiveRecord model and no code references in the Rails
  app (see "Schema cleanup" in section 9):
  - 2019 Bookshare-era tables: artifacts, titles, editions, periodicals,
    reading_lists, members and their join tables (artifacts_editions,
    artifacts_titles, editions_periodicals, editions_reading_lists,
    members_reading_lists, reading_lists_titles)
  - rolify tables: roles, users_roles (replaced by the users.role column in 2023)
  - entries, phases, actions (no migration or model in the repo)
  - Rails framework tables: active_storage_*, action_text_rich_texts,
    action_mailbox_inbound_emails (file storage is Shrine)

### 3. Target Go stack (do not substitute)

| Rails / gem | Go replacement | Notes |
|---|---|---|
| Rails routing (config/routes.rb, 826 lines) | github.com/go-chi/chi/v5 | One chi route per Rails route; preserve path params and named route helpers as Go funcs in package `paths` |
| ActionController, before_action, rescue_from | net/http handlers + chi middleware | before_action chains become explicit middleware or a per-handler `prepare()` call; rescue_from becomes an error-mapping middleware |
| Strong params | Explicit request structs per action with a `bind(r *http.Request)` method | Reject unpermitted keys exactly as Rails does (drop silently) |
| ActiveRecord models (app/models) | github.com/jackc/pgx/v5 + sqlc-generated queries | Hand-written repository layer per table; callbacks and validations become explicit methods invoked by the repository |
| ActiveRecord validations | Go `Validate() error` methods returning field-keyed errors | Error messages must come from the same i18n keys |
| Devise + OmniAuth Shibboleth (lib/ext/omniauth/lib/omniauth/strategies/shibboleth.rb) | Package `auth/oidc`: OpenID Connect relying party using github.com/coreos/go-oidc/v3 and golang.org/x/oauth2 | Do NOT port the Shibboleth header strategy. Authorization code flow with PKCE and `state`/`nonce` checks against the issuer in `OIDC_ISSUER_URL` (CILogon by default), client id/secret from `OIDC_CLIENT_ID`/`OIDC_CLIENT_SECRET`, scopes `openid email profile org.cilogon.userinfo`. Build this package, but ship it disabled (`OIDC_ENABLED=false`); EMMA launches with local accounts only. Account matching must reproduce `User.from_omniauth` (app/models/user.rb): lowercase the `eppn` claim and find the user whose `users.email` equals it; never auto-create users (org managers create accounts); fill first_name/last_name from `given_name`/`family_name` only when blank; set `users.provider` to `oidc`. Affiliations come from the `affiliation` claim (semicolon-separated eduPersonScopedAffiliation), else inferred as `member@<eppn scope>`, matching the Ruby strategy. If `eppn` is missing, show the existing `shibboleth_failure_html` flash message (reworded for the new sign-in). Routes: GET /users/auth/oidc starts the flow, GET /users/auth/oidc/callback finishes it. Drop the /users/auth/shibboleth routes. The feature flag becomes `OIDC_ENABLED` (replacing `SHIBBOLETH`); when false, hide the campus sign-in option in the UI |
| Devise database_authenticatable (local "EMMA" login), recoverable, registerable, rememberable, trackable | golang.org/x/crypto/bcrypt + explicit handlers | This is the only sign-in method at launch. Hash with bcrypt at cost 11 or higher. Port password reset tokens, remember-me cookie and trackable columns (sign_in_count, current/last_sign_in_at/ip). Provide a CLI command to create the first administrator account |
| activerecord-session_store | github.com/alexedwards/scs/v2 with postgresstore, using the existing `sessions` table | Session keys must be preserved |
| CanCanCan (app/models/ability.rb) | Package `authz` with `Can(user, action, subject) bool` | Translate each `can`/`cannot` rule 1:1 with the rule order preserved |
| good_job (ActiveJob backend) | github.com/riverqueue/river (Postgres-backed) | Map each job class in app/jobs to a river Worker; preserve retry counts and queue names. River's migrations replace the good_job tables |
| ActionCable channels (lookup_channel, submit_channel) | github.com/coder/websocket implementing the ActionCable wire protocol | The @rails/actioncable JS client stays, so the Go server must speak its subscribe/confirm/message JSON frames exactly |
| ActionMailer | net/smtp or github.com/wneessen/go-mail + html/template | |
| Shrine + aws-sdk-s3 | github.com/aws/aws-sdk-go-v2/service/s3 | Keep the same JSON shape in `uploads.file_data` that Shrine writes, since views and scripts read it. Buckets are in the IDS AWS account, named by env vars |
| Faraday API services (app/services/*) | net/http client with a shared retry/caching RoundTripper | One Go package per service; preserve the action/common/definition/error/status split as files |
| representable / virtus records (app/records) | Go structs with json and xml struct tags | Field names, omit rules and nesting must produce byte-equivalent JSON |
| Draper decorators (app/decorators) + helpers (app/helpers) | Go view-model packages that return `template.HTML` fragments, plus github.com/a-h/templ for full pages | These generate most of EMMA's HTML; DOM output must match |
| ERB views (app/views) | templ components | One component per view/partial, same nesting |
| workflow gem (app/models/upload_workflow) | Explicit state machine: typed `State`, transition table, event methods | Preserve state names as stored strings |
| Rails i18n (config/locales, 52 YAML files) | Load the existing YAML files at startup into a nested map; `t(key, args)` helper | EMMA uses locale files as configuration, not just translations. Do NOT convert them to Go code |
| Nokogiri, Sanitize | golang.org/x/net/html + github.com/microcosm-cc/bluemonday | Match the Sanitize allowlist exactly |
| pdf-reader | github.com/pdfcpu/pdfcpu | Metadata extraction only |
| prometheus-client | github.com/prometheus/client_golang | Same metric names and labels |
| recaptcha | Direct verify call via net/http | |
| CSV, archive-zip, iso-639 | encoding/csv, archive/zip, embedded ISO 639 table | |
| rack-cors | github.com/go-chi/cors | Same allowed origins |
| request_store | request-scoped values via context.Context | Never use package-level mutable state |

Where the decorator row says "DOM output must match", apply it as section 4a
defines (keep the JavaScript hooks; WCAG fixes are allowed), since section 4a
states HTML does not have to match the Rails output exactly.

### 4. Rails conventions the Go server must reproduce

The unmodified frontend depends on these. Treat each as a hard requirement.

1. **CSRF**: emit `<meta name="csrf-param">` and `<meta name="csrf-token">` in the
   layout, and accept the token from the `X-CSRF-Token` header or the
   `authenticity_token` form field. rails-ujs reads these.
2. **rails-ujs method override**: honor `_method` form fields (PATCH, PUT, DELETE)
   and `data-method` link behavior.
3. **Turbolinks**: on redirects for Turbolinks XHR requests, set the
   `Turbolinks-Location` header; respond to `Turbolinks-Referrer`.
4. **Flash messages**: one-request flash stored in the session, rendered in the
   layout with the same markup.
5. **Format negotiation**: honor `.json`, `.xml`, `.html` path suffixes and the
   `format` param the way `respond_to` does.
6. **Param coercion**: Rails nested params (`upload[file_data]`,
   `ids[]=1&ids[]=2`) must parse into the same structures.
7. **Status codes**: `head :no_content`, `redirect_to ... status: :see_other`,
   422 on validation failure, etc. must match per action.
8. **ActionCable protocol**: `welcome`, `ping` every 3s, `confirm_subscription`,
   `reject_subscription`, and `{identifier, message}` frames.
9. **No identity headers**: the Go service must never derive a signed-in user
   from request headers such as EPPN, AFFILIATION or MEMBER. User identity comes
   only from the OIDC flow and the server-side session. Gateway headers are
   handled as described in section 4b.

### 4a. HTML and accessibility requirements

HTML does not have to match the Rails output exactly. It must:

1. **Keep the JavaScript hooks.** Keep every element id, class, `data-*`
   attribute, form field name and nesting relationship that the scripts in
   app/assets/javascripts or the tests in test/system select on. Before
   converting a view, list the selectors those files use and treat them as
   fixed. Everything else (wrapper divs, presentational classes, attribute
   order, whitespace) may change.
2. **Conform to WCAG 2.2 Level AA.** Where the Rails markup falls short,
   correct it in Go rather than copying the defect. In particular:
   - Semantic landmarks (header, nav, main, footer) and one h1 per page with
     a logical heading order
   - Keep the existing skip-navigation links (app/helpers/layout_helper/skip_nav.rb)
   - Every form control has a programmatic label; errors are tied to fields
     with aria-describedby and announced with role="alert" or a live region
   - Visible focus indicators that are not obscured by sticky headers
     (2.4.11 Focus Not Obscured)
   - Target size of at least 24 by 24 CSS pixels for controls (2.5.8)
   - No drag-only interactions (2.5.7); any drag action needs a single-pointer
     alternative
   - Do not ask users to re-enter information already provided in the same
     process (3.3.7 Redundant Entry), for example in bulk upload and manifest flows
   - Accessible authentication (3.3.8): allow password managers and paste on
     the local sign-in form; no cognitive tests
   - Consistent placement of help links across pages (3.2.6)
   - `lang="en"` on html; meaningful page titles; tables with th/scope and
     captions; ARIA only where native HTML cannot express the role
   - Live progress from ActionCable (lookup and submit) is announced through
     an aria-live="polite" region
3. **Keep the i18n text.** User-facing strings still come from config/locales.

### 4b. Running behind the IDS gateway (Tyk)

The Go service is deployed like Logic and IRIS in the idsproject/ids-gateway
compose stack: reachable only through the Tyk gateway, never published
directly (see `references/gateway-reference.txt`).

1. **Gateway secret**: every request must carry `X-Gateway-Auth` equal to the
   `GATEWAY_SHARED_SECRET` environment variable (same variable name the other
   services use). Compare in constant time (crypto/subtle). Reject anything else
   with 403 before routing, except `/healthz`, which the container health check
   calls directly. Local development: when `DEPLOYMENT=local` and
   `GATEWAY_SHARED_SECRET` is empty, skip this check and log a warning at
   startup; in that mode do not trust X-Forwarded-*, `X-School-Id`,
   `X-Library-Id` or `X-Scope-Level`. In any other deployment, refuse to start
   if `GATEWAY_SHARED_SECRET` is empty.
   In local mode, use the TCP peer address and the request's own scheme
   instead of `X-Forwarded-For` and `X-Forwarded-Proto`. Routes that authorize
   with `X-School-Id`, `X-Library-Id` and `X-Scope-Level` (item 5) return 403.
   That 403 applies only to those routes: the emma-index Search and Ingest API
   authenticates with `X-API-Key` (`INGEST_API_KEY`, section 4d) and keeps
   working in local mode, so the local Rails reference app can use it.
2. **Health check**: add `GET /healthz` returning 200 with no auth and no
   database-heavy work, to match the compose health checks (curl -fsS).
3. **Request id**: use `X-Request-Id` from the gateway as the request id in
   logs and error pages; generate one only if it is absent.
4. **Client IP and scheme**: trackable sign-in IPs, CSRF origin checks, secure
   cookies and absolute URLs must use the client address and https scheme as
   forwarded by Tyk (X-Forwarded-For, X-Forwarded-Proto), trusting those
   headers only from the gateway (requests that passed check 1).
5. **Browser routes vs API keys**: browser pages and the OIDC routes are served
   through a keyless gateway API definition (like my-ids.json); the Go service
   does its own session auth. Machine-to-machine API routes (for example IRIS
   handing remediated files to EMMA) go through a keyed definition; for those
   requests, read the caller from `X-School-Id`, `X-Library-Id` and
   `X-Scope-Level` and authorize with them instead of a user session. Never
   trust these three headers on keyless (browser) routes.
6. **Settings**: listen port from `SERVERPORT`; database URL from `DB_URL`,
   following the gateway stack's conventions.
7. **Org mapping**: add two nullable, indexed text columns to `orgs`:
   `ids_school_id` and `ids_library_id`. They map an EMMA org to an IDS member
   for keyed API calls (item 5). Add them to the Org model and to the org edit
   form, visible to administrators only. This is the only schema change beyond
   db/schema.rb.

### 4c. Partner repositories

Keep these integrations. Each one is controlled by its own feature flag and
stays disabled until IDS has an agreement and credentials with the partner.
With a flag off, the partner's items, filters and download links must not
appear anywhere in the UI.

| Partner | Flag | How it works in the Rails code | Go target |
|---|---|---|---|
| Internet Archive | `IA_ENABLED` (replaces `IA_DOWNLOADS_SUPPORTED`) | Downloads through the "Printdisabled" API (`IA_DOWNLOAD_API_URL`, default `https://archive.org/services/printdisabled/fetch_or_make_ebook.php`) authenticated with `IA_ACCESS`/`IA_SECRET` (app/services/ia_download_service, app/controllers/concerns/ia_download_concern.rb). Remediated submissions derived from IA items go to an S3 "drop site" bucket as a pair of files: `<submission id>.xml` package and a data file (app/services/aws_s3_service) | Package `partners/ia` for downloads; S3 drop-site writer in `services/awss3`. Also port uvalib/emma-ia (see 4e) |
| ACE (Scholars Portal) | `ACE_ENABLED` | Uses the same Internet Archive template in repository.en.yml (`<<: *IA_TEMPLATE`), so ACE items are retrieved through the IA download path | Reuse `partners/ia` with ACE's repository settings; no separate client |
| BiblioVault | `BV_ENABLED` | Downloads and submissions through BiblioVault S3 transfer buckets (`BV_BUCKET`, `BV_REGION`, `BV_ACCESS_KEY_ID`, `BV_SECRET_KEY`; app/services/bv_download_service) | Package `partners/bv` using aws-sdk-go-v2 with its own credentials, separate from IDS's own S3 credentials |
| EMMA (native) | always on | Items uploaded directly by member DSOs, stored in EMMA's own bucket | `services/awss3` |

Lookup services (app/services/lookup_service: WorldCat, Google Books, Crossref)
are used to fill in bibliographic metadata. Port them with the same pattern:
one flag and one API key per service (`WORLDCAT_ENABLED` and so on).

The Math Detective tool (`/tool/md`, app/assets/javascripts/tool/math-detective.js,
`MD_API_KEY`) calls an external service from the browser. Keep it behind
`MD_ENABLED` (default off) and hide its menu entry when off.

`GET /upload/records` (UploadController#records) produces the JSON record
listing UVA used for APTrust preservation backup. Translate it as-is; whether
IDS uses APTrust is an open question (section 9).

### 4d. EMMA Unified Index (new companion service)

The Rails app does not contain its search index. It calls two external HTTP
APIs that UVA ran separately on Elasticsearch, originally from Benetech's
Bookshare unified search (config/locales/env_var.en.yml: `SERVICE_SEARCH_*`,
`SERVICE_INGEST_*`). Those services are gone. Build a replacement as a second
Go binary, `cmd/emma-index`, in the same repository.

1. **Contract**: implement exactly the endpoints and payloads the Rails client
   uses, so the unmodified Rails app can talk to it:
   - Search API: `GET /search` with the query parameters built in
     app/services/search_service/action/records.rb; response shapes from
     app/records/search/**.
   - Ingest API: `PUT /records`, record deletion and record retrieval as built
     in app/services/ingest_service/action/submissions.rb; payload shapes from
     app/records/ingest/**.
   - The `X-API-Key` header the ingest client sends (`INGEST_API_KEY`).
2. **Storage**: PostgreSQL full-text search (tsvector columns with GIN indexes)
   in its own `index` schema. Put the search behind a Go interface so an
   OpenSearch backend can be added later if partner record volume requires it.
3. **Callers**: the EMMA web service (search and ingest) and, later, partner
   feeds such as Internet Archive metadata. Partner feeds use keyed gateway
   routes (section 4b item 5).
4. **Scope note**: this component is new code written against an existing
   contract, not a translation. Generate it in a separate run, after the
   foundation slice (section 7).

### 4e. emma-ia submission processor

uvalib/emma-ia (about 1,900 lines of Python) processes the Internet Archive
S3 drop site: it reads each `.xml` package and data file pair and submits them
to Internet Archive. Translate it to Go as a River worker inside the EMMA
service (`jobs/iasubmit`), triggered on a schedule or by S3 event, instead of
an AWS Lambda. Disabled unless `IA_ENABLED` is true.

### 4f. Content formerly hosted by UVA

The Rails app fetches some page and email content at runtime from UVA's
project website, `https://emma.uvacreate.virginia.edu`, which no longer serves
it (the baseline tests fail with an SSL hostname mismatch):

- About page body: `en.emma.page.about.content_url`
  (config/locales/page.en.yml), rendered by `external_content_section`
  (app/helpers/about_helper/main.rb).
- Welcome email bodies: `body:` URLs in config/locales/mail.en.yml, fetched by
  `ApplicationMailer#fetch_remote_message`.
- The project link in config/locales/page.en.yml.

CRITICAL: the Go service must not fetch page or email content from remote
URLs at request time. Serve this content from local templates under
`go/internal/views/content/` (initially placeholders with a TODO for IDS
Network wording) and point the project link at an IDS Network page set by
`PROJECT_SITE_URL`. A failure to load optional content must never turn a page
into a 500 error.

### 4g. System and health pages

Keep health checks and a minimal administrator settings page. Drop the rest of
the System section (SysController), which exposes server internals.

Keep, translated as-is:

- HealthController and its routes: `/health/*` (including
  `/health/check/:subsystem` and `/health/run_state`), `/version`,
  `/healthcheck`, `/system_unavailable`. Subsystem checks that refer to
  services EMMA no longer uses (UVA search/ingest hosts) check emma-index instead.
- `/healthz` (section 4b) stays separate: a plain 200 for the container health
  check, with no database or service calls.

Keep, reduced:

- `GET /sys`: a short menu linking only to the pages kept below.
- `GET /sys/settings` and `POST|PUT|PATCH /sys` (`SysController#update`):
  view and change the AppSettings flags. Show AppSettings values only. Do not
  display environment variables, credentials, secrets or file paths, and drop
  the Rails text that refers to Terraform, `.idea/environment.rb` or Docker mounts.
- `GET /sys/jobs`: link to the River job dashboard (riverui) if it is
  deployed, otherwise omit.
- Administrator role only, using the existing ability rules for `SysController`.

Drop (no Go code, no routes): `/sys/analytics`, `/sys/database`,
`/sys/disk_space`, `/sys/environment`, `/sys/files`, `/sys/headers`,
`/sys/internals`, `/sys/loggers`, `/sys/mailers`, `/sys/processes`,
`/sys/var`, `/sys/view`, and their helpers in app/helpers/sys_helper/ other
than what settings needs. Remove their links from the menu and the nav bar.
Their Rails tests (SysControllerTest, SysTest) are excluded from parity
checks, except the settings and index tests.

### 5. Go project conventions

Follow the structure, naming, error handling and logging style of
idsproject/iris (`references/iris-reference.go.txt`), the Go service EMMA runs
beside behind the IDS gateway. Specifically:

- `cmd/<name>/main.go` with a `migrate` subcommand (`/emma migrate`,
  `/emma-index migrate`) that runs golang-migrate from `MIGRATIONS_DIR`, as
  IRIS does. CRITICAL: golang-migrate records versions in a table named
  `go_schema_migrations` (x-migrations-table), never `schema_migrations`,
  which Rails uses; the gateway compose stack runs it as a one-shot service before
  the main container starts.
  `RunMigrations` sets `x-migrations-table=go_schema_migrations` on the
  migration connection string when `DB_URL` does not already set it, and
  returns an error if `DB_URL` names any other migrations table. emma-index
  uses the same table name inside its own `index` schema.
- `app/` for wiring (Application struct holding logger and models, routes,
  server with graceful shutdown), `handler/` for HTTP handlers grouped by
  area, `internal/data/` for models wrapping a `*pgxpool.Pool`.
- go-chi/chi v5 with its RequestID and Recoverer middleware; `/healthz` on the
  root router.
- JSON responses for API routes use IRIS's envelope
  (`{"status": "success" | "error", "message": ...}`, util/response.go).
- `.golangci.yaml` and Makefile targets (build, test, lint, format) matching IRIS.

In addition:

- CRITICAL: write all Go code under the `go/` directory at the repository
  root, with its own `go.mod`. The Rails `app/`, `lib/` and `config/`
  directories stay in place, unmodified, as the source and reference app until
  the translation is finished. (IRIS's `app/` package name would otherwise
  collide with Rails' `app/` directory.)
- Module path: `github.com/idsproject/emma` (adjust as needed)
- Layout beyond the IRIS pattern: `internal/{authz,jobs,cable,services,records,views,i18n,config}`.
  Place the other packages named in this definition under `internal/` too:
  `internal/paths`, `internal/auth/oidc`, `internal/partners/ia`,
  `internal/partners/bv`, `internal/services/awss3`, `internal/jobs/iasubmit`.
- Reserve `internal/integrations/` for code that is not translated from Rails
  (the IRIS deposit API). The translation must not generate anything there.
- Configuration: the Rails app reads many ENV vars via config/env_vars.rb;
  preserve every variable name and default in `internal/config`.
- Errors: wrap with `fmt.Errorf("...: %w", err)`; no panics in request paths.
- Logging: `log/slog`, structured, request id on every line.
- No global DB handle; pass dependencies via a `deps` struct.
- Every exported func gets a doc comment carried over from the Ruby YARD comment
  where one exists.

### 6. Inputs to provide with this definition

- The EMMA repository (source).
- sig/** RBS files: use these as authoritative type information when inferring
  Go types for Ruby methods.
- db/schema.rb: authoritative table and column types for sqlc schema.
- config/locales/**: copied verbatim into the Go repo.
- Reference Go code sample: idsproject/iris (`references/iris-reference.go.txt`).
- Optionally: Rails guides for routing, CSRF and ActionCable protocol docs.

### 9. Decisions and remaining questions

Decided:

- **Hosting**: IDS Network now hosts EMMA (no longer UVA). The Go service runs
  behind the IDS gateway (section 4b).
- **Fresh start**: no data, users or files are migrated; the Go schema is
  created from scratch. No parallel run or cutover with a live Rails system.
- **Sign-in**: launch with local EMMA accounts. OIDC campus sign-in is built
  but disabled; turn it on later with CILogon or a self-hosted SATOSA by
  setting `OIDC_ISSUER_URL`. The Shibboleth header strategy is retired.
- **Partners**: keep Internet Archive, ACE and BiblioVault behind flags (4c).
  Drop Bookshare and HathiTrust (already inactive).
- **Search index**: rebuild as emma-index in Go (4d).
- **IRIS integration**: built separately after slices 5 and 6, as new code in
  `internal/integrations/iris`, per the IRIS to EMMA integration spec. The
  translation only adds the hooks (`orgs.ids_*` columns, keyed API routing,
  the reserved package).
- **HTML**: functional equivalence plus WCAG 2.2 AA (section 4a), not exact DOM parity.
- **Schema cleanup**: the tables listed in section 2 are simply never created.

Remaining (do not resolve these in code; where a slice touches one, add a
`TODO(Qn)` comment and list it in the report):

- **Q1 Gateway changes (Andromeda)**: set `enable_websockets` to true in
  configs/tyk.conf (EMMA's ActionCable channels need it), add
  apps-src/emma.json and apps-src/emma-index.json (keyless for browser routes,
  keyed for API routes), and test large PDF and zip uploads through the gateway
  for size and timeout limits. These files live in idsproject/ids-gateway; do not
  create them in this repository.
- **Q2 API callers**: confirm which EMMA and emma-index routes other systems
  will call (IRIS, partner feeds) so they get keyed gateway definitions.
- **Q3 Internet Archive**: as talks progress, get API credentials
  (`IA_ACCESS`/`IA_SECRET`), the drop-site bucket arrangement, and whether IA
  will push its metadata into emma-index.
- **Q4 ACE and BiblioVault**: confirm whether each is still interested, and
  for BiblioVault, the transfer bucket and credentials.
- **Q5 Lookup services**: decide which of WorldCat (OCLC subscription),
  Google Books and Crossref to enable, and get keys.
- **Q6 Campus sign-in**: revisit CILogon versus SATOSA once members ask for it.
- **Q7 APTrust**: UVA backed up EMMA submissions to APTrust using
  `GET /upload/records`. Decide whether IDS will use APTrust or another
  preservation service; the endpoint is translated either way.

## Validation / Exit Criteria

### 8. Validation

Build command: `cd go && go build ./... && go vet ./... && go test ./...`

Test sign-in: the Rails system tests sign in through `/users/sign_in_as?id=`
and "Sign in as ..." links on the sign-in page, which exist only when
`Rails.env.test?` (`SIGN_IN_AS` in lib/_constants.rb). The Go service must
provide the same route and links only when `EMMA_TEST_SIGN_IN=true`, and must
refuse to start with that flag set unless `DEPLOYMENT=local`.

Running the Rails system tests against Go: set `APP_HOST` to the Go server's
URL. test/application_system_test_case.rb then sets `Capybara.app_host` to it
and `Capybara.run_server = false`. For parity runs the Go server uses its own
database, `emma_go_test`, created by `emma migrate`. The Rails test runner
loads its fixtures into that database (`DBNAME=emma_go_test` with `APP_HOST`
set) without reloading db/schema.rb, so every table and column that
test/fixtures/*.yml writes must exist in the Go migrations with the same name
and a compatible type.

Slice status: the transformation marks a slice `built, validation pending`
when any section 8 check could not be run. A maintainer runs those checks
outside the transformation and changes the status to `done` in
go/TRANSLATION_PROGRESS.md; only then can the next slice start.

Reference app: run the Rails app locally only, as the reference for parity
tests. Point its `SERVICE_SEARCH_*` and `SERVICE_INGEST_*` settings at the new
emma-index service so search and submission work end to end.

Index contract: before slice 4, the Rails app must search, submit, update and
delete records against emma-index with no Rails code changes.

Behavioral parity: the existing Capybara system tests in test/system are
black-box browser tests. Run them against the Go server by pointing
`Capybara.app_host` at it with `Capybara.run_server = false`. A slice is done
when its system tests pass against both Rails and Go. Partner-dependent tests
run with partner flags off, plus stubbed partner APIs (httptest servers) for
the on path.

Accessibility: run axe-core (via @axe-core/cli or axe with Playwright) on every
page touched by the slice, with the wcag2a, wcag2aa, wcag21a, wcag21aa and
wcag22aa rule tags. A slice is not done until it reports zero violations.
Also run each slice's pages through a keyboard-only pass (Tab, Shift+Tab, Enter,
Space, Escape) as a manual checkpoint; automated tools catch only part of WCAG.

For JSON/XML endpoints, generate golden files by recording Rails responses for
the fixtures in test/fixtures, then assert the Go responses match byte for byte
(after normalizing timestamps and ids).

Rails controller tests (test/controllers) and model tests are not portable;
translate their assertions into Go table-driven tests in the matching package.

### Exit checklist for a run

1. Exactly one slice was translated, the one named in `additionalPlanContext`;
   or, in a rework run, only the listed problems in that slice were fixed and
   the rework is recorded in `go/TRANSLATION_PROGRESS.md`.
2. The build command passes.
3. Nothing outside `go/` changed; `app/`, `lib/`, `config/`, `db/`, `test/` are unmodified.
4. Nothing was generated in `go/internal/integrations/` (only `.gitkeep`), and
   nothing was generated from `references/iris-emma-integration-spec.md`.
5. No Go models, queries or repositories exist for the unused tables in section 2;
   no Go code exists for Bookshare, HathiTrust, pipeline/ or package/.
6. No dropped `/sys/*` route or `/users/auth/shibboleth` route is registered.
7. No code path fetches page or email content from a remote URL at request time.
8. Every Rails route in the slice has a chi route with the same method, path and
   status codes, and a named helper in `paths`.
9. `go/docs/selectors/<slice-id>.md` exists and every selector in it is present
   in the slice's templ output.
10. The slice's status in `go/TRANSLATION_PROGRESS.md` is `built, validation
    pending`, never `done`, with every pending section 8 check listed (at least
    the keyboard-only pass). Checks run during the transformation are recorded
    as passed only if they passed.
11. `go/TRANSLATION_PROGRESS.md` is updated for the slice.
12. The migrations version table is `go_schema_migrations`; no Go code creates
    or writes `schema_migrations`.
13. Every table and column written by `test/fixtures/*.yml` exists in the Go
    migrations with the same name and a compatible type.
14. With `DEPLOYMENT` other than `local` and an empty `GATEWAY_SHARED_SECRET`,
    the server refuses to start (covered by a Go test).
15. In local mode, Go tests show that routes authorizing with `X-School-Id`,
    `X-Library-Id` and `X-Scope-Level` return 403, and that the emma-index
    Search and Ingest API still accepts a valid `X-API-Key` (from slice 1a on).

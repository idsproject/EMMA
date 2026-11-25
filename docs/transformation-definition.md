# AWS Transform custom: EMMA Rails-to-Go Transformation Definition (Draft v0.6)

Source: https://github.com/uvalib/emma (Ruby 3.4.1, Rails 8.0.2, PostgreSQL)
Companion source: https://github.com/uvalib/emma-ia (Python, Internet Archive submission processor)
Target: Go services (same Go version as idsproject/iris, currently 1.26), behavior-equivalent to the Rails app at the HTTP boundary

Context: EMMA was shut down by UVA about a year ago. IDS Network is relaunching
it. There is no production database, no user accounts and no stored files to
migrate. The Go system starts empty.

---

## 1. Objective

Translate the EMMA server application from Ruby on Rails to idiomatic Go. The Go
service must behave like the Rails code in this repository: same URL routes,
same HTTP methods, same response status codes and same JSON/XML payload shapes.
Because nothing is being migrated, the Go service owns a fresh PostgreSQL
schema derived from db/schema.rb (minus the tables listed in section 2).
HTML output does NOT need to match Rails byte for byte. It must be functionally
equivalent and conform to WCAG 2.2 Level AA (see section 4a). The existing browser JavaScript bundle (app/assets/javascripts,
roughly 50k lines using jQuery, Select2, rails-ujs, Turbolinks and
@rails/actioncable) is NOT being rewritten in this phase and must keep working
unmodified against the Go server.

Do not redesign features. Do not "improve" behavior. Where Rails behavior is
implicit (callbacks, default scopes, CSRF, flash, param coercion), make it
explicit in Go and preserve it.

Deliberate differences from the Rails app: the Go service runs behind the IDS
gateway (section 4b); campus sign-in moves from Shibboleth headers to OpenID
Connect and is off at launch (section 3, auth rows); and the search/ingest
index that UVA ran as a separate service is rebuilt as part of this project
(section 4d).

## 2. Out of scope for this transformation

- app/assets/** (JavaScript and SCSS). Copy the compiled output from
  app/assets/builds and serve it as static files.
- Data migration. There is no legacy data. Create the schema with Go
  migrations (golang-migrate, matching the gateway stack) derived from
  db/schema.rb. Table and column names stay the same; tables owned by
  replaced libraries change to the replacement's own schema (good_job tables
  become River's tables; the `sessions` table uses the scs postgresstore
  schema).
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

## 3. Target Go stack (do not substitute)

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

## 4. Rails conventions the Go server must reproduce

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

## 4a. HTML and accessibility requirements

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
     process (3.3.7 Redundant Entry), for example in bulk upload and manifest
     flows
   - Accessible authentication (3.3.8): allow password managers and paste on
     the local sign-in form; no cognitive tests
   - Consistent placement of help links across pages (3.2.6)
   - `lang="en"` on html; meaningful page titles; tables with th/scope and
     captions; ARIA only where native HTML cannot express the role
   - Live progress from ActionCable (lookup and submit) is announced through
     an aria-live="polite" region
3. **Keep the i18n text.** User-facing strings still come from config/locales.

## 4b. Running behind the IDS gateway (Tyk)

The Go service is deployed like Logic and IRIS in the idsproject/ids-gateway
compose stack: reachable only through the Tyk gateway, never published
directly.

1. **Gateway secret**: every request must carry `X-Gateway-Auth` equal to the
   `GATEWAY_SHARED_SECRET` environment variable (same variable name the other
   services use). Compare in constant time (crypto/subtle). Reject anything else
   with 403 before routing, except `/healthz`, which the container health check
   calls directly. Local development: when `DEPLOYMENT=local` and
   `GATEWAY_SHARED_SECRET` is empty, skip this check and log a warning at
   startup; in that mode do not trust X-Forwarded-*, `X-School-Id`,
   `X-Library-Id` or `X-Scope-Level`. In any other deployment, refuse to start
   if `GATEWAY_SHARED_SECRET` is empty.
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

## 4c. Partner repositories

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

## 4d. EMMA Unified Index (new companion service)

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

## 4e. emma-ia submission processor

uvalib/emma-ia (about 1,900 lines of Python) processes the Internet Archive
S3 drop site: it reads each `.xml` package and data file pair and submits them
to Internet Archive. Translate it to Go as a River worker inside the EMMA
service (`jobs/iasubmit`), triggered on a schedule or by S3 event, instead of
an AWS Lambda. Disabled unless `IA_ENABLED` is true.

## 4f. Content formerly hosted by UVA

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

## 4g. System and health pages

Keep health checks and a minimal administrator settings page. Drop the rest of
the System section (SysController), which exposes server internals.

**Keep, translated as-is**

- HealthController and its routes: `/health/*` (including
  `/health/check/:subsystem` and `/health/run_state`), `/version`,
  `/healthcheck`, `/system_unavailable`. Subsystem checks that refer to
  services EMMA no longer uses (UVA search/ingest hosts) check emma-index
  instead.
- `/healthz` (section 4b) stays separate: a plain 200 for the container health
  check, with no database or service calls.

**Keep, reduced**

- `GET /sys`: a short menu linking only to the pages kept below.
- `GET /sys/settings` and `POST|PUT|PATCH /sys` (`SysController#update`):
  view and change the AppSettings flags. Show AppSettings values only. Do not
  display environment variables, credentials, secrets or file paths, and drop
  the Rails text that refers to Terraform, `.idea/environment.rb` or Docker
  mounts.
- `GET /sys/jobs`: link to the River job dashboard (riverui) if it is
  deployed, otherwise omit.
- Administrator role only, using the existing ability rules for `SysController`.

**Drop** (no Go code, no routes): `/sys/analytics`, `/sys/database`,
`/sys/disk_space`, `/sys/environment`, `/sys/files`, `/sys/headers`,
`/sys/internals`, `/sys/loggers`, `/sys/mailers`, `/sys/processes`,
`/sys/var`, `/sys/view`, and their helpers in app/helpers/sys_helper/ other
than what settings needs. Remove their links from the menu and the nav bar.
Their Rails tests (SysControllerTest, SysTest) are excluded from parity
checks, except the settings and index tests.

## 5. Go project conventions

Follow the structure, naming, error handling and logging style of
idsproject/iris, the Go service EMMA runs beside behind the IDS gateway.
Specifically:

- `cmd/<name>/main.go` with a `migrate` subcommand (`/emma migrate`,
  `/emma-index migrate`) that runs golang-migrate from `MIGRATIONS_DIR`, as
  IRIS does. CRITICAL: golang-migrate records versions in a table named
  `go_schema_migrations` (x-migrations-table), never `schema_migrations`,
  which Rails uses; the gateway compose stack runs it as a one-shot service before
  the main container starts.
- `app/` for wiring (Application struct holding logger and models, routes,
  server with graceful shutdown), `handler/` for HTTP handlers grouped by
  area, `internal/data/` for models wrapping a `*pgxpool.Pool`.
- go-chi/chi v5 with its RequestID and Recoverer middleware; `/healthz` on the
  root router.
- JSON responses for API routes use IRIS's envelope
  (`{"status": "success" | "error", "message": ...}`, util/response.go).
- `.golangci.yaml` and Makefile targets (build, test, lint, format) matching
  IRIS.

In addition:

- CRITICAL: write all Go code under the `go/` directory at the repository
  root, with its own `go.mod`. The Rails `app/`, `lib/` and `config/`
  directories stay in place, unmodified, as the source and reference app until
  the translation is finished. (IRIS's `app/` package name would otherwise
  collide with Rails' `app/` directory.)
- Module path: `github.com/idsproject/emma` (adjust as needed)
- Layout beyond the IRIS pattern: `internal/{authz,jobs,cable,services,records,views,i18n,config}`
- Reserve `internal/integrations/` for code that is not translated from Rails
  (the IRIS deposit API). The translation must not generate anything there.
- Configuration: the Rails app reads many ENV vars via config/env_vars.rb;
  preserve every variable name and default in `internal/config`.
- Errors: wrap with `fmt.Errorf("...: %w", err)`; no panics in request paths.
- Logging: `log/slog`, structured, request id on every line.
- No global DB handle; pass dependencies via a `deps` struct.
- Every exported func gets a doc comment carried over from the Ruby YARD comment
  where one exists.

## 6. Inputs to provide with this definition

- The EMMA repository (source).
- sig/** RBS files: use these as authoritative type information when inferring
  Go types for Ruby methods.
- db/schema.rb: authoritative table and column types for sqlc schema.
- config/locales/**: copied verbatim into the Go repo.
- Reference Go code sample: idsproject/iris.
- Optionally: Rails guides for routing, CSRF and ActionCable protocol docs.

## 7. Transformation order (one slice per run)

Run the transformation slice by slice. Each slice must build and pass its
validation before the next one starts.

1. **Foundation**: config, i18n loader, DB pool, migrations, sessions, CSRF,
   flash, layout, static assets, gateway checks (4b), health_controller,
   metrics_controller.
1a. **EMMA Unified Index** (section 4d): built and tested against the
   unmodified Rails app before slice 4 starts.
2. **Auth**: users, roles, OIDC sign-in and local sign-in, account_controller,
   user session controllers, authz (ability.rb).
3. **Orgs and enrollment**: org, enrollment models and controllers, mailers.
4. **Search**: records/search, search_service, search_controller,
   search_call_controller, search decorators and views.
5. **Uploads**: upload model, Shrine-compatible S3 storage, upload_workflow
   state machine, upload_controller, ingest_service, submission_service.
6. **Manifests and bulk**: manifest, manifest_item, submit/lookup jobs,
   ActionCable channels.
7. **Downloads and partners**: download model, partner packages (section 4c),
   download_controller, emma-ia worker (section 4e).
8. **Remaining tools**: tool_controller, data_controller, sys_controller (reduced per section 4g),
   about/help/home.

## 8. Validation

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

## 9. Decisions and remaining questions

**Decided**

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
- **HTML**: functional equivalence plus WCAG 2.2 AA (section 4a), not exact
  DOM parity.
- **Schema cleanup**: the tables listed in section 2 are simply never created.

**Remaining**

- **Q1 Gateway changes (Andromeda)**: set `enable_websockets` to true in
  configs/tyk.conf (EMMA's ActionCable channels need it), add
  apps-src/emma.json and apps-src/emma-index.json (keyless for browser routes,
  keyed for API routes), and test large PDF and zip uploads through the gateway
  for size and timeout limits.
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

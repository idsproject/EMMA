# Reference material for ids/emma-rails-to-go

- transformation-definition.md: the authoritative requirements. Where any
  other file disagrees, this one wins. Sections marked CRITICAL are mandatory.
- iris-reference.go.txt: idsproject/iris, the Go service EMMA runs beside.
  Copy its layout, naming, error handling, logging, migrate subcommand,
  response envelope, Makefile and lint settings (definition section 5).
- gateway-reference.txt: idsproject/ids-gateway compose file, API
  definitions and policies. Shows how services sit behind Tyk, the
  X-Gateway-Auth secret, health checks and env var names (section 4b).
- iris-emma-integration-spec.md: the IRIS deposit API that will be built
  later by hand. Do NOT generate anything from it; it is here only so the
  translation leaves internal/integrations/ empty and adds the hooks the
  spec needs (orgs.ids_* columns, keyed API routing).

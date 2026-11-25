# IRIS to EMMA Integration Spec (Draft v0.2)

Scope: every article and chapter IRIS remediates is deposited in EMMA, with
bibliographic metadata taken from the ILL request through CrossLink or IDS
Logic. IRIS also checks EMMA before paying for remediation. Other IDS Logic
integration is out of scope for now.

Sources reviewed: idsproject/iris (main, commit 26f23b3), uvalib/emma,
idsproject/ids-gateway, and the EMMA Rails-to-Go transformation definition v0.5.

**Decisions in this version**

- All remediated articles and chapters are deposited. There is no per-library
  opt-in.
- Bibliographic metadata comes from the ILL request: from CrossLink for
  requests that went through it, otherwise from IDS Logic (which reads the
  library's ILLiad transaction).
- IRIS fetches the metadata when the upload arrives, not when remediation
  finishes, so it is available for the pre-check and problems surface early.

---

## 1. How IRIS works today

1. A library posts a PDF to `POST /v1/upload?transaction=<id>` with
   `X-Library-Id` (set by the gateway from the caller's API key). IRIS counts
   the pages, uploads the file to S3 as `pdf/<filename>`, and records a
   `tracking` row (library, transaction, page count) for billing at $0.15 a page.
2. The AWS remediation pipeline writes `result/COMPLIANT_<filename>` and its
   Lambda hook calls `POST /v1/notify` with `"remediation complete"`.
3. IRIS downloads the result to `DOWNLOAD_DIR` and deletes it from S3.
4. The library polls `GET /v1/status/{filename}`, fetches
   `GET /v1/download/{filename}`, then sends `"download complete"`, and IRIS
   deletes its local copy.

The remediated file is temporary, so the deposit happens at step 3, before the
library can trigger deletion. IRIS has no bibliographic metadata today.

## 2. New flow

```
Library ──upload (transaction id)──▶ IRIS
                                      │ 1. fetch bib metadata (CrossLink or Logic)
                                      │ 2. pre-check emma-index by identifier
                                      │ 3. send PDF to remediation pipeline
  remediation pipeline ──notify──▶   IRIS
                                      │ 4. download result
                                      │ 5. deposit PDF + metadata ──▶ EMMA
                                      ▼                              │
Library ◀── download ───────────── IRIS          EMMA ──ingest──▶ emma-index
```

### Step 1. Fetch bibliographic metadata

On upload, IRIS resolves the transaction to a normalized bibliographic record
(section 3) through a `BibSource` interface with two implementations:

| Source | When | How |
|---|---|---|
| CrossLink | The request went through CrossLink | Look up the ISO 18626 request by the requesting agency and request id; read its `BibliographicInfo` and `PublicationInfo` |
| IDS Logic | The library uses ILLiad (most libraries; also the fallback) | Ask Logic for the transaction; Logic calls the library's ILLiad Web Platform API with the credentials it already stores for that library and returns the transaction fields |

Choosing the source:

- The upload call gains an optional `source=crosslink|illiad` query parameter.
- If it is absent, IRIS uses the library's default from its configuration
  (kept in Logic alongside the library's other settings).
- If the first source returns nothing, IRIS tries the other.

If neither source returns at least a title, IRIS still remediates the file
(the library is paying for it) but marks the transaction `metadata_missing`
and holds the deposit until metadata is supplied (section 4, open question 2).

Both endpoints are called through the gateway with IRIS's API key. New
endpoints needed:

- **CrossLink**: `GET /requests/{requestingAgencyId}/{requestId}/bib`
  (name to match CrossLink's conventions), returning the stored
  BibliographicInfo and PublicationInfo as JSON.
- **IDS Logic**: `GET /illiad/{libraryId}/transactions/{transactionNumber}`,
  returning the ILLiad transaction fields listed in section 3. Logic must only
  return transactions for the library named in `X-Library-Id`.

### Step 2. Check before remediating

IRIS searches emma-index by identifier through the gateway:
`GET /search?identifier=doi:<doi>` for articles, `identifier=isbn:<isbn>` for
chapters (see the chapter rule in section 3 for how chapter matches are
compared).

- Match rule for articles: `emma_repository = emma`, `dc_format = pdf`,
  `rem_status = remediated`, same DOI (or same ISSN, volume, issue and pages
  when there is no DOI).
- Match rule for chapters: same ISBN and overlapping page range in
  `rem_coverage`.
- On a match, IRIS returns the EMMA item link with the upload response and
  lets the library choose to use it or remediate anyway.

### Step 3 to 5. Remediate, download, deposit

Unchanged up to the download. Then IRIS calls EMMA:

```
POST /api/v1/deposits
Content-Type: multipart/form-data
X-School-Id, X-Library-Id, X-Scope-Level   (set by the gateway)
Idempotency-Key: <library id>:<transaction id>

file:      the remediated PDF
metadata:  JSON, the EMMA fields from section 3
```

Responses:

- `202 Accepted`: `{"status":"success","deposit_id":"...","state":"..."}`
- `200 OK` with the same body if the idempotency key was already used
- `400` for missing or invalid metadata (lists the fields), `413` if the file
  is too large

`GET /api/v1/deposits/{deposit_id}` returns the deposit's state and, once
indexed, the EMMA item URL. Responses use IRIS's envelope
(`{"status": "success" | "error", "message": ...}`, util/response.go).

Deposit failures never block the library's download. IRIS records the failure
and retries in the background (River job or equivalent) with backoff, and keeps
the remediated file until the deposit succeeds, even after the library sends
`"download complete"`.

What EMMA does with a deposit:

1. Assigns it to a single EMMA org for IRIS deposits ("IDS Network, IRIS"),
   recording the contributing library's `ids_library_id` and `ids_school_id`
   on the deposit. Libraries do not need their own EMMA org to contribute.
2. Creates an `uploads` row with `emma_repository = emma`, stores the file in
   EMMA's S3 bucket and runs the upload workflow.
3. Publishes automatically: the workflow skips the manager review step for
   this org, since all IRIS output is deposited by policy. An EMMA
   administrator can still withdraw an item.
4. Submits the record to emma-index through the ingest path so it is
   searchable.

## 3. Bibliographic record and field mapping

IRIS normalizes both sources into one record, stored with the transaction:

```go
type BibRecord struct {
    Kind          string   // "article" or "chapter"
    Title         string   // article or chapter title
    Authors       []string // article or chapter authors
    ContainerTitle string  // journal title or book title
    ContainerAuthors []string // book authors or editors (chapters)
    Volume, Issue string
    Pages         string   // e.g. "45-67"
    Year          string
    Publisher     string
    PlaceOfPublication string
    DOI, ISSN, ISBN, OCLC string
    Language      string   // ISO 639-2, default "eng"
    Source        string   // "crosslink" or "illiad"
    SourceRequestID string
}
```

### From CrossLink (ISO 18626)

| BibRecord | ISO 18626 element |
|---|---|
| Kind | `PublicationInfo/PublicationType` (Article, Chapter; confirm against the code list version CrossLink uses) |
| Title | `BibliographicInfo/TitleOfComponent` |
| Authors | `BibliographicInfo/AuthorOfComponent` |
| ContainerTitle | `BibliographicInfo/Title` |
| ContainerAuthors | `BibliographicInfo/Author` |
| Volume, Issue | `BibliographicInfo/Volume`, `BibliographicInfo/Issue` |
| Pages | `BibliographicInfo/PagesRequested` |
| Year | `PublicationInfo/PublicationDate` |
| Publisher, PlaceOfPublication | `PublicationInfo/Publisher`, `PublicationInfo/PlaceOfPublication` |
| ISSN, ISBN, DOI | `BibliographicInfo/BibliographicItemId` by `BibliographicItemIdentifierCode` |
| OCLC | `BibliographicInfo/BibliographicRecordId` where the code is OCLC |

### From IDS Logic (ILLiad transaction)

| BibRecord | ILLiad field |
|---|---|
| Kind | `DocumentType`: `Article` gives article, `Book Chapter` gives chapter |
| Title | `PhotoArticleTitle` |
| Authors | `PhotoArticleAuthor` |
| ContainerTitle | `PhotoJournalTitle` |
| ContainerAuthors | `PhotoItemAuthor`, else `PhotoItemEditor` |
| Volume, Issue | `PhotoJournalVolume`, `PhotoJournalIssue` |
| Pages | `PhotoJournalInclusivePages` |
| Year | `PhotoJournalYear` |
| Publisher, PlaceOfPublication | `PhotoItemPublisher`, `PhotoItemPlace` |
| ISSN or ISBN | `ISSN` (ILLiad stores both here; tell them apart by format) |
| DOI | `DOI` |
| OCLC | `ESPNumber` |

### To EMMA

Articles are deposited as complete works. Chapters are deposited the way EMMA
models partial remediation: the work is the book, and the chapter is the
portion that was remediated. This keeps chapters findable by the book's ISBN.

| EMMA field | Article | Chapter |
|---|---|---|
| `dc_title` (required) | Title | ContainerTitle (the book) |
| `dc_creator` (required) | Authors | ContainerAuthors |
| `dc_identifier` | `doi:<DOI>` | `isbn:<ISBN>`, plus `oclc:<OCLC>` |
| `dc_relation` | `issn:<ISSN>` | |
| `dc_description` | | `Chapter: <Title>, by <Authors>` |
| `bib_seriesType` | `journal` | `book` |
| `bib_series` | ContainerTitle (the journal) | |
| `bib_seriesPosition` | `v. <Volume>, no. <Issue>` | |
| `dc_publisher` | Publisher | Publisher |
| `emma_publicationDate` | Year | Year |
| `dc_language` (required) | Language | Language |
| `dc_type` (required) | `text` | `text` |
| `dc_format` (required) | `pdf` | `pdf` |
| `rem_complete` (required) | `true` | `false` |
| `rem_coverage` | | `Chapter "<Title>", pp. <Pages>` |
| `rem_status` (required) | `remediated` | `remediated` |
| `rem_source` | `library` | `library` |
| `rem_metadataSource` | `CrossLink` or `ILLiad` | same |
| `rem_remediatedBy` | `IRIS (IDS Network)` | same |
| `rem_remediatedAspects` | `taggedPdf` plus what the pipeline reports | same |
| `rem_remediationDate` | Date remediation finished | same |
| `rem_comments` (required) | Pipeline name and version | same |
| `s_accessibilitySummary` | From the compliance report | same |

Field names come from EMMA's config/locales/record/upload.en.yml; check them
again when building.

## 4. Changes needed, by system

**IRIS**

1. `BibSource` interface with CrossLink and Logic clients; fetch on upload.
2. A `transactions` table (library id, transaction id, source, bib record as
   JSONB, state, EMMA deposit id) replacing the filename as the key for
   everything.
3. Key S3 objects and local files by library and transaction. Today two
   libraries uploading `article.pdf` would collide in `pdf/`, `result/` and
   `DOWNLOAD_DIR`.
4. Pre-check against emma-index before sending to the pipeline.
5. Deposit on `"remediation complete"`, with background retry, and keep the
   file until the deposit succeeds.
6. Verify `X-Gateway-Auth` against `GATEWAY_SHARED_SECRET`. The compose file
   passes the secret, but the code does not check it and the authentication
   middleware is commented out.
7. Raise the HTTP server timeouts (`ReadTimeout` 5 s, `WriteTimeout` 10 s),
   which will cut off uploads near the 700 MB limit and large downloads.

**IDS Logic**

1. `GET /illiad/{libraryId}/transactions/{transactionNumber}`, scoped to the
   calling library.
2. A per-library setting for the default bibliographic source.

**CrossLink**

1. An endpoint returning a request's BibliographicInfo and PublicationInfo.

**EMMA (Go)**

1. `POST /api/v1/deposits` and `GET /api/v1/deposits/{id}` in
   `internal/integrations/iris`.
2. A `deposits` table (id, idempotency key, library and school ids, upload id,
   state, error, timestamps).
3. The "IDS Network, IRIS" org, with review skipped in its upload workflow.

**Gateway**

1. `apps-src/emma.json`: keyed route for `/api/v1/*`, keyless for browser pages.
2. An IRIS policy allowing POST `/api/v1/deposits`, GET `/api/v1/deposits/*`,
   GET emma-index `/search`, the CrossLink bib endpoint and the Logic
   transaction endpoint.

## 5. Order of work

1. Now: IRIS items 3, 6 and 7 (fixes needed regardless of EMMA).
2. Now: IRIS items 1 and 2 with the Logic and CrossLink endpoints. This is
   also the metadata CrossLink needs from IRIS.
3. After emma-index exists (translation slice 1a): the pre-check.
4. After translation slices 5 and 6 (uploads and manifests): the EMMA deposit
   endpoint and IRIS item 5.
5. Until the deposit endpoint exists, IRIS keeps remediated files and their
   bib records, and deposits the backlog once EMMA is ready.

## 6. Open questions

1. **Who uses EMMA.** Which people get EMMA accounts to find and download
   deposited items: library ILL staff, campus disability services offices, or
   both?
2. **Missing metadata.** When neither source has a title (for example, a
   request typed in by hand), who supplies it, and where? A small form in
   MyIDS is one option.
3. **Storage before EMMA is live.** Item 5 in section 5 means keeping
   remediated files for months. Confirm the S3 bucket and retention for that
   backlog.
4. **Pre-check pricing.** If a library uses an existing EMMA copy instead of
   remediating, is there any charge?

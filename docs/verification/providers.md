# Connected providers — live verification without accounts

On 2026-10-27 (01:36–01:49 UTC) every request a connected widget sends was replayed with `curl 8.7.1`
against the real service: same URL, method, query, headers (`Accept`, the app's `User-Agent: NiceDock/1.0 (macOS)`)
and body, once with **no credential** and once with an **obviously fake one** (`sk_test_invalid`, `Bearer invalid`, …).
No account was created and no credential from this machine was used.

The captures are in `Tests/Fixtures/live-auth/<provider>-<case>-2026-10-27.txt` (request, status, kept response
headers) plus `.json` (verbatim body). Cookies, request/trace ids, CDN telemetry headers, TikTok `log_id`, Anthropic
`request_id` and one IP address in a GitHub message were removed or redacted.

`Tests/CoolDockTests/LiveAuthTests.swift` checks three things for each provider:

1. **The endpoint exists.** Our request gets an auth error (401/403, or a documented 400), not "no such route".
   Some services route before they authenticate. For those, a control request to a misspelled path proves the
   route: it gets a 404, a 406 or an edge block. Other services authenticate first and answer 401 for any path.
   For those, the evidence is a routing header, the canonical-path redirect, or the provider's published API
   description (fetched live, extract stored as `<provider>-spec-2026-10-27.json`).
2. **The app still sends that request.** The provider's real `fetch` runs with `Net.transport` replaying the
   recorded answer (`LiveReplay`). The request it produces is compared with the curl request: method, host, path,
   query names (including percent-encoding such as `created%5Bgte%5D`) and values, app-set headers and JSON body.
   Clock- and time-zone-dependent values only have to be well-formed dates. `timezone` has to be `TimeZone.current`.
3. **The widget shows the right message for the real answer.** The message comes from `ConnService.message(for:)`.
   It is checked through the full fetch path and for every capture in `liveAnswerMapsToWidgetMessage`.

Messages referred to below: **"Check your token"** (invalid or missing key → reconnect), **"Rate limited"** (retry
later), **"Not found"**, **"Add your API token"** (no key configured; no request is sent:
`missingCredentialNeverReachesTheNetwork`).

## Summary

| Provider | Live answer (no key / fake key) | Route evidence | Widget message | Fixed |
| --- | --- | --- | --- | --- |
| Stripe | 401 / 401 | control path → 404 "Unrecognized request URL" | Check your token | — |
| Polar | 401 / 401 | keyless control → 404; `/v1/metrics` → 307 to `/v1/metrics/`; OpenAPI | Check your token | — |
| Dodo Payments | 401 / 401 (live and test host) | control path blocked at edge: "not part of the … API schema" | Check your token | — |
| Shopify | 401 / 401; unknown shop 404 | CSP `report-uri` names `admin/orders#index`, `admin/shops#show` (control: `admin/errors#error_404`) | Check your token / Not found | API version 2024-10 (retired) → 2026-10 |
| Plausible | 401 / 401 | control path → 406 | Check your token | — |
| Simple Analytics | public: **200** (real data); private/unknown: 404 | n/a (real 200) | data / Add your API token / Not found | — |
| DataFast | 401 / 401 | `x-matched-path` = our route (control `/404`) | Check your token | — |
| Dub | 401 / 401 | `x-matched-path: /api/analytics` (control `/404`) | Check your token | — |
| Resend | 401 / **400** `validation_error` | OpenAPI (auth before routing) | Check your token | 400 showed "Request failed (400)" |
| GitHub GraphQL | **403 rate limit** / 401 | control path → 404 | Rate limited / Check your token | 403 + `x-ratelimit-remaining: 0` showed "Check your token" |
| Supabase | 401 / 401 | OpenAPI (auth before routing) | Check your token | — |
| Linear | 401 / 401 (`AUTHENTICATION_ERROR`) | control path → 404 "Cannot POST /graphqlz" | Check your token | — |
| X | 401 / 401 (problem+json) | control path → 404 | Check your token | — |
| TikTok | 401 / 401 (`access_token_invalid`) | control path → 404 | Check your token | — |
| YouTube | 403 / **400** `API_KEY_INVALID` | control path → 404; discovery document | Check your token | 400 showed "Request failed (400)" |
| Anthropic Admin | 401 / 401 | `/v1/organizations/` family only (other prefixes 404 before auth) | Check your token | — |
| OpenAI Admin | 401 / 401 | control path → 404; OpenAPI | Check your token | — |
| Cursor Admin API | 401 / 401 "Invalid Team API Key" | control path → 404 "Route POST:/teams/filtered-usage-eventz not found" (with and without key) | Check your token | — |
| GitHub Copilot (billing usage) | 401 "Requires authentication" / 401 "Bad credentials" (also `GET /user`) | control path → 404 with and without token; REST description | Check your token | — |
| Gemini API (Cloud Monitoring) | 401 / 401 `ACCESS_TOKEN_TYPE_UNSUPPORTED`; API key → 401 "API keys are not supported by this API" | control path → 404; error names `MetricService.ListTimeSeries`; discovery document | Check your token | — |
| Perplexity Analytics | 401 / 401 `invalid_api_key` | control path → 404 (with and without key); OpenAPI | Check your token | — |
| xAI Management API | 401 / 401 (gRPC code 16) | control paths → 404 code 5 for both the validation and the usage route | Check your token | — |
| Z.ai Coding Plan monitor | **HTTP 200** `success:false`, code 1001 / code 401 (global and China host) | none live (a misspelled path gets the same 401); path from Z.ai's own plugin source | Check your token | — (body codes mapped by `zaiCheck`) |

OpenCode and Antigravity read data on this Mac and have no endpoint (see [AI usage: local sources](#ai-usage-local-sources)).
The rows from Cursor on were captured later the same day (02:46–03:02 UTC), same method.

Happy paths (real data) were captured only where a provider has a public mode that needs no account: Simple Analytics
public sites, and the GitHub public contribution calendar and public events (re-checked live today: both 200; real
fixtures `github/contributions-*-2026-10-27.html`, `github/events-torvalds-2026-10-27.json`). Every other success
path is still covered only by documentation-schema fixtures (`Tests/Fixtures/<provider>/*-docs-*.json`): it needs
a real key. No provider in this list documents a public demo key that works without an account. The Stripe API
reference pages checked (`/api/authentication`, `/api/balance_transactions/list`) show none, so none was used.

## Code changes driven by the live answers

- **Error-body hints** (`Net.HTTPError(response:data:)` in `ConnSupport.swift`, used by `ConnHTTP.send` and `Net.data`).
  The widget message now follows what the provider says, not only the status code:
  - Resend unknown key: HTTP 400 `{"name":"validation_error","message":"API key is invalid"}` → Check your token.
    Also `missing_api_key` / `invalid_api_key` / `restricted_api_key` → Check your token, and `rate_limit_exceeded` → Rate limited.
  - Google / YouTube: `API_KEY_INVALID` / `keyInvalid` / `keyExpired` → Check your token. `quotaExceeded`,
    `rateLimitExceeded`, `userRateLimitExceeded`, `dailyLimitExceeded` (documented 403s) → Rate limited.
  - GitHub: 403 with `x-ratelimit-remaining: 0` (seen live) or with `retry-after` (secondary limit, documented) → Rate limited.
    GraphQL HTTP 200 + `errors` + `x-ratelimit-remaining: 0` (documented) → Rate limited (`ConnGitHub.parseGraphQL(rateRemaining:)`).
  - GraphQL `extensions.code`: `AUTHENTICATION_ERROR` → Check your token, `RATELIMITED` → Rate limited (Linear).
- **Shopify Admin API version**: `2024-10` → `2026-10` (`ConnShopify.apiVersion`). Shopify's versioning page lists
  2024-10 as retired. Retired versions are served by the oldest accessible stable version (2026-01 today). The
  live answers show the version isn't checked before auth: `2024-10` and a bogus `1999-01` both reach
  `admin/orders#index`. 2026-10 is the latest stable version, accessible until 2027-10-16. The REST `orders`
  resource and its `status`, `created_at_min`, `limit`, `fields` parameters are documented for 2026-10.
- **Test seam**: `Net.transport` (`@TaskLocal`, nil in the app). `ConnHTTP.send` and `Net.data` go through
  `Net.load`, so tests can replay recorded responses without touching the network.

No wrong host, path or method was found: every endpoint answered with its own auth error. The new user-facing
messages reuse existing strings ("Check your token", "Rate limited"), so translations are unchanged
(`python3 scripts/l10n.py check`: 0 missing).

## Per provider

### Stripe

| | |
| --- | --- |
| Endpoint | `GET https://api.stripe.com/v1/balance_transactions?created[gte]=<unix>&limit=100[&starting_after=<id>]`, `Authorization: Bearer` |
| Verified live | No key: 401 `error.type=invalid_request_error` "You did not provide an API key…", `www-authenticate: Basic realm="Stripe"`. Fake key: 401 "Invalid API Key provided: sk_test_***alid", `www-authenticate: Bearer realm="Stripe"`. Control `/v1/balance_transactionz` → 404 "Unrecognized request URL" with the same fake key, so Stripe routes first and 401 proves the route. Foundation sends `created%5Bgte%5D`, the same as the capture. → Check your token |
| Doc-schema only | List envelope, `has_more`/`starting_after` paging, `net`/fee/refund amounts. Needs a Stripe key |
| Fixtures | `live-auth/stripe-{nokey,invalid,control-badroute}`; docs: `stripe/balance-transactions-page{1,2}-docs` |
| Tests | `LiveAuthTests.stripe`, `liveAnswerMapsToWidgetMessage`; `StripeTests` |

### Polar

| | |
| --- | --- |
| Endpoint | `GET https://api.polar.sh/v1/metrics/?start_date&end_date&interval=hour\|day&timezone`, `Authorization: Bearer` |
| Verified live | No token: 401 `{"error":"Unauthorized"}`. Fake token: 401 `{"error":"invalid_token"}` with `www-authenticate: Bearer realm="polar", error="invalid_token"`. Header `polar-version: 2026-10`. Keyless control `/v1/metricz/` → 404 `{"detail":"Not Found"}` (with a token Polar authenticates first: 401). `/v1/metrics` without the slash → 307 to the app's `/v1/metrics/`. Published OpenAPI (`polar.sh/docs/openapi.json`): `GET /v1/metrics/` with required `start_date`, `end_date`, `interval` (enum year/month/week/day/hour) and optional `timezone`, an enum that contains every `TimeZone.knownTimeZoneIdentifiers` value on this Mac. → Check your token |
| Doc-schema only | `periods[]`/`totals` revenue fields. Needs an organization token. Sandbox tokens only work on `sandbox-api.polar.sh`, which the app doesn't call |
| Fixtures | `live-auth/polar-{nokey,invalid,noslash-nokey,control-badroute,control-badroute-nokey}`, `polar-spec`; docs: `polar/metrics-docs` |
| Tests | `LiveAuthTests.polar`; `PolarTests` |

### Dodo Payments

| | |
| --- | --- |
| Endpoint | `GET https://live.dodopayments.com/payments?created_at_gte&page_size=100&page_number=N`, `Authorization: Bearer`. On 401 the app retries the same request on `test.dodopayments.com` |
| Verified live | Both hosts, with no key and with a fake key: 401 `{"error": "Unauthorized"}`. Control `/paymentz` → 403 HTML "The endpoint you tried to reach is not part of the Dodo Payments API schema, so it was blocked at the edge", so `/payments` is in the schema. Replay: exactly two requests, live then test. → Check your token |
| Doc-schema only | `items[]` payment schema, refund status. Needs a key |
| Fixtures | `live-auth/dodo-{live-nokey,live-invalid,test-invalid,control-badroute}`; docs: `dodo/payments-docs` |
| Tests | `LiveAuthTests.dodo`; `DodoTests` |

### Shopify

| | |
| --- | --- |
| Endpoint | `GET https://<shop>.myshopify.com/admin/api/2026-10/orders.json?status=any&created_at_min&limit=250&fields=…` and `…/shop.json?fields=currency`, `X-Shopify-Access-Token` |
| Verified live | Shop `your-development-store` (the docs' example). No token and fake token: 401 `{"errors":"[API] Invalid API key or access token (unrecognized login or wrong password)"}`, `www-authenticate: Basic Realm="Shopify API Authentication"`. Shopify authenticates before routing, but the CSP `report-uri` names the handling controller: `admin/orders#index` (orders.json), `admin/shops#show` (shop.json), `admin/errors#error_404` (control `orderz.json`). Unknown shop → 404 `{"errors":"Not Found"}` → Not found. Version: see fix above. → Check your token |
| Doc-schema only | Orders schema, `Link` pagination, which version actually serves retired pins. Needs a store token |
| Fixtures | `live-auth/shopify-{devstore-nokey,devstore-invalid,devstore-shop-invalid,unknownshop-invalid,control-badroute,retired-2024-10-invalid,control-badversion}`; docs: `shopify/*-docs` |
| Tests | `LiveAuthTests.shopify`; `ShopifyTests` |

### Plausible

| | |
| --- | --- |
| Endpoint | `GET https://plausible.io/api/v1/stats/aggregate?site_id&period&metrics=visitors,pageviews` and `…/timeseries?site_id&period&metrics=visitors`, `Authorization: Bearer` |
| Verified live | No key: 401 `{"error":"Missing API key. Please use a valid Plausible API key as a Bearer Token."}`. Fake key: 401 `{"error":"Invalid API key or site ID. …"}` from both endpoints. Control `/aggregatez` → 406 `Not Acceptable`. Plausible gives the same answer for a wrong site, so that also reads Check your token |
| Doc-schema only | `results.<metric>.value` and time-series rows. The Stats API needs a key even for sites with a public dashboard. Self-hosted hosts not exercised |
| Fixtures | `live-auth/plausible-{aggregate-nokey,aggregate-invalid,timeseries-invalid,control-badroute}`; docs: `plausible/*-docs` |
| Tests | `LiveAuthTests.plausible`; `PlausibleTests` |

### Simple Analytics

| | |
| --- | --- |
| Endpoint | `GET https://simpleanalytics.com/<site>.json?version=6&fields=pageviews,visitors,histogram&start&end=today&timezone`, optional `Api-Key` |
| Verified live | **Real success** for a public site (`simpleanalytics.com`), without a key and with a fake one (the key is ignored): 3,287 visitors, 4,892 pageviews, 7 daily histogram rows 2026-10-21…27, parsed by the widget. Unknown/private site: 404 `{"ok":false,"error":"View not found"}` with or without a key → Add your API token (no key) / Not found (with key) |
| Doc-schema only | Private site with a valid key (needs an account). A wrong key and a wrong site look the same live (both 404) |
| Fixtures | `live-auth/simpleanalytics-{public-nokey,public-invalid,private-nokey,private-invalid}`; earlier real: `simpleanalytics/v6-*` |
| Tests | `LiveAuthTests.simpleAnalytics`; `SimpleAnalyticsTests` |

### DataFast

| | |
| --- | --- |
| Endpoint | `GET https://datafa.st/api/v1/analytics/overview?startAt&endAt&timezone` and `…/timeseries?…&interval&fields=visitors`, `Authorization: Bearer` |
| Verified live | No key: 401 `{"status":"error","error":{"code":401,"message":"Unauthorized: Missing or invalid Authorization header"}}`. Fake key: 401 "Unauthorized: Invalid API Key" from both. `x-matched-path` equals each route (control → `/404`, HTTP 404). The parser rejects that envelope instead of reading it as zero visitors. → Check your token |
| Doc-schema only | Overview row and time-series shape (young API, read defensively). Needs a key |
| Fixtures | `live-auth/datafast-{overview-nokey,overview-invalid,timeseries-invalid,control-badroute}`; docs: `datafast/*-docs` |
| Tests | `LiveAuthTests.dataFast`; `DataFastTests` |

### Dub

| | |
| --- | --- |
| Endpoint | `GET https://api.dub.co/analytics?event=composite&interval&timezone&groupBy=count\|timeseries`, `Authorization: Bearer` |
| Verified live | No key: 401 `{"error":{"code":"unauthorized","message":"Missing Authorization header."}}`. Fake key: 401 "Unauthorized: Invalid API key." for both `groupBy` values. `x-matched-path: /api/analytics` (control `/analyticz` → 404, `/404`). → Check your token |
| Doc-schema only | Count object and time-series rows, `saleAmount` cents. Needs a key |
| Fixtures | `live-auth/dub-{count-nokey,count-invalid,timeseries-invalid,control-badroute}`; docs: `dub/*-docs` |
| Tests | `LiveAuthTests.dub`; `DubTests` |

### Resend

| | |
| --- | --- |
| Endpoint | `GET https://api.resend.com/emails?limit=100[&after=<id>]`, `Authorization: Bearer` |
| Verified live | No key: 401 `missing_api_key`. Fake key: **400** `{"name":"validation_error","message":"API key is invalid"}` (documented on Resend's error page). Before the fix the widget showed "Request failed (400)". Now it shows Check your token. Resend authenticates before routing (the control `/emailz` gets the same 400/401). Route checked in Resend's OpenAPI (`resend/resend-openapi`): `GET /emails` (`emails/list`) with `limit`/`after`/`before` |
| Doc-schema only | Email list items and `has_more` paging. Needs a key |
| Fixtures | `live-auth/resend-{nokey,invalid,control-badroute,control-badroute-nokey}`, `resend-spec`; docs: `resend/emails-page{1,2}-docs` |
| Tests | `LiveAuthTests.resend`; `ResendTests` |

### GitHub

| | |
| --- | --- |
| Endpoint | With token: `POST https://api.github.com/graphql`, `Authorization: Bearer`, the app's `user(login:)` / `viewer` contribution query. Keyless: `GET https://github.com/users/<u>/contributions`, fallback `GET https://api.github.com/users/<u>/events` |
| Verified live | Fake token: 401 `{"message":"Bad credentials"}` for both queries (request bodies compared as JSON). Control `/graphqlz` → 404. No token: 403 "API rate limit exceeded for [IP]…" with `x-ratelimit-limit: 0`, `x-ratelimit-remaining: 0`, `x-ratelimit-resource: graphql`: GitHub's primary-rate-limit answer. Before the fix the widget showed Check your token for it. Now it shows Rate limited. Keyless calendar and events: **real 200** |
| Doc-schema only | GraphQL contribution calendar data (needs a token). Secondary-limit 403 + `retry-after` and GraphQL 200 + `errors` limits are documented, not reproduced |
| Fixtures | `live-auth/github-{graphql-user-nokey,graphql-user-invalid,graphql-viewer-invalid,control-badroute}`; real: `github/contributions-*`, `github/events-torvalds` |
| Tests | `LiveAuthTests.gitHubGraphQL`, `LiveAuthTests.gitHubRateLimit`; `GitHubTests` |

### Supabase

| | |
| --- | --- |
| Endpoint | `GET https://api.supabase.com/v1/projects/<ref>` and `…/analytics/endpoints/usage.api-counts?interval=1day`, `Authorization: Bearer` |
| Verified live | No token: 401 `{"message":"No access token provided"}`. Fake token: 401 `{"message":"JWT could not be decoded"}` from both. Supabase authenticates before routing (control `/v1/projectz/…` is 401 too). The live OpenAPI document (`api.supabase.com/api/v1-json`) lists both `GET` paths with bearer auth and `interval` enum `15min…7day` incl. `1day`. → Check your token |
| Doc-schema only | Project status/region and usage rows. Needs a personal access token |
| Fixtures | `live-auth/supabase-{project-nokey,project-invalid,usage-invalid,control-badroute,control-badroute-nokey}`, `supabase-spec`; docs: `supabase/*-docs` |
| Tests | `LiveAuthTests.supabase`; `SupabaseTests` |

### Linear

| | |
| --- | --- |
| Endpoint | `POST https://api.linear.app/graphql`, `Authorization: <api key>` (no `Bearer`), `Content-Type: application/json`, body `{"query": "query { viewer { assignedIssues(…) … } }"}` |
| Verified live | No key, fake key and fake `Bearer` token: 401 with `errors[0].extensions.code = AUTHENTICATION_ERROR`. Control `/graphqlz` → 404 "Cannot POST /graphqlz". → Check your token, both from the 401 and from the body code |
| Doc-schema only | `assignedIssues` nodes. Rate limits are HTTP 429 + `RATELIMITED` per Linear's docs (→ Rate limited). Needs a key |
| Fixtures | `live-auth/linear-{nokey,invalid,invalid-bearer,control-badroute}`; docs: `linear/assigned-issues-docs` |
| Tests | `LiveAuthTests.linear`; `LinearTests` |

### X

| | |
| --- | --- |
| Endpoint | `GET https://api.x.com/2/users/by/username/<u>?user.fields=public_metrics`, `Authorization: Bearer` |
| Verified live | No token and fake token: 401 `application/problem+json` `{"title":"Unauthorized","detail":"Unauthorized"}`. Control `/usernamez/` → 404 (empty). → Check your token |
| Doc-schema only | `data.public_metrics.followers_count`, 200 + `errors[]` for unknown names. Needs a bearer token |
| Fixtures | `live-auth/x-{nokey,invalid,control-badroute}`; docs: `x/*-docs` |
| Tests | `LiveAuthTests.x`; `XTests` |

### TikTok

| | |
| --- | --- |
| Endpoint | `GET https://open.tiktokapis.com/v2/user/info/?fields=follower_count,display_name`, `Authorization: Bearer` |
| Verified live | No token and fake token: 401 `{"data":{},"error":{"code":"access_token_invalid","message":"The access token is invalid or not found in the request."}}`. This is the envelope `parseTikTok` reads. Control `/infoz/` → 404. → Check your token |
| Doc-schema only | `data.user.follower_count`. Needs a user access token (OAuth) |
| Fixtures | `live-auth/tiktok-{nokey,invalid,control-badroute}`; docs: `tiktok/*-docs` |
| Tests | `LiveAuthTests.tikTok`; `TikTokTests` |

### YouTube Data API v3

| | |
| --- | --- |
| Endpoint | `GET https://www.googleapis.com/youtube/v3/channels?part=statistics,snippet&forHandle=@<h>\|id=UC…&key=<key>` |
| Verified live | Fake key: **400** `INVALID_ARGUMENT`, `details[].reason = API_KEY_INVALID`, `metadata.service = youtube.googleapis.com` (for both `forHandle` and `id`). Before the fix the widget showed "Request failed (400)". Now it shows Check your token. No key: 403 `PERMISSION_DENIED` → Check your token. Control `/channelz` → 404. Live discovery document: `channels.list` is `GET youtube/v3/channels`, `part` is the only required parameter, `forHandle`, `id` and the global `key` are query parameters. The document's root is `youtube.googleapis.com`. The app's `www.googleapis.com` still reaches the service, as the error metadata shows |
| Doc-schema only | Channel statistics, hidden subscriber count, `quotaExceeded` (documented 403 → now Rate limited). Needs an API key |
| Fixtures | `live-auth/youtube-{nokey,invalid,id-invalid,control-badroute}`, `youtube-spec`; docs: `youtube/channels-list-docs` |
| Tests | `LiveAuthTests.youTube`; `YouTubeTests` |

### Anthropic Admin API

| | |
| --- | --- |
| Endpoint | `GET https://api.anthropic.com/v1/organizations/usage_report/messages?starting_at&bucket_width&limit&group_by[]=model` and `…/organizations/cost_report?starting_at&bucket_width=1d&limit=31`, `x-api-key`, `anthropic-version: 2023-06-01` |
| Verified live | No key: 401 `authentication_error` "x-api-key header is required". Fake key: 401 "API key is invalid." from both endpoints, with `x-should-retry: false`. Paths outside `/v1/organizations/` (e.g. `/v1/organizationz/…`, `/v1/cooldock-no-such-route`) get 404 `not_found_error` before auth. Anything below `/v1/organizations/` authenticates first, so only the family is proven live. The optional cost report's 401 leaves the list-price estimate. → Check your token |
| Doc-schema only | Exact sub-paths, usage/cost schemas, admin key vs standard key behaviour. Needs an Admin API key |
| Fixtures | `live-auth/anthropic-{usage-nokey,usage-invalid,cost-invalid,control-badroute,control-prefix,control-toplevel}`; docs: `anthropic/*-docs` |
| Tests | `LiveAuthTests.anthropic`; `AnthropicUsageTests` |

### OpenAI Admin API

| | |
| --- | --- |
| Endpoint | `GET https://api.openai.com/v1/organization/usage/completions?start_time&bucket_width&limit&group_by=model` and `…/organization/costs?start_time&bucket_width=1d&limit=31`, `Authorization: Bearer` |
| Verified live | No key: 401 "Missing bearer or basic authentication in header". Fake key: 401 `code=invalid_api_key` from both, with `www-authenticate: Bearer realm="OpenAI API"`. Control `/usagez/completions` → 404, so OpenAI routes before auth. OpenAPI (`openai/openai-openapi`): every parameter the app sends exists, `bucket_width`/`group_by` values are in their enums, and `limit` is within the documented maximum (31 for `1d`). The optional costs 401 leaves the estimate. → Check your token |
| Doc-schema only | Usage/cost buckets. A non-admin key's answer is untested. Needs an Admin key |
| Fixtures | `live-auth/openai-{usage-nokey,usage-invalid,cost-invalid,control-badroute}`, `openai-spec`; docs: `openai/*-docs` |
| Tests | `LiveAuthTests.openAI`; `OpenAIUsageTests` |

### Cursor (Admin API)

| | |
| --- | --- |
| Endpoint | `POST https://api.cursor.com/teams/filtered-usage-events`, Basic auth (key as user name), body `{startDate, endDate, page, pageSize: 1000, email?}` (ms timestamps), up to 10 pages while `pagination.hasNextPage` |
| Why this path | Cursor documents no personal usage API: its APIs (Admin, Analytics, AI Code Tracking) are for Enterprise teams (`cursor.com/docs/api`). Cursor isn't installed on this Mac, and the `cursor-agent` CLI's local stores have no token counts. "Personal" usage = a team key plus the optional **Member Email** filter. Cost is `chargedCents`, the billed amount, so it isn't an estimate. Request-based events (no `tokenUsage`) make the tile count requests |
| Verified live | No key and fake key: 401 `{"code":"error","message":"Invalid Team API Key"}`. Control `/teams/filtered-usage-eventz` → 404 "Route POST:/teams/filtered-usage-eventz not found" with and without a key, so Cursor routes before auth. → Check your token |
| Doc-schema only | Usage events (verbatim examples of `cursor.com/docs/account/teams/admin-api`: token-based, request-based, service account). Needs an Enterprise team key |
| Fixtures | `live-auth/cursor-{usage-nokey,usage-invalid,control-badroute,control-badroute-nokey}`; docs: `cursor/usage-events-*-docs` |
| Tests | `LiveAuthAITests.cursor`; `CursorUsageTests` |

### GitHub Copilot (billing usage)

| | |
| --- | --- |
| Endpoint | `GET https://api.github.com/users/{username}/settings/billing/usage?year&month[&day]` (one call per calendar month the range touches; `day` for today), `Accept: application/vnd.github+json`, `X-GitHub-Api-Version: 2026-03-10`, `Authorization: Bearer`. An empty user name is resolved with `GET /user` |
| Why this path | GitHub's per-user billing usage report is the official per-account source for Copilot premium requests / AI credits (the Copilot metrics API is org/enterprise engagement data). Items whose product contains "Copilot" are kept: quantity, `netAmount` (billed) and `grossAmount` (list price). GitHub's docs: user-level reports need the account holder's **personal access token (classic)**; fine-grained tokens aren't supported. Only for accounts on the enhanced billing platform |
| Verified live | No token: 401 "Requires authentication". Fake token: 401 "Bad credentials" (usage and `/user`). Control `/usagez` → 404 with and without a token, so GitHub routes before auth. REST description (`github/rest-api-description`): the path and its `username`/`year`/`month`/`day` parameters, and `GET /user`. → Check your token |
| Doc-schema only | Usage items (the documented example plus Copilot items built from the documented schema). The 403 for accounts without the enhanced billing platform is untested |
| Fixtures | `live-auth/copilot-{usage-nokey,usage-invalid,user-invalid,control-badroute,control-badroute-nokey}`, `copilot-spec`; docs: `copilot/billing-usage-*-docs` |
| Tests | `LiveAuthAITests.copilot`; `CopilotUsageTests` |

### Gemini API (Cloud Monitoring)

| | |
| --- | --- |
| Endpoint | `GET https://monitoring.googleapis.com/v3/projects/{project}/timeSeries?filter=metric.type="serviceruntime.googleapis.com/api/request_count" AND resource.type="consumed_api" AND resource.labels.service="generativelanguage.googleapis.com"&interval.startTime&interval.endTime&aggregation.alignmentPeriod=3600s&aggregation.perSeriesAligner=ALIGN_DELTA&aggregation.crossSeriesReducer=REDUCE_SUM` (up to 5 pages), `Authorization: Bearer <OAuth access token>`: pasted, or from `gcloud auth print-access-token` when left empty |
| Why this path | **Gemini API keys have no usage endpoint.** Google documents usage only in the AI Studio dashboard (`ai.google.dev/gemini-api/docs/billing`). The closest official data is the key's Google Cloud project's Generative Language API request count in Cloud Monitoring, the same numbers as Cloud Console → APIs & Services → Metrics. Requests only: there are no token counts or cost (those are in the Cloud Billing export, which needs BigQuery) |
| Verified live | No token: 401 `CREDENTIALS_MISSING`. Fake `ya29.` token: 401 `ACCESS_TOKEN_TYPE_UNSUPPORTED`. A Gemini-style API key (`key=AIza…`): 401 "API keys are not supported by this API. Expected OAuth2 access token…", which is why the widget asks for OAuth. Every error names `google.monitoring.v3.MetricService.ListTimeSeries`. Control `/timeSeriez` → 404 (HTML) with and without a token. Discovery document: every parameter exists; `ALIGN_DELTA` and `REDUCE_SUM` are in their enums. → Check your token |
| Doc-schema only | `TimeSeries` response (built from the documented schema). Needs a Google Cloud project with `monitoring.read` access |
| Fixtures | `live-auth/gemini-{timeseries-nokey,timeseries-invalid,timeseries-apikey,control-badroute,control-badroute-nokey}`, `gemini-spec`; docs: `gemini/timeseries-docs` |
| Tests | `LiveAuthAITests.gemini`; `GeminiUsageTests` |

### Perplexity (Analytics API)

| | |
| --- | --- |
| Endpoint | `GET https://api.perplexity.ai/v1/analytics/computer/usage?dataset=credit_usage&start_time&bucket_width=1d\|1h&limit=31\|24[&user_email][&page]`, plus `dataset=query_volume` (organization-wide, daily) for the query count when no member is set. `Authorization: Bearer` |
| Why this path | The Sonar API has no usage endpoint (usage is in the API settings page only). The Analytics API, with an organization analytics key that an org admin generates, is Perplexity's official usage source. Only complete UTC buckets are returned, so the current hour/day shows up later |
| Verified live | No key and fake key: 401 `invalid_api_key` (credits and query volume). Control `/usagez` → 404 with and without a key, so Perplexity routes before auth. OpenAPI (`docs.perplexity.ai/openapi.json`): names, the required `dataset`/`start_time`, and the `dataset`/`bucket_width` enums. The optional query-volume 401 leaves the credit total. → Check your token |
| Doc-schema only | Credit buckets (verbatim example). Needs an Enterprise organization |
| Fixtures | `live-auth/perplexity-{credits-nokey,credits-invalid,queries-invalid,control-badroute,control-badroute-nokey}`, `perplexity-spec`; docs: `perplexity/credit-usage-docs` |
| Tests | `LiveAuthAITests.perplexity`; `PerplexityUsageTests` |

### Grok (xAI Management API)

| | |
| --- | --- |
| Endpoint | `GET https://management-api.x.ai/auth/management-keys/validation` (team id: `scopeId` of a team-scoped key, else `teamId`), then `POST https://management-api.x.ai/v1/billing/teams/{team}/usage` with `{"analyticsRequest":{"timeRange":{startTime, endTime, timezone}, "timeUnit": TIME_UNIT_DAY\|HOUR, "values":[{"name":"usd","aggregation":"AGGREGATION_SUM"}], "groupBy":[], "filters":[]}}`, `Authorization: Bearer <management key>` |
| Why this path | xAI documents team usage and spend in the Management API (`docs.x.ai/developers/rest-api-reference/management/billing`). Inference API keys can't read billing. Amounts are billed USD |
| Verified live | Validation, no key: 401 code 16 "No credentials presented". Fake key: 401 "Invalid bearer token. Please ensure you use a valid management key." (also in `www-authenticate`), and the same from the usage route (documented example team id). Controls `/validatioz` and `…/usagez` → 404 code 5 "Not Found", with and without a key, so xAI routes before auth. → Check your token |
| Doc-schema only | Validation and usage responses (verbatim examples). A user-scoped key → "Use a team management key" |
| Fixtures | `live-auth/xai-{validation-nokey,validation-invalid,usage-invalid,usage-control-badroute,control-badroute,control-badroute-nokey}`; docs: `xai/*-docs` |
| Tests | `LiveAuthAITests.xai`; `XAIUsageTests` |

### GLM / Z.ai (Coding Plan)

| | |
| --- | --- |
| Endpoint | `GET https://api.z.ai/api/monitor/usage/model-usage?startTime=yyyy-MM-dd HH:mm:ss&endTime=…` (local wall-clock times; **China** region: `open.bigmodel.cn`), `Authorization: <key>` (no `Bearer`) |
| Why this path | Z.ai's API reference and OpenAPI document no usage or billing endpoint. This is the endpoint Z.ai's own Coding Plan plugin calls (`zai-org/zai-coding-plugins`, `glm-plan-usage/…/query-usage.mjs`), with the same headers. It returns tokens per model per hour |
| Official source (checked 27 Oct 2026) | npm `@z_ai/coding-helper@0.1.1` (maintainers `bigmodel`, `yf.h`, `tomsun28`, `carbon-agent`; integrity `sha512-oMYZBiyqns0SKLz8IhZFNg6GF+fgoohHl…`) ships `zai-coding-plugins/plugins/glm-plan-usage/skills/usage-query-skill/scripts/query-usage.mjs`, which requests `${baseDomain}/api/monitor/usage/model-usage` (plus `…/tool-usage` and `…/quota/limit`) for `api.z.ai` and `open.bigmodel.cn` with `method: 'GET'`, `Authorization: <token>` (no `Bearer`) and `?startTime=…&endTime=…` formatted `yyyy-MM-dd HH:mm:ss` in local time, the window ending at the current hour's `HH:59:59`. NiceDock's request matches on every point |
| Verified live | Errors come back as **HTTP 200** envelopes: no key → `{"code":1001,"msg":"Authentication parameter not received in Header…","success":false}`. Fake key (raw, with `Bearer`, and on the China host) → `{"code":401,"msg":"token expired or incorrect","success":false}`. `ConnAIUsageAPI.zaiCheck` maps the documented codes (`docs.z.ai/api-reference/api-code`). → Check your token. **Route evidence:** a misspelled leaf under `/api/monitor/usage/` gets the same 401 (auth before routing), while an unknown prefix such as `/api/zz-nothing/here` answers `{"code":500,"msg":"404 NOT_FOUND"}`, so the `/api/monitor/usage/` service exists at the gateway; the exact leaf rests on the official package above |
| Not documented | The success schema. The fixture is a shape fixture that follows a third-party client's test data (dates moved), so only the envelope and series structure are asserted. This is the least certain API source |
| Fixtures | `live-auth/zai-{usage-nokey,usage-invalid,usage-invalid-bearer,bigmodel-invalid,control-badroute,control-badroute-nokey}`; shape: `zai/model-usage-shape` |
| Tests | `LiveAuthAITests.zai`; `ZaiUsageTests` |

### AI usage: local sources

| | OpenCode | Antigravity |
| --- | --- | --- |
| Data path | `~/.local/share/opencode/opencode.db` (also `$XDG_DATA_HOME/opencode`, channel `opencode-*.db`, `OPENCODE_DB`; `opencode.ai/docs/troubleshooting#storage`). Assistant rows of `session_message` (`type = 'assistant'`) and of the older `message` table (`role = 'assistant'`); `data` JSON `tokens{input, output, reasoning, cache{read, write}}`, `cost`. Migrated rows are in both tables and are merged by id. Pre-database installs: `storage/message/<session>/<id>.json`. Opened read-only (`SQLITE_OPEN_READONLY`, then `immutable=1`), rescanned at most every 10 min | No usage API, and the app isn't installed here. The Antigravity CLI documents a read-only `/usage` report (`antigravity.google/docs/cli/commands/usage`) and print mode with `--output-format json` (changelog). The widget runs `agy -p /usage --output-format json --print-timeout 60s`: no shell, minimal environment, failing `open`/`xdg-open`/`BROWSER` shims (a lapsed login can't open a browser), 90 s timeout, never while rendering. It shows the tightest quota bucket (remaining %, window, reset); the panel lists every bucket |
| Verified | **Real data on this Mac.** The database has 2909 rows in both tables, 5 only in `message`, 37 only in `session_message`; the legacy JSON files had already been migrated. The fixture is 75 real rows reduced to ids, times, model ids, cost and token counts (no content, prompts, paths or titles; session ids replaced), plus 4 redacted legacy files. The expected numbers come from an independent Python tally of the same rows. `cost` is OpenCode's own figure (0 for free/subscription models), shown as an estimate | **Not verified.** No CLI on this Mac, and the JSON layout isn't documented: the fixture is a shape fixture after a third-party client's synthetic payload. Errors: CLI missing → "Antigravity CLI not found"; a non-SUCCESS status that mentions sign-in → "Sign in to Antigravity" |
| Fixtures | `opencode/opencode-redacted-2026-10-27.sql`, `opencode/legacy/…` | `antigravity/usage-report-shape-2026-10-27.json` |
| Tests | `OpenCodeUsageTests` (day, dedup of migrated rows, `message`-only row with cost, legacy files, no data, read-only) | `AntigravityUsageTests` (parse only; no CLI is run in tests) |

## Not verifiable without an account

- Every keyed success response (all providers above except the Simple Analytics and GitHub public modes). These
  stay documentation-schema fixtures.
- Rate-limit answers other than GitHub's. They are mapped from the providers' documented shapes: 429 everywhere,
  YouTube `quotaExceeded`, Linear `RATELIMITED`, Resend `rate_limit_exceeded`. Provoking them live would mean
  flooding the services.
- Exact sub-path existence for Supabase, Resend and Anthropic (they authenticate before routing). The published
  OpenAPI documents stand in for Supabase and Resend. Anthropic has none, so its sub-paths rest on the documentation.
- Which Shopify version serves a request, and permission-level errors (missing scopes, non-admin keys).
- AI usage success responses for the keyed sources added on 2026-10-27. Each needs a paid team or organization
  account: Cursor Enterprise, a Perplexity Enterprise org, an xAI team, GitHub's enhanced billing platform, a Google
  Cloud project, or a Z.ai Coding Plan. Also the Z.ai response schema (the official script prints `data` without
  naming its fields) and the Antigravity CLI output (not installed here; it needs a Google account sign-in).

## Reproducing

The curl commands follow the request lines in each `.txt` fixture (`curl -g --compressed -A 'NiceDock/1.0 (macOS)'
-H 'Accept: application/json' …`). curl's `Accept-Encoding: deflate, gzip` differs from URLSession's default
(`gzip, deflate, br`), so the test ignores that header together with `Accept-Language` and `User-Agent`. The tests
check `User-Agent` against `Net.session` separately. Run `swift test --filter LiveAuthTests` (this also runs
`LiveAuthAITests`, the AI usage sources added later). The tests make no network calls.

# Connected providers — live verification without accounts

On 2026-10-27 (01:36–01:49 UTC) every request a connected widget sends was replayed with `curl 8.7.1`
against the real service: same URL, method, query, headers (`Accept`, the app's `User-Agent: CoolDock/1.0 (macOS)`)
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

## Not verifiable without an account

- Every keyed success response (all providers above except the Simple Analytics and GitHub public modes). These
  stay documentation-schema fixtures.
- Rate-limit answers other than GitHub's. They are mapped from the providers' documented shapes: 429 everywhere,
  YouTube `quotaExceeded`, Linear `RATELIMITED`, Resend `rate_limit_exceeded`. Provoking them live would mean
  flooding the services.
- Exact sub-path existence for Supabase, Resend and Anthropic (they authenticate before routing). The published
  OpenAPI documents stand in for Supabase and Resend. Anthropic has none, so its sub-paths rest on the documentation.
- Which Shopify version serves a request, and permission-level errors (missing scopes, non-admin keys).

## Reproducing

The curl commands follow the request lines in each `.txt` fixture (`curl -g --compressed -A 'CoolDock/1.0 (macOS)'
-H 'Accept: application/json' …`). curl's `Accept-Encoding: deflate, gzip` differs from URLSession's default
(`gzip, deflate, br`), so the test ignores that header together with `Accept-Language` and `User-Agent`. The tests
check `User-Agent` against `Net.session` separately. Run `swift test --filter LiveAuthTests`. The tests make no
network calls.

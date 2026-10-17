# Jira Cloud REST API reference

Companion to `scripts/jira.sh`. The script's `api` command is a generic
passthrough, so **any endpoint in this map is callable today**:

```bash
bash <skill-dir>/scripts/jira.sh api <METHOD> <path> [json-body]
# e.g.
jira.sh api GET /rest/api/3/issue/PROJ-123
jira.sh api GET "/rest/api/3/issue/PROJ-123?fields=summary,status"
jira.sh api PUT /rest/api/3/issue/PROJ-123 '{"update":{"description":["new text"]}}'
jira.sh api POST /rest/api/2/issue/PROJ-123/comment '{"body":"hi"}'
```

Base URL: `https://<JIRA_DOMAIN>.atlassian.net` — the script builds it.
Auth: HTTP Basic with `JIRA_EMAIL` (as username) and the API token.
Responses are JSON; request `fields=` explicitly on issue reads to keep
payloads small (default is a huge object).

## Conventions

- **Pagination**: `startAt` + `maxResults` on list endpoints (page = `startAt`
  increments by the number of results). `/rest/api/3/search/jql` uses
  `nextPageToken` + `isLast` instead.
- **Issue keys vs IDs**: most issue endpoints accept `PROJ-123` keys; some
  (e.g. some bulk endpoints) want numeric IDs — resolve with
  `api GET /rest/api/3/issue/PROJ-123` (`id` field).
- **Mutations**: `PUT /rest/api/3/issue/{key}` uses the `update` object
  (append/replace via `{"update":{"summary":["new"]}}`), not a plain field
  replace.
- **Errors**: `{"errorMessages":[...],"errors":{field:msg}}` plus an HTTP
  status (401 bad credentials, 403 no permission, 404 wrong id/key,
  400 malformed body).
- **Rate limits**: 429 responses carry `Retry-After`; back off, don't retry
  immediately.

## Issue resource (`/rest/api/3/issue`)

| Operation | Call |
|---|---|
| Read one | `api GET /rest/api/3/issue/PROJ-123?fields=summary,status,assignee,description` |
| Bulk read (≤ 50 keys) | `api POST /rest/api/3/issue/bulkGet` with `'{"ids":["64529","64530"]}'` |
| Create | `api POST /rest/api/3/issue '{"fields":{"project":{"key":"PROJ"},"summary":"...","issuetype":{"name":"Task"}}}'` |
| Update | `api PUT /rest/api/3/issue/PROJ-123 '{"update":{"description":["new"]}}'` |
| Delete | `api DELETE /rest/api/3/issue/PROJ-123` |
| Available transitions | `api GET /rest/api/3/issue/PROJ-123/transitions` |
| Run transition | `api POST /rest/api/3/issue/PROJ-123/transitions '{"transition":{"id":"21"}}'` (add `"fields":{"assignee":{"accountId":"..."}}` to set fields at the same time) |
| Change history | `api GET /rest/api/3/issue/PROJ-123/history` |
| Comments (list) | `api GET /rest/api/3/issue/PROJ-123/comment` |
| Comment (create) | `api POST /rest/api/2/issue/PROJ-123/comment '{"body":"..."}'` — see quirks: api/2 shape is the one verified working |
| Comment (delete) | `api DELETE /rest/api/2/issue/PROJ-123/comment/<commentId>` |
| Worklogs (list) | `api GET /rest/api/3/issue/PROJ-123/worklog?startAt=0&maxResults=50` |
| Worklog (add) | `api POST /rest/api/3/issue/PROJ-123/worklog '{"timeSpentSeconds":3600,"comment":"..."}'` |
| Attachments | `api GET /rest/api/3/issue/PROJ-123/attachments` |
| Issue links | `api GET /rest/api/3/issue/PROJ-123/issues` (blocks/is blocked by/relates) |

Create-meta (what fields/types a project allows before creating an issue):

```
api GET /rest/api/3/issue/createmeta?expand=projects.issuetypes
api GET /rest/api/3/issue/createmeta/PROJ/issuetype/10000/fields
```

## Project, version, users, meta

| Operation | Call |
|---|---|
| List projects | `api GET /rest/api/3/project?maxResults=100` (or `curated` for visible ones) |
| One project | `api GET /rest/api/3/project/PROJ?expand=lead,url,issueCounts` |
| Versions/releases | `api GET /rest/api/3/project/PROJ/version?maxResults=50` |
| Fix for version | `api GET "/rest/api/3/version/<id>/recurringissues"` / `POST` with `'{"fixVersionId":<id>}'` on an issue |
| Current user | `jira.sh myself` or `api GET /rest/api/3/myself` |
| Search users | `api GET "/rest/api/3/user/search?query=name-or-email&maxResults=20"` |
| User by id | `api GET "/rest/api/3/user?accountId=<url-encoded accountId>"` |
| Custom fields | `api GET /rest/api/3/field?updatedSince=<epochMs>` (filter by `custom:true`) |
| Server info | `api GET /rest/api/3/serverInfo` |

## Agile / boards (`/rest/agile/1.0`)

| Operation | Call |
|---|---|
| List boards | `jira.sh boards [PROJECT]` or `api GET "/rest/agile/1.0/board?maxResults=50&name=foo&type=scrumb"` |
| One board | `api GET /rest/agile/1.0/board/<id>` |
| Board columns | `api GET /rest/agile/1.0/board/<id>/column?maxResults=50` |
| Board sprints | `api GET /rest/agile/1.0/board/<id>/sprint?maxResults=50` (`&state=closed` for history) |
| Board components (epics) | `api GET /rest/agile/1.0/board/<id>/component` |
| Sprint detail | `api GET /rest/agile/1.0/sprint/<id>` |
| Sprint issues | `api GET "/rest/agile/1.0/sprint/<id>/issue?maxResults=100&fields=summary,status,assignee"` |
| Create sprint | `api POST /rest/agile/1.0/board/<boardId>/sprint '{"name":"Sprint N","startDate":"...","endDate":"..."}'` |
| Rename sprint | `api POST /rest/agile/1.0/sprint/<id>/name '{"name":"New Name"}'` |

## Search (JQL)

- `jira.sh search "<JQL>" [--limit N]` — first page.
- `jira.sh count "<JQL>"` — exact total across all pages.
- Raw: `api GET "/rest/api/3/search/jql?jql=<url-encoded JQL>&maxResults=100&fields=summary,status"`
  (cursor: `&nextPageToken=<token>`; stop on `"isLast":true`).
- Bulk POST search (for very long JQL):
  `api POST /rest/api/3/issue/search '{"jql":"...","maxResults":100,"fields":["summary","status"]}'`

JQL quick reference: `project = X AND statusCategory in (To Do, In Progress)`,
`sprint in openSprints()`, `assignee is EMPTY`, `assignee = "<accountId>"`,
`updated > -7d`, `ORDER BY updated DESC`.

## Verified quirks (tested 2026-07, real tenant)

- `/rest/api/3/search` (legacy) is **removed**; use `/rest/api/3/search/jql`.
  It returns **no total-count field** — sum via `nextPageToken` (`count` does this).
- `fields=` on `search/jql` only accepts **bare field names**; dotted names
  (`project.key`) silently yield an empty fields block.
- **Comment creation**: `POST /rest/api/2/issue/{key}/comment` with
  `{"body":"..."}` works. On the same tenant, the api/3 comment endpoint
  rejected both `{"body"}` and `{"comment"}` shapes (400). Use the api/2
  endpoint for comments.
- `boards <PROJECT>` may ignore the filter; `board <id>` is the source of
  truth for a board's project (some boards report a null location).
- `projects` can omit real projects — issue keys are ground truth.

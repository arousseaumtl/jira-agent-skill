---
name: jira-board
description: Check Jira Cloud boards and tickets, or call any Jira REST API endpoint — boards, sprints, JQL search, user lookup, and a generic api passthrough (issue CRUD, transitions, comments, worklogs, projects, versions). Use when the user asks about Jira tickets, a board's contents, sprint status, work-in-progress, JQL queries, or any Jira operation the curated commands don't cover.
---

# Jira board

Query Jira Cloud — boards via the Agile REST API, plus a generic passthrough that reaches **the entire Jira REST API** (see `references/api.md` for the endpoint map). All work goes through the bundled script — run it relative to this skill directory:

```bash
bash <skill-dir>/scripts/jira.sh <command> [args]
```

## Required environment

The script reads three variables (never hardcode credentials, never echo them):

| Variable | Meaning | Example |
|---|---|---|
| `JIRA_DOMAIN` | Your Atlassian subdomain | `acme` |
| `JIRA_EMAIL` | Jira account email | `dev@acme.com` |
| `JIRA_TOKEN` | API token (create at id.atlassian.com → Security) | `***` |

Resolution order for each variable: process environment → `.env` in the current working directory → `~/.env` (only `JIRA_*` keys are parsed from `.env` files, never sourced). If the script still can't find them it exits with the exact variables to set — relay that message to the user. Never ask them to paste the token into chat.

## Commands

- `boards [PROJECT_KEY]` — list boards, optionally for one project. This is the usual first step when the user names a board by name: find its numeric ID here.
- `projects` — list software projects (key, name, lead). Use this when a board's project key can't be resolved (some boards report a null location) and you need the key for JQL.
- `board <BOARD_ID>` — board name, type (scrum/kanban), project, location.
- `columns <BOARD_ID>` — board column layout, left→right, with the status names in each column. This is the ONLY way to see a board's columns: the legacy `GET /rest/agile/1.0/board/{id}/column` endpoint is **404 (retired)** — column layout now comes from `GET /rest/agile/1.0/board/{id}/configuration` → `.columnConfig.columns`. Simple boards with a null location have no configuration and exit 2 with a hint.
- `sprints <BOARD_ID>` — sprints on the board: active ones first, then closed (for scrum boards).
- `sprint <SPRINT_ID>` — sprint name, state, dates, goal.
- `issues <SPRINT_ID>` — all issues in a sprint: key, summary, status, assignee, priority.
- `search "<JQL>"` — arbitrary JQL search, first page (max 100), e.g. `search "project = PROJ AND sprint in openSprints()"`.
- `count "<JQL>"` — exact total of all matches, fully paginated. Use for "how many all-time" questions; `search --limit` can never see past page 1.
- `users "<name>"` — resolve a display name or email to an accountId. JQL `assignee = "<accountId>"` needs the ID; internal accounts look like `123456:uuid`, guest/external accounts carry a `qm:` prefix (count them separately).
- `issue <ISSUE_KEY>` — full detail for one issue (description, status, assignee, labels, links).
- `api <METHOD> <path> [json-body]` — call **any** Jira REST endpoint; `references/api.md` maps the common ones (issue CRUD, transitions, comments, worklogs, project/version/user endpoints, bulk search). Use it whenever the curated commands don't cover the request.
- `myself` — who is the authenticated account (useful to verify credentials).

## Typical flow

1. User names a board → `boards` (or `boards PROJ`) to resolve the board ID.
2. Scrum board → `sprints <BOARD_ID>`, pick the active sprint, then `issues <SPRINT_ID>`.
3. Kanban / "simple" board (no sprints — `sprints` exits 2 with a hint) → run `board <BOARD_ID>` first to get the project key, then `search "project = <KEY> AND statusCategory != Done ORDER BY updated DESC"`.
4. User asks about a specific ticket → `issue PROJ-123`.

## Reading results

The script prints one line per item, tab-separated **when `jq` is installed**; without it (or without `python3` for URL encoding) it emits **raw JSON instead — parse it yourself**, nothing else changes. `api` always outputs the response JSON (pretty-printed if jq is available). Summarize for the user (counts by status, unassigned work, blockers), don't just paste raw output. For `search`, add `--limit N` if the result set is large; the API caps at 100 per page.

## Mutations (use `api` carefully)

The curated commands are read-only. `api` can `POST`/`PUT`/`DELETE` — creating issues, running transitions, adding comments or worklogs, deleting — but **write methods are blocked unless the user has set `JIRA_ALLOW_WRITES=1`**. If the script reports that writes are disabled, tell the user and ask; do not retry. Before mutating: (1) confirm the exact key/action with the user, (2) prefer the smallest reversible action, (3) report what changed. Never use `api DELETE` on production data without explicit user confirmation.

## Counting "all time" (API quirks, verified 2026-07)

- The legacy `/rest/api/3/search` endpoint is **removed** — it returns an error pointing at `/rest/api/3/search/jql`. The new endpoint returns **no total-count field** (`total` and `issueCountOfQuery` are absent/null), and `maxResults` is effectively capped at 100/page. The only way to get an exact total is the `count` command, which follows `nextPageToken` until `isLast`.
- `search/jql` honors a `fields=` param, but only with **bare field names** (`project,status`). Dotted names (`project.key`) silently return issues with an empty fields block.
- Example: "how many tickets has X completed?" → `users "X"` → `count "assignee = \"<accountId>\" AND statusCategory = Done"` → then per-project `count`s to break it down.
- **Comment creation** via the passthrough: `api POST /rest/api/2/issue/{key}/comment '{"body":"..."}'` is the verified shape; the api/3 comment endpoint rejected both `body` and `comment` field names on the test tenant (2026-07).
- **Board column layout** is only available via `GET /rest/agile/1.0/board/{id}/configuration` → `.columnConfig.columns` (ordered left→right; each column lists status `{id,self}`). The old `GET /rest/agile/1.0/board/{id}/column` is 404. The `columns` command wraps this and maps status ids to names via `/rest/api/3/status`.
- **Board order / card rank is not retrievable via REST.** The `rank` field comes back `null` from `/rest/api/3/search/jql`, and there is no per-column card-listing endpoint for kanban. You can map a ticket's status to its column (via `columns`), but NOT recover the exact top-to-bottom order of cards inside a column. Sort by Priority and status stage instead.
- **A project can have no board of its own** (e.g. a support/IT project may surface only through issue keys). Don't assume "the <PROJECT> board" exists — confirm with `boards` + `board <ID>`.

## Notes

- Credentials come from the environment or a `.env` file (working directory first, then `~/.env`); existing environment values always win. `JIRA_API_TOKEN` is accepted as an alias for `JIRA_TOKEN`. Never commit credentials (`.env` is git-ignored here).
- `projects` may omit projects that genuinely exist (observed on real sites). If a project key the user names is missing there, don't stop — try `search "project = <KEY> ..."` directly; a 400/empty result is the real signal.
- `boards <PROJECT_KEY>` may ignore the filter and return all boards; confirm with `board <ID>` (some boards report a null project location).
- A project existing only through issue keys (found via a global `search "assignee is EMPTY"` or ticket prefix) is normal — the issue keys are ground truth.
- Errors print to stderr with the Jira status code — a 401 means bad credentials, 403 means the account lacks board access, 404 usually means a wrong ID (re-run `boards` to resolve).
- Hard dependencies: `bash` + `curl`. `jq` (pretty output/TSV) and `python3` (URL encoding) are optional — without them the script works identically and emits raw JSON.
- This skill is read-only by default (curated commands); `api` is the explicit mutation path — see the Mutations section.

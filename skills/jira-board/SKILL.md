---
name: jira-board
description: Check Jira Cloud boards and tickets — list boards, inspect sprints, and read issues on a specific board. Use when the user asks about Jira tickets, a board's contents, sprint status, work-in-progress, or JQL queries.
---

# Jira board

Query Jira Cloud boards via the Agile REST API. All work goes through the bundled script — run it relative to this skill directory:

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
- `sprints <BOARD_ID>` — sprints on the board: active ones first, then closed (for scrum boards).
- `sprint <SPRINT_ID>` — sprint name, state, dates, goal.
- `issues <SPRINT_ID>` — all issues in a sprint: key, summary, status, assignee, priority.
- `search "<JQL>"` — arbitrary JQL search, first page (max 100), e.g. `search "project = PROJ AND sprint in openSprints()"`.
- `count "<JQL>"` — exact total of all matches, fully paginated. Use for "how many all-time" questions; `search --limit` can never see past page 1.
- `users "<name>"` — resolve a display name or email to an accountId. JQL `assignee = "<accountId>"` needs the ID; internal accounts look like `123456:uuid`, guest/external accounts carry a `qm:` prefix (count them separately).
- `issue <ISSUE_KEY>` — full detail for one issue (description, status, assignee, labels, links).

## Typical flow

1. User names a board → `boards` (or `boards PROJ`) to resolve the board ID.
2. Scrum board → `sprints <BOARD_ID>`, pick the active sprint, then `issues <SPRINT_ID>`.
3. Kanban / "simple" board (no sprints — `sprints` exits 2 with a hint) → run `board <BOARD_ID>` first to get the project key, then `search "project = <KEY> AND statusCategory != Done ORDER BY updated DESC"`.
4. User asks about a specific ticket → `issue PROJ-123`.

## Reading results

The script prints one line per item, tab-separated. Summarize for the user (counts by status, unassigned work, blockers), don't just paste raw output. For `search`, add `--limit N` if the result set is large; the API caps at 100 per page.

## Counting "all time" (API quirks, verified 2026-07)

- The legacy `/rest/api/3/search` endpoint is **removed** — it returns an error pointing at `/rest/api/3/search/jql`. The new endpoint returns **no total-count field** (`total` and `issueCountOfQuery` are absent/null), and `maxResults` is effectively capped at 100/page. The only way to get an exact total is the `count` command, which follows `nextPageToken` until `isLast`.
- `search/jql` honors a `fields=` param, but only with **bare field names** (`project,status`). Dotted names (`project.key`) silently return issues with an empty fields block.
- Example: "how many tickets has X completed?" → `users "X"` → `count "assignee = \"<accountId>\" AND statusCategory = Done"` → then per-project `count`s to break it down.

## Notes

- Credentials come from the environment or a `.env` file (working directory first, then `~/.env`); existing environment values always win. `JIRA_API_TOKEN` is accepted as an alias for `JIRA_TOKEN`. Never commit credentials (`.env` is git-ignored here).
- `projects` may omit projects that genuinely exist (observed on real sites). If a project key the user names is missing there, don't stop — try `search "project = <KEY> ..."` directly; a 400/empty result is the real signal.
- `boards <PROJECT_KEY>` may ignore the filter and return all boards; confirm with `board <ID>` (some boards report a null project location).
- A project existing only through issue keys (found via a global `search "assignee is EMPTY"` or ticket prefix) is normal — the issue keys are ground truth.
- Errors print to stderr with the Jira status code — a 401 means bad credentials, 403 means the account lacks board access, 404 usually means a wrong ID (re-run `boards` to resolve).
- This skill is read-only: no commands create or mutate issues.

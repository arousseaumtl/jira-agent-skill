# Jira Board — Pi Skill Package

A [Pi](https://pi.dev) agent skill for querying Jira Cloud boards and tickets via the Agile + REST APIs. The curated commands are **read-only**; a generic `api` passthrough can reach any endpoint (including mutations) and the agent is instructed to confirm before writing.

## What it does

The skill teaches the agent to:

- resolve board names to numeric IDs (`boards`, `board`)
- read board column layout with status names (`columns`)
- inspect scrum sprints and their issues (`sprints`, `sprint`, `issues`)
- run arbitrary read-only JQL (`search`, and `count` for exact all-time totals)
- resolve people to accountIds for `assignee` filters (`users`)
- read full issue detail including description (`issue`)
- verify the authenticated account (`myself`)
- call any other Jira REST endpoint (`api`, e.g. comments, transitions) — the only mutation path, used with explicit confirmation

It also encodes the Jira API quirks verified against a live Cloud instance (2026-07):

- legacy `/rest/api/3/search` is **removed** — everything goes through `/rest/api/3/search/jql`
- that endpoint returns **no total-count field** and caps at 100 results/page, so `count` follows `nextPageToken` until `isLast`
- `fields=` only accepts bare field names (`project,status`); dotted names silently return empty fields
- `projects` listings can omit real project keys — a direct `search "project = KEY"` is the ground truth
- internal accountIds look like `123456:uuid`; guest/external accounts carry a `qm:` prefix

## Install

```bash
pi install /path/to/JiraExtension   # from a local checkout
pi install git:<your-repo-url>@main # if you host the repo
```

Then ask the agent things like "what's unassigned on the ACME board?" or `/skill:jira-board`.

## Configure

The skill needs three values. For each one, it is picked up from the first place it is found:

1. **Your environment** (`JIRA_DOMAIN`, `JIRA_EMAIL`, `JIRA_TOKEN`)
2. **A `.env` file in the current working directory** (wherever you launched pi)
3. **A `.env` file in your home directory** (`~/.env`)

If none of them provide a value, the script stops and prints the exact variables to set, e.g.:

```text
JIRA_DOMAIN=acme                # your Atlassian subdomain
JIRA_EMAIL=dev@acme.com         # your Jira account email
JIRA_TOKEN=***                # API token (id.atlassian.com -> Security)
```

Notes:

- `.env` files are parsed line-by-line for `JIRA_*` keys only — never sourced — and any value already in your environment wins.
- `JIRA_API_TOKEN` is accepted as an alias for `JIRA_TOKEN`.
- `.env` is git-ignored in this repo; never commit credentials.

## Commands

```text
bash skills/jira-board/scripts/jira.sh api <METHOD> <path> [json-body] # any Jira REST endpoint (mutation path)
bash skills/jira-board/scripts/jira.sh myself                          # who is authenticated

bash skills/jira-board/scripts/jira.sh boards [PROJECT_KEY]            # list boards
bash skills/jira-board/scripts/jira.sh board <BOARD_ID>                # board details
bash skills/jira-board/scripts/jira.sh columns <BOARD_ID>              # column layout, L->R, with status names
bash skills/jira-board/scripts/jira.sh sprints <BOARD_ID>              # sprints (active first)
bash skills/jira-board/scripts/jira.sh sprint <SPRINT_ID>              # sprint details
bash skills/jira-board/scripts/jira.sh issues <SPRINT_ID> [--limit N]  # issues in a sprint
bash skills/jira-board/scripts/jira.sh search "<JQL>" [--limit N]      # JQL search (first page, 100 max)
bash skills/jira-board/scripts/jira.sh count "<JQL>"                   # exact total, fully paginated
bash skills/jira-board/scripts/jira.sh users "<name>"                  # name/email -> accountId
bash skills/jira-board/scripts/jira.sh projects                        # software projects
bash skills/jira-board/scripts/jira.sh issue <ISSUE_KEY>               # full issue detail
```

Examples:

```bash
bash skills/jira-board/scripts/jira.sh count 'project = ACME AND assignee is EMPTY AND statusCategory != Done'
bash skills/jira-board/scripts/jira.sh users "Jane Doe"
bash skills/jira-board/scripts/jira.sh count 'assignee = "<accountId-from-users>" AND statusCategory = Done'
```

## Requirements

- `bash`, `curl` (hard deps); `jq` and `python3` optional — without them the script emits raw JSON
- A Jira Cloud site with an API token; `api/3` endpoints (search) plus Agile `api/1.0` (boards/sprints)
- Curated commands never call write/mutation endpoints; only `api` can

## Files

- `package.json` — Pi package manifest (`pi-package` keyword, declares the skill)
- `skills/jira-board/SKILL.md` — the skill definition (agent-facing instructions + API quirks)
- `skills/jira-board/scripts/jira.sh` — the query script (all commands)
- `skills/jira-board/references/api.md` — endpoint map for the `api` passthrough

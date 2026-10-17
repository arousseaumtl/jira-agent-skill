#!/usr/bin/env bash
# jira.sh — read-only Jira Cloud board queries.
# Env: JIRA_DOMAIN, JIRA_EMAIL, JIRA_TOKEN (required).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: jira.sh <command> [args]

  boards [PROJECT_KEY]            List boards (optionally for one project)
  board <BOARD_ID>                Board details
  sprints <BOARD_ID>              Sprints on a board (active first)
  sprint <SPRINT_ID>              Sprint details
  issues <SPRINT_ID> [--limit N]  Issues in a sprint
  search "<JQL>" [--limit N]      JQL search (first page, API caps at 100)
  count "<JQL>"                   Total matches, fully paginated (API has no total field)
  users "<name>"                  Resolve display name/email to accountId (for JQL assignee)
  projects                        List projects (key, name, lead)
  issue <ISSUE_KEY>               Full issue detail

Env: JIRA_DOMAIN (e.g. acme), JIRA_EMAIL, JIRA_TOKEN
      (env vars, or a .env in your working directory, or ~/.env)
EOF
  exit 1
}

# Accept JIRA_API_TOKEN as an alias for JIRA_TOKEN.
export JIRA_TOKEN="${JIRA_TOKEN:-${JIRA_API_TOKEN:-}}"

# Fallback: if vars are missing, look for a .env in the current directory
# (wherever pi was launched), then in $HOME. Only JIRA_* keys are read and
# existing environment values always win. Lines are parsed, never sourced.
_env_load() {
  local file="$1" line key val
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?(JIRA_DOMAIN|JIRA_EMAIL|JIRA_TOKEN|JIRA_API_TOKEN)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      key="${BASH_REMATCH[2]}"
      val="${BASH_REMATCH[3]}"
      # strip one pair of surrounding quotes, if present
      if [[ "$val" == \"*\" && ${#val} -ge 2 ]]; then val="${val#\"}"; val="${val%\"}"; fi
      if [[ "$val" == \'*\' && ${#val} -ge 2 ]]; then val="${val#\'}"; val="${val%\'}"; fi
      [[ "$key" == "JIRA_API_TOKEN" ]] && key="JIRA_TOKEN"
      [[ -n "${!key:-}" ]] || export "$key=$val"
    fi
  done < "$file"
}
_env_load "./.env"
_env_load "$HOME/.env"

for var in JIRA_DOMAIN JIRA_EMAIL JIRA_TOKEN; do
  if [[ -z "${!var:-}" ]]; then
    echo "error: $var is not set" >&2
    echo "" >&2
    echo "Set it in your environment or in a .env file in your working directory or in ~/.env, e.g.:" >&2
    echo "  JIRA_DOMAIN=acme                # your Atlassian subdomain" >&2
    echo "  JIRA_EMAIL=dev@acme.com         # your Jira account email" >&2
    echo "  JIRA_TOKEN=***                # API token (id.atlassian.com -> Security)" >&2
    exit 1
  fi
done

# Allow JIRA_DOMAIN to be a bare subdomain (acme) or full host (acme.atlassian.net).
domain="${JIRA_DOMAIN%.atlassian.net}"
BASE="https://${domain}.atlassian.net"
AUTH="-u ${JIRA_EMAIL}:${JIRA_TOKEN}"

api() { # api <path> [extra curl args...]
  local path="$1"; shift
  curl -sS --fail-with-body $AUTH "$@" "$BASE$path"
}

fmt_issues() {
  # Tab-separated: key, status, assignee, priority, summary
  # api/2 returns strings, api/3 returns objects — handle both
  jq -r '.issues[]? | [
    .key,
    (.fields.status.name // .fields.status // "unknown"),
    (.fields.assignee.displayName // .fields.assignee // "unassigned"),
    (.fields.priority.name // .fields.priority // "None"),
    (.fields.summary // "")
  ] | @tsv'
}

cmd="${1:-}"; shift || true
limit=""
case "$cmd" in
  boards)
    path="/rest/agile/1.0/board?maxResults=50"
    if [[ -n "${1:-}" ]]; then path="/rest/agile/1.0/board?projectKey=$1&maxResults=50"; fi
    api "$path" | # list endpoint omits project; `board <id>` shows it
    jq -r '.values[]? | [.id, .name, .type] | @tsv'
    ;;
  board)
    api "/rest/agile/1.0/board/$1" | jq -r '. as $b | [$b.id, $b.name, $b.type, ($b.location.projectKey // "")] | @tsv'
    ;;
  sprints)
    if ! json=$(api "/rest/agile/1.0/board/$1/sprint?maxResults=50" 2>&1); then
      echo "error: board does not support sprints (kanban/simple board) — use: jira.sh search \"project = <KEY> AND statusCategory != Done\"" >&2
      exit 2
    fi
    printf '%s' "$json" | jq -r '.values[]? | select(.state=="active" or .state=="future") | [.id, .name, .state] | @tsv'
    echo "--- closed ---"
    if ! json=$(api "/rest/agile/1.0/board/$1/sprint?state=closed&maxResults=10" 2>/dev/null); then
      echo "(no closed sprints)"; exit 0
    fi
    printf '%s' "$json" | jq -r '.values[]? | [.id, .name, .state, .endDate] | @tsv'
    ;;
  sprint)
    api "/rest/agile/1.0/sprint/$1" | jq -r '. as $s | [$s.id, $s.name, $s.state, $s.startDate, $s.endDate, ($s.goal // "")] | @tsv'
    ;;
  issues)
    shift
    sprint_id=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --limit) limit="$2"; shift 2 ;;
        *) sprint_id="$1"; shift ;;
      esac
    done
    [[ -n "$sprint_id" ]] || usage
    mr="${limit:-50}"
    api "/rest/agile/1.0/sprint/$sprint_id/issue?maxResults=$mr" | fmt_issues
    ;;
  search)
    jql="$1"; shift || true
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --limit) limit="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    [[ -n "$jql" ]] || usage
    mr="${limit:-50}"
    encoded=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$jql")
    api "/rest/api/3/search/jql?jql=${encoded}&maxResults=${mr}&fields=summary,status,assignee,priority,labels" | fmt_issues
    ;;
  count)
    jql="$1"; shift || true
    [[ -n "$jql" ]] || usage
    encoded=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$jql")
    total=0; next=""
    while :; do
      url="/rest/api/3/search/jql?jql=${encoded}&maxResults=100"
      if [[ -n "$next" ]]; then
        nextenc=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$next")
        url="${url}&nextPageToken=${nextenc}"
      fi
      json=$(api "$url")
      n=$(jq '.issues | length' <<<"$json")
      total=$((total + n))
      last=$(jq -r '.isLast // false' <<<"$json")
      next=$(jq -r '.nextPageToken // empty' <<<"$json")
      # isLast is unreliable: also stop on empty pages or missing token
      if [[ "$last" == "true" || -z "$next" || "$n" == "0" ]]; then break; fi
    done
    echo "$total"
    ;;
  users)
    q="$1"; shift || true
    [[ -n "$q" ]] || usage
    encoded=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$q")
    api "/rest/api/3/user/search?query=${encoded}&maxResults=20" \
      | jq -r '.[] | [.accountId, .displayName, (.emailAddress // "")] | @tsv'
    ;;
  projects)
    api "/rest/api/3/project?maxResults=100" \
      | jq -r '.[] | select(.projectTypeKey=="software") | [.key, .name, (.projectLead.displayName // "")] | @tsv'
    ;;
  issue)
    api "/rest/api/2/issue/$1?fields=summary,status,assignee,reporter,creator,priority,labels,issuetype,created,updated,due,sprint,description" \
      | jq -r '
        .fields as $f
        | "KEY:      \(.key)\n"
        + "SUMMARY:  \($f.summary)\n"
        + "TYPE:     \($f.issuetype.name)\n"
        + "STATUS:   \($f.status.name)\n"
        + "ASSIGNEE: \($f.assignee.displayName // $f.assignee // "unassigned")\n"
        + "PRIORITY: \($f.priority.name // "None")\n"
        + "DUE:      \($f.due // "n/a")\n"
        + "LABELS:   \((($f.labels // []) | join(", ")) | if . == "" then "none" else . end)\n"
        + "UPDATED:  \(.fields.updated)\n\n"
        + ($f.description // "(no description)" | gsub("\r"; "") | .[0:4000])'
    ;;
  *)
    usage
    ;;
esac

#!/usr/bin/env bash
# jira.sh — Jira Cloud CLI: generic REST/Agile passthrough + curated helpers.
#
# Hard dependencies: bash, curl.
# Optional: jq (pretty output / TSV), python3 (URL encoding, JSON parsing).
#          Without them the script still works — it emits raw JSON, which the
#          calling agent can parse.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: jira.sh <command> [args]

  Generic (covers the whole Jira REST spec):
    api <METHOD> <path> [json-body]   Call any endpoint, e.g.
      api GET /rest/api/3/issue/PROJ-123
      api GET "/rest/api/3/issue/PROJ-123?fields=summary,status"
      api POST /rest/api/3/issue/PROJ-123/comment '{"body":"hi"}'
      api PUT /rest/api/3/issue/PROJ-123 '{"update":{"description":["new"]}}'
      api DELETE /rest/api/3/attachment/42
    myself                            Who is the authenticated account?

  Curated:
    boards [PROJECT_KEY]              List boards (optionally for one project)
    board <BOARD_ID>                  Board details
    sprints <BOARD_ID>                Sprints (active first, then closed)
    sprint <SPRINT_ID>                Sprint details
    issues <SPRINT_ID> [--limit N]    Issues in a sprint
    search "<JQL>" [--limit N]        JQL search, first page (API caps at 100)
    count "<JQL>"                     Total matches, fully paginated (no total field in API)
    users "<name>"                    Resolve display name/email to accountId
    projects                          List software projects (key, name, lead)
    issue <ISSUE_KEY>                 Full issue detail (description, links, ...)

Output: tab-separated one-line-per-item when jq is installed, otherwise raw
JSON. `api` always outputs the raw response JSON (pretty-printed if jq exists).

Env (never hardcode, never echo): JIRA_DOMAIN, JIRA_EMAIL, JIRA_TOKEN
(resolved from environment, then ./.env, then ~/.env; JIRA_API_TOKEN aliases
JIRA_TOKEN). See references/api.md for the endpoint map.
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

HAVE_JQ=0; command -v jq >/dev/null 2>&1 && HAVE_JQ=1
HAVE_PY=0; command -v python3 >/dev/null 2>&1 && HAVE_PY=1

api() { # api <method> <path> [json-body]
  local method="$1" path="$2" body="${3:-}"
  [[ "$path" == /* ]] || path="/$path"
  local args=(-sS --fail-with-body -X "$method" $AUTH)
  [[ -n "$body" ]] && args+=(-H "Content-Type: application/json" --data "$body")
  curl "${args[@]}" "$BASE$path"
}

urlencode() {
  if [[ $HAVE_PY == 1 ]]; then
    python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1"
  else
    local s="$1" out="" c i hex
    for ((i=0; i<${#s}; i++)); do
      c="${s:i:1}"
      case "$c" in
        [a-zA-Z0-9.~_-]) out+="$c" ;;
        *) printf -v hex '%%%02X' "'$c"; out+="$hex" ;;
      esac
    done
    printf '%s' "$out"
  fi
}

pretty() { if [[ $HAVE_JQ == 1 ]]; then jq '.'; else cat; fi; }

# Extract one top-level string field from compact JSON without jq/python.
json_str() { # json_str <key> <json>
  sed -n 's/.*"'"$1"'":"\([^"]*\)".*/\1/p' <<<"$2" | head -n1
}

# Count top-level issues in a /search/jql response without jq/python.
# Each issue object starts with {"id":" (string id); Jira field objects
# (status, priority, ...) use numeric ids, so they never match.
issue_count() {
  grep -o '"id":"' <<<"$1" | wc -l | tr -d ' '
}

fmt_issues() {
  if [[ $HAVE_JQ == 1 ]]; then
    # api/2 returns strings, api/3 returns objects — handle both
    jq -r '.issues[]? | [
      .key,
      (.fields.status.name // .fields.status // "unknown"),
      (.fields.assignee.displayName // .fields.assignee // "unassigned"),
      (.fields.priority.name // .fields.priority // "None"),
      (.fields.summary // "")
    ] | @tsv'
  else
    pretty
  fi
}

cmd="${1:-}"; shift || true
limit=""
case "$cmd" in
  api)
    method="${1:-GET}"; shift || true
    path="${1:-}"; [[ -n "$path" ]] || usage
    shift || true
    body="${1:-}"
    api "$method" "$path" "$body" | pretty
    ;;
  myself)
    api GET /rest/api/3/myself | pretty
    ;;
  boards)
    path="/rest/agile/1.0/board?maxResults=50"
    if [[ -n "${1:-}" ]]; then path="/rest/agile/1.0/board?projectKey=$1&maxResults=50"; fi
    # list endpoint omits project; `board <id>` shows it
    if [[ $HAVE_JQ == 1 ]]; then
      api GET "$path" | jq -r '.values[]? | [.id, .name, .type] | @tsv'
    else
      api GET "$path" | pretty
    fi
    ;;
  board)
    json=$(api GET "/rest/agile/1.0/board/$1")
    if [[ $HAVE_JQ == 1 ]]; then
      jq -r '. as $b | [$b.id, $b.name, $b.type, ($b.location.projectKey // "")] | @tsv' <<<"$json"
    else
      pretty <<<"$json"
    fi
    ;;
  sprints)
    if ! json=$(api GET "/rest/agile/1.0/board/$1/sprint?maxResults=50" 2>&1); then
      echo "error: board does not support sprints (kanban/simple board) — use: jira.sh search \"project = <KEY> AND statusCategory != Done\"" >&2
      exit 2
    fi
    if [[ $HAVE_JQ == 1 ]]; then
      jq -r '.values[]? | select(.state=="active" or .state=="future") | [.id, .name, .state] | @tsv' <<<"$json"
      echo "--- closed ---"
      if json=$(api GET "/rest/agile/1.0/board/$1/sprint?state=closed&maxResults=10" 2>/dev/null); then
        jq -r '.values[]? | [.id, .name, .state, .endDate // ""] | @tsv' <<<"$json"
      else
        echo "(no closed sprints)"
      fi
    else
      echo "active/future + closed sprints:"
      pretty <<<"$json"
    fi
    ;;
  sprint)
    json=$(api GET "/rest/agile/1.0/sprint/$1")
    if [[ $HAVE_JQ == 1 ]]; then
      jq -r '. as $s | [$s.id, $s.name, $s.state, $s.startDate, $s.endDate, ($s.goal // "")] | @tsv' <<<"$json"
    else
      pretty <<<"$json"
    fi
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
    api GET "/rest/agile/1.0/sprint/$sprint_id/issue?maxResults=$mr" | fmt_issues
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
    encoded=$(urlencode "$jql")
    api GET "/rest/api/3/search/jql?jql=${encoded}&maxResults=${mr}&fields=summary,status,assignee,priority,labels" | fmt_issues
    ;;
  count)
    jql="$1"; shift || true
    [[ -n "$jql" ]] || usage
    encoded=$(urlencode "$jql")
    total=0; next=""
    while :; do
      url="/rest/api/3/search/jql?jql=${encoded}&maxResults=100"
      if [[ -n "$next" ]]; then
        url="${url}&nextPageToken=${next}"
      fi
      json=$(api GET "$url")
      if [[ $HAVE_JQ == 1 ]]; then
        n=$(jq '.issues | length' <<<"$json")
        last=$(jq -r '.isLast // false' <<<"$json")
        next=$(jq -r '.nextPageToken // empty' <<<"$json")
      else
        n=$(issue_count "$json")
        last="false"
        grep -q '"isLast":true' <<<"$json" && last="true"
        next=$(json_str nextPageToken "$json")
      fi
      total=$((total + n))
      # isLast is unreliable: also stop on empty pages or missing token
      if [[ "$last" == "true" || -z "$next" || "$n" == "0" ]]; then break; fi
    done
    echo "$total"
    ;;
  users)
    q="$1"; shift || true
    [[ -n "$q" ]] || usage
    encoded=$(urlencode "$q")
    json=$(api GET "/rest/api/3/user/search?query=${encoded}&maxResults=20")
    if [[ $HAVE_JQ == 1 ]]; then
      jq -r '.[] | [.accountId, .displayName, (.emailAddress // "")] | @tsv' <<<"$json"
    else
      pretty <<<"$json"
    fi
    ;;
  projects)
    json=$(api GET "/rest/api/3/project?maxResults=100")
    if [[ $HAVE_JQ == 1 ]]; then
      jq -r '.[] | select(.projectTypeKey=="software") | [.key, .name, (.projectLead.displayName // "")] | @tsv' <<<"$json"
    else
      pretty <<<"$json"
    fi
    ;;
  issue)
    json=$(api GET "/rest/api/2/issue/$1?fields=summary,status,assignee,reporter,creator,priority,labels,issuetype,created,updated,due,sprint,description")
    if [[ $HAVE_JQ == 1 ]]; then
      jq -r '
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
        + ($f.description // "(no description)" | gsub("\r"; "") | .[0:4000])' <<<"$json"
    else
      pretty <<<"$json"
    fi
    ;;
  *)
    usage
    ;;
esac

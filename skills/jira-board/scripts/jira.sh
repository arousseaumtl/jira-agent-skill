#!/usr/bin/env bash
# jira.sh — Jira Cloud CLI: generic REST/Agile passthrough + curated helpers.
#
# Hard dependencies: bash, curl.
# Optional: jq (pretty output / TSV), python3 (URL encoding, JSON parsing).
#          Without them the script still works — it emits raw JSON, which the
#          calling agent can parse.
set -euo pipefail

command -v curl >/dev/null 2>&1 || {
  echo "error: curl is a hard dependency — install it and retry" >&2
  exit 1
}

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
        (writes are OFF by default — set JIRA_ALLOW_WRITES=1 to enable)
    myself                            Who is the authenticated account?

  Curated:
    boards [PROJECT_KEY]              List boards (optionally for one project)
    board <BOARD_ID>                  Board details
    columns <BOARD_ID>                Board column layout, left->right, with status names
    sprints <BOARD_ID>                Sprints (active first, then closed)
    sprint <SPRINT_ID>                Sprint details
    issues <SPRINT_ID> [--limit N]    Issues in a sprint (all pages; --limit caps total)
    search "<JQL>" [--limit N]        JQL search, first page (API caps at 100)
    count "<JQL>"                     Total matches, fully paginated (no total field in API)
    users "<name>"                    Resolve display name/email to accountId
    projects                          List software projects (key, name, lead)
    issue <ISSUE_KEY>                 Full issue detail (description, links, ...)

Output: tab-separated one-line-per-item when jq is installed, otherwise raw
JSON. `api` always outputs the raw response JSON (pretty-printed if jq exists).

Env (never hardcode, never echo): JIRA_DOMAIN (Cloud subdomain like
`acme`, or a self-hosted host like `jira.example.com` — the script
auto-detects), JIRA_EMAIL (your username on self-hosted), JIRA_TOKEN;
JIRA_ALLOW_WRITES=1 enables api mutations; JIRA_INSECURE=1 accepts
self-signed TLS certs (some self-hosted deployments). Resolved from
environment, then ./.env, then ~/.env; JIRA_API_TOKEN aliases JIRA_TOKEN.
See references/api.md for the endpoint map.
EOF
  exit "${1:-1}"
}

# Accept JIRA_API_TOKEN as an alias for JIRA_TOKEN.
export JIRA_TOKEN="${JIRA_TOKEN:-${JIRA_API_TOKEN:-}}"

# Fallback: if vars are missing, look for a .env in the current directory
# (wherever pi was launched), then in $HOME. Only JIRA_* keys are read and
# existing environment values always win. Lines are parsed, never sourced.
_env_load() {
  local file="$1" line key val quoted
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?(JIRA_DOMAIN|JIRA_EMAIL|JIRA_TOKEN|JIRA_API_TOKEN|JIRA_ALLOW_WRITES|JIRA_INSECURE)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      key="${BASH_REMATCH[2]}"
      val="${BASH_REMATCH[3]}"
      # strip one pair of surrounding quotes, if present
      quoted=0
      if [[ "$val" == \"*\" && ${#val} -ge 2 ]]; then val="${val#\"}"; val="${val%\"}"; quoted=1; fi
      if [[ "$val" == \'*\' && ${#val} -ge 2 ]]; then val="${val#\'}"; val="${val%\'}"; quoted=1; fi
      if [[ $quoted -eq 0 ]]; then
        # unquoted: drop an inline comment (whitespace + '#') and trailing
        # padding, so README-style example lines work verbatim. A '#' with no
        # preceding whitespace stays (tokens may contain #).
        if [[ "$val" =~ ^(.*[^[:space:]])[[:space:]]+# ]]; then
          val="${BASH_REMATCH[1]}"
        fi
        val="${val%"${val##*[![:space:]]}"}"
      fi
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
    echo "  JIRA_DOMAIN=acme                # your Atlassian subdomain (Cloud)" >&2
    echo "  JIRA_DOMAIN=jira.example.com    # ...or your self-hosted Jira host" >&2
    echo "  JIRA_EMAIL=dev@acme.com         # your Jira account email" >&2
    echo "  JIRA_TOKEN=***                # API token (id.atlassian.com -> Security)" >&2
    exit 1
  fi
done

# JIRA_DOMAIN accepts one variable for every deployment; the format is detected:
#   acme                      Cloud subdomain      -> https://acme.atlassian.net
#   acme.atlassian.net        full Cloud host      -> https://acme.atlassian.net
#   https://acme.atlassian.net/   pasted URL       -> https://acme.atlassian.net
#   jira.example.com          self-hosted host     -> https://jira.example.com
#   https://jira.example.com:8443/jira  self-hosted URL -> used as-is
domain="${JIRA_DOMAIN#*://}"
domain="${domain%/}"
case "$domain" in
  *.atlassian.net) BASE="https://${domain%.atlassian.net}.atlassian.net" ;;
  *.*|*:*|*/*)     BASE="https://$domain" ;;   # has dot/port/path: self-hosted
  *)               BASE="https://${domain}.atlassian.net" ;;  # bare subdomain: Cloud
esac
HAVE_JQ=0; command -v jq >/dev/null 2>&1 && HAVE_JQ=1
HAVE_PY=0; command -v python3 >/dev/null 2>&1 && HAVE_PY=1

# --fail-with-body only exists in curl >= 8.4; older releases fall back to -f.
CURL_FAIL=(--fail-with-body)
curl --help all 2>/dev/null | grep -q -- '--fail-with-body' || CURL_FAIL=(-f)

api() { # api <method> <path> [json-body]
  # Timeouts so a hung connection cannot hang the script; HTTP 429 (Jira rate
  # limit) is retried twice with backoff; other non-2xx fails fast with the body.
  local method="$1" path="$2" body="${3:-}"
  [[ "$path" == /* ]] || path="/$path"
  method="$(printf '%s' "$method" | tr '[a-z]' '[A-Z]')"
  # Write operations (POST/PUT/PATCH/DELETE) are off by default so unattended
  # runs stay read-only. Set JIRA_ALLOW_WRITES=1 (or true) to enable mutations.
  case "$method" in
    GET|HEAD|OPTIONS) ;;
    *)
      if [[ "${JIRA_ALLOW_WRITES:-}" != "1" && "${JIRA_ALLOW_WRITES:-}" != "true" ]]; then
        echo "error: ${method} is a write operation and is disabled by default" >&2
        echo "set JIRA_ALLOW_WRITES=1 to enable mutations (see README, Configure)" >&2
        return 3
      fi ;;
  esac
  local args=(-sS "${CURL_FAIL[@]}" --connect-timeout 10 --max-time 120 -X "$method" -u "${JIRA_EMAIL}:${JIRA_TOKEN}" -w $'\n%{http_code}')
  case "${JIRA_INSECURE:-}" in 1|true) args+=(-k) ;; esac
  case "$method" in GET|HEAD|OPTIONS) args+=(-L --max-redirs 5) ;; esac
  [[ -n "$body" ]] && args+=(-H "Content-Type: application/json" --data-raw "$body")
  local out rc=0 code attempt=1
  while :; do
    out=$(curl "${args[@]}" "$BASE$path" 2>&1) || rc=$?
    code="${out##*$'\n'}"          # http code appended via -w
    out="${out%$'\n'*}"            # body, minus the code line
    if [[ "$code" == "429" && $attempt -lt 3 ]]; then
      local wait_s=$((attempt * 5))
      echo "warning: Jira rate limit (HTTP 429); retry ${attempt}/2 in ${wait_s}s" >&2
      sleep "$wait_s"
      attempt=$((attempt + 1))
      continue
    fi
    if [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then
      if [[ -n "$out" ]]; then
        printf '%s\n' "$out"
      else
        echo "HTTP $code"   # empty success body (e.g. 204) — explicit confirmation
      fi
      return 0
    fi
    if [[ "$code" == "000" ]]; then
      echo "error: could not reach ${BASE} (curl rc=${rc}) — check JIRA_DOMAIN, network/DNS, and TLS (self-signed cert? set JIRA_INSECURE=1)" >&2
    else
      echo "error: HTTP ${code:-?} for ${method} ${path}" >&2
    fi
    [[ -n "$out" ]] && printf '%s\n' "$out" >&2
    [[ "$code" == "429" ]] && echo "hint: Jira rate limit still active; wait a moment and retry" >&2
    return 22
  done
}

require_arg() { # require_arg <value> <what>
  [[ -n "$1" ]] || { echo "error: missing $2 (see: jira.sh help)" >&2; exit 1; }
}

check_limit() { # check_limit <limit>
  [[ -z "$1" || "$1" =~ ^[1-9][0-9]*$ ]] || { echo "error: --limit expects a positive integer (got: $1)" >&2; exit 1; }
}

urlencode() {
  if [[ $HAVE_PY == 1 ]]; then
    python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1"
  else
    # byte-wise iteration (C locale) so multi-byte UTF-8 encodes to correct
    # %XX sequences. urlencode is always invoked in a subshell, so the locale
    # change is confined to it.
    LC_ALL=C
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

# Count issues in a response without jq/python. Counts top-level "key":"..."
# (issue keys): quotes inside JSON string values are always escaped, and
# field objects never match (priority carries a string id, which would fake
# an "id":" count).
issue_count() {
  grep -o '"key":"' <<<"$1" | wc -l | tr -d ' '
}

fmt_issues() {
  if [[ $HAVE_JQ == 1 ]]; then
    # accepts {issues: [...]} or a bare array (the issues slicer emits the
    # latter); api/2 returns strings, api/3 returns objects — handle both.
    # Note: `.issues // .` is NOT safe on arrays (indexing an array with a
    # string errors before // applies), so branch on type explicitly.
    jq -r '(if type == "object" then (.issues // []) else . end)[]? | [
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
    resp=$(api "$method" "$path" "$body") || exit $?   # propagate gate/failure rc
    case "$resp" in
      "HTTP "[0-9]*) printf '%s\n' "$resp" ;;   # empty-body marker (e.g. 204)
      *)             printf '%s\n' "$resp" | pretty ;;
    esac
    ;;
  myself)
    api GET /rest/api/3/myself | pretty
    ;;
  boards)
    path="/rest/agile/1.0/board?maxResults=50"
    if [[ -n "${1:-}" ]]; then path="/rest/agile/1.0/board?projectKey=$1&maxResults=50"; fi
    # list endpoint omits project; `board <id>` shows it
    json=$(api GET "$path")
    if [[ $HAVE_JQ == 1 ]]; then
      if [[ $(jq '.values | length' <<<"$json") -ge 50 ]]; then
        echo "warning: 50-board page limit reached; list may be truncated" >&2
      fi
      jq -r '.values[]? | [.id, .name, .type] | @tsv' <<<"$json"
    else
      pretty <<<"$json"
    fi
    ;;
  board)
    require_arg "${1:-}" "board id"
    json=$(api GET "/rest/agile/1.0/board/$1")
    if [[ $HAVE_JQ == 1 ]]; then
      jq -r '. as $b | [$b.id, $b.name, $b.type, ($b.location.projectKey // "")] | @tsv' <<<"$json"
    else
      pretty <<<"$json"
    fi
    ;;
  columns)
    # Column layout comes from /configuration (columnConfig.columns, ordered L->R).
    # The legacy GET /rest/agile/1.0/board/{id}/column is 404 (retired) — do not use it.
    # columnConfig statuses carry only {id,self}; map ids to names via /rest/api/3/status.
    require_arg "${1:-}" "board id"
    if ! cfg=$(api GET "/rest/agile/1.0/board/$1/configuration" 2>/dev/null); then
      echo "error: no column configuration for board $1 (simple board with a null location?) — run: jira.sh board $1" >&2
      exit 2
    fi
    if [[ $HAVE_JQ == 1 ]]; then
      smap=$(api GET "/rest/api/3/status?maxResults=1000" \
        | jq -c '[to_entries[] | {key:(.value.id|tostring), value:.value.name}] | from_entries')
      jq -r --argjson smap "$smap" '
        ( (.columnConfig.columns // []) | to_entries[] )
        | .key as $i | .value as $c
        | (($i+1)|tostring) + ". " + $c.name + "  ::  "
          + ( [ $c.statuses[]? | ($smap[(.id|tostring)] // ((.id|tostring))) ] | join(", ") )
      ' <<<"$cfg"
    else
      pretty <<<"$cfg"
    fi
    ;;
  sprints)
    require_arg "${1:-}" "board id"
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
      echo "sprints (first page, raw JSON):"
      pretty <<<"$json"
    fi
    ;;
  sprint)
    require_arg "${1:-}" "sprint id"
    json=$(api GET "/rest/agile/1.0/sprint/$1")
    if [[ $HAVE_JQ == 1 ]]; then
      jq -r '. as $s | [$s.id, $s.name, $s.state, $s.startDate, $s.endDate, ($s.goal // "")] | @tsv' <<<"$json"
    else
      pretty <<<"$json"
    fi
    ;;
  issues)
    sprint_id=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --limit) [[ $# -ge 2 ]] || { echo "error: --limit needs a value" >&2; exit 1; }; limit="$2"; shift 2 ;;
        *) sprint_id="$1"; shift ;;
      esac
    done
    check_limit "$limit"
    [[ -n "$sprint_id" ]] || usage
    # The Agile API caps at 50 issues per page — paginate so large sprints are
    # not silently truncated; --limit caps the total (default: all of them).
    startAt=0; shown=0
    while :; do
      json=$(api GET "/rest/agile/1.0/sprint/$sprint_id/issue?maxResults=50&startAt=$startAt")
      if [[ $HAVE_JQ == 1 ]]; then
        n=$(jq '.issues | length' <<<"$json")
        take=$n
        if [[ -n "$limit" ]]; then
          rem=$((limit - shown))
          (( take > rem )) && take=$rem
        fi
        jq -c --argjson t "$take" '.issues[:$t]' <<<"$json" | fmt_issues
      else
        n=$(issue_count "$json")
        pretty <<<"$json"
      fi
      shown=$((shown + n))
      startAt=$((startAt + n))
      { [[ -n "$limit" && $shown -ge $limit ]] || [[ $n -lt 50 ]]; } && break
    done
    ;;
  search)
    jql="${1:-}"; shift || true
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --limit) [[ $# -ge 2 ]] || { echo "error: --limit needs a value" >&2; exit 1; }; limit="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    check_limit "$limit"
    [[ -n "$jql" ]] || usage
    mr="${limit:-50}"
    (( mr > 100 )) && mr=100   # server-side page cap
    encoded=$(urlencode "$jql")
    api GET "/rest/api/3/search/jql?jql=${encoded}&maxResults=${mr}&fields=summary,status,assignee,priority,labels" | fmt_issues
    ;;
  count)
    jql="${1:-}"; shift || true
    [[ -n "$jql" ]] || usage
    encoded=$(urlencode "$jql")
    total=0; next=""
    while :; do
      # fields=key keeps payloads minimal (the endpoint returns ids only by default)
      url="/rest/api/3/search/jql?jql=${encoded}&maxResults=100&fields=key"
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
    q="${1:-}"; shift || true
    require_arg "$q" "user name or email"
    encoded=$(urlencode "$q")
    json=$(api GET "/rest/api/3/user/search?query=${encoded}&maxResults=20")
    if [[ $HAVE_JQ == 1 ]]; then
      if [[ $(jq 'length' <<<"$json") -ge 20 ]]; then
        echo "warning: 20-result page limit reached; more matches may exist" >&2
      fi
      jq -r '.[] | [.accountId, .displayName, (.emailAddress // "")] | @tsv' <<<"$json"
    else
      pretty <<<"$json"
    fi
    ;;
  projects)
    json=$(api GET "/rest/api/3/project?maxResults=100")
    if [[ $HAVE_JQ == 1 ]]; then
      if [[ $(jq 'length' <<<"$json") -ge 100 ]]; then
        echo "warning: 100-project page limit reached; list may be truncated" >&2
      fi
      jq -r '.[] | select(.projectTypeKey=="software") | [.key, .name, (.projectLead.displayName // "")] | @tsv' <<<"$json"
    else
      pretty <<<"$json"
    fi
    ;;
  issue)
    require_arg "${1:-}" "issue key"
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
  help|-h|--help)
    usage 0
    ;;
  *)
    usage
    ;;
esac

#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  move_quartal.sh -pk PROJECT_KEY -q YYQq [--dry-run]
  move_quartal.sh --project-key PROJECT_KEY --quartal YYQq [--dry-run]

Finds the requested YYQq token in the summaries of a project's epics, creates
or reuses the corresponding epics for the following quarter, and moves every
not-Done issue from each source epic to its new epic.

Required environment variables:
  JIRA_URL                 Jira base URL, for example https://jira.example.com

Authentication (choose one):
  JIRA_TOKEN               Bearer/PAT token
  JIRA_USER and
  JIRA_API_TOKEN           Basic auth (email + API token for Jira Cloud)

Optional environment variables:
  JIRA_API_VERSION         REST API version (default: 2)
  JIRA_EPIC_ISSUE_TYPE     Epic issue type name (default: Epic)
  JIRA_EPIC_FIELD          Epic Link field id; auto-detected by default
  JIRA_EPIC_NAME_FIELD     Epic Name field id; auto-detected by default
  JIRA_PAGE_SIZE           Search page size (default: 100)
  JIRA_CACERT              Path to a CA certificate bundle
  JIRA_INSECURE=1          Disable TLS certificate verification

Options:
  -pk, --project-key KEY   Jira project key (mandatory)
  -q, --quartal YYQq       Quarter to update, for example 26Q4 (mandatory)
  --dry-run                Show changes without creating or updating issues
  -h, --help               Show this help

Examples:
  JIRA_URL=https://jira.example.com JIRA_TOKEN=... \
    ./move_quartal.sh -pk NSSF -q 26Q4 --dry-run

  JIRA_URL=https://example.atlassian.net JIRA_USER=user@example.com \
    JIRA_API_TOKEN=... ./move_quartal.sh --project-key NSSF --quartal 26Q4
EOF
}

log() {
  printf '%s\n' "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command is not installed: $1"
}

project_key=""
quartal=""
dry_run=0

while (( $# > 0 )); do
  case "$1" in
    -pk|--project-key)
      (( $# >= 2 )) || die "$1 requires a value"
      project_key="$2"
      shift 2
      ;;
    -q|--quartal)
      (( $# >= 2 )) || die "$1 requires a value"
      quartal="$2"
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1 (use --help for usage)"
      ;;
  esac
done

[[ -n "$project_key" ]] || die "Project key is mandatory; use -pk or --project-key"
[[ "$project_key" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]] || \
  die "Invalid project key: $project_key"
[[ -n "$quartal" ]] || die "Quartal is mandatory; use -q or --quartal"
[[ "$quartal" =~ ^[0-9]{2}Q[1-4]$ ]] || \
  die "Invalid quartal: $quartal (expected YYQq, for example 26Q4)"

require_command curl
require_command jq

: "${JIRA_URL:?JIRA_URL is required}"
JIRA_URL="${JIRA_URL%/}"
JIRA_API_VERSION="${JIRA_API_VERSION:-2}"
JIRA_EPIC_ISSUE_TYPE="${JIRA_EPIC_ISSUE_TYPE:-Epic}"
JIRA_PAGE_SIZE="${JIRA_PAGE_SIZE:-100}"

[[ "$JIRA_API_VERSION" =~ ^[0-9]+$ ]] || die "JIRA_API_VERSION must be numeric"
[[ "$JIRA_PAGE_SIZE" =~ ^[1-9][0-9]*$ ]] || die "JIRA_PAGE_SIZE must be positive"

curl_args=(
  --silent
  --show-error
  --connect-timeout 15
  -H 'Accept: application/json'
)

if [[ -n "${JIRA_TOKEN:-}" ]]; then
  curl_args+=( -H "Authorization: Bearer ${JIRA_TOKEN}" )
elif [[ -n "${JIRA_USER:-}" && -n "${JIRA_API_TOKEN:-}" ]]; then
  curl_args+=( --user "${JIRA_USER}:${JIRA_API_TOKEN}" )
else
  die "Set JIRA_TOKEN, or both JIRA_USER and JIRA_API_TOKEN"
fi

if [[ -n "${JIRA_CACERT:-}" ]]; then
  curl_args+=( --cacert "$JIRA_CACERT" )
fi
if [[ "${JIRA_INSECURE:-0}" == "1" ]]; then
  curl_args+=( --insecure )
fi

api() {
  local method="$1"
  local path="$2"
  local payload="${3:-}"
  local response_file http_code
  local request_args=( "${curl_args[@]}" -X "$method" )

  # Retry read-only calls only. Retrying epic creation after an ambiguous
  # network failure could create a duplicate epic.
  if [[ "$method" == "GET" || "$path" == */search ]]; then
    request_args+=( --retry 2 )
  fi

  response_file="$(mktemp "${TMPDIR:-/tmp}/move-quartal.XXXXXX")"
  if [[ -n "$payload" ]]; then
    request_args+=( -H 'Content-Type: application/json' --data "$payload" )
  fi

  if ! http_code="$(curl "${request_args[@]}" -o "$response_file" -w '%{http_code}' \
      "${JIRA_URL}${path}")"; then
    log "Jira request failed: $method $path"
    [[ ! -s "$response_file" ]] || cat "$response_file" >&2
    rm -f "$response_file"
    return 1
  fi

  if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    log "Jira returned HTTP $http_code: $method $path"
    [[ ! -s "$response_file" ]] || jq . "$response_file" >&2 2>/dev/null || cat "$response_file" >&2
    rm -f "$response_file"
    return 1
  fi

  cat "$response_file"
  rm -f "$response_file"
}

search_issues() {
  local jql="$1"
  local fields="$2"
  local start_at=0 response count total payload

  while :; do
    payload="$(jq -nc \
      --arg jql "$jql" \
      --arg fields "$fields" \
      --argjson startAt "$start_at" \
      --argjson maxResults "$JIRA_PAGE_SIZE" \
      '{
        jql: $jql,
        startAt: $startAt,
        maxResults: $maxResults,
        fields: ($fields | split(",") | map(select(length > 0)))
      }')"

    response="$(api POST "/rest/api/${JIRA_API_VERSION}/search" "$payload")"
    jq -e '.issues | type == "array"' >/dev/null <<<"$response" || \
      die "Unexpected response from Jira search API"
    jq -c '.issues[]' <<<"$response"

    count="$(jq '.issues | length' <<<"$response")"
    total="$(jq '.total // 0' <<<"$response")"
    start_at=$((start_at + count))
    (( count > 0 && start_at < total )) || break
  done
}

next_quarter() {
  local year="$1"
  local quarter="$2"
  if (( quarter == 4 )); then
    printf '%02dQ1' "$(( (year + 1) % 100 ))"
  else
    printf '%02dQ%d' "$year" "$((quarter + 1))"
  fi
}

create_epic() {
  local summary="$1"
  local payload response

  payload="$(jq -nc \
    --arg project "$project_key" \
    --arg summary "$summary" \
    --arg issueType "$JIRA_EPIC_ISSUE_TYPE" \
    '{fields: {
      project: {key: $project},
      summary: $summary,
      issuetype: {name: $issueType}
    }}')"

  if [[ -n "$epic_name_field" ]]; then
    payload="$(jq -c --arg field "$epic_name_field" --arg value "$summary" \
      '.fields[$field] = $value' <<<"$payload")"
  fi

  response="$(api POST "/rest/api/${JIRA_API_VERSION}/issue" "$payload")"
  jq -er '.key' <<<"$response"
}

move_issue() {
  local issue_key="$1"
  local new_epic_key="$2"
  local payload

  if [[ "$epic_link_field" == "parent" ]]; then
    payload="$(jq -nc --arg key "$new_epic_key" '{fields: {parent: {key: $key}}}')"
  else
    payload="$(jq -nc --arg field "$epic_link_field" --arg key "$new_epic_key" \
      '{fields: {($field): $key}}')"
  fi

  api PUT "/rest/api/${JIRA_API_VERSION}/issue/${issue_key}" "$payload" >/dev/null
}

log "Reading Jira fields..."
fields_json="$(api GET "/rest/api/${JIRA_API_VERSION}/field")"

epic_link_field="${JIRA_EPIC_FIELD:-}"
if [[ -z "$epic_link_field" ]]; then
  epic_link_field="$(jq -r '
    first(
      .[]
      | select(
          .schema.custom == "com.pyxis.greenhopper.jira:gh-epic-link"
          or ((.name | ascii_downcase) == "epic link")
        )
      | .id
    ) // empty
  ' <<<"$fields_json")"
fi

if [[ -z "$epic_link_field" ]]; then
  epic_link_field="parent"
  log "Epic Link custom field was not found; using Jira's parent field."
else
  log "Using epic field: $epic_link_field"
fi

epic_name_field="${JIRA_EPIC_NAME_FIELD:-}"
if [[ -z "$epic_name_field" ]]; then
  epic_name_field="$(jq -r '
    first(
      .[]
      | select(
          .schema.custom == "com.pyxis.greenhopper.jira:gh-epic-label"
          or ((.name | ascii_downcase) == "epic name")
        )
      | .id
    ) // empty
  ' <<<"$fields_json")"
fi

project_key="$(tr '[:lower:]' '[:upper:]' <<<"$project_key")"
project_jql="project = \"${project_key}\""
epic_type_jql="issuetype = \"${JIRA_EPIC_ISSUE_TYPE//\"/\\\"}\""

log "Reading epics from project $project_key..."
epics_jsonl="$(search_issues "${project_jql} AND ${epic_type_jql} ORDER BY key" 'summary')"
[[ -n "$epics_jsonl" ]] || die "No epics found in project $project_key"

declare -a all_epic_keys=() all_epic_summaries=()
declare -a source_keys=() target_summaries=() target_keys=()

source_year=$((10#${quartal:0:2}))
source_quarter=$((10#${quartal:3:1}))
new_token="$(next_quarter "$source_year" "$source_quarter")"
quartal_pattern="(^|[^0-9])${quartal}([^0-9]|$)"

while IFS= read -r epic; do
  [[ -n "$epic" ]] || continue
  key="$(jq -r '.key' <<<"$epic")"
  summary="$(jq -r '.fields.summary // ""' <<<"$epic")"

  all_epic_keys[${#all_epic_keys[@]}]="$key"
  all_epic_summaries[${#all_epic_summaries[@]}]="$summary"

  if [[ "$summary" =~ $quartal_pattern ]]; then
    source_keys[${#source_keys[@]}]="$key"
    target_summaries[${#target_summaries[@]}]="${summary/$quartal/$new_token}"
  fi
done <<<"$epics_jsonl"

(( ${#source_keys[@]} > 0 )) || \
  die "No epic summary in project $project_key contains quartal $quartal"

log "Source quartal: $quartal; target quartal: $new_token"
log "Matched ${#source_keys[@]} epic(s) for $quartal."

# Create or find every target epic before moving any issue. This makes a rerun
# safe after an interrupted execution and limits partially applied migrations.
for ((i = 0; i < ${#source_keys[@]}; i++)); do
  source_key="${source_keys[i]}"
  new_summary="${target_summaries[i]}"
  existing_key=""

  for ((j = 0; j < ${#all_epic_keys[@]}; j++)); do
    if [[ "${all_epic_summaries[j]}" == "$new_summary" ]]; then
      existing_key="${all_epic_keys[j]}"
      break
    fi
  done

  if [[ -n "$existing_key" ]]; then
    log "Reusing existing target epic $existing_key for $source_key: $new_summary"
    target_keys[${#target_keys[@]}]="$existing_key"
  elif (( dry_run )); then
    log "[dry-run] Would create epic for $source_key: $new_summary"
    target_keys[${#target_keys[@]}]=""
  else
    log "Creating target epic for $source_key: $new_summary"
    created_key="$(create_epic "$new_summary")"
    log "Created $created_key"
    target_keys[${#target_keys[@]}]="$created_key"
    all_epic_keys[${#all_epic_keys[@]}]="$created_key"
    all_epic_summaries[${#all_epic_summaries[@]}]="$new_summary"
  fi
done

moved_count=0
for ((i = 0; i < ${#source_keys[@]}; i++)); do
  source_key="${source_keys[i]}"
  target_key="${target_keys[i]}"

  if [[ "$epic_link_field" == "parent" ]]; then
    relation_jql="parent = \"${source_key}\""
  elif [[ "$epic_link_field" =~ ^customfield_([0-9]+)$ ]]; then
    relation_jql="cf[${BASH_REMATCH[1]}] = \"${source_key}\""
  else
    relation_jql="\"${epic_link_field//\"/\\\"}\" = \"${source_key}\""
  fi

  children_jsonl="$(search_issues \
    "${project_jql} AND ${relation_jql} AND statusCategory != Done AND status NOT IN (\"ready for test\", \"ready to check\") ORDER BY key" '')"

  if [[ -z "$children_jsonl" ]]; then
    log "No non-completed issues in $source_key"
    continue
  fi

  while IFS= read -r child; do
    [[ -n "$child" ]] || continue
    child_key="$(jq -r '.key' <<<"$child")"
    if (( dry_run )); then
      if [[ -n "$target_key" ]]; then
        target_description="$target_key"
      else
        target_description="new epic '${target_summaries[i]}'"
      fi
      log "[dry-run] Would move $child_key from $source_key to $target_description"
    else
      log "Moving $child_key: $source_key -> $target_key"
      move_issue "$child_key" "$target_key"
    fi
    moved_count=$((moved_count + 1))
  done <<<"$children_jsonl"
done

if (( dry_run )); then
  log "Dry run complete: ${#source_keys[@]} target epic(s), $moved_count issue move(s)."
else
  log "Done: ${#source_keys[@]} target epic(s), $moved_count issue(s) moved."
fi

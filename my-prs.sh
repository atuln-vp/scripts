#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [DAYS]

Show merged PRs across all repos for the authenticated GitHub user,
with per-day/per-week rates and total lines changed.

Arguments:
  DAYS    Number of days to look back (from midnight UTC).
          If omitted, defaults to since last Thursday at 10:30 AM Pacific.

Examples:
  $(basename "$0")        # since last Thursday 10:30 AM PT
  $(basename "$0") 7      # last 7 days
  $(basename "$0") 30     # last 30 days

Requires: gh (authenticated), jq, bc
EOF
  exit 0
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

AUTHOR="$(gh api user --jq '.login')"

if [ $# -ge 1 ]; then
  DAYS="$1"
  SINCE="$(date -u -v-"${DAYS}"d +%Y-%m-%dT00:00:00Z 2>/dev/null \
        || date -u -d "${DAYS} days ago" +%Y-%m-%dT00:00:00Z)"
  LABEL="last ${DAYS} day(s)"
else
  DOW="$(date +%u)" # 1=Mon … 7=Sun
  # Days since last Thursday (4). If today is Thu before 10:30 PT, use previous Thu.
  DAYS_SINCE_THU=$(( (DOW - 4 + 7) % 7 ))
  [ "${DAYS_SINCE_THU}" -eq 0 ] && DAYS_SINCE_THU=7

  LAST_THU="$(date -v-"${DAYS_SINCE_THU}"d +%Y-%m-%d 2>/dev/null \
            || date -d "${DAYS_SINCE_THU} days ago" +%Y-%m-%d)"
  SINCE="${LAST_THU}T17:30:00Z"

  # If today IS Thursday and it's past 10:30 PT (17:30 UTC), use today instead.
  if [ "${DOW}" -eq 4 ]; then
    NOW_UTC="$(date -u +%H%M)"
    if [ "${NOW_UTC}" -ge 1730 ]; then
      SINCE="$(date +%Y-%m-%d)T17:30:00Z"
      DAYS_SINCE_THU=0
    fi
  fi

  LABEL="since last Thursday 10:30 AM PT (${LAST_THU})"
fi

echo "Merged PRs by ${AUTHOR} — ${LABEL}"
echo

RESULTS="$(gh search prs \
  --author "${AUTHOR}" \
  --merged-at ">=${SINCE}" \
  --limit 1000 \
  --json number,title,updatedAt,repository,url \
  --jq 'sort_by(.updatedAt) | reverse')"

COUNT="$(echo "${RESULTS}" | jq 'length')"

if [ "${COUNT}" -eq 0 ]; then
  echo "No PRs found."
  exit 0
fi

echo "${RESULTS}" | jq -r '.[] | "  #\(.number)  \(.updatedAt[:10])  \(.repository.nameWithOwner)  \(.title)"'

# Fetch +/- lines for each PR via the GitHub API.
ADDS=0; DELS=0
while IFS=$'\t' read -r repo num; do
  STATS="$(gh api "repos/${repo}/pulls/${num}" --jq '[.additions, .deletions] | @tsv' 2>/dev/null || echo "0	0")"
  a="${STATS%%	*}"; d="${STATS##*	}"
  ADDS=$(( ADDS + a )); DELS=$(( DELS + d ))
done < <(echo "${RESULTS}" | jq -r '.[] | "\(.repository.nameWithOwner)\t\(.number)"')

SINCE_EPOCH="$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "${SINCE}" +%s 2>/dev/null \
             || date -d "${SINCE}" +%s)"
NOW_EPOCH="$(date +%s)"
ELAPSED_DAYS=$(( (NOW_EPOCH - SINCE_EPOCH) / 86400 ))
[ "${ELAPSED_DAYS}" -lt 1 ] && ELAPSED_DAYS=1
WEEKS="$(echo "scale=1; ${ELAPSED_DAYS} / 7" | bc)"
[ "$(echo "${WEEKS} < 1" | bc)" -eq 1 ] && WEEKS="1.0"
PER_WEEK="$(echo "scale=1; ${COUNT} / ${WEEKS}" | bc)"
PER_DAY="$(echo "scale=1; ${COUNT} / ${ELAPSED_DAYS}" | bc)"

echo
printf "Total: %d merged  |  %d days  |  %s PRs/day  |  %s PRs/week\n" "${COUNT}" "${ELAPSED_DAYS}" "${PER_DAY}" "${PER_WEEK}"
printf "Lines: +%s / -%s  (net %s)\n" "$(printf '%d' "${ADDS}")" "$(printf '%d' "${DELS}")" "$(printf '%+d' $(( ADDS - DELS )))"

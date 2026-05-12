#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [DAYS]

Show merged PRs across all repos for the authenticated GitHub user,
with per-day/per-week rates and total lines changed.

Arguments:
  DAYS    Number of days to look back (from midnight Pacific Time).
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

PT_TZ="America/Los_Angeles"

if [ $# -ge 1 ]; then
  DAYS="$1"
  # Midnight Pacific, N days ago, as an absolute epoch second.
  SINCE_EPOCH="$(TZ="${PT_TZ}" date -j -v-"${DAYS}"d -v0H -v0M -v0S +%s 2>/dev/null \
              || TZ="${PT_TZ}" date -d "${DAYS} days ago 00:00:00" +%s)"
  LABEL="last ${DAYS} day(s) (since midnight PT)"
else
  DOW="$(TZ="${PT_TZ}" date +%u)"   # 1=Mon … 7=Sun, in Pacific Time
  HHMM="$(TZ="${PT_TZ}" date +%H%M)" # current HHMM in Pacific Time

  # Days since last Thursday (4). If today is Thu before 10:30 PT, use previous Thu.
  DAYS_SINCE_THU=$(( (DOW - 4 + 7) % 7 ))
  if [ "${DAYS_SINCE_THU}" -eq 0 ] && [ "${HHMM}" -lt 1030 ]; then
    DAYS_SINCE_THU=7
  fi

  LAST_THU="$(TZ="${PT_TZ}" date -v-"${DAYS_SINCE_THU}"d +%Y-%m-%d 2>/dev/null \
            || TZ="${PT_TZ}" date -d "${DAYS_SINCE_THU} days ago" +%Y-%m-%d)"

  # 10:30 AM Pacific on LAST_THU, as an absolute epoch second (handles DST).
  SINCE_EPOCH="$(TZ="${PT_TZ}" date -j -f "%Y-%m-%d %H:%M:%S" "${LAST_THU} 10:30:00" +%s 2>/dev/null \
              || TZ="${PT_TZ}" date -d "${LAST_THU} 10:30:00" +%s)"

  LABEL="since last Thursday 10:30 AM PT (${LAST_THU})"
fi

# GitHub's search API takes ISO 8601; use UTC for an unambiguous query string.
SINCE="$(date -u -r "${SINCE_EPOCH}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
       || date -u -d "@${SINCE_EPOCH}" +%Y-%m-%dT%H:%M:%SZ)"

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

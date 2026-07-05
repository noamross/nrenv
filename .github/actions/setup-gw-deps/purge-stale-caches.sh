#!/usr/bin/env bash
set -euo pipefail

# purge-stale-caches.sh — delete superseded GitHub Actions caches.
#
# For each cache-key prefix passed as an argument, keep the NEWEST cache on the
# current ref and delete the older ones. Designed to run from inside the
# container job (uses curl + jq; no gh CLI needed).
#
# Safe by design: it only ever deletes caches OLDER than the newest existing
# one, so a cache is purged only after a newer one has already been uploaded on
# a previous run. That means it can run before this run's own (post-step) cache
# upload without risk — the not-yet-uploaded cache simply isn't "newest" yet.
#
# Needs: GH_TOKEN (a token with actions:write), GITHUB_REPOSITORY, GITHUB_REF.
# Degrades to a no-op (with a notice) if the token or permission is missing —
# e.g. pull requests from forks get a read-only token.

if [ -z "${GH_TOKEN:-}" ] || [ -z "${GITHUB_REPOSITORY:-}" ]; then
  echo "purge-stale-caches: no token/repository in environment; skipping."
  exit 0
fi

API="${GITHUB_API_URL:-https://api.github.com}/repos/${GITHUB_REPOSITORY}/actions/caches"
REF="${GITHUB_REF:-}"
auth=(-sS
      -H "Authorization: Bearer ${GH_TOKEN}"
      -H "Accept: application/vnd.github+json"
      -H "X-GitHub-Api-Version: 2022-11-28")

for prefix in "$@"; do
  url="${API}?key=${prefix}&per_page=100&sort=created_at&direction=desc"
  [ -n "$REF" ] && url="${url}&ref=${REF}"

  resp="$(curl "${auth[@]}" "$url" || true)"

  # A missing actions:write permission returns a message object, not a list.
  if ! jq -e '.actions_caches' >/dev/null 2>&1 <<<"$resp"; then
    echo "purge-stale-caches: cannot list caches (needs actions: write?); skipping '${prefix}'."
    continue
  fi

  # Sorted newest-first by the API; keep index 0, delete the rest.
  mapfile -t ids < <(jq -r '.actions_caches[1:][].id' <<<"$resp")
  if [ "${#ids[@]}" -eq 0 ]; then
    echo "purge-stale-caches: nothing superseded for '${prefix}'."
    continue
  fi

  echo "purge-stale-caches: deleting ${#ids[@]} superseded cache(s) for '${prefix}'."
  for id in "${ids[@]}"; do
    curl "${auth[@]}" -X DELETE "${API}/${id}" >/dev/null \
      || echo "  (failed to delete cache id ${id}; continuing)"
  done
done

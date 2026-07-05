#!/usr/bin/env bash
set -euo pipefail

# propose-sysdeps.sh — opens a PR on the nrenv repo to promote newly-detected
# system packages into apt-packages.txt (and thus into the Docker image).
#
# Called by the setup-nr-deps composite action when packages are installed at
# runtime that are not yet baked into the image.
#
# Env vars (set by action.yml):
#   GH_TOKEN      token with contents:write + pull_requests:write on the nrenv repo
#   NEW_PKGS      space-separated newly-installed package names
#   CALLING_REPO  org/repo of the calling workflow  (e.g. acme/my-analysis)
#   CALLING_SHA   commit SHA of the calling workflow run
#
# GITHUB_ACTION_REPOSITORY is set automatically by GitHub Actions to the
# owner/repo of this action (e.g. noamross/nrenv).

NEW_PKGS="${NEW_PKGS:-}"
CALLING_REPO="${CALLING_REPO:-unknown}"
CALLING_SHA="${CALLING_SHA:-unknown}"
NRENV_REPO="${GITHUB_ACTION_REPOSITORY:-}"
APT_PACKAGES_PATH="apt-packages.txt"
APT_PACKAGES_EXCLUDE_PATH="apt-packages-exclude.txt"
BRANCH_PREFIX="add-sysdeps"

if [ -z "$NEW_PKGS" ] || [ -z "$NRENV_REPO" ]; then
  echo "propose-sysdeps: missing NEW_PKGS or NRENV_REPO; skipping."
  exit 0
fi

if [ -z "${GH_TOKEN:-}" ]; then
  echo "::notice title=No nrenv token::Runtime sysdeps ($NEW_PKGS) were installed but no token is available to open a PR. Set NRENV_WRITE_TOKEN as a repo secret and expose it in your workflow: env: { NRENV_WRITE_TOKEN: \${{ secrets.NRENV_WRITE_TOKEN }} }"
  exit 0
fi

# Clone the nrenv repo into a temp directory.
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

gh repo clone "$NRENV_REPO" "$tmpdir" -- --depth 1
cd "$tmpdir"

# Build a lookup of packages excluded from PR proposals.
declare -A PKG_EXCLUDED_FROM_PR
if [ -f "$APT_PACKAGES_EXCLUDE_PATH" ]; then
  while IFS= read -r _pkg; do
    [[ "$_pkg" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${_pkg//[[:space:]]/}" ]] && continue
    PKG_EXCLUDED_FROM_PR["$_pkg"]=1
  done < "$APT_PACKAGES_EXCLUDE_PATH"
fi

# Identify packages not already listed and not excluded from PR proposals.
TRULY_NEW=()
for pkg in $NEW_PKGS; do
  [ -n "${PKG_EXCLUDED_FROM_PR[$pkg]:-}" ] && continue
  grep -qxF "$pkg" "$APT_PACKAGES_PATH" || TRULY_NEW+=("$pkg")
done

if [ "${#TRULY_NEW[@]}" -eq 0 ]; then
  echo "propose-sysdeps: all packages already listed in ${APT_PACKAGES_PATH}; no PR needed."
  exit 0
fi

# Skip if an open PR with our branch prefix already exists.
if gh pr list --repo "$NRENV_REPO" --state open --json headRefName \
    | jq -e --arg p "$BRANCH_PREFIX" 'any(.[]; .headRefName | startswith($p))' \
    >/dev/null 2>&1; then
  echo "propose-sysdeps: an open ${BRANCH_PREFIX} PR already exists; skipping."
  exit 0
fi

# Create branch, update file, push, open PR.
BRANCH="${BRANCH_PREFIX}-${GITHUB_RUN_ID:-$(date +%s)}"
git checkout -b "$BRANCH"

# Append new packages; preserve header comment lines; sort package lines.
{
  grep '^[[:space:]]*#' "$APT_PACKAGES_PATH" || true
  { grep -v '^[[:space:]]*#' "$APT_PACKAGES_PATH"; printf '%s\n' "${TRULY_NEW[@]}"; } \
    | grep -v '^[[:space:]]*$' | sort -u
} > "${APT_PACKAGES_PATH}.new"
mv "${APT_PACKAGES_PATH}.new" "$APT_PACKAGES_PATH"

git config user.email "github-actions[bot]@users.noreply.github.com"
git config user.name "github-actions[bot]"
git add "$APT_PACKAGES_PATH"
git commit -m "Add system deps to image: ${TRULY_NEW[*]}"
git push origin "$BRANCH"

PKG_LIST="${TRULY_NEW[*]}"
gh pr create \
  --repo "$NRENV_REPO" \
  --title "Add system deps to image: ${PKG_LIST}" \
  --body "$(cat <<EOF
Packages were installed at runtime during a CI run and are not yet baked into the Docker image.

**New packages:** \`${PKG_LIST}\`
**Detected in:** \`${CALLING_REPO}\` @ \`${CALLING_SHA}\`

Merge this PR and let the image rebuild (triggered automatically) to avoid the runtime install on every future CI run.
EOF
)" \
  --base main \
  --head "$BRANCH"

echo "propose-sysdeps: opened PR for: ${PKG_LIST}"

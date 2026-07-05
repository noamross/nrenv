#!/usr/bin/env bash
set -euo pipefail

# install-nr-deps.sh — driver for the setup-nr-deps composite action.
#
# Runs inside the Grant Watch CI image and:
#   1. Resolves the apt system dependencies for every package in renv.lock via
#      the Posit public sysreqs API, unions them with any caller-supplied extra
#      apt packages, dedupes, and installs ONLY those not already baked into the
#      image.
#   2. Emits the newly-installed package names as a GitHub annotation, a step
#      summary, and the step output `installed-sysdeps`, so they can be promoted
#      into the Dockerfile to speed up later CI runs.
#   3. Restores the renv project library from renv.lock with parallel installs,
#      tuned for a 2-core runner.
#
# Inputs (env, with positional-arg fallbacks for local use):
#   LOCKFILE            renv.lock path                 (arg $1, default ./renv.lock)
#   R_LIB               target R library               (arg $2, default: renv project library)
#   EXTRA_APT_PACKAGES  extra apt packages, space/newline separated   (default "")
#   UBUNTU_RELEASE      sysreqs distro release         (default: from /etc/os-release)
#   NCPUS               parallel build jobs            (default: nproc)
#
# The RENV_PATHS_CACHE default below MUST match the actions/cache `path:` entry
# in action.yml, or the cache won't be persisted.

LOCKFILE="${LOCKFILE:-${1:-./renv.lock}}"
R_LIB="${R_LIB:-${2:-}}"
EXTRA_APT_PACKAGES="${EXTRA_APT_PACKAGES:-}"
# Packages the sysreqs API may list but the image satisfies by other means, so
# they're never installed at runtime. Default: pandoc (Quarto bundles its own,
# symlinked onto PATH in the image) — otherwise rmarkdown/knitr's sysreq would
# pull ~190 MB of apt pandoc on every run.
EXCLUDE_APT_PACKAGES="${EXCLUDE_APT_PACKAGES-pandoc}"
NCPUS="${NCPUS:-$(nproc)}"

if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
fi
UBUNTU_RELEASE="${UBUNTU_RELEASE:-${VERSION_ID:-24.04}}"

export RENV_PATHS_CACHE="${RENV_PATHS_CACHE:-$HOME/.cache/R/renv}"
mkdir -p "$RENV_PATHS_CACHE"

# ---------------------------------------------------------------------------
# apt helpers
# ---------------------------------------------------------------------------
APT_UPDATED=0
apt_update_once() {
  if [ "$APT_UPDATED" -eq 0 ]; then
    apt-get update -qq
    APT_UPDATED=1
  fi
}

# A package counts as present if it's installed OR provided (virtually) by an
# installed package. The Provides check matters for renamed/transitional names
# the sysreqs API still returns — e.g. noble ships `libfreetype-dev`, which
# Provides `libfreetype6-dev`; a plain dpkg check would miss it and reinstall
# (paying for an apt-get update) on every single run.
declare -A PKG_SATISFIED
while IFS='|' read -r _status _pkg _provides; do
  [[ "$_status" == ii* ]] || continue
  PKG_SATISFIED["$_pkg"]=1
  if [ -n "$_provides" ]; then
    IFS=',' read -ra _provs <<< "$_provides"
    for _pr in "${_provs[@]}"; do
      _pr="${_pr%%(*}"   # drop "(= version)"
      _pr="${_pr// /}"   # drop whitespace
      [ -n "$_pr" ] && PKG_SATISFIED["$_pr"]=1
    done
  fi
done < <(dpkg-query -W -f='${db:Status-Abbrev}|${Package}|${Provides}\n' 2>/dev/null || true)

pkg_installed() {
  [ -n "${PKG_SATISFIED[$1]:-}" ]
}

# Skip docs/man/locales to speed up any runtime apt installs.
mkdir -p /etc/dpkg/dpkg.cfg.d
cat > /etc/dpkg/dpkg.cfg.d/01-nodoc <<'EOF'
path-exclude /usr/share/doc/*
path-exclude /usr/share/man/*
path-exclude /usr/share/locale/*
path-exclude /usr/share/info/*
EOF

# Make sure the tools this script needs are present (no-ops if already in image).
ENSURE=()
command -v curl >/dev/null 2>&1 || ENSURE+=(curl)
command -v jq   >/dev/null 2>&1 || ENSURE+=(jq)
pkg_installed ca-certificates   || ENSURE+=(ca-certificates)
if [ "${#ENSURE[@]}" -gt 0 ]; then
  apt_update_once
  apt-get install -y --no-install-recommends "${ENSURE[@]}"
fi

# ---------------------------------------------------------------------------
# 1. Resolve + install system dependencies
# ---------------------------------------------------------------------------
echo "Resolving system dependencies from ${LOCKFILE} (ubuntu ${UBUNTU_RELEASE})…"

mapfile -t RPKGS < <(jq -r '.Packages | keys[]' "$LOCKFILE")

QUERY=""
for p in "${RPKGS[@]}"; do
  QUERY="${QUERY}&pkgname=${p}"
done

# Query the Posit public sysreqs API for the apt packages those R packages need.
SYSREQS="$(curl -sf \
  "https://packagemanager.posit.co/__api__/repos/1/sysreqs?distribution=ubuntu&release=${UBUNTU_RELEASE}${QUERY}" \
  | jq -r '[.requirements[].requirements.packages[]] | .[]' || true)"

# Union sysreqs with caller-provided extras, then dedupe.
mapfile -t NEEDED < <(printf '%s\n%s\n' "$SYSREQS" "$EXTRA_APT_PACKAGES" \
  | tr ' ' '\n' | sed '/^[[:space:]]*$/d' | sort -u)

# Packages satisfied by other means in the image — never install these.
declare -A PKG_EXCLUDED
for _x in $EXCLUDE_APT_PACKAGES; do PKG_EXCLUDED["$_x"]=1; done

# Keep only packages that aren't excluded and aren't already in the image.
MISSING=()
for p in "${NEEDED[@]}"; do
  [ -n "${PKG_EXCLUDED[$p]:-}" ] && continue
  pkg_installed "$p" || MISSING+=("$p")
done

if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "Installing ${#MISSING[@]} system package(s) on top of the image: ${MISSING[*]}"
  apt_update_once
  apt-get install -y --no-install-recommends "${MISSING[@]}"

  list="${MISSING[*]}"
  # Annotation — visible at the top of the run.
  echo "::warning title=System packages installed on top of the image::Add these to the Dockerfile to speed up CI: ${list}"
  # Step summary — a copy/paste-ready Dockerfile snippet.
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "### 🧱 System packages installed on top of the image"
      echo
      echo "These weren't in the image and were installed at runtime. Promote them into \`Dockerfile\` to speed up future CI runs:"
      echo
      echo '```dockerfile'
      printf '      %s \\\n' "${MISSING[@]}"
      echo '```'
    } >> "$GITHUB_STEP_SUMMARY"
  fi
  # Step output — for downstream automation.
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "installed-sysdeps=${list}" >> "$GITHUB_OUTPUT"
  fi
else
  echo "All required system packages are already present in the image. 🎉"
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "installed-sysdeps=" >> "$GITHUB_OUTPUT"
fi

# ---------------------------------------------------------------------------
# 2. Restore R packages from renv.lock (parallel, tuned for 2 cores)
# ---------------------------------------------------------------------------
LIB_ARG=""
[ -n "$R_LIB" ] && LIB_ARG="library = '${R_LIB}', "

# Ncpus / install.jobs -> renv installs packages in parallel. Most arrive as
#   pre-built binaries from the P3M repo baked into the image, so this is
#   download/link-bound rather than CPU-bound — a clear win even on 2 cores.
# MAKEFLAGS -> within-package compile parallelism for the few packages that do
#   build from source.
#
# CRAN source fallback: P3M's "latest" snapshot can lag CRAN, so a version
# pinned in renv.lock may have no P3M binary AND not resolve from P3M at all
# (e.g. s2 1.1.11). We try binaries first (fast); if that fails, we retry with
# the PPM binary path disabled, so renv resolves those packages from the CRAN
# source repo and builds them from source. Only the still-missing packages get
# rebuilt — everything installed on the first pass is left as-is.
RESTORE_OPTS="options(Ncpus = ${NCPUS}, renv.config.install.jobs = ${NCPUS}, renv.config.install.sysreqs = FALSE); Sys.setenv(MAKEFLAGS = '-j${NCPUS}')"
RESTORE_CALL="renv::restore(lockfile = '${LOCKFILE}', ${LIB_ARG}prompt = FALSE, clean = TRUE)"

# Attempt 1: P3M binaries (fast path).
if Rscript -e "${RESTORE_OPTS}; ${RESTORE_CALL}"; then
  echo "renv::restore completed using P3M binaries."
else
  # Each fallback runs in a FRESH R process: renv memoizes config on first use,
  # so changes to options in the same session that already ran a restore have no
  # effect. Set options (not env vars): the image's Rprofile.site configures
  # repos, and renv reads renv.config.* options in preference to env vars.

  # Attempt 2: PPM still enabled (so renv rewrites P3M URLs to the correct
  # binary path), but add plain CRAN as a secondary repo so versions not yet in
  # the P3M snapshot can still be resolved. Binaries are preferred where P3M
  # has them; packages only on CRAN will be downloaded as source.
  echo "renv::restore with P3M binaries failed — retrying with CRAN as secondary repo."
  if Rscript -e "options(renv.config.ppm.enabled = TRUE, renv.config.repos.override = c(PPM = 'https://p3m.dev/cran/latest', CRAN = 'https://cran.r-project.org')); ${RESTORE_OPTS}; ${RESTORE_CALL}"; then
    echo "renv::restore completed (P3M binaries + CRAN fallback)."
  else
    # Attempt 3: PPM disabled so renv resolves exact pinned versions against
    # the plain CRAN PACKAGES index and falls through to the CRAN archive for
    # versions that have been superseded. Everything installs from source, but
    # any version in the lockfile is reachable.
    echo "Retrying with PPM disabled so pinned versions resolve from CRAN archive."
    Rscript -e "options(renv.config.ppm.enabled = FALSE, renv.config.repos.override = c(PPM = 'https://cran.r-project.org', CRAN = 'https://cran.r-project.org')); ${RESTORE_OPTS}; ${RESTORE_CALL}"
  fi
fi

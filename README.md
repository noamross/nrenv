# brenv — A relatively fast R CI environment

The repo contains a setup for relatively fast R installs across GW repos.
It builds a Docker image and and has a GitHub Actions composite action for Grant Watch CI jobs.
The image bundles R, Quarto, and system libraries.
The action, used in a repo action step, does more efficient and robust caching of R libraries than the standard `r-lib` options, using `renv`.
The action uses the Posit API to detect any system dependencies not yet in the image and installs them before package installation, as `pak` does.

If you have set `NRENV_WRITE_TOKEN` in your repo, on detecting new system dependencies, the action will open a PR in this repo to add them to the base image.
Overall this setup generally has ~1 minute startup time.

## Using the image and action

Copy `.github/workflows/example-ci.yml` from this repo into your repo as a
starting point. The essentials:

```yaml
permissions:
  contents: read
  packages: read   # pull image from GHCR
  actions: write   # lets the action purge stale renv caches

env:
  NRENV_WRITE_TOKEN: ${{ secrets.NRENV_WRITE_TOKEN }} # Optional, see below

jobs:
  ci:
    runs-on: ubuntu-latest
    container:
      image: ghcr.io/noamross/nrenv/gwimg:latest  # Your action runs in this image
      credentials:
        username: ${{ github.actor }}
        password: ${{ secrets.GITHUB_TOKEN }}
    steps:
      - uses: actions/checkout@v6

      - uses: noamross/nrenv/.github/actions/setup-gw-deps@main # This does your setup based on your renv.lock
        with:
          exclude-apt-packages: pandoc # packages you don't want to trigger warnings/PRs over

      # your steps here — R, Quarto, etc. are ready
```

### One-time repo setup

Create a repo secret named `NRENV_WRITE_TOKEN` containing a fine-grained PAT
scoped to **this repo** (`noamross/nrenv`) with **Contents: Read and write**
and **Pull requests: Read and write**. Without it the action still works but
won't open PRs for new system dependencies.

## How new system dependencies get promoted

When the action installs a system package at runtime (i.e. one needed by your
`renv.lock` but not yet in the image), it:

1. Emits a warning annotation on the run.
2. Opens a PR on this repo adding the package to [`apt-packages.txt`](apt-packages.txt).

Merge the PR and the next image build picks it up automatically.

To suppress a package from ever triggering a PR just from your repo, set action parameter `exclude-apt-packages:`

To suppress a package from triggering a PR from _any_ repo, add it to [`apt-packages-exclude.txt`](apt-packages-exclude.txt) here.

## Caching Quarto's `_freeze` (and other build outputs)

The action caches the renv source cache and project library keyed on
`renv.lock`, so they only re-save when dependencies change. The `cache-dirs`
input handles directories that change with your _content_ rather than your
dependencies — the canonical case being Quarto's `_freeze`, which stores chunk
execution results so unchanged documents skip re-running R.

These directories use a rolling strategy: each run restores the most recent
cache, your checkout and build steps overwrite/update it, and a fresh cache is
saved at the end of the job (older ones are purged). Because the cache carries
`_freeze` between runs, you don't have to commit it.

The [`example/`](example/) directory is a tiny Quarto project demonstrating
this, wired up in [`example-ci.yml`](.github/workflows/example-ci.yml):

```yaml
- uses: noamross/nrenv/.github/actions/setup-gw-deps@main
  with:
    cache-dirs: example/_freeze   # one path per line for multiple
```

## Updating the image

The image rebuilds automatically on any push to `main` that changes
`Dockerfile` or `apt-packages.txt`. To add or remove system packages, edit
[`apt-packages.txt`](apt-packages.txt) directly — don't edit the `Dockerfile`.
To upgrade Quarto, bump `QUARTO_VERSION` in the `Dockerfile`.

## Action inputs

| Input | Default | Description |
|---|---|---|
| `lockfile` | `renv.lock` | Path to renv.lock relative to the workspace |
| `extra-apt-packages` | — | Extra apt packages beyond the renv.lock sysreqs |
| `exclude-apt-packages` | `pandoc` | Packages the sysreqs API lists but the image already satisfies |
| `cache-dirs` | — | Extra directories to cache with a rolling, most-recent-wins strategy (one path per line), e.g. Quarto's `_freeze` |
| `cache-key-prefix` | `gw-v1` | Bump to invalidate all caches |
| `purge-stale-caches` | `true` | Delete superseded caches (needs `actions: write`) |
| `nrenv-token` | — | Override token for opening sysdep PRs (defaults to `NRENV_WRITE_TOKEN` env var) |

**Output:** `installed-sysdeps` — space-separated list of packages installed at
runtime; empty if none.

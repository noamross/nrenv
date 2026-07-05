# Load env vars from any file starting with `.env`. This allows user-specific
# options to be set in `.env_user` (which is .gitignored), and to have both
# encrypted and non-encrypted .env files
load_env <- function() {
  for (f in list.files(
    pattern = "^\\.env",
    all.files = TRUE,
    full.names = TRUE
  )) {
    try(readRenviron(f), silent = TRUE)
  }
}

is_targets <- Sys.getenv("TAR_ACTIVE") == "true"
is_interactive <- interactive()
sys <- Sys.info()[["sysname"]]

options(
  repos = c(
    PPM = "https://p3m.dev/all/latest",
    CRAN = "https://cran.rstudio.com/"
  ),

  # conflicts.policy = list(
  #   "depends.ok" = TRUE,
  #   can.mask = c("stats", "tools", "utils", "graphics", "grDevices")
  # ),

  warn = if (is_targets) 1 else 0, # Show warnings as they occur during targets runs, but not interactively,
  renv.config.startup.quiet = !is_interactive, # Suppress renv startup messages in non-interactive sessions (e.g. targets runs)
  renv.config.synchronized.check = !is_targets,
  renv.config.sysreqs.check = !is_targets,
  renv.config.activate.prompt = is_interactive,

  renv.config.user.environ = FALSE,
  renv.config.auto.snapshot = FALSE, ## Attempt to keep renv.lock updated automatically
  renv.config.rspm.enabled = TRUE, ## Use RStudio Package manager for pre-built package binaries
  renv.config.install.shortcuts = TRUE, ## Use the existing local library to fetch copies of packages for renv
  renv.config.cache.enabled = TRUE, ## Use the renv build cache to speed up install times

  # Since RSPM does not provide Mac binaries, always install packages from CRAN
  # on Mac or Windows, and from RSPM on Linux, even if renv.lock specifies otherwise
  renv.config.repos.override = if (sys %in% c("Darwin", "Windows")) {
    c(CRAN = "https://cran.rstudio.com/")
  } else if (sys == "Linux") {
    c(PPM = "https://p3m.dev/all/latest")
  }
)

source("renv/activate.R")
load_env()

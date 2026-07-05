FROM rocker/r-ver:4.6.0

# dpkg: skip docs/man/locale for everything we install.
RUN mkdir -p /etc/dpkg/dpkg.cfg.d && \
    printf '%s\n' \
      'path-exclude /usr/share/doc/*' \
      'path-exclude /usr/share/man/*' \
      'path-exclude /usr/share/locale/*' \
      'path-exclude /usr/share/info/*' \
    > /etc/dpkg/dpkg.cfg.d/01-nodoc

# Quarto — rebuilt only when QUARTO_VERSION changes.
# curl/wget are not in the rocker base image (purged after R's build); use R's
# own download.file() which uses the libcurl4 runtime that is present.
# Exposes Quarto's bundled pandoc as `pandoc` on PATH so rmarkdown/knitr find
# it without the 190 MB apt pandoc package.
ARG QUARTO_VERSION=1.9.38
RUN ARCH="$(dpkg --print-architecture)" && \
    URL="https://github.com/quarto-dev/quarto-cli/releases/download/v${QUARTO_VERSION}/quarto-${QUARTO_VERSION}-linux-${ARCH}.deb" && \
    Rscript -e "download.file('${URL}', '/tmp/quarto.deb', method='libcurl')" && \
    dpkg -i /tmp/quarto.deb && \
    rm /tmp/quarto.deb && \
    ln -sf "$(find /opt/quarto -type f -name pandoc | head -1)" /usr/local/bin/pandoc

# AWS CLI v2 — not in Ubuntu Noble apt repos; use the official installer.
# curl/unzip are not in the rocker base image; use R's download.file() and
# unzip() (same approach as the Quarto step above).
# Maps dpkg arch (amd64/arm64) to the names AWS uses in download URLs.
RUN ARCH="$(dpkg --print-architecture)" && \
    AWS_ARCH=$([ "$ARCH" = "amd64" ] && echo "x86_64" || echo "aarch64") && \
    URL="https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip" && \
    Rscript -e "download.file('${URL}', '/tmp/awscliv2.zip', method='libcurl'); unzip('/tmp/awscliv2.zip', exdir='/tmp')" && \
    chmod -R +x /tmp/aws && \
    /tmp/aws/install && \
    rm -rf /tmp/awscliv2.zip /tmp/aws

# System packages — rebuilt only when apt-packages.txt changes.
# apt-packages.txt at the repo root is the canonical list; edit it (not here)
# to add/remove packages. The setup-gw-deps action opens a PR to add any
# package it installs at runtime.
COPY apt-packages.txt /tmp/apt-packages.txt
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      $(grep -Ev '^[[:space:]]*(#|$)' /tmp/apt-packages.txt) && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/apt-packages.txt /var/tmp/*

# renv — cached independently; only rebuilds on an explicit renv update.
RUN Rscript -e "install.packages('renv', repos = 'https://cloud.r-project.org')"

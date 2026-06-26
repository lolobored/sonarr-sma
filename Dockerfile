# syntax=docker/dockerfile:1
#
# Sonarr on a Debian (glibc) base so the sickbeard_mp4_automator OCR extras
# (easyocr / PyTorch) install from wheels, which are unavailable on the
# upstream Alpine/musl image. Built on the LinuxServer ffmpeg image, which
# provides the same s6-overlay v3 scaffolding (init-config / init-services)
# the SMA init scripts depend on, plus a VAAPI/QSV-capable ffmpeg.

FROM ghcr.io/linuxserver/ffmpeg

LABEL maintainer="laurent.laborde@gmail.com"
LABEL description="Sonarr (Debian) + sickbeard_mp4_automator with PGS->SRT subtitle OCR"

# Optional pins supplied by CI's resolve job so the built image matches exactly
# what the daily check saw. Both fall back to "resolve latest at build time"
# (the curl in the install step / the branch HEAD clone) when empty.
ARG SONARR_VERSION
ARG SMA_COMMIT
# Provenance: `docker inspect` shows what's baked in. Empty on unpinned builds.
LABEL org.sma.app-version="${SONARR_VERSION}"
LABEL org.sma.sma-commit="${SMA_COMMIT}"

# SMA_REPO/SMA_BRANCH are baked as ENV (not just ARG) so the init-sma-config
# runtime auto-update (SMA_UPDATE=true) pulls from the same fork/branch that
# was cloned at build time. SMA_OCR=true makes update.py enable PGS OCR.
ENV SMA_PATH=/usr/local/sma \
    SMA_RS=Sonarr \
    SMA_UPDATE=false \
    SMA_OCR=true \
    SMA_FFMPEG_PATH=ffmpeg \
    SMA_FFPROBE_PATH=ffprobe \
    SMA_REPO=https://github.com/lolobored/sickbeard_mp4_automator.git \
    SMA_BRANCH=feature/pgs-ocr-subtitles \
    EASYOCR_MODULE_PATH=/usr/local/sma/config/.EasyOCR \
    XDG_CONFIG_HOME=/config/xdg \
    SONARR_CHANNEL=v4-stable \
    SONARR_BRANCH=main \
    COMPlus_EnableDiagnostics=0 \
    TMPDIR=/run/sonarr-temp

# buildx provides TARGETARCH (amd64 / arm64); map it to the servarr arch token.
ARG TARGETARCH

# System packages: Sonarr runtime (libicu/sqlite), helpers, python, and the
# shared libs easyocr/opencv/torch load at runtime (libGL, glib, OpenMP).
RUN set -eux; \
  apt-get update; \
  apt-get install --no-install-recommends -y \
    curl jq xmlstarlet unzip \
    libicu-dev libsqlite3-dev \
    python3 python3-venv python3-pip git \
    libgl1 libglib2.0-0 libgomp1 \
    fontconfig fonts-dejavu; \
  rm -rf /var/lib/apt/lists/*

# Install Sonarr (servarr self-contained .NET build, v4-stable).
RUN set -eux; \
  case "${TARGETARCH}" in \
    amd64) SONARR_ARCH=x64 ;; \
    arm64) SONARR_ARCH=arm64 ;; \
    arm)   SONARR_ARCH=arm ;; \
    *)     SONARR_ARCH=x64 ;; \
  esac; \
  mkdir -p /app/sonarr/bin; \
  if [ -z "${SONARR_VERSION:-}" ]; then \
    SONARR_VERSION=$(curl -sX GET "http://services.sonarr.tv/v1/releases" | jq -r "first(.[] | select(.releaseChannel==\"${SONARR_CHANNEL}\") | .version)"); \
  fi; \
  curl -o /tmp/sonarr.tar.gz -L "https://services.sonarr.tv/v1/update/${SONARR_BRANCH}/download?version=${SONARR_VERSION}&os=linux&runtime=netcore&arch=${SONARR_ARCH}"; \
  tar xzf /tmp/sonarr.tar.gz -C /app/sonarr/bin --strip-components=1; \
  printf 'UpdateMethod=docker\nBranch=%s\nPackageVersion=sma\nPackageAuthor=lolobored\n' "${SONARR_BRANCH}" > /app/sonarr/package_info; \
  rm -rf /app/sonarr/bin/Sonarr.Update /tmp/*

# Install the mp4 automator fork and its python environment (including the
# optional OCR extras). Baked at build time so the container starts fast.
RUN set -eux; \
  git config --global --add safe.directory ${SMA_PATH}; \
  git clone --depth 1 -b "${SMA_BRANCH}" "${SMA_REPO}" ${SMA_PATH}; \
  if [ -n "${SMA_COMMIT:-}" ]; then \
    git -C ${SMA_PATH} fetch --depth 1 origin "${SMA_COMMIT}"; \
    git -C ${SMA_PATH} checkout -q "${SMA_COMMIT}"; \
  fi; \
  python3 -m venv ${SMA_PATH}/venv; \
  ${SMA_PATH}/venv/bin/pip install --no-cache-dir --upgrade pip; \
  ${SMA_PATH}/venv/bin/pip install --no-cache-dir \
    -r ${SMA_PATH}/setup/requirements.txt \
    -r ${SMA_PATH}/setup/requirements-ocr.txt; \
  rm -rf /root/.cache

EXPOSE 8989

VOLUME /config
VOLUME /usr/local/sma/config

# update.py sets FFMPEG/FFPROBE paths, API key, Sonarr settings and OCR toggle
# in autoProcess.ini
COPY extras/ ${SMA_PATH}/
COPY root/ /

# The ffmpeg base overrides ENTRYPOINT to /ffmpegwrapper.sh (CLI use); reset it
# to the s6-overlay init so the init scripts and svc-sonarr service actually run.
ENTRYPOINT ["/init"]

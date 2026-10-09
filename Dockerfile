FROM node:20-bookworm-slim

# ---- adb (Android platform tools) ----
# python3/make/g++ are required at build time: ws-scrcpy's dependency tree
# pulls in node-pty (native module, used for its remote-shell feature), which
# node-gyp cannot compile without them. Without this, `npm install` below
# fails outright on a fresh clone.
#
# IMPORTANT: do NOT use Debian's `android-tools-adb` package. It ships a
# stale build (platform-tools 29.0.6) that predates Android 11+ Wireless
# Debugging support — it has no `adb pair` command at all, and even once a
# key is already paired/trusted on the device, its TLS client can't
# complete the secure-connect handshake (`adb connect` just reports
# "offline" forever). Install the real Google platform-tools binary instead.
RUN apt-get update && apt-get install -y --no-install-recommends \
      wget \
      unzip \
      ca-certificates \
      git \
      python3 \
      make \
      g++ \
    && wget -q https://dl.google.com/android/repository/platform-tools-latest-linux.zip -O /tmp/pt.zip \
    && unzip -q /tmp/pt.zip -d /opt \
    && ln -s /opt/platform-tools/adb /usr/bin/adb \
    && rm -f /tmp/pt.zip \
    && rm -rf /var/lib/apt/lists/*

# ---- ws-scrcpy (build from source, pinned) ----
ARG WSSCRCPY_REF=master
RUN git clone --depth 1 --branch "${WSSCRCPY_REF}" https://github.com/NetrisTV/ws-scrcpy.git /opt/ws-scrcpy \
    && cd /opt/ws-scrcpy \
    && npm install \
    && npm run dist \
    && npm cache clean --force

WORKDIR /opt/ws-scrcpy

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# ws-scrcpy default web port
EXPOSE 8000

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

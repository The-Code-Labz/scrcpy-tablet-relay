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
# docker/webclient/* overlays our own fixes on top of upstream before it's
# built: higher-quality default video settings (upstream ships a 512kbps/
# 480px WebCodecs default and a 7.3Mbps/720px MSE default — both are why
# the stream looks heavily compressed on first connect), a PWA app shell
# (manifest/service-worker/icons) and touch/mobile CSS (44px+ hit targets,
# safe-area insets, no rubber-banding). None of this touches the websocket
# relay protocol itself, so it survives upstream updates to WSSCRCPY_REF as
# long as the patched source lines don't move.
ARG WSSCRCPY_REF=master
COPY docker/webclient /tmp/webclient
RUN git clone --depth 1 --branch "${WSSCRCPY_REF}" https://github.com/NetrisTV/ws-scrcpy.git /opt/ws-scrcpy \
    && cd /opt/ws-scrcpy \
    && cp /tmp/webclient/patches/index.html src/public/index.html \
    && cat /tmp/webclient/patches/mobile.css >> src/style/app.css \
    && sed -i \
         -e 's/bitrate: 524288,/bitrate: 8000000,/' \
         -e 's/maxFps: 24,/maxFps: 60,/' \
         -e 's/bounds: new Size(480, 480),/bounds: new Size(1600, 1600),/' \
         src/app/player/WebCodecsPlayer.ts \
    && sed -i \
         -e 's/bitrate: 7340032,/bitrate: 16000000,/' \
         -e 's/bounds: new Size(720, 720),/bounds: new Size(1600, 1600),/' \
         src/app/player/MsePlayer.ts \
    && npm install \
    && npm run dist \
    && cp /tmp/webclient/pwa-assets/manifest.webmanifest dist/public/manifest.webmanifest \
    && cp /tmp/webclient/pwa-assets/sw.js dist/public/sw.js \
    && cp /tmp/webclient/pwa-assets/icon-192.png dist/public/icon-192.png \
    && cp /tmp/webclient/pwa-assets/icon-512.png dist/public/icon-512.png \
    && npm cache clean --force \
    && rm -rf /tmp/webclient

WORKDIR /opt/ws-scrcpy

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# ws-scrcpy default web port
EXPOSE 8000

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

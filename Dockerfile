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
#
# nmap is used by entrypoint.sh's port-discovery fallback: Wireless
# Debugging's connect port is an OS-assigned ephemeral port with no stable
# mDNS path over Tailscale (see entrypoint.sh), so we bounded-scan for it
# instead of requiring it be read off the tablet's screen by hand.
RUN apt-get update && apt-get install -y --no-install-recommends \
      wget \
      unzip \
      ca-certificates \
      git \
      python3 \
      make \
      g++ \
      nmap \
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
#
# server-patches/RelayApi.ts adds a small Express router (mounted at
# /relay-api by a one-line patch to HttpServer.ts, below) so the web UI can
# re-pair/reconnect adb itself -- via a port+code form or a scanned QR code --
# without needing shell access, for when the tablet revokes trust (not just
# rotates its ephemeral connect port, which entrypoint.sh already
# self-heals on its own).
ARG WSSCRCPY_REF=master
COPY docker/webclient /tmp/webclient
RUN git clone --depth 1 --branch "${WSSCRCPY_REF}" https://github.com/NetrisTV/ws-scrcpy.git /opt/ws-scrcpy \
    && cd /opt/ws-scrcpy \
    && cp /tmp/webclient/patches/index.html src/public/index.html \
    && cat /tmp/webclient/patches/mobile.css >> src/style/app.css \
    && cat /tmp/webclient/patches/relay-ui.css >> src/style/app.css \
    && cat /tmp/webclient/patches/pwa-install.css >> src/style/app.css \
    && sed -i \
         -e 's/bitrate: 524288,/bitrate: 8000000,/' \
         -e 's/maxFps: 24,/maxFps: 60,/' \
         -e 's/bounds: new Size(480, 480),/bounds: new Size(1600, 1600),/' \
         src/app/player/WebCodecsPlayer.ts \
    && sed -i \
         -e 's/bitrate: 7340032,/bitrate: 16000000,/' \
         -e 's/bounds: new Size(720, 720),/bounds: new Size(1600, 1600),/' \
         src/app/player/MsePlayer.ts \
    && cp /tmp/webclient/server-patches/RelayApi.ts src/server/RelayApi.ts \
    && sed -i "/import { EnvName } from '..\/EnvName';/a import { createRelayApiRouter } from '..\/RelayApi';" src/server/services/HttpServer.ts \
    && sed -i "/this.mainApp = express();/a\\        this.mainApp.use(express.json());\\n        this.mainApp.use(path.join(PATHNAME, 'relay-api'), createRelayApiRouter());" src/server/services/HttpServer.ts \
    && npm install \
    && npm install qrcode \
    && npm install --save-dev @types/qrcode \
    && npm run dist \
    && cp /tmp/webclient/pwa-assets/manifest.webmanifest dist/public/manifest.webmanifest \
    && cp /tmp/webclient/pwa-assets/sw.js dist/public/sw.js \
    && cp /tmp/webclient/pwa-assets/icon-192.png dist/public/icon-192.png \
    && cp /tmp/webclient/pwa-assets/icon-512.png dist/public/icon-512.png \
    && cp /tmp/webclient/pwa-assets/relay-ui.js dist/public/relay-ui.js \
    && cp /tmp/webclient/pwa-assets/pwa-install.js dist/public/pwa-install.js \
    && npm cache clean --force \
    && rm -rf /tmp/webclient

WORKDIR /opt/ws-scrcpy

# ---- tango-mirror (audio sidecar) ----
# ws-scrcpy's vendored scrcpy-server predates scrcpy's audio protocol
# (scrcpy 2.0+). tango-mirror pushes the current stock scrcpy v3.1 server
# and streams video+Opus audio+touch over WebRTC instead — a separate
# process (see entrypoint-audio.sh / docker-compose.yml `scrcpy-audio`
# service), reusing this same image and the adb trust/connection this
# stage already sets up. Pinned version: npm ships it with a prebuilt
# public/app.js and scrcpy-server.bin already, no extra build step needed.
ARG TANGO_MIRROR_VERSION=0.6.0
COPY docker/tango-pwa /tmp/tango-pwa
RUN mkdir -p /opt/tango-mirror && cd /opt/tango-mirror \
    && npm install --no-save --omit=dev "tango-mirror@${TANGO_MIRROR_VERSION}" \
    && cd node_modules/tango-mirror \
    && sed -i "/<title>tango-mirror<\/title>/r /tmp/tango-pwa/head-snippet.html" public/index.html \
    && sed -i "/<body>/r /tmp/tango-pwa/body-snippet.html" public/index.html \
    && cp /tmp/tango-pwa/manifest.webmanifest public/manifest.webmanifest \
    && cp /tmp/tango-pwa/sw.js public/sw.js \
    && npm cache clean --force \
    && rm -rf /tmp/tango-pwa

# icon-192/512.png live in the ws-scrcpy stage above (webclient dir already
# removed by then) — copy them into tango-mirror's public dir from the
# original build-context path instead of the (now-deleted) /tmp/webclient.
COPY docker/webclient/pwa-assets/icon-192.png docker/webclient/pwa-assets/icon-512.png \
     docker/webclient/patches/pwa-install.css \
     /opt/tango-mirror/node_modules/tango-mirror/public/

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY entrypoint-audio.sh /usr/local/bin/entrypoint-audio.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/entrypoint-audio.sh

# ws-scrcpy default web port; tango-mirror audio sidecar port
EXPOSE 8000 8010

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

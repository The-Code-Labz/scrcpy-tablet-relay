FROM node:20-bookworm-slim

# ---- adb (Android platform tools) ----
# python3/make/g++ are required at build time: ws-scrcpy's dependency tree
# pulls in node-pty (native module, used for its remote-shell feature), which
# node-gyp cannot compile without them. Without this, `npm install` below
# fails outright on a fresh clone.
RUN apt-get update && apt-get install -y --no-install-recommends \
      android-tools-adb \
      wget \
      ca-certificates \
      git \
      python3 \
      make \
      g++ \
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

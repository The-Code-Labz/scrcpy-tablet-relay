FROM node:20-bookworm-slim

# ---- adb (Android platform tools) ----
RUN apt-get update && apt-get install -y --no-install-recommends \
      android-tools-adb \
      wget \
      ca-certificates \
      git \
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

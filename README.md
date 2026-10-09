# scrcpy-tablet-relay

Turn a Samsung Tab A9+ (or any Android 11+ tablet) into a **persistent app host** —
fully viewable and controllable from an iPhone through a web browser, no cables,
no per-session setup.

```
┌──────────────┐   wireless adb (port 5555, pinned)   ┌──────────────────────┐   HTTPS/WSS   ┌────────┐
│  Tab A9+     │ ──────────────────────────────────▶ │  scrcpy-relay        │ ────────────▶ │ iPhone │
│  (apps run   │                                     │  Docker container    │               │ Safari │
│   24/7)      │ ◀────────────────────────────────── │  adb + ws-scrcpy     │ ◀──────────── │  PWA   │
└──────────────┘   scrcpy video stream + touch input  └──────────────────────┘               └────────┘
                                                            │ bound to Tailscale IP
                                                       (see BIND_HOST below)
```

* **Real touch injection** — scrcpy's native multitouch protocol, not VNC mouse emulation.
  Scrolling, pinch, long-press, and app gestures work like they do in your hand.
* **Audio forwarding** — scrcpy 2.x forwards the tablet's audio (Android 13+).
  See *Audio caveats* below for web-client decode limits.
* **Self-healing** — a keepalive loop reconnects adb every 30 s after tablet reboots,
  Wi-Fi flaps, or relay restarts. No manual intervention.
* **Tailscale-bound** — `BIND_HOST` publishes port 8000 only on the relay
  host's Tailscale IP, since ws-scrcpy has no built-in authentication.

---

## 1. One-time tablet setup (Tab A9+, Android 13/14/15)

1. **Enable Developer Options**: `Settings → About tablet → Software information` →
   tap **Build number** 7 times.
2. **Enable Wireless debugging**: `Settings → Developer options → Wireless debugging` → ON.
3. **Pin the port (USB required, once)** — Android 11+ randomizes the wireless-debug
   port **every session**, which would break the relay. Pin it permanently:
   ```bash
   # on any machine with adb:
   adb devices                      # confirm the tablet shows over USB
   adb tcpip 5555                   # switch to network mode, pin port 5555
   adb connect <TABLET_IP>:5555     # confirm it works wirelessly
   ```
   After a tablet reboot the port stays 5555 (only the *authorization* may need
   re-acceptance once — see Troubleshooting).
4. **Note the tablet's IP**: `Settings → Wi-Fi → <your network>` (or give the tablet a
   DHCP reservation / use its Tailscale IP if Tailscale is installed on it).

## 2. Deploy the relay

Requires: Docker + docker compose plugin.

```bash
git clone https://github.com/The-Code-Labz/scrcpy-tablet-relay.git
cd scrcpy-tablet-relay
cp .env.example .env
# edit .env — set TABLET_HOST (tablet LAN IP or Tailscale hostname) and
# BIND_HOST (the relay host's own Tailscale IP, from `tailscale ip -4`)
docker compose up -d --build
docker compose logs -f           # watch: "[relay] target ..." then ws-scrcpy startup
```

Open `http://<relay-host>:8000` — the ws-scrcpy page lists your tablet.
Click it → live mirror with full touch control.

## 3. iPhone access (Tailscale)

1. Install [Tailscale](https://tailscale.com) on the relay host **and** the iPhone;
   log both into the same tailnet.
2. On the iPhone: Safari → `http://<relay-tailscale-hostname>:8000` → open the tablet.
3. **Add to Home Screen** (Share → *Add to Home Screen*) — it becomes a fullscreen PWA:
   no Safari chrome, looks like a native app.

> Plain `http` is fine on a tailnet (WireGuard-encrypted). If you want a padlock,
> front the relay with Caddy/nginx on the same host with a Tailscale cert.

## 4. Making the tablet a persistent app host

* **Never let it sleep on Wi-Fi**: `Settings → Display → Screen timeout` → max, and
  `Settings → Developer options → Stay awake` (while charging) ON. Keep it on a charger.
* **Disable battery optimization** for your hosted apps so Android doesn't kill them.
* scrcpy keeps the screen mirrored but the tablet can run fully headless —
  the relay stays attached even when the screen is off.

---

## Audio caveats (no audio, on any client)

This relay has **no audio support at all** — not a browser-decode limitation,
a missing feature. The web client (`NetrisTV/ws-scrcpy`) vendors a pinned
`scrcpy-server.jar` build (`1.19-ws8`, based on scrcpy 1.19) that predates
scrcpy's audio-forwarding protocol entirely (added upstream in scrcpy 2.0,
2023) — there is no `audio` code path anywhere in that server binary, and the
TypeScript client has no audio decoder/player to go with it. Confirmed by
inspecting the vendored jar (zero `audio` strings) and upstream's own
tracking issue, [ws-scrcpy#38](https://github.com/NetrisTV/ws-scrcpy/discussions/38),
which is still an open research discussion, not a shipped feature.

Workarounds:

1. Play audio natively on the tablet (it stays audible on-device through its
   own speakers/Bluetooth) while the relay only mirrors video + input.
2. Casting the tablet's audio separately (e.g. a local Bluetooth speaker near
   the tablet) if you need it audible where the relay client is.

Fixing this for real means swapping the underlying relay technology for one
that implements scrcpy's audio protocol (e.g. a newer scrcpy-server build
plus matching client decode) — a different project/architecture, not a
config change to this one. Ask if you want that evaluated as a separate
effort; it's out of scope for a patch to the current `ws-scrcpy` base.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `adb connect` hangs / "unable to connect" | Wireless debugging toggled off or port no longer 5555 → re-run `adb tcpip 5555` over USB once |
| Shows `unauthorized` | On the tablet: accept the **Allow USB debugging?** RSA prompt (check "always allow") |
| Works, then drops after tablet reboot | Authorization revoked → accept the prompt again once; the keepalive then maintains it |
| Tablet IP changed | Use a DHCP reservation, or set `TABLET_HOST` to the tablet's **Tailscale hostname** (stable) and install Tailscale on the tablet |
| ws-scrcpy page is empty / no device | Check `docker compose logs` — adb must show the device as `device`, not `offline`/`unauthorized` |
| Laggy video | ws-scrcpy has no server-side bitrate flags/env vars. The image now ships higher default quality (MSE player: 16 Mbps / up to 1600px; WebCodecs player: 8 Mbps / up to 1600px / 60 fps, up from upstream's 512 kbps–7.3 Mbps 480–720px defaults) — if it's still laggy, your network is the bottleneck, not the defaults. You can still click the gear/**Configure stream** button next to the tablet *before* connecting to tune **Bitrate** / **Max size** per session |
| No audio | Expected — see *Audio caveats*. This relay has no audio pipeline at all, on any client |

## PWA / "Add to Home Screen" behavior

The image now ships a real app shell: `manifest.webmanifest`, a minimal
service worker, and app icons, all generated at build time and served from
the ws-scrcpy static root (`/manifest.webmanifest`, `/sw.js`, `/icon-*.png`).

* **iPhone (Safari):** Share → **Add to Home Screen** installs it as a
  standalone app (no Safari chrome), with the app icon and a
  `black-translucent` status bar, honoring the notch/home-indicator safe
  areas.
* **Android (Chrome):** gets an install prompt / "Install app" menu entry.
* The service worker only caches the HTML shell for offline opening — it
  deliberately never touches the video/control WebSocket traffic
  (`?action=proxy-adb&...`), so there's no risk of it serving stale/cached
  stream data.
* Touch targets (toolbox buttons, device list rows, dialog buttons) are
  enlarged to ≥44px on coarse-pointer (touch) devices, and the stream/touch
  surface disables text-selection callouts and rubber-band scrolling so it
  feels like a native app rather than a web page.
* If iOS evicts the PWA from memory, reopening it reconnects in a few
  seconds — this is normal iOS background-tab behavior, not a relay issue.

## Configuration

All in `.env` (see `.env.example`):

| Variable | Default | Purpose |
|---|---|---|
| `TABLET_HOST` | — (required) | Tablet IP or Tailscale hostname |
| `TABLET_PORT` | `5555` | Pinned wireless-adb port |
| `KEEPALIVE_INTERVAL` | `30` | Seconds between adb reconnect checks |
| `BIND_HOST` | `127.0.0.1` | Host IP port 8000 is published on — set to your Tailscale IP |
| `IMAGE_TAG` | `latest` | Tag pulled from `ghcr.io/the-code-labz/scrcpy-tablet-relay` |
| `SCRCPY_HOSTNAME` | `scrcpy.example.com` | Hostname Traefik routes to this service (Traefik users only) |
| `TRAEFIK_NETWORK` | `dokploy-network` | Docker network your Traefik instance watches (Traefik users only) |
| `TRAEFIK_CERTRESOLVER` | `cloudflare` | Traefik certresolver for automatic TLS (Traefik users only) |

### Traefik (optional)

`docker-compose.yml` ships Traefik labels and attaches the container to an
external `traefik-network` (named via `TRAEFIK_NETWORK`, default
`dokploy-network`) alongside the default bridge network ws-scrcpy/adb use.

- **Running Traefik already?** Set `SCRCPY_HOSTNAME`/`TRAEFIK_NETWORK`/
  `TRAEFIK_CERTRESOLVER` in `.env` to match your setup. Traefik terminates
  TLS and proxies ws-scrcpy's WebSocket upgrade transparently — no extra
  middleware needed (just don't attach a compression middleware to this
  router, that breaks WS).
- **Not running Traefik?** Nothing to do — the direct `BIND_HOST:8000`
  publish still works exactly as before. To fully remove the Traefik
  wiring, delete the `labels:` block, the `traefik-network` network, and
  its entry under the service's `networks:` key.
- The external network must already exist and have Traefik attached to it
  (`docker network create dokploy-network` if you're starting fresh) —
  Traefik only discovers containers on networks it's watching; labels alone
  aren't enough.

## Files

```
Dockerfile              Node 20 + adb + ws-scrcpy build
entrypoint.sh           adb connect → 30s keepalive loop → ws-scrcpy on :8000
docker-compose.yml      restart: unless-stopped; BIND_HOST direct publish + optional Traefik labels
.env.example            configuration template
docker/webclient/       build-time overlay on ws-scrcpy: PWA app shell
                        (manifest/service-worker/icons) + mobile/touch CSS,
                        applied before `npm run dist` in the Dockerfile
```

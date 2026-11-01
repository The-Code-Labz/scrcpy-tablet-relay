/*
 * Reconnect widget behavior — talks to /relay-api/* (see RelayApi.ts).
 * Vanilla JS, no deps, no bundler step: copied verbatim to dist/public/
 * alongside the other PWA assets.
 */
(function () {
    'use strict';

    // Paths relative to the current document, same convention as
    // manifest.webmanifest/sw.js, so this keeps working under a custom
    // WS_SCRCPY_PATHNAME.
    var API = 'relay-api/';

    function qs(sel) {
        return document.querySelector(sel);
    }

    function setDot(state) {
        var dot = qs('#relay-reconnect-dot');
        if (!dot) {
            return;
        }
        dot.className = 'relay-dot relay-dot-' + state;
    }

    function fetchJson(url, opts) {
        return fetch(url, opts).then(function (r) {
            return r.json().catch(function () {
                return { ok: false, error: 'bad response (' + r.status + ')' };
            });
        }).catch(function (e) {
            return { ok: false, error: e && e.message ? e.message : String(e) };
        });
    }

    function pollStatus() {
        fetchJson(API + 'status').then(function (data) {
            if (!data || !data.ok) {
                setDot('unknown');
                return;
            }
            var device = data.device;
            if (device && device.state === 'device') {
                setDot('connected');
            } else {
                // offline/unauthorized (paired entry exists but not trusted/ready) or no entry at all
                setDot('offline');
            }
        });
    }

    function openModal() {
        var overlay = qs('#relay-reconnect-modal');
        if (!overlay) {
            return;
        }
        overlay.hidden = false;
        fetchJson(API + 'status').then(function (data) {
            var hostInput = qs('#relay-code-host');
            if (hostInput && !hostInput.value && data && data.host) {
                hostInput.value = data.host;
            }
        });
    }

    function closeModal() {
        var overlay = qs('#relay-reconnect-modal');
        if (overlay) {
            overlay.hidden = true;
        }
    }

    function switchTab(name) {
        document.querySelectorAll('.relay-tab').forEach(function (btn) {
            var isActive = btn.getAttribute('data-tab') === name;
            btn.classList.toggle('active', isActive);
            btn.setAttribute('aria-selected', isActive ? 'true' : 'false');
        });
        document.querySelectorAll('.relay-tab-panel').forEach(function (panel) {
            panel.hidden = panel.getAttribute('data-panel') !== name;
        });
    }

    // kind: 'success' | 'error' | 'pending' | null/undefined
    function setStatus(el, text, kind) {
        if (!el) {
            return;
        }
        el.textContent = text || '';
        el.className = 'relay-status' + (kind ? ' ' + kind : '');
    }

    function submitPairCode() {
        var host = (qs('#relay-code-host').value || '').trim();
        var pairPort = (qs('#relay-code-pairport').value || '').trim();
        var code = (qs('#relay-code-code').value || '').trim();
        var connectPort = (qs('#relay-code-connectport').value || '').trim();
        var statusEl = qs('#relay-code-status');
        var btn = qs('#relay-code-submit');

        if (!host || !pairPort || !code) {
            setStatus(statusEl, 'Host, pairing port and code are all required.', 'error');
            return;
        }

        btn.disabled = true;
        btn.setAttribute('aria-busy', 'true');
        setStatus(statusEl, 'Pairing...', 'pending');

        fetchJson(API + 'pair', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ host: host, pairPort: pairPort, code: code, connectPort: connectPort }),
        }).then(function (data) {
            btn.disabled = false;
            btn.removeAttribute('aria-busy');
            if (!data || !data.ok) {
                setStatus(statusEl, (data && (data.output || data.error)) || 'Pairing failed — the code may have expired, request a fresh one on the tablet.', 'error');
                return;
            }
            setStatus(statusEl, data.message || 'Paired.', data.stage === 'connected' ? 'success' : 'pending');
            pollStatus();
        });
    }

    var qrJobId = null;
    var qrPollTimer = null;

    function stopQrPoll() {
        if (qrPollTimer) {
            clearInterval(qrPollTimer);
            qrPollTimer = null;
        }
    }

    function startQr() {
        var statusEl = qs('#relay-qr-status');
        var img = qs('#relay-qr-img');
        var genBtn = qs('#relay-qr-generate');
        var cancelBtn = qs('#relay-qr-cancel');

        genBtn.disabled = true;
        genBtn.setAttribute('aria-busy', 'true');
        setStatus(statusEl, 'Requesting QR code...', 'pending');

        fetchJson(API + 'qr/start', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({}),
        }).then(function (data) {
            genBtn.disabled = false;
            genBtn.removeAttribute('aria-busy');
            if (!data || !data.ok) {
                setStatus(statusEl, (data && data.error) || 'Could not start QR pairing.', 'error');
                return;
            }
            qrJobId = data.jobId;
            img.src = data.qrDataUrl;
            img.hidden = false;
            genBtn.hidden = true;
            cancelBtn.hidden = false;
            setStatus(statusEl, 'Scan the QR code on the tablet now...', 'pending');

            stopQrPoll();
            qrPollTimer = setInterval(function () {
                if (!qrJobId) {
                    stopQrPoll();
                    return;
                }
                fetchJson(API + 'qr/status/' + qrJobId).then(function (s) {
                    if (!s || !s.ok) {
                        return;
                    }
                    var kind = s.state === 'connected' ? 'success' : (s.state === 'error' || s.state === 'timeout' ? 'error' : 'pending');
                    setStatus(statusEl, s.message, kind);
                    if (s.state === 'connected' || s.state === 'error' || s.state === 'timeout' || s.state === 'cancelled') {
                        stopQrPoll();
                        img.hidden = true;
                        cancelBtn.hidden = true;
                        genBtn.hidden = false;
                        qrJobId = null;
                        pollStatus();
                    }
                });
            }, 1500);
        });
    }

    function cancelQr() {
        if (qrJobId) {
            fetchJson(API + 'qr/cancel/' + qrJobId, { method: 'POST' });
        }
        stopQrPoll();
        qrJobId = null;
        qs('#relay-qr-img').hidden = true;
        qs('#relay-qr-cancel').hidden = true;
        qs('#relay-qr-generate').hidden = false;
        setStatus(qs('#relay-qr-status'), 'Cancelled.', null);
    }

    function init() {
        var fab = qs('#relay-reconnect-fab');
        if (!fab) {
            return; // widget markup not present on this page for some reason — fail quiet
        }
        fab.addEventListener('click', openModal);
        qs('#relay-modal-close').addEventListener('click', closeModal);
        qs('#relay-reconnect-modal').addEventListener('click', function (e) {
            if (e.target === e.currentTarget) {
                closeModal();
            }
        });
        document.querySelectorAll('.relay-tab').forEach(function (btn) {
            btn.addEventListener('click', function () {
                switchTab(btn.getAttribute('data-tab'));
            });
        });
        qs('#relay-code-submit').addEventListener('click', submitPairCode);
        qs('#relay-qr-generate').addEventListener('click', startQr);
        qs('#relay-qr-cancel').addEventListener('click', cancelQr);

        pollStatus();
        setInterval(pollStatus, 10000);
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();

/*
 * PWA install affordance. The manifest/service-worker alone only make the
 * app *installable* — neither browser shows a prompt a user is guaranteed
 * to notice:
 *   - iOS Safari NEVER fires an automatic install prompt at all (Apple
 *     platform limitation, not a bug) — the only path is Share > Add to
 *     Home Screen, and nothing on the page told anyone that.
 *   - Android Chrome fires `beforeinstallprompt`, but if nothing captures
 *     it the only affordance is a small icon in the address bar most
 *     people never notice.
 * This adds an explicit, dismissible banner for both cases.
 */
(function () {
  var DISMISS_KEY = 'relay-pwa-install-dismissed-until';
  var DISMISS_DAYS = 14;

  function isStandalone() {
    return (
      window.matchMedia('(display-mode: standalone)').matches ||
      window.navigator.standalone === true
    );
  }

  function isDismissed() {
    try {
      var until = Number(localStorage.getItem(DISMISS_KEY) || 0);
      return Date.now() < until;
    } catch (e) {
      return false;
    }
  }

  function dismiss() {
    try {
      localStorage.setItem(
        DISMISS_KEY,
        String(Date.now() + DISMISS_DAYS * 24 * 60 * 60 * 1000)
      );
    } catch (e) {
      /* ignore */
    }
    hideBanner();
  }

  var banner = null;

  function ensureBanner() {
    if (banner) return banner;
    banner = document.createElement('div');
    banner.id = 'pwa-install-banner';
    banner.className = 'pwa-install-banner';
    banner.hidden = true;
    banner.innerHTML =
      '<span class="pwa-install-icon" aria-hidden="true">' +
      '<svg viewBox="0 0 24 24" focusable="false"><path d="M7 2.75h10A2.25 2.25 0 0 1 19.25 5v14A2.25 2.25 0 0 1 17 21.25H7A2.25 2.25 0 0 1 4.75 19V5A2.25 2.25 0 0 1 7 2.75Z"/><path d="M10 18.25h4M12 6.5v8M9 11l3 3 3-3"/></svg>' +
      '</span>' +
      '<span class="pwa-install-copy" id="pwa-install-copy"></span>' +
      '<button type="button" class="pwa-install-action" id="pwa-install-action">Install</button>' +
      '<button type="button" class="pwa-install-dismiss" id="pwa-install-dismiss" aria-label="Dismiss">' +
      '<svg viewBox="0 0 20 20" aria-hidden="true" focusable="false"><path d="m5 5 10 10M15 5 5 15"/></svg>' +
      '</button>';
    document.body.appendChild(banner);
    banner
      .querySelector('#pwa-install-dismiss')
      .addEventListener('click', dismiss);
    return banner;
  }

  function hideBanner() {
    if (banner) banner.hidden = true;
  }

  function showBanner(copy, actionLabel, onAction) {
    if (isDismissed() || isStandalone()) return;
    var el = ensureBanner();
    el.querySelector('#pwa-install-copy').textContent = copy;
    var actionBtn = el.querySelector('#pwa-install-action');
    if (onAction) {
      actionBtn.hidden = false;
      actionBtn.textContent = actionLabel;
      actionBtn.onclick = onAction;
    } else {
      actionBtn.hidden = true;
    }
    el.hidden = false;
  }

  if (isStandalone()) return;

  var ua = navigator.userAgent || '';
  var isIOS =
    /iphone|ipad|ipod/i.test(ua) ||
    (ua.includes('Macintosh') && navigator.maxTouchPoints > 1);
  var isSafari = isIOS && !/CriOS|FxiOS|EdgiOS/i.test(ua);

  if (isSafari) {
    // No beforeinstallprompt on iOS — just point at the manual step.
    showBanner(
      'Install this app: tap the Share icon, then "Add to Home Screen".',
      null,
      null
    );
    return;
  }

  // Android Chrome / other Chromium browsers that support the real prompt.
  var deferredEvent = null;
  window.addEventListener('beforeinstallprompt', function (event) {
    event.preventDefault();
    deferredEvent = event;
    showBanner('Install this app for a fullscreen, app-like view.', 'Install', function () {
      if (!deferredEvent) return;
      deferredEvent.prompt();
      deferredEvent.userChoice.finally(function () {
        deferredEvent = null;
        hideBanner();
      });
    });
  });

  window.addEventListener('appinstalled', function () {
    deferredEvent = null;
    hideBanner();
  });
})();

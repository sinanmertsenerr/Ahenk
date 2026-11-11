// Ahenk browser bridge, content script (isolated world): carries messages
// between the page-world engine (page/engine.js) and the extension's
// background, and keeps that connection up while the page lives.
//
// An extension that was updated or reloaded leaves its old relay in the
// page without a way to reach the new background. The new one puts this
// script into the page again (see background.js): the relay that was here
// steps down and this one carries on.
(function () {
  'use strict';
  const before = window.__ahenkRelay;
  if (before && typeof before.retire === 'function') {
    try {
      before.retire();
    } catch (_) {
      // Its extension is gone; it reaches nobody.
    }
  }
  const ext = globalThis.browser || globalThis.chrome;

  let retired = false;
  let port = null;
  let attempts = 0;
  let lastState = null;
  let beat = null;

  function connect() {
    if (retired) return;
    try {
      port = ext.runtime.connect({ name: 'ahenk-tab' });
    } catch (_) {
      // The extension was reloaded or removed: this page's relay is done.
      port = null;
      return;
    }
    const openedAt = Date.now();
    port.onMessage.addListener((message) => {
      if (retired) return;
      attempts = 0;
      window.postMessage({ __ahenk: 'ext', message }, location.origin);
    });
    port.onDisconnect.addListener(() => {
      port = null;
      void (ext.runtime && ext.runtime.lastError);
      // The background went to sleep or restarted: come back and tell it
      // again what plays here. A connection that held for a while worked;
      // one that keeps dropping at once is given up after a few tries.
      if (retired) return;
      if (Date.now() - openedAt > 10000) attempts = 0;
      attempts += 1;
      if (attempts > 8) return;
      setTimeout(() => {
        if (retired) return;
        connect();
        if (port && lastState) port.postMessage({ kind: 'state', state: lastState });
        window.postMessage({ __ahenk: 'ext', message: { kind: 'resync' } }, location.origin);
      }, Math.min(5000, 250 * attempts));
    });
  }

  function onPageMessage(event) {
    if (retired || event.source !== window || !event.data || event.data.__ahenk !== 'page') return;
    const message = event.data.message;
    if (!message || typeof message.kind !== 'string') return;
    if (message.kind === 'state') lastState = message.state;
    if (message.kind === 'gone') lastState = null;
    if (!port) connect();
    try {
      if (port) port.postMessage(message);
    } catch (_) {
      port = null;
    }
  }
  window.addEventListener('message', onPageMessage);

  connect();
  // The page world may have started first and missed the connection: ask
  // it for its state (it answers with "ready" and what plays).
  window.postMessage({ __ahenk: 'ext', message: { kind: 'resync' } }, location.origin);
  // A heartbeat keeps the background awake while this page may play.
  beat = setInterval(() => {
    try {
      if (port) port.postMessage({ kind: 'beat' });
      else if (attempts > 8) clearInterval(beat);
    } catch (_) {
      port = null;
    }
  }, 20000);

  window.__ahenkRelay = {
    /** Steps down for the relay of an updated extension. */
    retire() {
      retired = true;
      clearInterval(beat);
      window.removeEventListener('message', onPageMessage);
      try {
        if (port) port.disconnect();
      } catch (_) {
        // Already gone.
      }
      port = null;
    },
  };
})();

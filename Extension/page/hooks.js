// Ahenk browser bridge, page world, document_start: watches what the site
// tells the system about its player (Media Session metadata, action
// handlers, position) and which media elements play, before the site's own
// scripts run. Changes nothing the site does; only remembers and notifies.
(function () {
  'use strict';
  if (window.__ahenkHooks) return;

  const listeners = new Set();
  const state = {
    /** The site's own handlers for play, pause, nexttrack, seekto, … */
    handlers: new Map(),
    /** The last setPositionState() call and when it happened (ms). */
    position: null,
    positionAt: 0,
    playbackState: null,
    metadataAt: 0,
    /** Media elements that played, newest last (at most a few). */
    media: [],
    /** JSON responses that may hold lyrics, for the engine. */
    onJSON: null,
  };

  let scheduled = false;
  function notify() {
    if (scheduled) return;
    scheduled = true;
    Promise.resolve().then(() => {
      scheduled = false;
      for (const listener of listeners) {
        try {
          listener();
        } catch (_) {
          // A listener's failure never reaches the site.
        }
      }
    });
  }

  function remember(element) {
    if (!(element instanceof HTMLMediaElement)) return;
    const index = state.media.indexOf(element);
    if (index >= 0) state.media.splice(index, 1);
    else {
      for (const name of ['play', 'pause', 'playing', 'seeked', 'ratechange', 'durationchange', 'emptied', 'ended', 'loadedmetadata', 'volumechange']) {
        element.addEventListener(name, notify, { passive: true });
      }
    }
    state.media.push(element);
    if (state.media.length > 6) state.media.shift();
    notify();
  }

  const session = window.MediaSession && window.MediaSession.prototype;
  if (session) {
    const setActionHandler = session.setActionHandler;
    if (typeof setActionHandler === 'function') {
      session.setActionHandler = function (action, handler) {
        try {
          if (typeof handler === 'function') state.handlers.set(String(action), handler);
          else state.handlers.delete(String(action));
          notify();
        } catch (_) {
          // Never in the site's way.
        }
        return setActionHandler.apply(this, arguments);
      };
    }
    const setPositionState = session.setPositionState;
    if (typeof setPositionState === 'function') {
      session.setPositionState = function (value) {
        try {
          state.position = value && Number.isFinite(value.duration)
            ? { duration: value.duration, position: Number(value.position) || 0, playbackRate: Number.isFinite(value.playbackRate) ? value.playbackRate : 1 }
            : null;
          state.positionAt = Date.now();
          notify();
        } catch (_) {
          // Ignored.
        }
        return setPositionState.apply(this, arguments);
      };
    }
    for (const property of ['metadata', 'playbackState']) {
      const descriptor = Object.getOwnPropertyDescriptor(session, property);
      if (!descriptor || typeof descriptor.set !== 'function' || !descriptor.configurable) continue;
      Object.defineProperty(session, property, {
        configurable: true,
        enumerable: descriptor.enumerable,
        get: descriptor.get,
        set(value) {
          descriptor.set.call(this, value);
          if (property === 'metadata') state.metadataAt = Date.now();
          else state.playbackState = String(value);
          notify();
        },
      });
    }
  }

  // Elements that start playing: through play(), autoplay or the controls.
  const play = HTMLMediaElement.prototype.play;
  HTMLMediaElement.prototype.play = function () {
    remember(this);
    return play.apply(this, arguments);
  };
  document.addEventListener('play', (event) => remember(event.target), true);
  document.addEventListener('playing', (event) => remember(event.target), true);

  // JSON the site fetches for its lyrics view (only URLs that may hold
  // lyrics are looked at; see lib/lyrics.js).
  function inspect(url, read) {
    const sink = state.onJSON;
    if (!sink || !sink.wants(url)) return;
    Promise.resolve()
      .then(read)
      .then((json) => {
        if (json && typeof json === 'object') sink.deliver(url, json);
      })
      .catch(() => {});
  }

  const originalFetch = window.fetch;
  if (typeof originalFetch === 'function') {
    window.fetch = function (input, init) {
      const pending = originalFetch.apply(this, arguments);
      try {
        // A string, a Request or a URL.
        const url = typeof input === 'string' ? input : input && (input.url || input.href);
        if (url && state.onJSON && state.onJSON.wants(String(url))) {
          pending.then((response) => {
            // Copied now: this callback runs before the site's own, which
            // reads the body; a copy made later would find it used.
            if (!response || !response.ok) return;
            const copy = response.clone();
            inspect(response.url || String(url), () => copy.json());
          }).catch(() => {});
        }
      } catch (_) {
        // Ignored.
      }
      return pending;
    };
  }

  const open = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (method, url) {
    try {
      const request = this;
      const address = String(url);
      if (state.onJSON && state.onJSON.wants(address)) {
        request.addEventListener('load', () => {
          inspect(address, () => {
            if (request.responseType === 'json') return request.response;
            if (request.responseType === '' || request.responseType === 'text') return JSON.parse(request.responseText);
            return null;
          });
        }, { once: true });
      }
    } catch (_) {
      // Ignored.
    }
    return open.apply(this, arguments);
  };

  Object.defineProperty(window, '__ahenkHooks', {
    value: Object.freeze({
      state,
      subscribe(listener) {
        listeners.add(listener);
        return () => listeners.delete(listener);
      },
      remember,
      notify,
    }),
    enumerable: false,
    configurable: false,
  });
})();

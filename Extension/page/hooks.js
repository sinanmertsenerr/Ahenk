// Ahenk browser bridge, page world, document_start: watches what the site
// tells the system about its player (Media Session metadata, action
// handlers, position) and which media elements play, before the site's own
// scripts run. Changes nothing the site does; only remembers and notifies.
// One exception, at Ahenk's own request: a page Ahenk loads another page
// over does not ask whether to leave (see `leaveQuietly`).
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

  // The sound YouTube's player holds ahead of what it plays: a copy of the
  // audio stream as the player hands it to the browser (lib/sound.js), so
  // Ahenk can hear what a video sings before it is sung. Kept in this page
  // only, a few megabytes at most, and given to Ahenk when it asks. (Ahenk
  // also runs this file in its own embedded player, for a song's clip.)
  let sound = null;
  const S = window.AhenkSound;
  if (S && /(^|\.)youtube(-nocookie)?\.com$/.test(location.hostname) && window.MediaSource && window.SourceBuffer && typeof WeakMap === 'function') {
    /** Audio streams, newest last. */
    const captures = [];
    const ofBuffer = new WeakMap();
    /** MediaSource → the address a media element plays it from. */
    const addresses = new WeakMap();

    const ranges = (buffer) => {
      const list = [];
      try {
        const held = buffer.buffered;
        for (let i = 0; i < held.length; i += 1) list.push([held.start(i), held.end(i)]);
      } catch (_) {
        // A buffer taken out of its source has none.
      }
      return list;
    };
    /** Counts the last append, once the buffer shows it. */
    const settle = (capture, buffer) => {
      const waiting = capture.waiting;
      if (!waiting) return;
      capture.waiting = null;
      S.settle(capture, waiting.before, ranges(buffer), waiting.count, waiting.offset);
    };

    const createObjectURL = URL.createObjectURL;
    if (typeof createObjectURL === 'function') {
      URL.createObjectURL = function (object) {
        const address = createObjectURL.apply(this, arguments);
        try {
          if (object instanceof MediaSource) addresses.set(object, address);
        } catch (_) {
          // Ignored.
        }
        return address;
      };
    }

    const addSourceBuffer = MediaSource.prototype.addSourceBuffer;
    MediaSource.prototype.addSourceBuffer = function (type) {
      const buffer = addSourceBuffer.apply(this, arguments);
      try {
        if (/^audio\//i.test(String(type))) {
          const capture = S.capture(type);
          capture.source = typeof WeakRef === 'function' ? new WeakRef(this) : null;
          capture.waiting = null;
          ofBuffer.set(buffer, capture);
          captures.push(capture);
          if (captures.length > 3) captures.shift();
        }
      } catch (_) {
        // Never in the site's way.
      }
      return buffer;
    };

    const appendBuffer = SourceBuffer.prototype.appendBuffer;
    SourceBuffer.prototype.appendBuffer = function (data) {
      try {
        const capture = ofBuffer.get(this);
        if (capture && data) {
          // The append before this one is in the buffer by now.
          settle(capture, this);
          const bytes = data instanceof ArrayBuffer ? new Uint8Array(data) : new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
          const offset = Number(this.timestampOffset) || 0;
          const waiting = { before: ranges(this), count: S.append(capture, bytes, offset), offset };
          capture.waiting = waiting;
          this.addEventListener('updateend', () => {
            try {
              if (capture.waiting === waiting) settle(capture, this);
            } catch (_) {
              // Ignored.
            }
          }, { once: true });
        }
      } catch (_) {
        // Never in the site's way.
      }
      return appendBuffer.apply(this, arguments);
    };

    sound = {
      /** What is held, in a line (for a log: numbers only). */
      describe() {
        return captures.map((capture) => [
          capture.header ? 'h' : '-', capture.lost ? 'lost' : capture.full ? 'full' : 'ok', 'run' + capture.run,
          capture.start === null ? '?' : capture.start.toFixed(1), capture.until === null ? '?' : capture.until.toFixed(1), capture.bytes,
        ].join(' ')).join(' | ');
      },
      /** The stream `element` plays, when its beginning is known. */
      held(element) {
        const address = element && (element.currentSrc || element.src);
        let found = null;
        for (const capture of captures) {
          if (!capture.header || capture.start === null || capture.until === null) continue;
          const source = capture.source && capture.source.deref();
          if (address && source && addresses.get(source) === address) return capture;
          // Not told which element plays it: the newest stream.
          if (!capture.source || !source || !addresses.has(source)) found = capture;
        }
        return found;
      },
    };
  }

  // "Leave site?": a music site asks it when a page is loaded over one
  // that plays. Asked in a browser nobody looks at, it holds up the song
  // picked in Ahenk until somebody answers, and that pick was the answer.
  // So for a moment after the engine says it loads another page (and only
  // then; the site's question stays for everything the user does in the
  // tab), the site's own listeners are not reached. Registered before the
  // site's scripts run, in the capturing phase, so this one runs first.
  let quietUntil = 0;
  window.addEventListener('beforeunload', (event) => {
    if (Date.now() < quietUntil) event.stopImmediatePropagation();
  }, true);

  Object.defineProperty(window, '__ahenkHooks', {
    value: Object.freeze({
      state,
      sound,
      subscribe(listener) {
        listeners.add(listener);
        return () => listeners.delete(listener);
      },
      remember,
      notify,
      /** The page Ahenk loads next replaces this one without a question. */
      leaveQuietly() {
        quietUntil = Date.now() + 3000;
      },
    }),
    enumerable: false,
    configurable: false,
  });
})();

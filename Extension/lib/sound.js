// Ahenk browser bridge: the sound a player holds ahead of what it plays.
// YouTube's player hands its audio stream to the browser in pieces, well
// before they are heard; a copy of those pieces says what will be sung
// before it is sung (Ahenk times a video's lyrics with it). Pure: bytes and
// time ranges in, a stream that can be decoded and 16 kHz sound out. The
// sound goes to Ahenk on this Mac only; nothing here keeps or logs it.
(function (root) {
  'use strict';

  /** Samples a second of what Ahenk is given (mono). */
  const RATE = 16000;
  /** Bytes of one stream kept at most (about three minutes of a song). */
  const LIMIT = 4 << 20;
  /** A piece this far from what is held begins a new stretch (a seek). */
  const GAP = 0.5;
  /** The first bytes of a stretch, where its start time is looked for. */
  const HEAD = 512;

  function startsWith(bytes, at, values) {
    if (at < 0 || at + values.length > bytes.length) return false;
    for (let i = 0; i < values.length; i += 1) if (bytes[at + i] !== values[i]) return false;
    return true;
  }

  function find(bytes, values, from) {
    for (let i = from || 0; i + values.length <= bytes.length; i += 1) if (startsWith(bytes, i, values)) return i;
    return -1;
  }

  const EBML = [0x1a, 0x45, 0xdf, 0xa3];
  const CLUSTER = [0x1f, 0x43, 0xb6, 0x75];
  const FTYP = [0x66, 0x74, 0x79, 0x70];
  const MOOF = [0x6d, 0x6f, 0x6f, 0x66];
  /** MP4 boxes that belong to a stream's header. */
  const HEADER_BOXES = ['ftyp', 'moov', 'free', 'skip'];

  /** 'webm' or 'mp4' when `bytes` begin a stream, else null. */
  function container(bytes) {
    if (startsWith(bytes, 0, EBML)) return 'webm';
    if (startsWith(bytes, 4, FTYP)) return 'mp4';
    return null;
  }

  /** How many bytes at the start of `bytes` are a stream's header (WebM:
   *  up to its first cluster; MP4: its ftyp and moov); 0 when `bytes` do
   *  not begin a stream. */
  function headerLength(bytes) {
    const kind = container(bytes);
    if (kind === 'webm') {
      const cluster = find(bytes, CLUSTER, 4);
      return cluster < 0 ? bytes.length : cluster;
    }
    if (kind === 'mp4') {
      let at = 0;
      while (at + 8 <= bytes.length) {
        const size = ((bytes[at] << 24) | (bytes[at + 1] << 16) | (bytes[at + 2] << 8) | bytes[at + 3]) >>> 0;
        const type = String.fromCharCode(bytes[at + 4], bytes[at + 5], bytes[at + 6], bytes[at + 7]);
        if (!HEADER_BOXES.includes(type)) return at;
        if (size < 8) return bytes.length;
        at += size;
      }
      return bytes.length;
    }
    return 0;
  }

  /** Where the first whole piece of sound begins in `bytes` (a WebM
   *  cluster, an MP4 fragment); -1 when none does. */
  function pieceStart(bytes, kind) {
    if (kind === 'webm') return find(bytes, CLUSTER, 0);
    const moof = find(bytes, MOOF, 4);
    return moof < 0 ? -1 : moof - 4;
  }

  function number(bytes, at, length) {
    let value = 0;
    for (let i = 0; i < length; i += 1) value = value * 256 + bytes[at + i];
    return value;
  }

  /** The video's time (seconds) at which the piece of sound that `bytes`
   *  begin with starts, read from the stream itself (a WebM cluster's
   *  timecode, an MP4 fragment's decode time); null when it is not there. */
  function pieceTime(bytes, kind, header) {
    if (kind === 'webm') {
      if (!startsWith(bytes, 0, CLUSTER) || bytes.length < 8) return null;
      // The cluster's size, then its children: the timecode comes first
      // (a checksum or padding may stand before it).
      let at = 4;
      let width = 1;
      while (width <= 8 && !(bytes[at] & (0x80 >> (width - 1)))) width += 1;
      at += width;
      for (let children = 0; children < 4 && at + 2 <= bytes.length; children += 1) {
        const id = bytes[at];
        const size = bytes[at + 1] & 0x7f;
        if (!(bytes[at + 1] & 0x80) || size > 8 || at + 2 + size > bytes.length) return null;
        if (id === 0xe7) {
          let scale = 1000000;
          const stated = header ? find(header, [0x2a, 0xd7, 0xb1], 0) : -1;
          if (stated >= 0 && (header[stated + 3] & 0x80) && (header[stated + 3] & 0x7f) <= 6) scale = number(header, stated + 4, header[stated + 3] & 0x7f) || scale;
          return (number(bytes, at + 2, size) * scale) / 1e9;
        }
        if (id !== 0xbf && id !== 0xec) return null;
        at += 2 + size;
      }
      return null;
    }
    if (kind === 'mp4') {
      const stated = find(bytes, [0x74, 0x66, 0x64, 0x74], 0);
      const media = header ? find(header, [0x6d, 0x64, 0x68, 0x64], 0) : -1;
      if (stated < 0 || media < 0) return null;
      const long = bytes[stated + 4] === 1;
      if (stated + 8 + (long ? 8 : 4) > bytes.length) return null;
      const scaleAt = media + 4 + 4 + (header[media + 4] === 1 ? 16 : 8);
      if (scaleAt + 4 > header.length) return null;
      const scale = number(header, scaleAt, 4);
      return scale > 0 ? number(bytes, stated + 8, long ? 8 : 4) / scale : null;
    }
    return null;
  }

  /** What `after` holds that `before` did not, as [start, end] pairs
   *  (both are lists of such pairs, in order). */
  function added(before, after) {
    const fresh = [];
    for (const [start, end] of after) {
      let from = start;
      for (const [heldStart, heldEnd] of before) {
        if (heldEnd <= from || heldStart >= end) continue;
        if (heldStart > from + 1e-3) fresh.push([from, heldStart]);
        from = Math.max(from, heldEnd);
      }
      if (end > from + 1e-3) fresh.push([from, end]);
    }
    return fresh;
  }

  /** One audio stream as it is handed over. `start`…`until` (seconds of
   *  the video) is the stretch `header` + `media` decode to; `run` counts
   *  the stretches (a new stream, a seek). */
  function capture(mime) {
    return { mime: String(mime || ''), kind: null, header: null, media: [], head: new Uint8Array(0), bytes: 0, counted: 0, start: null, until: null, run: 0, full: false, lost: false };
  }

  /** Bytes the page appends (copied, never kept by reference); `offset`
   *  is the buffer's timestamp offset. Returns how many pieces are held
   *  afterwards, for `settle`. */
  function append(held, bytes, offset) {
    let rest = bytes;
    const head = headerLength(bytes);
    if (head > 0) {
      // A new stream: what was held belonged to another.
      held.kind = container(bytes);
      held.header = bytes.slice(0, head);
      held.media = [];
      held.head = new Uint8Array(0);
      held.bytes = 0;
      held.counted = 0;
      held.start = null;
      held.until = null;
      held.full = false;
      held.lost = false;
      held.run += 1;
      rest = bytes.subarray(head);
    }
    if (!held.header || held.full || held.lost || !rest.length) return held.media.length;
    if (held.bytes + rest.length > LIMIT) {
      // The beginning is what matters: the rest of a long video is let go.
      held.full = true;
      return held.media.length;
    }
    if (held.start === null && held.head.length < HEAD) {
      // Where the stretch begins is in the stream itself, in its first
      // bytes (which may come in several appends).
      const head = new Uint8Array(Math.min(HEAD, held.head.length + rest.length));
      head.set(held.head, 0);
      head.set(rest.subarray(0, head.length - held.head.length), held.head.length);
      held.head = head;
      const time = pieceTime(head, held.kind, held.header);
      if (time !== null) held.start = time + (Number.isFinite(offset) ? offset : 0);
    }
    held.media.push(rest.slice());
    held.bytes += rest.length;
    return held.media.length;
  }

  /** After an append: `before` and `after` are the buffer's time ranges
   *  around it, `count` what `append` returned, `offset` the buffer's
   *  timestamp offset. Moves `until`; a piece away from the stretch held
   *  (a seek) begins a new stretch with it. */
  function settle(held, before, after, count, offset) {
    if (!held.header || held.lost) return;
    const fresh = added(before || [], after || []);
    if (!fresh.length) return;
    const from = fresh[0][0];
    const to = fresh[fresh.length - 1][1];
    const pieces = Math.min(Math.max(count || 0, held.counted), held.media.length);
    if (held.start === null) {
      // Not told by the stream: where the buffer grew.
      held.start = from;
      held.until = to;
    } else if (held.until === null) {
      // The stream told where it begins; the buffer must have grown after it.
      if (to < held.start) return;
      held.until = to;
    } else if (from > held.until + GAP || from < held.start - GAP) {
      // The pieces not counted yet hold the new stretch. It begins with a
      // whole piece of sound that starts where the buffer grew (what came
      // before it is the tail of the stretch before), or it cannot be
      // told where it begins.
      const shift = Number.isFinite(offset) ? offset : 0;
      const waiting = held.media.slice(held.counted);
      let kept = [];
      let begins = null;
      const untimed = [];
      for (let i = 0; i < waiting.length && !kept.length; i += 1) {
        const at = pieceStart(waiting[i], held.kind);
        if (at < 0) continue;
        const piece = waiting[i].subarray(at);
        const time = pieceTime(piece, held.kind, held.header);
        if (time === null) {
          untimed.push(i);
        } else if (Math.abs(time + shift - from) <= GAP) {
          kept = [piece].concat(waiting.slice(i + 1));
          begins = time + shift;
        }
      }
      // No piece says when it starts: a single one is where the buffer grew.
      if (!kept.length && untimed.length === 1) {
        const i = untimed[0];
        kept = [waiting[i].subarray(pieceStart(waiting[i], held.kind))].concat(waiting.slice(i + 1));
        begins = from;
      }
      held.run += 1;
      if (held.full || !kept.length) {
        held.lost = true;
        held.media = [];
        held.bytes = 0;
        held.start = null;
        held.until = null;
        return;
      }
      held.media = kept;
      held.bytes = kept.reduce((sum, piece) => sum + piece.length, 0);
      held.counted = kept.length;
      held.start = begins;
      held.until = to;
      return;
    } else {
      held.until = Math.max(held.until, to);
    }
    held.counted = pieces;
  }

  /** The stream so far, as one file a decoder reads. */
  function stream(held) {
    const all = new Uint8Array(held.header.length + held.bytes);
    all.set(held.header, 0);
    let at = held.header.length;
    for (const piece of held.media) {
      all.set(piece, at);
      at += piece.length;
    }
    return all;
  }

  /** Several channels as one. */
  function mono(channels) {
    if (channels.length === 1) return channels[0];
    const length = channels[0].length;
    const mixed = new Float32Array(length);
    for (const channel of channels) for (let i = 0; i < length; i += 1) mixed[i] += channel[i];
    for (let i = 0; i < length; i += 1) mixed[i] /= channels.length;
    return mixed;
  }

  /** `seconds` of `samples` (which begin at `start` of the video) from
   *  `from`, or from where they begin if that is later; null when they do
   *  not reach that far yet. */
  function cut(start, samples, from, seconds) {
    const first = Math.max(from, start);
    const offset = Math.round((first - start) * RATE);
    const wanted = Math.round(seconds * RATE);
    // A decoder may drop a few milliseconds at the very beginning.
    const length = Math.min(wanted, samples.length - offset);
    if (length < wanted - RATE / 10 || length <= 0) return null;
    return { start: first, samples: samples.subarray(offset, offset + length) };
  }

  /** Samples as 16-bit little-endian PCM in base64. */
  function pcm16(samples) {
    const bytes = new Uint8Array(samples.length * 2);
    for (let i = 0; i < samples.length; i += 1) {
      const value = Math.max(-1, Math.min(1, samples[i]));
      const whole = Math.round(value < 0 ? value * 32768 : value * 32767);
      bytes[i * 2] = whole & 0xff;
      bytes[i * 2 + 1] = (whole >> 8) & 0xff;
    }
    let text = '';
    for (let i = 0; i < bytes.length; i += 32768) text += String.fromCharCode.apply(null, bytes.subarray(i, i + 32768));
    return btoa(text);
  }

  const api = { RATE, LIMIT, container, headerLength, pieceStart, pieceTime, added, capture, append, settle, stream, mono, cut, pcm16 };
  // The newest scripts win: an updated extension puts its own over the
  // ones a page still holds (a page from before 1.5.0 keeps its own
  // until it loads again).
  try {
    Object.defineProperty(root, 'AhenkSound', { value: Object.freeze(api), configurable: true, enumerable: false });
  } catch (_) {
    // Held by scripts that cannot be replaced.
  }
})(typeof globalThis !== 'undefined' ? globalThis : this);

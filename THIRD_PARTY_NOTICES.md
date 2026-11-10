# Third-party notices

Ahenk is released under the MIT License (see `LICENSE`). It includes the
following third-party code.

## mediaremote-adapter

- Upstream: https://github.com/ungive/mediaremote-adapter
- Location in this repository: `Vendor/mediaremote-adapter` (sources, the
  `mediaremote-adapter.pl` script, the public header and the license; the
  upstream build files, editor settings and CI scripts are not included).
- How Ahenk uses it: `Scripts/build-adapter.sh` compiles
  `MediaRemoteAdapter.framework`, which `Scripts/make-app.sh` bundles with the
  script in `Ahenk.app/Contents/Resources/adapter`. Ahenk runs the script with
  the system's `/usr/bin/perl` to read what is playing (macOS 15.4 and later
  only allow Apple-signed processes to read MediaRemote). Ahenk does not link
  against the framework.
- License: BSD 3-Clause

```
BSD 3-Clause License

Copyright (c) 2025, Jonas van den Berg and contributors

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## Lyrics

- The lyrics providers, the chain, the timeline vote, the cache, the LRC
  parser and the automatic sync measurement (`Sources/AhenkKit/Lyrics`) were
  ported from DynamicIsland by the same author, under the same MIT License.
- The lyric styles use fonts that come with macOS; Ahenk bundles no fonts.
- No lyrics ship with Ahenk. While lyrics are on, they are fetched from
  LRCLIB, Musixmatch and NetEase for the song that plays and kept only in the
  user's cache (`~/Library/Caches/Ahenk/Lyrics`).

## Demo content

The songs, artists, albums and lyric lines used by `--demo` and in the tests
were written for Ahenk, and the demo covers are generated in code. They are
part of Ahenk and covered by its MIT License.

## Live wallpaper

- The motion artwork lookup (`Sources/AhenkKit/Wallpaper/MotionArtwork.swift`)
  was ported from DynamicIsland by the same author, under the same MIT
  License.
- No videos, motion artwork or covers ship with Ahenk, and none are
  downloaded or stored. While the live wallpaper shows them, motion artwork is
  streamed from Apple's catalog, music videos play in YouTube's own embedded
  player (privacy-enhanced mode, `www.youtube-nocookie.com`, loaded at run
  time and subject to YouTube's terms), and the user's own videos play from
  where they are. Searches and catalog answers (titles, IDs, lengths) are
  cached in `~/Library/Caches/Ahenk/Catalog`.

## whisper.cpp (optional, not included)

- Upstream: https://github.com/ggml-org/whisper.cpp (MIT License)
- Ahenk does not include whisper.cpp or any speech model. "Align Lyrics"
  (Beta) runs a `whisper-cli` the user installed (for example with
  `brew install whisper-cpp`) and a `ggml-*.bin` model already on the Mac.
  **Download the Model** fetches the suggested model from the whisper.cpp
  project's model page on Hugging Face only when the user presses it, into
  `~/Library/Application Support/Ahenk/Models`.

## App icon

The app icon is drawn by `Scripts/make-icon.swift` for Ahenk and is covered
by its MIT License.

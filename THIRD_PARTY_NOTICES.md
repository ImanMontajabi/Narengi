# Third-party notices

## Satsuma (MIT)

Parts of Narengi are ported to Swift from **Satsuma**, a Rust re-implementation of the same workflow
(<https://github.com/sonatina-dream/satsuma>). Only behaviour, data tables and algorithms were ported; no
Rust code is compiled into Narengi. The ported pieces, with the Satsuma file each came from:

| Narengi | Satsuma source |
|---|---|
| `Core/FormatCatalog.swift` (route matrix, selection rule) | `satsuma-core/src/matrix.rs`, `SPEC.md` §4 |
| `Core/Tools.swift` (26 tools, per-format lists, labels, actions) | `satsuma-core/src/tools.rs`, `actions.rs` |
| `Core/NamingRules.swift` (` 2` collision naming, stems) | `satsuma-core/src/naming.rs` |
| `Overlay/WheelGeometry.swift` (petals, gaps, hit test, clamping, hub text, keyboard navigation) | `satsuma-core/src/geometry.rs`, `wheel.rs` |
| `Engines/MediaEngine.swift`, `MediaEnvironment.swift` (codec choices, GIF palette, probe, progress) | `satsuma-engine/src/media.rs`, `probe.rs`, `env.rs` |
| `Engines/ArchiveEngine.swift` | `satsuma-engine/src/archive.rs` |
| `Engines/SubtitleEngine.swift` | `satsuma-engine/src/subtitle.rs` |
| `Engines/SheetEngine.swift` | `satsuma-engine/src/sheet.rs` |
| `Engines/OCREngine.swift` (paragraph grouping) | `satsuma-engine/src/ocr.rs` |
| `Engines/Tools/MediaTools.swift` (normalize, trim silence, channels, mute, speed, snapshot, split, join, visualizer, compress, metadata filters) | `satsuma-engine/src/media.rs` |
| `Engines/Tools/MetadataStripper.swift` (lossless JPEG/PNG/WebP/GIF stripping, orientation kept) | `satsuma-engine/src/metadata.rs` |
| `Engines/Tools/PDFTools.swift`, `CompressEngine.swift` (split, merge, compress strengths, "never grow" rule) | `satsuma-engine/src/pdf.rs`, `image.rs`, `run.rs` |
| `Editing/CropGeometry.swift` (handles, aspect fitting, drag rules, gradients, frame layout) | `satsuma-core/src/edit.rs` |
| `Float/*`, `Actions/ActionRunner.swift` (shelf layout and behaviour, action set) | `satsuma-app/src/float.rs`, `satsuma-core/src/actions.rs` |
| `Engines/Tools/VideoTools.swift` (trim, crop, redact and bleep argument choices; even-size rule) | `satsuma-engine/src/media.rs` |
| `Engines/Documents/*` (HTML hub, HTML→Markdown, printable HTML, DOCX/EPUB writers, text clippings) | `satsuma-engine/src/doc.rs`, `html.rs`, `docx.rs`, `epub.rs` |

```
MIT License

Copyright (c) 2026 The Satsuma contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

Satsuma was read from a temporary local clone, which has since been deleted; nothing of it is built or bundled.

## Bundled helper tools

Fetched by `scripts/setup-vendor.sh` (cwebp, ExifTool) and copied by `scripts/bundle-ffmpeg.sh` (ffmpeg):

- **libwebp / `cwebp`**: BSD-3-Clause, © Google Inc. and the WebM Project.
- **ExifTool**: Artistic License / GPL, © Phil Harvey.
- **FFmpeg** (`Vendor/bin/ffmpeg`) and its libraries in `Vendor/lib/` (libx264, libx265, libvpx, libopus, libmp3lame, dav1d, SVT-AV1,
  libvmaf, OpenSSL, mpg123, xz, and the libav* family): copied from the local Homebrew installation. **This build is GPL
  (version 3 or later)** because of x264 and x265, and some libraries have their own licenses (see
  `Vendor/licenses/ffmpeg-NOTICE.txt`). That is fine for running Narengi on your own Mac. If you ever redistribute
  the app, either ship a build of FFmpeg without `--enable-gpl` or comply with the GPL for the bundled copy, including
  offering its source (https://ffmpeg.org/).

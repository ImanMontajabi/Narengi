# Narengi: Reverse-Engineering Findings & Architecture

Target: `/Applications/Tangerine.app` v2.0.2 (build 9), arm64, Mach-O SHA-256 `7691b34c…a92928`.
Tools: REA + Hopper (static only, nothing executed), `otool`, `codesign`, 19 screenshots in `./screenshot`.

Labels: **[O]** observed in the artifact, **[I]** inferred, **[U]** unknown / not yet verified.
Evidence IDs (REA): drag/overlay strings `ev_355f89fc…`, `ev_c1f94f4b…`; class inventory `ev_ff8034fe…`, `ev_2c47c6ce…`.

---

## 1. Bundle facts

| Item | Finding |
|---|---|
| Bundle ID / type | `com.th.Tangerine`, `LSUIElement=true` (no Dock icon, menu-bar agent) **[O]** |
| Min OS | macOS 13.0; built with Xcode 27 / SDK macosx27.0 **[O]** |
| Language/UI | Swift + SwiftUI + AppKit (`libswiftAppKit`, `SwiftUI`, `_TtC9Tangerine…` classes) **[O]** |
| Sandbox | App Sandbox **on**; entitlements: `files.user-selected.read-write`, `files.bookmarks.app-scope`, `network.client` **[O]** |
| Network | Only for licensing: RevenueCat SDK, StoreKit, AdServices **[O]**. Conversion is local. |
| Frameworks | AVFoundation, AVKit, CoreImage, ImageIO, PDFKit, Quartz, Vision, QuickLookUI/Thumbnailing, JavaScriptCore, WebKit, Compression (Swift), CryptoKit, ServiceManagement, IOKit **[O]** |
| Bundled helpers | `Resources/Tools/ffmpeg` (LGPL), `Tools/cwebp` (libwebp), LAME (MP3 encoder, license only listed), `ExifTool/` (Perl: `tangerine_metadata.pl`, `tangerine_privacy.pl`), `PowerPoint/{arm64,x86_64,lib}`, `OfficePreview.js`, `PagesWriter.js`, `PagesTemplate.pages`, `HighlightSound.{wav,mp3}` **[O]** |
| 3rd-party code | `cupertino-files 0.4.0` (MIT; includes Apple LZVN decoder → likely reads `.pages` / iWork / bplist containers) **[O]** |
| Licensing | 20 free uses, then €34.99 one-time unlock (RevenueCat) **[O]** (see §7: not replicated) |

## 2. Global drag + modifier detection

Observed symbols/strings: `DragGestureMonitor` (`Tangerine/DragGestureMonitor.swift`), log line `"[Tangerine] Drag shortcut monitor started"`, `addGlobalMonitorForEventsMatchingMask:handler:`, `addLocalMonitorForEventsMatchingMask:handler:`, `removeMonitor:`, properties `activeDragPasteboardChangeCount`, `pasteboardChangeCountBeforeMouseDown`, `lastObservedPasteboardChangeCount`, `clipboardChangeCount`, plus `NSTimer` / dispatch-source timers.

**Inferred mechanism [I], consistent with all of the above:**
1. A global `NSEvent` monitor sees `leftMouseDown`, `leftMouseDragged`, `leftMouseUp` and `flagsChanged`.
2. On `leftMouseDown` the monitor snapshots `NSPasteboard(name: .drag).changeCount` (`pasteboardChangeCountBeforeMouseDown`).
3. When the drag-pasteboard count changes during `leftMouseDragged`, a file drag from another app is active (`activeDragPasteboardChangeCount`). File URLs are read from the drag pasteboard (`.fileURL` items).
4. A modifier "tap" while dragging (per setting text "Tap the chosen modifier combination while dragging files") is detected from `flagsChanged` and selects the wheel: Conversion / Tools / Actions.
5. Timers handle debounce/poll (`replacementTimer`, `resizeTimer`).

**[U]** Exact event mask and whether a `CGEventTap` is used: no `CGEventTap` string was found, so global `NSEvent` monitoring is the observed route. Required TCC permission (Input Monitoring / Accessibility) was not determined statically. Narengi should verify empirically.

**Defaults from screenshots [O]:** Conversion wheel = **Shift**, Tools wheel = **Command**, Actions wheel = **Control**. All three are user-selectable pop-ups. *(Your brief said Shift+Option for tools; the shipped default is Command. Narengi will make all three configurable and default as you prefer.)*

## 3. Overlay windows

Observed classes **[O]**: `ConversionOverlayPanel` (overrides `canBecomeKey/Main`, `initWithContentRect:styleMask:backing:defer:`), `FileToolOptionsPanel`, `OperationProgressPanel`, `QRCodeResultsPanel`, `PaywallPanel`, `WelcomePanel`, `FloatingFilePanel` (+ `constrainFrameRect:toScreen:`), `TangerinePanelBackgroundView`, and selectors `setLevel:`, `setCollectionBehavior:`, `setIgnoresMouseEvents:`, `setFloatingPanel:`. SwiftUI `GlassEffectContainer` is imported (Liquid Glass, matching the "Glass / Solid" style setting). Wheel drawing uses SwiftUI `Path.addArc`, `RadialGradient`, `Canvas/GraphicsContext.stroke`, `DragGesture`, `Font.system(size:weight:design:)`, `Text.tracking`.

**[U]** The numeric window level, style mask and collection-behavior values were not extracted. **Narengi design choice [I]:** `NSPanel` with `.borderless + .nonactivatingPanel`, level `.popUpMenu`/`.screenSaver`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`, `hasShadow=false`, transparent background, `ignoresMouseEvents=false` only while a drop is hovering a slice.

**Drop capture without breaking Finder's drag [I]:** the panel registers for `NSPasteboard.PasteboardType.fileURL` as an `NSDraggingDestination`; Finder's drag session is never owned or cancelled by Narengi. Slice hit-testing is done from the `draggingUpdated:` location (`FloatingFileDragSourceView` implements the full `draggingEntered/Updated/Exited/performDragOperation/concludeDragOperation` set **[O]**), and the highlight follows the cursor angle.

## 4. Wheels and tools (from screenshots)

**Wheel geometry [O, from screenshots 12.30.38 / 12.30.52 / 12.30.57]:** a ring about 250 pt in diameter centred on the cursor, translucent dark glass, an inner circle showing total size of the dragged files (e.g. `3,3 MB`), and rounded wedge slices with an icon + small-caps label. Slice counts differ by wheel: the Tools wheel shows 5 slices (**Compress, Metadata, Read QR, Organize, Split**); the Conversion wheel shows up to ~9 target formats (for a PDF: DOCX, PAGES, PPTX, XLSX, JPG, PNG, EPUB, TXT, MD). Above the Conversion wheel a small ⚡ button appears and a **"Drop files here"** glass tile (the Float shelf). Selected/hovered slice brightens; a Finder-style blue file label follows the cursor.

**Tool windows [O]:** all are dark rounded panels with an `×` button top-left, a centred title, a footer action in accent orange.
- **Metadata** (12.31.49): file name + "Search metadata", grouped key/value rows, a ⊖ remove button per row, editable text fields, "Remove All", "Save". Footer note: "For photos, Remove All also clears hidden camera and processing data. HDR and portrait effects may change." → ExifTool-backed.
- **Compress** (12.32.18): original size, Mode pop-up (Percentage / presets), "Reduce by" slider 0–100 %, live estimate "Output will be at most 1,6 MB.", "Compress" button.
- **Read QR** (12.32.37): results list or empty state "No QR codes found", "Copy All" → Vision `VNDetectBarcodesRequest` **[I]** (Vision is linked).
- **Organize PDF** (12.32.57): 42-page thumbnail grid (4 columns), numbered orange badges, per-page rotate button, drag-to-reorder, "Reset Order", checkbox "Make all pages the same width", "Save Organized PDF" → PDFKit **[I]**.
- **Split** (12.33.20): produces `Page N.pdf` files beside the original (Finder screenshot) → PDFKit **[I]**.
- **Float** (12.30.57): a floating shelf window with context-menu actions Open, Open With, Quick Look, Show in Finder, Copy, Duplicate, Move to Trash, Remove from Float; rubber-band multi-selection; drag-out source; Quick Look via `QLPreviewPanel` **[O]** (class names). Setting "Float Behaviour: Create a New Float".
- **Actions wheel** items per the brief: AirDrop, Float, Copy, Move, Copy Path, Open in Terminal (Setting "Terminal app") **[O for settings, I for items; the Actions wheel itself is not in the screenshots]**.
- **Redact / Annotate**: classes `RedactionTimeRange`, `RedactionDeleteKeyHandler`, `AnnotationKeyboardHandler` exist **[O]**; no screenshots, so UI is **[U]**.

**Settings window [O]:** 5 tabs: General (Appearance Glass/Solid; Launch at login; Sound and haptic feedback; Drag Modifiers; Float Behaviour; Terminal app), **Formats** (sidebar by category + per-format settings: Quality, Preserve metadata, Image Compression Balanced/Strong, Image size), **Compatibility** (per-category input→output check matrix), **Folders** (sandbox folder grants, "Add Folder…"), **About** (version, uses left, Unlock/Restore). Accent colour ≈ orange `#F26522`; surfaces ≈ `#222`/`#2A2A2A`; rounded 12–14 pt cards. Haptics via `NSHapticFeedbackManager.performFeedbackPattern` + `HighlightSound` **[O]**.

## 5. Conversion / compression engines

| Category | Tangerine engine | Evidence | Narengi plan |
|---|---|---|---|
| Images (JPG, PNG, HEIC, TIFF, BMP, AVIF, SVG, PDF) | ImageIO (`CGImageSource/Destination`), CoreImage; `CGImageMetadata*` for preserving metadata | **[O]** imports | ImageIO + CoreGraphics; SVG via WebKit/NSImage render |
| WebP | bundled `cwebp` (libwebp); decode via ImageIO | **[O]** | Bundle `cwebp` (BSD) or use system if present |
| Audio / Video | bundled `ffmpeg` (LGPL) + LAME; falls back to `/opt/homebrew/bin` and `/usr/local/bin` ffmpeg; AVFoundation also linked | **[O]** | Spawn `ffmpeg` (user supplied or bundled LGPL build), AVAssetExportSession for fast MOV/MP4/M4A paths |
| PDF | PDFKit (+Quartz filters probable for compression) | **[O]** link / **[I]** use | PDFKit + Quartz `QuartzFilter`/image resampling |
| Office/iWork (DOCX, PAGES, PPTX, PPT, XLSX, ODS…) | JavaScriptCore running `OfficePreview.js`, `PagesWriter.js` (+`PagesTemplate.pages`), a `PDFOfficeConverter` class that reflows PDF text to HTML/images, `PowerPoint/` arm64+x86_64 payload | **[O]** | Largest unknown. See §8. |
| Text/RTF/HTML/MD | `NSAttributedString` / `NSXMLNode` text readers **[I]** | partial **[O]** | Foundation + AppKit document readers |
| Archives | Swift `Compression` framework; ZIP/TAR/GZIP (RAR input only per matrix) | **[O]** | `Compression` + `/usr/bin/ditto`/`tar` (non-sandboxed) |
| Subtitles SRT/VTT | in-process text transform **[I]** | matrix only | trivial parsers |
| Metadata | bundled ExifTool via Perl scripts (`tangerine_metadata.pl`, `tangerine_privacy.pl`) | **[O]** | Bundle ExifTool (Artistic/GPL) or call `/usr/bin/perl` |
| QR | Vision **[I]** | link | `VNDetectBarcodesRequest` |

Compatibility matrices (screenshots 12.36.16–12.36.42) define the legal input→output pairs; Narengi will encode them as data (`FormatMatrix.swift`) rather than code.

## 6. Proposed Narengi architecture

```
Narengi/
  App/            NarengiApp (MenuBarExtra), AppDelegate, SettingsStore (UserDefaults)
  Input/          DragGestureMonitor     (global NSEvent monitors, drag-pasteboard changeCount)
                  ModifierResolver       (maps held/tapped modifiers → WheelKind)
  Overlay/        WheelPanel (NSPanel), WheelView (SwiftUI Canvas/Path), WheelGeometry (angle→slice),
                  DropTargetView (NSDraggingDestination), HUDPanel
  Core/           Job, JobQueue (async/await, cancellable), OutputNamer (collision-safe "name 2.ext")
                  FormatMatrix, UTType helpers
  Engines/        ImageEngine, AudioVideoEngine (ffmpeg/AVF), PDFEngine, OfficeEngine,
                  ArchiveEngine, SubtitleEngine, MetadataEngine (ExifTool), QREngine
  Tools/          Compress, Metadata, ReadQR, OrganizePDF, SplitPDF, Redact, Annotate
  Actions/        AirDrop (NSSharingService), Float, Copy, Move, CopyPath, OpenInTerminal
  Float/          FloatShelfPanel, FloatItemView, drag-out source
  UI/Settings/    General, Formats, Compatibility, Folders, About, Onboarding
  Resources/      Tools/ (ffmpeg, cwebp), ExifTool/
```

Key decisions:
- **Distribution: not sandboxed (Developer ID).** Tangerine's sandbox forces the Folders tab and per-folder grants; Narengi saves "beside the original" without that friction, and can spawn helpers freely. (Mac App Store distribution would need Tangerine's bookmark model.)
- Swift concurrency for jobs, `Progress` for HUD, results revealed with `NSWorkspace.activateFileViewerSelecting`.
- Wheel math isolated in `WheelGeometry` (pure, unit-testable): slice = `floor(((atan2(dy,dx)+π/2) mod 2π) / (2π/n))`, with an inner dead zone radius.
- Everything local; **no network entitlement**.

## 7. What Narengi will deliberately not copy

- RevenueCat / paywall / usage cap (your brief says no file limits).
- Tangerine's icon, `Assets.car`, name, copy text and sounds; Narengi gets its own artwork (an orange-slice motif is fine, but redrawn).
- The reverse-engineering informs *behavior and architecture*; no decompiled code is reused.

## 8. Open questions / unknowns

1. TCC permission needed for the global monitor (Input Monitoring vs Accessibility), and exact event mask. Needs a runtime test on this machine.
2. Overlay window level and style mask values (not extracted).
3. How Office conversions work. `OfficePreview.js`/`PagesWriter.js` are JS run in JavaScriptCore; what the `PowerPoint/` binaries are is unidentified. Quality of DOCX/PPTX/XLSX output will be the hardest part; likely staged: PDF→TXT/MD/HTML/EPUB/images first, OOXML writers later.
4. Redact and Annotate UIs (no screenshots).
5. Actions-wheel items and visuals (no screenshot). Website/App Store pages were not fetched; I can do that next if useful.

## 8b. Web findings (tangerineformac.com, App Store page)

- **Actions wheel** (Control, while dragging): AirDrop, Float, Copy, Move, Copy Path, Terminal. Works on folders and mixed selections; no conversion allowance used.
- **Wheel behaviour:** once opened by tapping the modifier mid-drag, the wheel stays open until drop or cancel, even after the key is released. Keyboard: Enter opens a file's format menu, arrows choose, Enter applies, Escape cancels. Pressing Command inside a format menu switches to the Tools wheel.
- **Tools (26 total, per file type):** Compress (also to an exact target size); Photos: crop, adjust, annotate, redact; Video: trim, crop, speed, split, join, snapshot; Audio: normalize, trim, bleep, channels; Metadata read/edit/remove; PDF: merge, split, reorganize, images→PDF/collage; Read QR.
- 275 conversion options; notable limits: PDF export from images is SVG-input only, RAR and PPT are input only.
- Redact/Annotate UIs are not described or shown on either page. Still unknown; Narengi will design them (rectangle blackout/blur + text/arrow markup).
- The App Store page lists Shift+Option for the Tools wheel (v1 behaviour); v2 defaults to Command. Narengi supports both.

## 9. Proposed build order

1. Xcode/SwiftPM project, menu bar item, Settings shell (General + Folders-less).
2. `DragGestureMonitor` + wheel overlay with hover + sounds/haptics; prove it against a real Finder drag (highest risk).
3. Job queue + progress HUD + output naming.
4. Image engine → audio/video (ffmpeg) → PDF → archives → text/subtitles.
5. Tools: Compress, Metadata, QR, Organize, Split.
6. Actions wheel + Float shelf.
7. Redact/Annotate, Office conversions.


## 10. Implementation status (updated after Milestone 7)

Decisions: pure Swift/SwiftUI/AppKit, non-sandboxed, no Rust. Behaviour, data and algorithms were ported from
Satsuma (MIT; see `THIRD_PARTY_NOTICES.md`).

| Area | State |
|---|---|
| Menu-bar item (`NSStatusItem`, retained, SF Symbol → drawn image → text fallback), reopen → Settings, hidden-by-notch detection | done |
| Drag monitor, wheel overlay with petal gaps, 3-petal start, dense labels, screen clamping, hub caption, empty-wheel messages, keyboard/click mode (**Convert Files…**) | done |
| Route matrix (283 reference paths + Narengi extras), selection rule, 26 tools data, naming (` 2`), hidden-staging atomic outputs | done |
| Job queue, progress HUD | done |
| Image, PDF (+OCR), audio/video (ffmpeg), documents (textutil hub, DOCX/EPUB writers), spreadsheets (CSV/TSV/XLSX/ODS), subtitles, archives engines | done |
| Tools wheel pipelines, Actions wheel, Float shelf + drop tile, Compress/Metadata/Read QR/Organize windows, Crop/Add Background/Edit Photo/Annotate/Redact editors | **Milestone 6: done** (Pages/PowerPoint/PDF→XLSX output remain unimplemented and hidden) |
| Welcome guide, Trim/Crop/Redact Video, Bleep Audio, bundled ffmpeg, release build + install | **Milestone 7: done** |
| Pages, PowerPoint, PDF→XLSX, legacy XLS input | not implemented (hidden from the wheel) |

Web findings recap: see §8b. Narengi-only extras beyond the reference matrix: PDF→HTML/TIFF, image→TXT/MD.

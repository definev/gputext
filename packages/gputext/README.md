# gputext

GPU-accelerated vector text for Flutter. Glyphs are rasterized by an analytic
coverage shader through [Flutter GPU](https://docs.flutter.dev/), with
[HarfBuzz](https://harfbuzz.github.io/) for shaping (complex scripts and
bidirectional text).

> **Pre-release.** Requires a recent Flutter `master` / Impeller build with
> `flutter_gpu`. Widgets paint blank without Impeller.

## Install

```yaml
dependencies:
  gputext: ^0.1.0-dev.1
```

```sh
flutter pub get
```

The package build hook compiles shaders and a HarfBuzz amalgamation from
`third_party/harfbuzz` (vendored; no separate system install).

## Quick start

```dart
import 'package:gputext/gputext.dart';

GPURichText(
  text: TextSpan(
    text: 'Hello GPU text',
    style: TextStyle(fontSize: 24, color: Colors.white),
  ),
)
```

Register fonts with `GPUFont` / the engine APIs before layout when you are not
using the bundled Lato default. See the
[example app](https://github.com/definev/gputext/tree/main/example) for demos
(RTL, variable fonts, benchmarks).

## System fonts (macOS / iOS / Android)

Resolve an OS-installed font by family name — no bundled TTF — via the native
resolver (CoreText on Apple, the NDK font matcher on Android). It's opt-in and
non-breaking; the bundled Lato default is unchanged until you call it.

```dart
final engine = GPUText.instance;

// Platform default UI font (San Francisco / Roboto), registered as `system-ui`.
await engine.loadDefaultSystemFont();

// A named installed family, in a specific weight.
await engine.loadSystemFont('Georgia', weight: FontWeight.w700);

// Or up front, no first-frame flash:
await GPUText.initialize(
  useSystemDefaultFont: true,
  systemFonts: {'Serif': 'Georgia'}, // gputext family : OS family
);
```

Each call returns `null` (never throws) when the platform has no backend, the
family is unavailable, or it uses CFF/PostScript outlines gputext can't render —
so callers keep their fallback. `GPUText.systemFontsAvailable` reports whether a
backend is present. Try it: `GPUTEXT_DEMO=sysfont`.

**Caveats.** gputext renders TrueType (`glyf`) outlines only, so CFF-flavored
families fall back. The platform default UI font is `glyf` on both Apple and
Android, so `loadDefaultSystemFont` is the reliable path. Android name matching
uses the NDK matcher (API 29+; a `/system/fonts` best-effort below that) and may
substitute a fallback for an unknown name. On iOS, some builds decline to hand
over the synthetic system font's tables — reconstruction then returns `null` and
your bundled default stays in place. Call once per weight/style variant.

## Hybrid rendering

`GPURichText` is not a single paint path:

- **GPU blit** — glyphs covered by a registered `GPUFont` are rasterized into a
  cached `ui.Image`, then blitted.
- **Platform `Text`** — color-emoji clusters and characters no registered font
  covers (often CJK) become baseline-aligned `WidgetSpan`s with stock Flutter
  `Text`.
- **WidgetSpan children** — measured in layout and painted on top of the text
  image, same as `RichText`.

## Testing

`flutter test` boots the tester without Impeller, so gputext widgets lay out
but paint blank. To exercise the real GPU path in widget tests, enable both
flags:

```sh
flutter test --enable-impeller --enable-flutter-gpu
```

In debug builds the shader bundle is loaded straight from gputext's package
directory when asset lookup fails (the tester's asset manager never sees hook
data assets), so this works in gputext's own tests and in packages that depend
on it — no extra setup.

## Limits

- Impeller / `flutter_gpu` only.
- `foreground` `Paint` is flat color only.
- System fonts resolve TrueType (`glyf`) faces only; CFF families fall back.
- Still evolving; APIs may change before `0.1.0`.

## License

MIT. HarfBuzz and bundled fonts carry their own licenses (see `LICENSE` and
`assets/`).

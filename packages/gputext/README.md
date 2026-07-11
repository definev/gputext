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
- Still evolving; APIs may change before `0.1.0`.

## License

MIT. HarfBuzz and bundled fonts carry their own licenses (see `LICENSE` and
`assets/`).

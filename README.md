# gputext

GPUText vector text renderer ported to Flutter GPU. The library package lives
in `packages/gputext/`; this repo is a [Melos](https://melos.invertase.dev/)
workspace. `GPURichText` is a
near drop-in replacement for `RichText` whose glyphs are rasterized by an
analytic coverage shader (see `lib/src/widgets/rich_text.dart` for the API
surface and current limits).

## Demos

The demo app lives in `example/` (it depends on the package via
`path: ../packages/gputext`). Run it from there:

```sh
cd example
flutter run -d macos
GPUTEXT_DEMO=<page> flutter run -d macos   # open a page directly
```

`<page>` is one of `widgets`, `pretext`, `justify`, `vars`, or `bench`.

## Workspace

From the repo root:

```sh
dart pub global activate melos   # once
dart pub get                     # install melos locally
melos bootstrap                  # link packages and run hooks
melos run build                  # compile shader bundles (required before analyze)
melos run analyze
melos run test
melos run format                 # or melos run format:check
```

## Benchmarks

A full-matrix RichText vs GPURichText benchmark lives in `example/lib/bench/`
and runs as an in-app mode. Run the scripts from `example/`:

```sh
tool/run_bench.sh                          # full run, compares to baseline
GPUTEXT_BENCH_QUICK=1 tool/run_bench.sh   # short smoke run
GPUTEXT_BENCH_FILTER=frame.zoom,cpu. tool/run_bench.sh   # subset by id prefix
tool/run_bench.sh --update-baseline        # promote this run to the baseline
```

The runner launches the app in profile mode on macOS (keep its window
foregrounded — background throttling corrupts frame timings), collects the
report from stdout (`GPUBENCH:` marker lines; the sandboxed app cannot write
into the repo), stores it under `benchmark/results/`, and prints a delta
table against `benchmark/baseline/macos.json` via `tool/compare_bench.dart`.

Four tiers, methodology mirroring `/pretext/pages/benchmark.ts` (warmup +
median-of-runs, width cycling, DCE sinks; corpus files are copies of
`/pretext/corpora`):

- **cpu.*** — pure layout: flatten/prepare/relayout vs `TextPainter`,
  long-form corpora, Knuth–Plass vs greedy.
- **frame.*** — end-to-end `FrameTiming` (build/raster percentiles, jank
  counts) across cold init, atlas warm-up, idle floor, per-frame repaint /
  text change / reflow, long-document scroll, transform + InteractiveViewer
  zoom, widget grids, justification, variable-font animation, the hybrid
  emoji/CJK and WidgetSpan-heavy paths, and `frame.rich_interleave`
  (mixed WidgetSpan kinds/alignments + styled/hybrid runs under reflow).
- **mem.*** — RSS plus gputext-internal accounting (atlas bytes, cached
  glyph images, instance buffers, prepare-cache size).
- **vis.*** — RepaintBoundary captures of paired renderings diffed in Dart
  (luma MAE/RMSE, size parity, ink coverage), including a 4× zoom crispness
  case and `vis.rich_interleave` for the complex WidgetSpan tree.

Reading the numbers: every entry carries a `path` tag — `pure` rows isolate
gputext; `hybrid`/`cache-disabled` rows exercise the native-delegation and
WidgetSpan paths and are not comparable with pure rows. GPUText's
steady-state paint is a cached-image blit, so static scenarios structurally
favor it; weigh them against the dynamic ones (`repaint_color`,
`text_update`, `reflow_width`, zooms). Sanity checks (cache-hit expectations,
idle floor, zoom re-render counts) are embedded in `meta.sanity` and fail the
report's status when violated.

## Hybrid rendering

`GPURichText` is not a single paint path:

- **GPU blit** — glyphs covered by a registered `GPUFont` (including in-engine
  `fontFamilyFallback`) are rasterized by the coverage shader into a cached
  `ui.Image`, then blitted.
- **Platform `Text`** — color-emoji clusters (`expandEmojiSpans`) and characters
  no registered font covers (`expandUncoveredSpans`, often CJK) become
  baseline-aligned WidgetSpans whose child is stock Flutter `Text`.
- **WidgetSpan children** — measured in layout and painted on top of the text
  image, same as `RichText`.

Benchmark rows tagged `pure` isolate the GPU path; `hybrid` /
`cache-disabled` rows exercise platform delegation and are not comparable.
Coverage styling knobs on `GPURichText` / `FrameUniforms`: `coverageGamma`,
`coverageSharp` (default `1, 1` = exact), and `minificationGuardPx` (default
`3.7`; raise toward `8` for thumbnail-heavy UIs).

**Limits:** Impeller / `flutter_gpu` only (widgets paint blank otherwise); no
bidi/RTL shaping; `locale` is accepted but unused; `foreground` Paint is flat
color only.

## API (migrated from windfoil_flutter)

| windfoil_flutter | gputext |
|------------------|---------|
| `WindfoilRichText` | `GPURichText` |
| `WindfoilText` | `GPULabel` |
| `Windfoil` | `GPUText` |
| `WindfoilFont` | `GPUFont` |
| `package:windfoil_flutter` | `package:gputext` |

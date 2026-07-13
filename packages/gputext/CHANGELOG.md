## Unreleased

- Native system fonts (macOS / iOS / Android): resolve OS-installed families by
  name — including the platform default UI font — into GPU-renderable outlines,
  via a small CoreText / NDK-font-matcher FFI resolver. Opt-in and non-breaking:
  `GPUTextEngine.loadSystemFont` / `loadDefaultSystemFont`, the `systemFonts` /
  `useSystemDefaultFont` params on `GPUText.initialize`, and the
  `GPUText.systemFontsAvailable` diagnostic. TrueType (`glyf`) faces only.
- `GPUFont.parse` now unwraps TrueType Collection (`.ttc`) files (face 0).

## 0.1.0-dev.1

- Initial pre-release on pub.dev.
- GPU-accelerated vector text via Flutter GPU analytic coverage shaders.
- HarfBuzz shaping (complex scripts, bidirectional / RTL text).
- `GPURichText` / `GPULabel` widgets with hybrid emoji and uncovered-glyph fallback.
- Variable font axes, font features, selection geometry, and shared glyph atlas.

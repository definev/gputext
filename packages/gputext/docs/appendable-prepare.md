# Design sketch: appendable prepare (streaming documents)

Status: **v0 + v2 IMPLEMENTED** 2026-07-17.
- v0 — `GPUTextWorker.syncStream` / `finishStream` / `debugStreamStats` in
  `gpu_text_worker.dart`, tested in `test/streaming_sync_test.dart` (drawable
  byte-parity vs prepareDoc+reflowDoc, incl. RTL across slice boundaries;
  tail-only re-shape verified via stats). Deviations from the sketch: slices
  are cached as SHAPED ITEMS and a single `prepareParagraph` runs over the
  concatenation (no per-chunk stacked layout — prepare/break/emit stay
  O(document), pure arithmetic; HarfBuzz shaping, the dominant cost, is
  O(delta)). A non-null LineBreakConfig disables slice reuse (its callbacks
  lose identity crossing the isolate).
- v2 (lighter than the sketch's `GPUStreamingText`) — `GPUTextDocument`
  gained `streaming: true`: `GPUTextView` routes such documents through
  `GPUTextViewController._syncStreamDoc` (same atlas-mirror folding as
  reflows), reflows on every non-identical document object (the same-id
  equivalence skip is bypassed), and idles while content is empty. Public
  `GPUTextViewController.finishStream` / `disposeDoc`. Tested end-to-end in
  `test/streaming_view_test.dart`; the chat demo's hot-message leaf uses it
  in worker mode. No placeholder support in streaming docs (asserted).
- v1 below (incremental segmentation/break/emit + delta replies) remains open.
Motivation: the AI-chat demo (`GPUTEXT_DEMO=chat`).

## Problem

Both render paths key their expensive phase on *content*:

- Widget path: `GPURichText`'s layout cache keys on the flattened span content;
  the render-skip fast path only helps *same content, new width*.
- Worker path: the prepare cache keys on `GPUTextDocument.id`, and the id
  contract is "same id ⇒ same content", so changed content means a new id and
  a full prepare. `reflowDoc` is the cheap phase but is same-content-only.

An LLM-style stream appends a few words per tick (16–40 ms). Every tick the
content changes, so the *whole accumulated block* re-shapes. Over a W-word
response, total shaping is **O(W²)** — long replies get progressively jankier.
The chat demo currently works around this at the widget layer by freezing
completed code lines / list items / quote children as separate paragraphs
(shaped once each) and re-shaping only the tail — capped per tick, O(W) total.
That workaround is markdown-shaped and lives outside the engine; this sketch
moves the idea into gputext where it belongs.

## Key insight

Streaming text is **append-only**, and every stage of the pipeline has a
stable prefix under append:

| stage                | what appending invalidates                                   |
|----------------------|--------------------------------------------------------------|
| HarfBuzz shaping     | only the run(s) whose text changed (shaping is per-run)      |
| `prepareParagraph`   | only the final segment(s) — a trailing partial word may merge with appended text; earlier `SegmentPiece`s are untouched |
| greedy line breaking | only lines at/after the first dirty segment (the breaker is a forward scan; resumable from carried pen state) |
| instance emission    | only instances for re-broken lines (atlas is append-only; `rowBase`s never move outside compaction) |
| offscreen render     | only the band of the surface covering the dirty lines        |

So the correct cost model for a streaming tick is O(delta), not O(document).

## API sketch — three layers

### Layer 0 (VM-pure, `src/text/`): `StreamingParagraph`

```dart
/// Incrementally maintained PreparedParagraph. All items before [from] must
/// be byte-identical to the previous sync; everything from [from] on is
/// replaced. Internals resegment from a safe resume point (the segment
/// boundary one segment before the first dirty item — UAX #14 needs one
/// segment of lookbehind for word merges; a strong-RTL arrival widens the
/// window to the last hard break for bidi level correctness).
class StreamingParagraph {
  StreamingParagraph({LineBreakConfig? lineBreak});

  /// Returns the updated prepare plus the first dirty segment index, so the
  /// breaker knows where to resume.
  (PreparedParagraph, int firstDirtySegment) sync(
    List<InlineItem> items, {
    required int from,
  });
}
```

Storage: the `PreparedParagraph` arrays (`segmentTexts`, `segmentPieces`,
`graphemeEndOffsets`, `PreparedLineBreakData`'s typed buffers) become
append-truncate buffers (the same `Float32Buf`/growable pattern the shared
atlas uses) instead of rebuilt lists.

Line breaking gets a resumable form:

```dart
/// Reuse [prev]'s lines strictly before the line containing
/// [firstDirtySegment]; re-break from there with the carried pen state.
ParagraphLines layoutPreparedLinesFrom(
  PreparedParagraph prepared,
  double width,
  ParagraphStyle style, {
  required ParagraphLines prev,
  required int firstDirtySegment,
});
```

Constraints:
- **Greedy breaker only.** Knuth–Plass is a whole-paragraph optimizer;
  `sync` asserts `lineBreaker == greedy`.
- Justified alignment is fine (per-line), but `TextWidthBasis.longestLine`
  boxes may still grow — width is reported per sync.

### Layer 1 (worker protocol): streaming documents

New controller verbs (same tuple protocol as `('layout', …)` /
`('reflowDoc', …)`):

```dart
/// Create-or-update a streaming doc. [runs] is the FULL current content —
/// the controller diffs against the previous sync (longest common prefix at
/// run granularity, then a text-prefix split inside the boundary run) so
/// callers never compute deltas. A retroactive restyle (markdown's "**bold"
/// closing) simply produces a smaller stable prefix and costs a bigger tail
/// re-shape — never incorrectness.
Future<GPUTextStreamDelta> syncStream(
  String id, {
  required List<GPUInlineSpec> runs,
  required double width,
  GPUTextLayoutStyle? style,
  List<String> fallbackFontIds,
  String? emojiFontId,
});

/// Promote the streaming doc into an ordinary prepared doc (it becomes
/// eligible for the normal reflowDoc path and the prepare cache) and free
/// the streaming state. The natural call site: message hardening.
Future<void> finishStream(String id);
```

Worker-side state per stream id: shaped-run cache (keyed by spec identity),
one `StreamingParagraph` per hard-break paragraph, committed `ParagraphLines`,
and the emitted instance buffer. Overlapping syncs coalesce exactly like
reflows (`_kReflowSuperseded`: latest wins, stale futures throw).

The delta reply mirrors `GPUTextInstances` but tail-scoped:

```dart
class GPUTextStreamDelta {
  int firstDirtyLine;          // lines before this are byte-stable
  int removedLineCount;        // lines truncated from the previous state
  TransferableTypedData instances; // instances for lines >= firstDirtyLine
  TransferableTypedData lineTableRows; // same, for the selection line table
  double height;               // new document height
  int atlasGeneration;         // append-only glyph rows ride along as today
}
```

- Width change mid-stream → full re-break (`firstDirtyLine = 0`) but no
  re-shape: it's the existing cheap reflow arithmetic.
- Atlas **structure** change (compaction relocated rowBases) → the one case
  the delta contract can't hold: reply falls back to a full-instance snapshot,
  exactly like today's reflow reply. Rare by design (`retainFonts` early-outs
  when no font drops).

### Layer 2 (widget): `GPUStreamingText`

```dart
GPUStreamingText({
  required GPUTextViewController controller,
  required String streamId,        // stable for the WHOLE stream — no id churn
  required InlineSpan span,        // full current content; diffed internally
  required String Function(TextStyle) fontIdResolver,
  List<String> fallbackFontIds,
  String? emojiFontId,
  GPUTextLayoutStyle? style,
  Color background,
  void Function(GPUTextMetrics)? onMetrics,
})
```

Behavior deltas vs `GPUTextView`:
- Keeps one persistent surface + instance buffer; applies `GPUTextStreamDelta`
  by truncating `removedLineCount` worth of tail instances and appending the
  new ones — paint re-rasters only the dirty band (the sliding-window image
  already re-rasters on epoch bump).
- Extent grows monotonically except small tail re-breaks; the
  first-layout-parking exemption added for `GPUTextView` covers the mount
  case, and mid-scroll tail growth applies immediately (it's the bottom of
  the document — outside the parked-thumb concern).
- On dispose or an explicit `finish()`, calls `finishStream` so the content
  survives as a normal document (the chat "hardening" moment becomes free:
  same worker state, no re-prepare, no widget swap).

## What this retires in the chat demo

- `_streamingTail`/`_streamingCode`/`_streamingList` and `_tailCache` — the
  markdown-shaped freeze logic collapses into `GPUStreamingText` with one
  streaming doc per growing tail block (or even one per message).
- The widget-path/worker-path hot-message split: the hot message becomes
  worker-hosted, so streaming never touches the UI thread at all — the
  original goal.

## Phasing

- **v0 — engine-side paragraph memo (cheap, ~days):** no new Layer-0 code.
  `syncStream` splits runs at hard breaks and re-prepares only paragraphs
  whose concatenated content hash changed (per-paragraph `prepareParagraph`
  reuse). Emission stays full. Shaping already drops to O(last paragraph) —
  this alone matches the demo workaround, correctly, for every block type.
- **v1 — true incremental (`StreamingParagraph` + resumable breaker + delta
  emit/reply):** per-tick cost O(delta); the reply shrinks to the dirty tail.
- **v2 — `GPUStreamingText` + `finishStream` promotion + demo migration.**

## Open questions

1. Bidi resume window: is "re-analyze from the last hard break" tight enough,
   or should strong-RTL arrival force whole-paragraph re-analysis? (Current
   bidi fast-path work suggests the latter is affordable — it's rare.)
2. Should `syncStream` accept an explicit `stablePrefix` override for callers
   (like a markdown streamer) that already know the settled boundary — or is
   the internal LCP diff always cheap enough? (Diff is O(prefix) string
   compares per tick; probably fine, but it's the same O(W²) shape in the
   limit — a rolling hash or caller hint caps it.)
3. `maxLines`+ellipsis on a streaming doc: re-break of the final visible line
   per tick is unavoidable; is the ellipsis path resumable or does it force
   `firstDirtyLine = maxLines - 1` always (acceptable)?
4. Eviction: streaming docs are pinned (never LRU-evicted) until
   `finishStream` — enforce a cap on concurrent streams? (Chat needs exactly
   one.)

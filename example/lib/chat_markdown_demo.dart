// AI chat + markdown demo: a chat transcript where user messages are plain
// bubbles and "assistant" responses are markdown — headings, bold/italic,
// inline code, fenced code blocks, lists, blockquotes, links, emoji — rendered
// with GPURichText/GPULabel and streamed in word-by-word like an LLM response.
// Every block renders on the high-level widget path: chat-sized messages lay
// out synchronously on the UI thread in microseconds and hit GPURichText's
// process-wide layout cache on rebuild, so there is no worker isolate here. A
// whole long document is the honest unit for off-thread layout — see the
// Reader demo (GPUTEXT_DEMO=reader) — not a heterogeneous tree of tiny markdown
// blocks. Body text is Lato (regular/bold/italic/bold-italic faces); code is
// JetBrains Mono.
//
// The streaming (hot) message re-parses its markdown source on every tick.
// package:markdown never throws on momentarily-unbalanced input ("**bo") — it
// renders literals until the closer arrives — so parse-per-tick is safe.
// Settled blocks are reused by (tag, text) key and completed sub-units of the
// growing tail (code lines, list items, quote children) freeze in a per-message
// cache, so each shapes exactly once and only the growing tail re-shapes.
//
// The bolt button starts STRESS MODE: an endless auto-played turn-based
// conversation of procedurally generated replies (deep nested lists, 70-line
// code files, GFM tables, nested quotes, CJK/RTL/emoji, dense inline styling)
// streamed at ~8 words per 16ms tick until toggled off. The chip under the
// app bar tracks turns, transcript size, and rolling frame build/raster times
// so regressions show up as numbers, not vibes.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:gputext/gputext.dart';
import 'package:markdown/markdown.dart' as md;

// ---------------------------------------------------------------------------
// Palette (fixed dark theme) + text styles
// ---------------------------------------------------------------------------

const _bg = Color(0xFF101418); // page background
const _panel = Color(0xFF1B2128); // AI bubble
const _panel2 = Color(0xFF232B34); // inline-code bg, code header strip
const _codeBg = Color(0xFF12161B); // code block body
const _userBg = Color(0xFF2F6FED); // user bubble
const _ink = Color(0xFFE8ECF1); // body text
const _muted = Color(0xFF9AA5B1); // secondary text
const _accent = Color(0xFF7EB6FF); // links, caret
const _codeInk = Color(0xFFEAD9A8); // code text tint
const _border = Color(0xFF39424C); // blockquote bar, hr

const _body = TextStyle(
  fontFamily: 'Lato',
  fontSize: 15,
  height: 1.45,
  color: _ink,
);

const _mono = TextStyle(
  fontFamily: 'JetBrainsMono',
  fontSize: 13.5,
  height: 1.5,
  color: _codeInk,
);

TextStyle _headingStyle(int level) => switch (level) {
  1 => _body.copyWith(fontSize: 24, fontWeight: FontWeight.w700, height: 1.3),
  2 => _body.copyWith(fontSize: 20, fontWeight: FontWeight.w700, height: 1.3),
  3 => _body.copyWith(
    fontSize: 17.5,
    fontWeight: FontWeight.w600,
    height: 1.35,
  ),
  4 => _body.copyWith(fontSize: 16, fontWeight: FontWeight.w600),
  5 => _body.copyWith(fontSize: 15, fontWeight: FontWeight.w600),
  _ => _body.copyWith(
    fontSize: 13.5,
    fontWeight: FontWeight.w600,
    color: _muted,
  ),
};

// ---------------------------------------------------------------------------
// Scripted conversation
// ---------------------------------------------------------------------------

const _welcome = '''
### Hi, I'm a GPU-rendered assistant 👋

Every glyph in this conversation is shaped, laid out, and rasterized by **gputext** — no `dart:ui` paragraphs involved. Send a message and I'll stream back a markdown response.

Try things like:

- *Explain how you render text*
- *Show me some code*
- [What is gputext?](https://github.com/definev/gputext)
''';

typedef _Exchange = ({String prompt, String response});

const List<_Exchange> _script = [
  (
    prompt: 'How does GPU text rendering work?',
    response: r'''
## How gputext renders text

Text goes through three stages before it hits the screen:

1. **Shape** — HarfBuzz turns each run into positioned glyph ids
2. **Layout** — lines are broken and glyphs get absolute positions
3. **Raster** — a coverage shader fills glyph outlines directly on the GPU

The interesting part is stage 3: instead of uploading pre-baked bitmaps, the shader evaluates each glyph's *vector outline* per pixel, so text stays crisp at **any** scale.

Key pieces if you want to dig in:

- [GPURichText](https://github.com/definev/gputext) — drop-in `RichText` replacement
  - resolves fonts per span, including **bold** and *italic*
  - delegates uncovered scripts to platform text
- `GPUTextView` — worker-isolate layout for huge documents
- `SliverGPUText` — lazy rasterization inside any `CustomScrollView`
''',
  ),
  (
    prompt: 'Show me some code',
    response: r'''
Sure — here's a minimal widget that renders styled text with `GPURichText`:

```dart
class Greeting extends StatelessWidget {
  const Greeting({super.key});

  @override
  Widget build(BuildContext context) {
    return GPURichText(
      text: const TextSpan(
        style: TextStyle(fontFamily: 'Google Sans Flex', fontSize: 15, color: Color(0xFFE8ECF1)),
        children: [
          TextSpan(text: 'Hello, '),
          TextSpan(text: 'GPU', style: TextStyle(fontWeight: FontWeight.w700)),
          TextSpan(text: ' world!'),
        ],
      ),
    );
  }
}
```

A few things to notice:

1. Spans are plain `TextSpan` / `TextStyle` — no custom span types
2. `fontWeight` maps onto the variable font's `wght` axis automatically
3. The long line above scrolls horizontally instead of wrapping

Inline code like `GPUText.instance.registerFont(...)` gets the monospace treatment too.
''',
  ),
  (
    prompt: "What's your design philosophy?",
    response: r'''
> *Text is the UI.* Most apps are 90% glyphs, so the text stack deserves GPU-class care. 🚀

A few principles:

**Correctness first** — shaping, bidi, and emoji must match platform text before anything else matters. That means real ZWJ sequences 👨‍👩‍👧, skin tones 👍🏽, and flags 🇻🇳 — not tofu.

*Speed second* — ***but a close second***. Layout should never block a frame.

~~Features third~~ — features fall out of the first two.

---

That's the whole manifesto. ✨
''',
  ),
  (
    prompt: 'Give me the full tour',
    response: r'''
# The full tour

## Widgets

`GPURichText` and `GPULabel` are drop-in replacements for `RichText` and `Text`. They handle selection, hit-testing, hover cursors, and text scaling like the originals — try drag-selecting across this bubble.

## Documents

For big content you switch to the worker path: a background isolate shapes and lays out text, then ships compact geometry back to the UI thread. The widgets there — `GPUTextView`, `GPUTextBlocksView`, `SliverGPUText` — never block a frame on layout.

## Ten reasons to render text on the GPU

1. Crisp glyphs at every scale factor, no atlas blur
2. Zoom without re-rasterization
3. One shared glyph atlas across the whole app
4. Layout off the UI thread with the worker isolate
5. Sub-pixel positioning for free
6. COLR emoji composited in the same pass
7. Variable font axes animate without paragraph rebuilds
8. Selection geometry computed from the layout the GPU actually drew
9. Slivers rasterize only the visible strip
10. It is simply more fun 🎉

## Wrap-up

```dart
// The whole API fits in one line:
GPULabel('Hello from the GPU');
```

That's the tour — scroll back up any time; selection works across every bubble.
''',
  ),
];

// ---------------------------------------------------------------------------
// Stress mode: procedurally generated "real AI session" turns. Seven content
// shapes cycle by turn index, each varied by the turn number so the layout
// cache can't trivially dedupe successive replies.
// ---------------------------------------------------------------------------

String _stressPrompt(int t) {
  final n = t + 1;
  return switch (t % 7) {
    0 => 'Turn $n: deep dive with nested lists, please',
    1 => 'Turn $n: show me a long annotated code file',
    2 => 'Turn $n: compare the options in a table',
    3 => 'Turn $n: quote the docs with commentary',
    4 => 'Turn $n: emoji + multilingual stress',
    5 => 'Turn $n: long-form essay, heavy inline styling',
    _ => 'Turn $n: kitchen sink — everything at once',
  };
}

String _stressResponse(int t) {
  final n = t + 1;
  return switch (t % 7) {
    0 => _genNestedLists(n),
    1 => _genCodeFile(n),
    2 => _genTable(n),
    3 => _genQuotes(n),
    4 => _genPolyglot(n),
    5 => _genEssay(n),
    _ => _genKitchenSink(n),
  };
}

String _genNestedLists(int n) {
  final b = StringBuffer('## Turn $n · dependency graph\n\n')
    ..writeln(
      'Every node below is **live** — expand any `pkg_${n}_x` and the '
      'resolver walks it again. See [the resolver notes](https://example.com/resolver/$n).\n',
    );
  for (var i = 1; i <= 3; i++) {
    b.writeln('- Layer $i — `pkg_${n}_$i` *(pinned at v$n.$i)*');
    for (var j = 1; j <= 3; j++) {
      b.writeln('  - resolves **${j * i} deps** through `graph_$j`');
      for (var k = 1; k <= 2; k++) {
        b.writeln('    - shard $k caches by *style key* `$n:$i:$j:$k`');
        b.writeln(
          '      - evicts LRU past ${128 << k} entries — '
          'see [shard docs](https://example.com/shard/$k)',
        );
      }
    }
  }
  b.writeln('\nRollout steps:\n');
  for (var i = 1; i <= 8; i++) {
    b.writeln(
      '$i. verify `output_${n}_$i` matches the **golden** for stage $i',
    );
  }
  return b.toString();
}

String _genCodeFile(int n) {
  final b =
      StringBuffer(
          'Here is `renderer_$n.dart` in full — long lines scroll horizontally, '
          'and the mono face carries the whole block:\n\n```dart\n',
        )
        ..writeln(
          '/// Stress-generated renderer #$n — every pass is banded separately.',
        )
        ..writeln('class Renderer$n {')
        ..writeln('  final buffers = <Buffer>[];')
        ..writeln('  var frame = 0;')
        ..writeln('');
  for (var i = 0; i < 12; i++) {
    b
      ..writeln('  /// Pass $i: coverage accumulation for band $i of turn $n.')
      ..writeln('  void pass$i(Scene scene) {')
      ..writeln(
        "    buffers.add(Buffer(id: $i, label: 'buffer-$i-of-turn-$n', "
        'capacity: ${(i + 1) * 256}, mode: BufferMode.persistent, '
        "debugName: 'stress/turn$n/band$i'));",
      )
      ..writeln('    frame += ${i + 1};')
      ..writeln('  }')
      ..writeln('');
  }
  b
    ..writeln('}\n```\n')
    ..writeln('Reading order:\n')
    ..writeln('1. `pass0` seeds the atlas')
    ..writeln('2. passes 1–10 accumulate coverage')
    ..writeln('3. `pass11` resolves — **never** reorder it');
  return b.toString();
}

String _genTable(int n) {
  final b = StringBuffer('## Turn $n · option matrix\n\n')
    ..writeln(
      'Verdicts below are **generated** — column widths come from intrinsic '
      'cell measurement.\n',
    )
    ..writeln('| Option | Cost | Latency | Notes | Verdict |')
    ..writeln('|---|---|---|---|---|');
  for (var i = 1; i <= 8; i++) {
    final fast = i % 3 != 0;
    b.writeln(
      '| `opt_${n}_$i` | \$${i * 3}/mo | ${i * 7}ms | '
      '${fast ? '**fast path**, zero copies ✅' : '*slow path*, re-shapes each frame ⚠️'} | '
      '${fast ? 'keep' : '~~drop~~'} |',
    );
  }
  b
    ..writeln('\nFollow-ups:\n')
    ..writeln(
      '- benchmark `opt_${n}_2` against [the baseline](https://example.com/bench/$n)',
    )
    ..writeln('- re-run with **cold caches**')
    ..writeln('- document the ⚠️ rows');
  return b.toString();
}

String _genQuotes(int n) =>
    '''
## Turn $n · from the docs

> **Layout invariant $n.** A line never exceeds its measured advance; ellipsis
> applies only after the last `break opportunity`.
>
> > *Fine print, level 2:* shaping is cluster-safe — see [UAX #14](https://unicode.org/reports/tr14/).
> >
> > > Level 3 keeps its own left bar and inherits the paragraph style.
>
> Quoted checklist:
>
> - measure with `strut` enabled
> - compare against **platform** output

---

Commentary: the invariant holds for turn $n because reflow re-runs on the *same
prepared* paragraph — nothing re-shapes unless content changes.
''';

String _genPolyglot(int n) =>
    '''
## Turn $n · scripts and emoji

Vietnamese diacritics: *Xin chào!* Tiếng Việt đầy đủ dấu — **đúng** từng ký tự.

CJK through the fallback face: 文本渲染在 GPU 上完成，速度很快，缓存共享。

RTL sample (platform-delegated if uncovered): مرحبا بالعالم

Greek/Cyrillic: αβγδε · привет мир · **στυλ** works inline.

Emoji storm $n:

- families 👨‍👩‍👧‍👦 👩‍👩‍👦 workers 👩🏽‍💻 🧑🏿‍🚀 hands 👍🏽 🤙🏻
- flags 🇻🇳 🇯🇵 🇧🇷 🏳️‍🌈 symbols ⚡ ✨ 🚀 🎉 ♻️
- mixed **bold 粗体** and *nghiêng* and `代码 code`
''';

String _genEssay(int n) {
  final b = StringBuffer('## Turn $n · why text is the hard part\n\n');
  for (var p = 1; p <= 5; p++) {
    if (p == 3) b.writeln('### Midpoint checkpoint $n.$p\n');
    b
      ..write(
        'Paragraph $p of turn $n: rendering text well means **shaping** before ',
      )
      ..write(
        'breaking, *measuring* before painting, and `caching` everything the ',
      )
      ..write(
        'pipeline touches — see [note $p](https://example.com/essay/$n/$p). ',
      )
      ..write(
        'When a span changes only its ~~geometry~~ color, the layout is reused ',
      )
      ..write(
        'byte-for-byte; when the **content** grows, only the *streaming* tail ',
      )
      ..write(
        're-parses, which keeps a $p-paragraph reply under a millisecond of ',
      )
      ..write('parse time even at `tick $n.$p`. ')
      ..writeln(
        'The transcript above this line is already ${p * n} bubbles deep.\n',
      );
  }
  return b.toString();
}

String _genKitchenSink(int n) =>
    '''
# Turn $n · kitchen sink

Everything in one reply — **table**, `code`, *lists*, quotes, emoji 🚀.

| Stage | Output |
|---|---|
| shape | `glyphs_$n` |
| layout | **lines** |
| raster | ✅ |

```dart
// turn $n: the whole API in three lines
final doc = parse(source_$n);
final page = render(doc);
present(page); // banded, cached, GPU-resident
```

- one
  - two
    - three `deep_$n`

> Final quote for turn $n — *ship it*. ✨

---

Done with turn $n.
''';

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

enum _Role { user, ai }

class _ChatMessage {
  _ChatMessage(this.role, this.text, {this.streaming = false});

  final _Role role;
  String text; // accumulated markdown source (mutable while streaming)
  bool streaming;

  // Parse cache: text is append-only, so length is a sufficient key. Without
  // this, every visible completed bubble would re-parse its full source on
  // every stream tick of the transcript.
  List<md.Node>? _parsedNodes;
  int _parsedLength = -1;

  // Built-block cache for completed messages (immutable widget subtrees):
  // built once on the widget path and reused on every rebuild.
  List<Widget>? _builtBlocks;

  // While streaming, settled blocks (everything but the growing tail) are
  // reused across ticks keyed by (tag, textContent) so their elements skip
  // rebuild — and, being wrapped in RepaintBoundaries, skip paint too. Only
  // the tail block re-flattens/re-shapes/re-renders per tick.
  List<(String, Widget)>? _streamCache;

  // Sub-block cache for the growing tail itself: completed code lines, list
  // items, and quote children freeze here (keyed by index + content) so each
  // is shaped exactly once. Bounded by message size, cleared on completion.
  final Map<String, Widget> _tailCache = {};

  List<md.Node> parsedWith(List<md.Node> Function(String) parse) {
    if (_parsedLength != text.length) {
      _parsedNodes = parse(text);
      _parsedLength = text.length;
    }
    return _parsedNodes!;
  }
}

class ChatMarkdownDemoPage extends StatefulWidget {
  const ChatMarkdownDemoPage({super.key});

  @override
  State<ChatMarkdownDemoPage> createState() => _ChatMarkdownDemoPageState();
}

class _ChatMarkdownDemoPageState extends State<ChatMarkdownDemoPage> {
  // Gate the transcript on font registration: registering a font AFTER a
  // GPURichText mounts fires the engine's notifyListeners() and re-expands
  // spans mid-update, tripping the framework's '!_dirty' assert in debug (see
  // cursed_demo.dart). All fonts load before the first bubble builds, which
  // also keeps the page-wide SelectionArea below safe; if a late font swap
  // ever reintroduces the assert, demote it to per-bubble SelectionAreas.
  bool _fontsReady = false;

  final List<_ChatMessage> _messages = [_ChatMessage(_Role.ai, _welcome)];
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final Map<String, TapGestureRecognizer> _linkRecognizers = {};

  Timer? _streamTimer;
  _ChatMessage? _streamingMsg;
  List<String> _chunks = const [];
  int _chunkCursor = 0;
  int _tickCount = 0;
  int _scriptIndex = 0;
  bool _stickToBottom = true;
  bool _fastStream = false;

  // Stress mode: auto-plays generated turns back to back until toggled off.
  bool _stressActive = false;
  int _stressTurn = 0;
  int _turnsDone = 0;
  Timer? _betweenTurns;

  // Live stats (turns/chars + frame times), updated outside setState so only
  // the chip under the app bar rebuilds.
  final ValueNotifier<String> _stats = ValueNotifier('');
  final List<FrameTiming> _frames = [];

  bool get _streaming => _streamingMsg != null;

  @override
  void initState() {
    super.initState();
    _loadFonts();
    SchedulerBinding.instance.addTimingsCallback(_onFrameTimings);
  }

  // Process-wide: Lato regular is registered by GPUText.initialize; the bold/
  // italic variants must register exactly once (resolveFont can't distinguish
  // "family has bold" from nearest-weight matching to regular).
  static bool _latoVariantsLoaded = false;

  Future<void> _loadFonts() async {
    final engine = GPUText.instance;
    // Skip fonts that are already registered: re-entering the demo doesn't
    // pile up duplicate variants, and tests that pre-register fonts in
    // setUpAll make this loader a no-op (as cursed_demo_test does).
    try {
      if (!_latoVariantsLoaded) {
        _latoVariantsLoaded = true;
        if (engine.resolveFont('Lato') == null) {
          await engine.loadFontAsset('Lato', 'assets/Lato-Regular.ttf');
        }
        await engine.loadFontAsset(
          'Lato',
          'assets/Lato-Bold.ttf',
          weight: FontWeight.w700,
        );
        await engine.loadFontAsset(
          'Lato',
          'assets/Lato-Italic.ttf',
          style: FontStyle.italic,
        );
        await engine.loadFontAsset(
          'Lato',
          'assets/Lato-BoldItalic.ttf',
          weight: FontWeight.w700,
          style: FontStyle.italic,
        );
      }
      if (engine.resolveFont('JetBrainsMono') == null) {
        await engine.loadFontAsset(
          'JetBrainsMono',
          'assets/JetBrainsMono-Regular.ttf',
        );
        await engine.loadFontAsset(
          'JetBrainsMono',
          'assets/JetBrainsMono-Bold.ttf',
          weight: FontWeight.w700,
        );
      }
    } catch (e) {
      debugPrint('chat demo: font load failed: $e');
    }
    // CJK fallback for the multilingual stress turns (subset face; anything
    // it misses falls through to platform-text delegation).
    try {
      if (engine.resolveFont('NotoSansSC') == null) {
        await engine.loadFontAsset(
          'NotoSansSC',
          'assets/NotoSansSC-subset.ttf',
        );
      }
      if (engine.fallbackFamilies.isEmpty) {
        engine.setFallbackFamilies(const ['NotoSansSC']);
      }
    } catch (e) {
      debugPrint('chat demo: CJK fallback unavailable: $e');
    }
    // COLR emoji for the 👋🚀✨ sprinkled through the script (process-wide;
    // reload Twemoji defensively if a bitmap font is still active).
    if (engine.emojiFont == null || engine.emojiFont!.hasBitmapGlyphs) {
      try {
        await engine.loadEmojiFontAsset('assets/TwemojiMozilla.ttf');
      } catch (e) {
        debugPrint('chat demo: emoji font unavailable: $e');
      }
    }
    if (mounted) setState(() => _fontsReady = true);
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_onFrameTimings);
    _streamTimer?.cancel();
    _betweenTurns?.cancel();
    _stats.dispose();
    for (final r in _linkRecognizers.values) {
      r.dispose();
    }
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onFrameTimings(List<FrameTiming> timings) {
    if (!mounted) return;
    _frames.addAll(timings);
    if (_frames.length > 120) _frames.removeRange(0, _frames.length - 120);
    var build = 0, raster = 0, worst = 0;
    for (final f in _frames) {
      build += f.buildDuration.inMicroseconds;
      raster += f.rasterDuration.inMicroseconds;
      worst = math.max(worst, f.totalSpan.inMilliseconds);
    }
    final chars = _messages.fold<int>(0, (a, m) => a + m.text.length);
    String ms(int us) =>
        '${(us / (_frames.length * 1000)).toStringAsFixed(1)}ms';
    _stats.value =
        'turns $_turnsDone · msgs ${_messages.length} · '
        '${(chars / 1000).toStringAsFixed(1)}k chars · '
        'build ${ms(build)} · raster ${ms(raster)} · worst ${worst}ms';
  }

  // -- streaming --------------------------------------------------------------

  void _send() {
    final typed = _input.text.trim();
    final exchange = _script[_scriptIndex % _script.length];
    _scriptIndex++;
    _input.clear();
    _beginExchange(
      prompt: typed.isEmpty ? exchange.prompt : typed,
      response: exchange.response,
      fast: false,
      pin: true,
    );
  }

  void _beginExchange({
    required String prompt,
    required String response,
    required bool fast,
    required bool pin,
  }) {
    _skipStreaming(); // flush any in-flight response first
    final ai = _ChatMessage(_Role.ai, '', streaming: true);
    setState(() {
      _messages.add(_ChatMessage(_Role.user, prompt));
      _messages.add(ai);
    });
    _streamingMsg = ai;
    _fastStream = fast;
    _chunks = _wordChunks(response);
    _chunkCursor = 0;
    if (pin) _stickToBottom = true;
    _streamTimer = Timer.periodic(
      Duration(milliseconds: fast ? 16 : 40),
      (_) => _tick(),
    );
    _autoScroll();
  }

  void _tick() {
    final msg = _streamingMsg;
    if (msg == null) return;
    // Normal sends pace 1–2 word chunks per tick for an organic rhythm;
    // stress turns push 6–10 to pile up a long transcript quickly while still
    // re-parsing partial markdown on every tick.
    final take = _fastStream ? 6 + (_tickCount++ % 5) : 1 + (_tickCount++ % 2);
    final end = math.min(_chunkCursor + take, _chunks.length);
    msg.text += _chunks.sublist(_chunkCursor, end).join();
    _chunkCursor = end;
    if (_chunkCursor >= _chunks.length) _finishStreaming(msg);
    setState(() {});
    _autoScroll();
  }

  /// Skip-to-end: flush the remaining chunks in one go (stop button, or a new
  /// send while a response is still streaming).
  void _skipStreaming() {
    final msg = _streamingMsg;
    if (msg == null) return;
    msg.text += _chunks.sublist(_chunkCursor).join();
    _finishStreaming(msg);
    setState(() {});
    _autoScroll();
  }

  void _finishStreaming(_ChatMessage msg) {
    msg.streaming = false;
    msg._streamCache = null; // hardened path rebuilds via _builtBlocks
    msg._tailCache.clear();
    _streamingMsg = null;
    _streamTimer?.cancel();
    _streamTimer = null;
    _turnsDone++;
    if (_stressActive) {
      _betweenTurns?.cancel();
      _betweenTurns = Timer(const Duration(milliseconds: 250), _nextStressTurn);
    }
  }

  // -- stress mode -------------------------------------------------------------

  void _toggleStress() {
    if (_stressActive) {
      _betweenTurns?.cancel();
      _betweenTurns = null;
      setState(() => _stressActive = false);
      return;
    }
    setState(() => _stressActive = true);
    _stickToBottom = true;
    if (!_streaming) _nextStressTurn();
  }

  void _nextStressTurn() {
    if (!_stressActive || !mounted) return;
    final t = _stressTurn++;
    // pin: false — scrolling up mid-run keeps the viewport where the user put
    // it while turns keep streaming below.
    _beginExchange(
      prompt: _stressPrompt(t),
      response: _stressResponse(t),
      fast: true,
      pin: false,
    );
  }

  void _reset() {
    _betweenTurns?.cancel();
    _betweenTurns = null;
    _streamTimer?.cancel();
    _streamTimer = null;
    _streamingMsg = null;
    _stressActive = false;
    _stressTurn = 0;
    _turnsDone = 0;
    _tickCount = 0;
    _chunks = const [];
    _chunkCursor = 0;
    _stickToBottom = true;
    setState(() {
      _messages
        ..clear()
        ..add(_ChatMessage(_Role.ai, _welcome));
    });
  }

  /// Word-boundary chunks, each keeping its trailing whitespace (so joining
  /// them back never needs separator logic and newlines survive).
  static List<String> _wordChunks(String source) =>
      RegExp(r'\S+\s*').allMatches(source).map((m) => m[0]!).toList();

  void _autoScroll() {
    if (!_stickToBottom) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  // -- markdown → widgets ------------------------------------------------------

  List<md.Node> _parse(String source) => md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    encodeHtml: false,
  ).parse(source);

  /// One text block, rendered by GPURichText on the widget path.
  Widget _text(TextSpan span) => GPURichText(text: span);

  List<Widget> _buildBlocks(List<md.Node> nodes, {int depth = 0}) => [
    for (final n in nodes) _buildBlock(n, depth: depth),
  ];

  Widget _buildBlock(md.Node node, {int depth = 0}) {
    if (node is! md.Element) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: _text(TextSpan(text: node.textContent, style: _body)),
      );
    }
    final children = node.children ?? const <md.Node>[];
    switch (node.tag) {
      case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
        final level = int.parse(node.tag.substring(1));
        return Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 4),
          child: _text(_inline(children, _headingStyle(level))),
        );
      case 'p':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: _text(_inline(children, _body)),
        );
      case 'ul' || 'ol':
        return _buildList(node, depth);
      case 'pre':
        final code = children.whereType<md.Element>().firstOrNull;
        final lang = code?.attributes['class']?.replaceFirst('language-', '');
        final source = (code ?? node).textContent.trimRight();
        // The body lives in a horizontal SingleChildScrollView.
        // GPURichText(softWrap: false) sizes to its widest line, and its
        // process-wide layout cache makes scroll-back re-layout cheap.
        return _CodeBlock(
          code: source,
          language: (lang?.isEmpty ?? true) ? null : lang,
        );
      case 'blockquote':
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.only(left: 12),
          decoration: const BoxDecoration(
            border: Border(left: BorderSide(color: _border, width: 3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: _buildBlocks(children, depth: depth),
          ),
        );
      case 'hr':
        return Container(
          height: 1,
          color: _border,
          margin: const EdgeInsets.symmetric(vertical: 10),
        );
      case 'table':
        // Table needs synchronous intrinsic cell widths.
        return _buildTable(node);
      default:
        // Anything this demo doesn't style: render the plain text rather than
        // throwing mid-stream.
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: _text(TextSpan(text: node.textContent, style: _body)),
        );
    }
  }

  Widget _buildList(md.Element list, int depth) {
    final ordered = list.tag == 'ol';
    var n = int.tryParse(list.attributes['start'] ?? '') ?? 1;
    final rows = <Widget>[];
    for (final item in (list.children ?? const <md.Node>[])) {
      if (item is! md.Element || item.tag != 'li') continue;
      final marker = ordered ? '${n++}.' : (depth == 0 ? '•' : '◦');
      rows.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 26, child: GPULabel(marker, style: _body)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: _buildListItem(item, depth),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: rows,
      ),
    );
  }

  /// An `li` mixes bare inline nodes (tight lists) with block children (loose
  /// lists, nested lists): group consecutive inline nodes into paragraphs and
  /// recurse into the blocks.
  List<Widget> _buildListItem(md.Element li, int depth) {
    const blockTags = {'p', 'ul', 'ol', 'pre', 'blockquote', 'hr'};
    final out = <Widget>[];
    var inlineRun = <md.Node>[];
    void flush() {
      if (inlineRun.isEmpty) return;
      out.add(_text(_inline(inlineRun, _body)));
      inlineRun = <md.Node>[];
    }

    for (final n in li.children ?? const <md.Node>[]) {
      if (n is md.Element && blockTags.contains(n.tag)) {
        flush();
        out.add(_buildBlock(n, depth: depth + 1));
      } else {
        inlineRun.add(n);
      }
    }
    flush();
    return out;
  }

  /// GFM table → Flutter Table with GPURichText cells, horizontally
  /// scrollable so wide matrices don't fight the bubble width. During
  /// streaming a row can arrive half-parsed, so rows are padded to the widest
  /// column count (Table throws on ragged rows).
  Widget _buildTable(md.Element table) {
    final cellRows = <(bool header, List<md.Element> cells)>[];
    for (final section
        in (table.children ?? const <md.Node>[]).whereType<md.Element>()) {
      final header = section.tag == 'thead';
      for (final tr
          in (section.children ?? const <md.Node>[]).whereType<md.Element>()) {
        cellRows.add((
          header,
          (tr.children ?? const <md.Node>[]).whereType<md.Element>().toList(),
        ));
      }
    }
    if (cellRows.isEmpty) return const SizedBox.shrink();
    final columns = cellRows.fold<int>(0, (a, r) => math.max(a, r.$2.length));
    final cellStyle = _body.copyWith(fontSize: 13.5);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Table(
          defaultColumnWidth: const IntrinsicColumnWidth(),
          border: TableBorder.all(color: _border, width: 1),
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          children: [
            for (final (header, cells) in cellRows)
              TableRow(
                decoration: header ? const BoxDecoration(color: _panel2) : null,
                children: [
                  for (var c = 0; c < columns; c++)
                    if (c < cells.length)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        child: GPURichText(
                          text: _inline(
                            cells[c].children ?? const <md.Node>[],
                            header
                                ? cellStyle.copyWith(
                                    fontWeight: FontWeight.w600,
                                  )
                                : cellStyle,
                          ),
                        ),
                      )
                    else
                      const SizedBox.shrink(),
                ],
              ),
          ],
        ),
      ),
    );
  }

  TextSpan _inline(List<md.Node> nodes, TextStyle style) => TextSpan(
    style: style,
    children: [for (final n in nodes) _inlineNode(n, style)],
  );

  InlineSpan _inlineNode(md.Node node, TextStyle style) {
    if (node is! md.Element) return TextSpan(text: node.textContent);
    final children = node.children ?? const <md.Node>[];
    switch (node.tag) {
      case 'strong':
        return _inline(children, style.copyWith(fontWeight: FontWeight.w700));
      case 'em':
        return _inline(children, style.copyWith(fontStyle: FontStyle.italic));
      case 'del':
        return _inline(
          children,
          style.copyWith(
            decoration: TextDecoration.lineThrough,
            decorationColor: style.color,
          ),
        );
      case 'code':
        // Background is a plain rect matching the run's line extent — gputext
        // has no rounded/padded inline boxes, so this is the GitHub-style
        // "highlight strip" look rather than a pill.
        return TextSpan(
          text: node.textContent,
          style: style.copyWith(
            fontFamily: 'JetBrainsMono',
            fontSize: (style.fontSize ?? 15) - 1.5,
            color: _codeInk,
            backgroundColor: _panel2,
          ),
        );
      case 'a':
        final href = node.attributes['href'] ?? '';
        return TextSpan(
          text: node.textContent,
          style: style.copyWith(
            color: _accent,
            decoration: TextDecoration.underline,
            decorationColor: _accent,
          ),
          recognizer: _linkRecognizer(href),
          mouseCursor: SystemMouseCursors.click,
        );
      case 'br':
        return const TextSpan(text: '\n');
      case 'img':
        return TextSpan(
          text:
              '[image: ${node.attributes['alt'] ?? node.attributes['src'] ?? ''}]',
          style: style.copyWith(color: _muted, fontStyle: FontStyle.italic),
        );
      default:
        return _inline(children, style);
    }
  }

  /// One recognizer per distinct URL, reused across the constant rebuilds of a
  /// streaming transcript; all disposed with the page.
  TapGestureRecognizer _linkRecognizer(String href) =>
      _linkRecognizers.putIfAbsent(href, () {
        return TapGestureRecognizer()
          ..onTap = () {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text('Link tapped: $href')));
          };
      });

  // -- UI ----------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        title: const Text('AI chat — markdown on gputext'),
        backgroundColor: _bg,
        foregroundColor: _ink,
        actions: [
          IconButton(
            tooltip: _stressActive
                ? 'Stop the stress run'
                : 'Stress: auto-play long generated turns',
            color: _stressActive ? _accent : _muted,
            icon: const Icon(Icons.bolt),
            onPressed: _fontsReady ? _toggleStress : null,
          ),
          IconButton(
            tooltip: 'Reset conversation',
            color: _muted,
            icon: const Icon(Icons.refresh),
            onPressed: _fontsReady ? _reset : null,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(20),
          child: Padding(
            padding: const EdgeInsets.only(left: 16, right: 16, bottom: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: ValueListenableBuilder<String>(
                valueListenable: _stats,
                builder: (_, value, _) => Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 11,
                    color: _muted,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      body: !_fontsReady
          ? const Center(child: CircularProgressIndicator(color: _accent))
          : Column(
              children: [
                Expanded(
                  child: NotificationListener<ScrollUpdateNotification>(
                    onNotification: (n) {
                      // Follow the stream only while the user is at (or
                      // near) the bottom; scrolling up releases the pin,
                      // scrolling back down re-engages it.
                      _stickToBottom =
                          n.metrics.pixels >= n.metrics.maxScrollExtent - 80;
                      return false;
                    },
                    child: SelectionArea(
                      child: ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                        // Generous cache extent so off-screen bubbles are built
                        // (and their layout cached) before they scroll in.
                        scrollCacheExtent: .pixels(1200),
                        itemCount: _messages.length,
                        itemBuilder: (context, i) =>
                            _buildMessage(context, _messages[i]),
                      ),
                    ),
                  ),
                ),
                _buildInputBar(),
              ],
            ),
    );
  }

  Widget _buildMessage(BuildContext context, _ChatMessage m) {
    if (m.role == _Role.user) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(top: 12, left: 64),
          constraints: const BoxConstraints(maxWidth: 560),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: const BoxDecoration(
            color: _userBg,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(16),
              topRight: Radius.circular(16),
              bottomLeft: Radius.circular(16),
              bottomRight: Radius.circular(4),
            ),
          ),
          child: GPULabel(m.text, style: _body.copyWith(color: Colors.white)),
        ),
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(top: 12, right: 32),
        constraints: const BoxConstraints(maxWidth: 720),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        decoration: const BoxDecoration(
          color: _panel,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(4),
            topRight: Radius.circular(16),
            bottomLeft: Radius.circular(16),
            bottomRight: Radius.circular(16),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ..._messageBlocks(m),
            if (m.streaming)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: _BlinkingCaret(),
              ),
          ],
        ),
      ),
    );
  }

  /// The streaming (hot) message renders per-tick; completed messages build
  /// once and cache the immutable widget subtree.
  List<Widget> _messageBlocks(_ChatMessage m) {
    if (m.streaming) return _streamingBlocks(m);
    return m._builtBlocks ??= _buildBlocks(m.parsedWith(_parse));
  }

  /// Per-tick block list for the streaming message. Naively rebuilding every
  /// block each tick makes the paint phase call prepareContent (and layout
  /// walk compareTo) on the whole bubble 25-60×/s when only the growing tail
  /// changed. Settled blocks are reused by (tag, textContent) key — identical
  /// widget instances short-circuit the element rebuild — and every block
  /// gets its own RepaintBoundary so the tail's re-render doesn't repaint its
  /// siblings. The tail (and any block a re-parse retroactively reshaped —
  /// the key mismatch catches that) rebuilds fresh.
  List<Widget> _streamingBlocks(_ChatMessage m) {
    final nodes = m.parsedWith(_parse);
    final prev = m._streamCache;
    final next = <(String, Widget)>[];
    for (var i = 0; i < nodes.length; i++) {
      final node = nodes[i];
      final key =
          '${node is md.Element ? node.tag : 'txt'}|${node.textContent}';
      final settled = i < nodes.length - 1;
      Widget? reused;
      if (settled && prev != null && i < prev.length && prev[i].$1 == key) {
        reused = prev[i].$2;
      }
      next.add((
        key,
        reused ??
            RepaintBoundary(
              child: settled ? _buildBlock(node) : _streamingTail(node, m),
            ),
      ));
    }
    m._streamCache = next;
    return [for (final (_, w) in next) w];
  }

  /// The growing tail block re-shapes per tick, and for container blocks that
  /// cost is O(whole block) — a 60-line streaming code block re-shaped every
  /// 16-40ms is the profiled performLayout jank, and over a W-word response
  /// whole-block re-prepare totals O(W²) shaping. Streaming text is
  /// append-only, so completed sub-units never change: freeze each finished
  /// code line / list item / quote child as a cached widget (shaped exactly
  /// once) and rebuild only the growing sub-unit — total shaping drops to
  /// O(W). Leaf blocks (paragraph / heading / text) have no sub-units to
  /// freeze, so they re-shape whole each tick on the widget path.
  Widget _streamingTail(md.Node node, _ChatMessage m) {
    if (node is md.Element) {
      switch (node.tag) {
        case 'pre':
          return _streamingCode(node, m);
        case 'ul' || 'ol':
          return _streamingList(node, m);
        case 'blockquote':
          final children = node.children ?? const <md.Node>[];
          return Container(
            margin: const EdgeInsets.symmetric(vertical: 6),
            padding: const EdgeInsets.only(left: 12),
            decoration: const BoxDecoration(
              border: Border(left: BorderSide(color: _border, width: 3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < children.length; i++)
                  if (i == children.length - 1)
                    _streamingTail(children[i], m)
                  else
                    m._tailCache.putIfAbsent(
                      'bq$i|${_nodeKey(children[i])}',
                      () => _buildBlock(children[i]),
                    ),
              ],
            ),
          );
      }
    }
    return _buildBlock(node);
  }

  static String _nodeKey(md.Node n) =>
      '${n is md.Element ? n.tag : 'txt'}|${n.textContent}';

  /// Streaming code block: every completed line is frozen as its own
  /// one-line GPURichText (mono, no wrap — line boxes stack identically to
  /// the single-block layout), so per tick only the partial last line
  /// re-shapes.
  Widget _streamingCode(md.Element pre, _ChatMessage m) {
    final code =
        (pre.children ?? const <md.Node>[])
            .whereType<md.Element>()
            .firstOrNull ??
        pre;
    final lang = code.attributes['class']?.replaceFirst('language-', '');
    final lines = code.textContent.split('\n');
    final active = lines.removeLast(); // partial ('' right after a newline)
    return _CodeBlock(
      code: code.textContent,
      language: (lang?.isEmpty ?? true) ? null : lang,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < lines.length; i++)
            m._tailCache.putIfAbsent(
              'cl$i|${lines[i]}',
              // A space keeps blank code lines one line-box tall.
              () => GPURichText(
                text: TextSpan(
                  text: lines[i].isEmpty ? ' ' : lines[i],
                  style: _mono,
                ),
                softWrap: false,
              ),
            ),
          if (active.isNotEmpty)
            GPURichText(
              text: TextSpan(text: active, style: _mono),
              softWrap: false,
            ),
        ],
      ),
    );
  }

  /// Streaming list: completed items are frozen rows; only the last item
  /// (which may still be receiving words or nested content) rebuilds.
  Widget _streamingList(md.Element list, _ChatMessage m) {
    final ordered = list.tag == 'ol';
    var n = int.tryParse(list.attributes['start'] ?? '') ?? 1;
    final items = (list.children ?? const <md.Node>[])
        .whereType<md.Element>()
        .where((e) => e.tag == 'li')
        .toList();
    final rows = <Widget>[];
    for (var i = 0; i < items.length; i++) {
      final marker = ordered ? '${n++}.' : '•';
      Widget buildRow() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 26, child: GPULabel(marker, style: _body)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: _buildListItem(items[i], 0),
              ),
            ),
          ],
        ),
      );
      rows.add(
        i == items.length - 1
            ? buildRow()
            : m._tailCache.putIfAbsent(
                'li$i|$marker|${items[i].textContent}',
                buildRow,
              ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: rows,
      ),
    );
  }

  Widget _buildInputBar() {
    return Container(
      color: _panel,
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                style: const TextStyle(color: _ink, fontSize: 15),
                cursorColor: _accent,
                onSubmitted: (_) => _send(),
                decoration: InputDecoration(
                  hintText: 'Ask anything — the reply is scripted markdown',
                  hintStyle: const TextStyle(color: _muted, fontSize: 15),
                  filled: true,
                  fillColor: _panel2,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: _streaming ? 'Skip to end' : 'Send',
              color: _accent,
              icon: Icon(
                _streaming ? Icons.stop_circle_outlined : Icons.send_rounded,
              ),
              onPressed: _streaming ? _skipStreaming : _send,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Code block + caret
// ---------------------------------------------------------------------------

class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.code, this.language, this.body});

  final String code;
  final String? language;

  /// Optional body override — the streaming path passes a per-line Column so
  /// completed lines shape once; null renders [code] as one GPURichText.
  final Widget? body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              color: _panel2,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: GPULabel(
                language ?? 'code',
                style: _mono.copyWith(fontSize: 11, color: _muted),
              ),
            ),
            Container(
              color: _codeBg,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                scrollDirection: Axis.horizontal,
                child:
                    body ??
                    GPURichText(
                      text: TextSpan(text: code, style: _mono),
                      softWrap: false,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BlinkingCaret extends StatefulWidget {
  const _BlinkingCaret();

  @override
  State<_BlinkingCaret> createState() => _BlinkingCaretState();
}

class _BlinkingCaretState extends State<_BlinkingCaret>
    with SingleTickerProviderStateMixin {
  late final AnimationController _blink = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // RepaintBoundary: the fade repaints ~60×/s for as long as a response
    // streams. Without the boundary that repaint propagates to the enclosing
    // ListView item and re-paints every text block in the streaming bubble
    // each frame (a prepareContent flood in the timeline); with it, the
    // animation is confined to this 3×16 layer.
    return RepaintBoundary(
      child: FadeTransition(
        opacity: _blink,
        child: Container(
          width: 3,
          height: 16,
          decoration: BoxDecoration(
            color: _accent,
            borderRadius: BorderRadius.circular(1.5),
          ),
        ),
      ),
    );
  }
}

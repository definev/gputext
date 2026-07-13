// A Flutter + gputext port of the "pretext-playground" ASCII dragon demo
// (github.com/0xNyk/pretext-playground). Every on-screen character is a
// physics body anchored at a home position; an ASCII dragon flies through the
// text, hold to breathe fire (letters scatter + burn), shoot floating enemies.
//
// This build maximizes gputext: BOTH halves run on the engine.
//   • Layout — the inner pretext prebuilt (prepareParagraph →
//     layoutPreparedLines / breakLines). Each block is prepared once, then a
//     resize re-runs only the pure-arithmetic line walker; a HUD shows the
//     prepare-vs-relayout microsecond split.
//   • Rendering — every glyph is rasterized by gputext's GPU coverage shader.
//     We build one Float32 instance buffer per frame (16 floats per glyph:
//     pen, baseline, scale, bbox, rgba, band refs) against a Lato glyph atlas
//     and draw it through GPUTextPipeline into an offscreen flutter_gpu
//     surface, then blit the cached ui.Image.
//
// Two consequences of going all-GPU (the shader rasterizes vector outlines
// from the loaded TTF, and has no per-glyph rotation): glyphs are upright, and
// only characters Lato actually contains render — so the dragon body, fire,
// enemies and runes are drawn with Lato-covered ASCII, and the original's
// CJK/Arabic/emoji line becomes Latin. Non-glyph flourishes (head glow, the
// cursor crosshair) are a thin Canvas overlay on top of the GPU image.
//
// Dev hook (demo only): GPUTEXT_DEMO=dragon opens this page directly.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:vector_math/vector_math.dart' as vm;

import 'package:gputext/gputext.dart';
import 'package:gputext/internal.dart' as gt;

const _floatsPerInstance = 16;

gpu.PixelFormat _surfaceFormat(gpu.GpuContext context) {
  final preferred = context.defaultColorFormat;
  if (preferred != gpu.PixelFormat.unknown &&
      context.supportsTextureFormat(preferred, renderTarget: true)) {
    return preferred;
  }
  return gpu.PixelFormat.b8g8r8a8UNormInt;
}

// ─── Config (mutated by the control panel) ──────────────────────────────

class DragonConfig {
  int dragonSegments = 60;
  double dragonSpeed = 0.18;
  double dragonScale = 1.0;
  bool showWings = true;
  bool showSpines = true;
  double pushForce = 6;
  double springStrength = 0.015;
  double damping = 0.93;
  double burnGravity = 0.8;
  double fireRadius = 120;
  double fireForce = 25;
  bool screenShake = true;
  bool showEmbers = true;
  bool showParticles = true;
  bool showRunes = true;
  bool showCursor = true;
  double textOpacity = 1.0;
  bool showEnemies = true;
  int enemyCount = 8;
  double enemySpeed = 0.6;

  void copyFrom(DragonConfig o) {
    dragonSegments = o.dragonSegments;
    dragonSpeed = o.dragonSpeed;
    dragonScale = o.dragonScale;
    showWings = o.showWings;
    showSpines = o.showSpines;
    pushForce = o.pushForce;
    springStrength = o.springStrength;
    damping = o.damping;
    burnGravity = o.burnGravity;
    fireRadius = o.fireRadius;
    fireForce = o.fireForce;
    screenShake = o.screenShake;
    showEmbers = o.showEmbers;
    showParticles = o.showParticles;
    showRunes = o.showRunes;
    showCursor = o.showCursor;
    textOpacity = o.textOpacity;
    showEnemies = o.showEnemies;
    enemyCount = o.enemyCount;
    enemySpeed = o.enemySpeed;
  }
}

typedef _Preset = void Function(DragonConfig c);

final Map<String, _Preset> _presets = {
  'Default': (c) {},
  'Gentle': (c) {
    c.dragonSpeed = 0.10;
    c.pushForce = 5;
    c.fireForce = 10;
    c.fireRadius = 60;
    c.screenShake = false;
    c.burnGravity = 0.2;
    c.springStrength = 0.03;
  },
  'Chaos': (c) {
    c.pushForce = 25;
    c.fireForce = 50;
    c.fireRadius = 200;
    c.burnGravity = 2.5;
    c.springStrength = 0.005;
    c.damping = 0.96;
    c.screenShake = true;
  },
  'Zen': (c) {
    c.showParticles = false;
    c.showEmbers = false;
    c.screenShake = false;
    c.showRunes = false;
    c.pushForce = 4;
    c.fireForce = 8;
    c.springStrength = 0.04;
    c.burnGravity = 0;
  },
  'Tiny': (c) {
    c.dragonSegments = 20;
    c.dragonScale = 0.6;
    c.fireRadius = 50;
    c.pushForce = 6;
  },
  'Leviathan': (c) {
    c.dragonSegments = 80;
    c.dragonScale = 2.0;
    c.dragonSpeed = 0.08;
    c.pushForce = 20;
    c.fireRadius = 180;
  },
};

// ─── Text corpus (Latin-only so Lato's outlines cover every glyph) ──────

enum _Col { left, right, center }

class _TextEntry {
  const _TextEntry({
    required this.text,
    required this.fontSize,
    required this.rgb,
    required this.alpha,
    required this.yOffset,
    required this.maxWidth,
    required this.lineHeight,
    required this.column,
    this.pre = false,
  });

  final String text;
  final double fontSize;
  final int rgb; // 0xRRGGBB
  final double alpha;
  final double yOffset;
  final double maxWidth;
  final double lineHeight;
  final _Col column;
  final bool pre;
}

const _textEntries = <_TextEntry>[
  _TextEntry(
    text: 'PRETEXT',
    fontSize: 120,
    rgb: 0x222222,
    alpha: 0.5,
    yOffset: -20,
    maxWidth: 1200,
    lineHeight: 130,
    column: _Col.center,
  ),
  _TextEntry(
    text: 'HERE BE DRAGONS',
    fontSize: 54,
    rgb: 0xF0F0F0,
    alpha: 1.0,
    yOffset: 100,
    maxWidth: 900,
    lineHeight: 64,
    column: _Col.left,
  ),
  _TextEntry(
    text: 'Text measurement without DOM reflow - pure arithmetic, pure fire',
    fontSize: 18,
    rgb: 0x999999,
    alpha: 0.75,
    yOffset: 175,
    maxWidth: 700,
    lineHeight: 26,
    column: _Col.left,
  ),
  _TextEntry(
    text:
        'In the age of AI, text layout was the last and biggest bottleneck for '
        'unlocking much more interesting UIs. No longer do we have to choose '
        'between the flashiness of a WebGL landing page versus the practicality '
        'of a blog article. The engine is tiny, aware of browser quirks, and '
        'supports every language you will ever need.',
    fontSize: 14,
    rgb: 0xBBBBBB,
    alpha: 0.65,
    yOffset: 225,
    maxWidth: 500,
    lineHeight: 21,
    column: _Col.left,
  ),
  // CJK (subset Noto Sans SC) + color emoji (Twemoji COLR) + Latin — every
  // glyph on this line is GPU-rendered natively by the coverage shader. Keep
  // the CJK characters in sync with the NotoSansSC-subset.ttf glyph set.
  _TextEntry(
    text:
        '春天到了，龙穿行于文字之间。每一个都是粒子 🐉🔥 '
        'prepare() once, layout() forever.',
    fontSize: 20,
    rgb: 0xEE9944,
    alpha: 0.85,
    yOffset: 460,
    maxWidth: 520,
    lineHeight: 30,
    column: _Col.left,
  ),
  _TextEntry(
    text:
        "import { prepare, layout } from '@chenglou/pretext'\n"
        "const prepared = prepare(text, '16px Inter')\n"
        'const { height } = layout(prepared, width, 20)\n'
        '// ~0.0002ms per layout call. Pure math.',
    fontSize: 13,
    rgb: 0x77CC77,
    alpha: 0.6,
    yOffset: 550,
    maxWidth: 520,
    lineHeight: 18,
    column: _Col.left,
    pre: true,
  ),
  _TextEntry(
    text:
        '"Fast, accurate and comprehensive userland text measurement algorithm '
        'in pure TypeScript, usable for laying out entire web pages without CSS"',
    fontSize: 14,
    rgb: 0xCC9966,
    alpha: 0.65,
    yOffset: 120,
    maxWidth: 380,
    lineHeight: 21,
    column: _Col.right,
  ),
  _TextEntry(
    text:
        'Shrinkwrapped chat bubbles. Responsive magazine layouts. Variable font '
        'width ASCII art. Canvas, SVG, WebGL - render anywhere. 120fps masonry '
        'with 100k items.',
    fontSize: 13,
    rgb: 0xBBBBBB,
    alpha: 0.6,
    yOffset: 310,
    maxWidth: 380,
    lineHeight: 19,
    column: _Col.right,
  ),
  _TextEntry(
    text:
        '* CJK per-character breaking\n* Arabic/Hebrew bidi\n* Emoji correction\n'
        '* Soft hyphens & tab stops\n* overflow-wrap: break-word\n'
        '* Grapheme-level breaking',
    fontSize: 12,
    rgb: 0xFF9955,
    alpha: 0.55,
    yOffset: 470,
    maxWidth: 350,
    lineHeight: 17,
    column: _Col.right,
    pre: true,
  ),
  _TextEntry(
    text:
        'The serpent coils through the GPU. Each scale a character. Each breath '
        'a particle. The text scatters and reforms.',
    fontSize: 15,
    rgb: 0x998877,
    alpha: 0.5,
    yOffset: 680,
    maxWidth: 800,
    lineHeight: 22,
    column: _Col.center,
  ),
];

// ─── The simulation ─────────────────────────────────────────────────────

class _Game {
  _Game(this.cfg);

  final DragonConfig cfg;
  final math.Random _rng = math.Random(0xD7A6);

  final ValueNotifier<int> repaint = ValueNotifier<int>(0);

  double w = 0, h = 0, dpr = 1;
  double time = 0;
  double mouseX = 0, mouseY = 0;
  bool breathingFire = false;

  // Three glyph sources, set once the GPU boots: Lato (Latin + the ASCII
  // dragon/particles), a subset Noto Sans SC (the CJK line), and Twemoji COLR
  // color glyphs (the emoji). Each has its own atlas + instance buffer so it
  // draws with its own texture set; layout resolves each character to whichever
  // covers it.
  GPUFont? _font; // Lato
  Map<String, GlyphTableEntry>? _atlas;
  double _unitsPerEm = 1000;

  GPUFont? _fontCjk;
  Map<String, GlyphTableEntry>? _atlasCjk;
  double _uemCjk = 1000;

  GPUFont? _fontEmoji;
  ColrEmojiAtlas? _emojiAtlas;
  double _uemEmoji = 1000;

  int letterCount = 0;
  double prepareUs = 0;
  double relayoutUs = 0;
  double oneShotUs = 0;

  final List<PreparedParagraph?> _prepared = [];

  // Per-frame instance scratch (16 floats/glyph); one buffer per font, reused
  // to avoid GC churn.
  static const _maxGlyphs = 5000;
  final Float32List _scratch = Float32List(_maxGlyphs * _floatsPerInstance);
  int _outLen = 0;
  final Float32List _scCjk = Float32List(512 * _floatsPerInstance);
  int _outCjk = 0;
  final Float32List _scEmoji = Float32List(256 * _floatsPerInstance);
  int _outEmoji = 0;

  Float32List get instancesLato => _scratch;
  Float32List get instancesCjk => _scCjk;
  Float32List get instancesEmoji => _scEmoji;
  int get countLato => _outLen ~/ _floatsPerInstance;
  int get countCjk => _outCjk ~/ _floatsPerInstance;
  int get countEmoji => _outEmoji ~/ _floatsPerInstance;
  bool get hasCjk => _atlasCjk != null;
  bool get hasEmoji => _emojiAtlas != null;

  // ── Letters (struct-of-arrays) ──────────────────────────────────────────
  static const maxLetters = 2000;
  final Float32List lHomeX = Float32List(maxLetters);
  final Float32List lHomeY = Float32List(maxLetters);
  final Float32List lX = Float32List(maxLetters);
  final Float32List lY = Float32List(maxLetters);
  final Float32List lVx = Float32List(maxLetters);
  final Float32List lVy = Float32List(maxLetters);
  final Float32List lAngVel = Float32List(maxLetters);
  final Float32List lCharW = Float32List(maxLetters);
  final Float32List lBaseAlpha = Float32List(maxLetters);
  final Float32List lFontSize = Float32List(maxLetters);
  final Float32List lBurnTimer = Float32List(maxLetters);
  final Float32List lScaleMul = Float32List(maxLetters);
  final Float32List lGravity = Float32List(maxLetters);
  final List<String> lChar = List.filled(maxLetters, '');
  final Int32List lColor = Int32List(maxLetters); // packed rgb
  final Int8List lFont = Int8List(maxLetters); // 0=Lato, 1=CJK, 2=emoji

  // ── Embers ──────────────────────────────────────────────────────────────
  static const maxEmbers = 60;
  int emberCount = 0;
  final Float32List emX = Float32List(maxEmbers);
  final Float32List emY = Float32List(maxEmbers);
  final Float32List emVx = Float32List(maxEmbers);
  final Float32List emVy = Float32List(maxEmbers);
  final Float32List emLife = Float32List(maxEmbers);
  final Float32List emSize = Float32List(maxEmbers);
  final List<String> emChar = List.filled(maxEmbers, '.');
  final Int32List emColor = Int32List(maxEmbers);
  static const _emberChars = ['.', 'o', '*', '+'];
  static const _emberColors = [0xFF6600, 0xFFAA00, 0xFF4400];

  // ── Fire particles ───────────────────────────────────────────────────────
  static const maxParticles = 150;
  int particleCount = 0;
  final Float32List pX = Float32List(maxParticles);
  final Float32List pY = Float32List(maxParticles);
  final Float32List pVx = Float32List(maxParticles);
  final Float32List pVy = Float32List(maxParticles);
  final Float32List pLife = Float32List(maxParticles);
  final Float32List pMaxLife = Float32List(maxParticles);
  final Float32List pSize = Float32List(maxParticles);
  final List<String> pChar = List.filled(maxParticles, '*');
  static const _fireChars = ['*', '+', 'o', 'x', '.', "'", '~'];

  // ── Dragon chain ─────────────────────────────────────────────────────────
  static const segSpacing = 10.0;
  int chainN = 0;
  Float32List chX = Float32List(80);
  Float32List chY = Float32List(80);
  Float32List chPx = Float32List(80);
  Float32List chPy = Float32List(80);
  // Dense head to sparse tail, all Lato-covered ASCII.
  static const _dragonChars = r'@@##%%&&$$88OO00ooccxx==++**~~;;::--..';

  // ── Enemies ──────────────────────────────────────────────────────────────
  final List<_Enemy> enemies = [];
  int score = 0;
  double scoreFlash = 0;
  static const _enemyKinds = <_EnemyKind>[
    _EnemyKind('X', 0xFF4466, 1, 22, 1.0),
    _EnemyKind('#', 0xFF6688, 3, 28, 0.5),
    _EnemyKind('+', 0x44DDFF, 1, 16, 2.2),
    _EnemyKind('o', 0xAA88FF, 2, 20, 0.8),
  ];

  // ── Tunnel ────────────────────────────────────────────────────────────────
  static const _tunnelTexts = [
    'PRETEXT - pure text measurement',
    'measure once, lay out forever',
    'prepare() then layout() then render',
    'every character is a particle',
    'No DOM. No reflow. Pure math.',
    'CJK / Bidi / Emoji / Graphemes',
  ];
  static const tunnelRings = 12;
  static const tunnelDepth = 1200.0;
  final Float32List tunnelZ = Float32List(tunnelRings);
  final Int32List tunnelSide = Int32List(tunnelRings);
  final Int32List tunnelTextIdx = Int32List(tunnelRings);

  // ── Runes ──────────────────────────────────────────────────────────────────
  static const runeN = 8;
  static const _runeChars = ['R', 'F', 'W', 'X', 'K', 'A', 'V', 'Z'];
  final Float32List runeX = Float32List(runeN);
  final Float32List runeY = Float32List(runeN);
  final Float32List runeSpd = Float32List(runeN);
  final Float32List runePhase = Float32List(runeN);
  final Float32List runeSz = Float32List(runeN);
  final Float32List runeOp = Float32List(runeN);
  final List<String> runeC = List.filled(runeN, 'R');

  double shakeIntensity = 0, shakeX = 0, shakeY = 0;
  double _fireAccum = 0, _totalFireTime = 0;
  bool _runesSeeded = false;

  bool get ready => _atlas != null;

  void setLato(GPUFont font, Map<String, GlyphTableEntry> atlas) {
    _font = font;
    _atlas = atlas;
    _unitsPerEm = font.unitsPerEm.toDouble();
    if (w > 0) layoutAllText();
  }

  void setCjk(GPUFont font, Map<String, GlyphTableEntry> atlas) {
    _fontCjk = font;
    _atlasCjk = atlas;
    _uemCjk = font.unitsPerEm.toDouble();
    if (w > 0) layoutAllText();
  }

  void setEmoji(GPUFont font, ColrEmojiAtlas atlas) {
    _fontEmoji = font;
    _emojiAtlas = atlas;
    _uemEmoji = font.unitsPerEm.toDouble();
    if (w > 0) layoutAllText();
  }

  void _triggerShake(double intensity) {
    if (!cfg.screenShake) return;
    shakeIntensity = math.max(shakeIntensity, math.min(intensity, 8));
  }

  void _updateShake() {
    if (shakeIntensity > 0.1) {
      shakeX = (_rng.nextDouble() - 0.5) * shakeIntensity;
      shakeY = (_rng.nextDouble() - 0.5) * shakeIntensity;
      shakeIntensity *= 0.85;
    } else {
      shakeX = 0;
      shakeY = 0;
      shakeIntensity = 0;
    }
  }

  void resize(double newW, double newH) {
    final first = w == 0 && h == 0;
    w = newW;
    h = newH;
    if (first) {
      // Rest the dragon in a calm lower-right spot on load so the headline
      // text isn't scattered before the user moves the pointer.
      mouseX = w * 0.9;
      mouseY = h * 0.85;
      _seedRunes();
      _seedTunnel();
      rebuildDragon();
    }
    layoutAllText();
    _seedTunnel();
  }

  void _seedRunes() {
    if (_runesSeeded) return;
    _runesSeeded = true;
    for (var i = 0; i < runeN; i++) {
      runeX[i] = _rng.nextDouble() * w;
      runeY[i] = _rng.nextDouble() * h;
      runeSpd[i] = 0.1 + _rng.nextDouble() * 0.4;
      runePhase[i] = _rng.nextDouble() * math.pi * 2;
      runeSz[i] = 14 + _rng.nextDouble() * 14;
      runeOp[i] = 0.03 + _rng.nextDouble() * 0.05;
      runeC[i] = _runeChars[_rng.nextInt(_runeChars.length)];
    }
  }

  void _seedTunnel() {
    for (var i = 0; i < tunnelRings; i++) {
      tunnelZ[i] = (i / tunnelRings) * tunnelDepth;
      tunnelSide[i] = i % 4;
      tunnelTextIdx[i] = i % _tunnelTexts.length;
    }
  }

  void rebuildDragon() {
    chainN = cfg.dragonSegments;
    if (chX.length < chainN) {
      chX = Float32List(chainN);
      chY = Float32List(chainN);
      chPx = Float32List(chainN);
      chPy = Float32List(chainN);
    }
    final sx = mouseX == 0 ? w / 2 : mouseX;
    final sy = mouseY == 0 ? h / 2 : mouseY;
    for (var i = 0; i < chainN; i++) {
      chX[i] = sx;
      chY[i] = sy + i * segSpacing;
      chPx[i] = chX[i];
      chPy[i] = chY[i];
    }
  }

  double segScale(int i) {
    if (i < 3) return (2.5 - i * 0.15) * cfg.dragonScale;
    final t = (i - 3) / (chainN - 3);
    return (2.0 * (1 - t * t) + 0.2) * cfg.dragonScale;
  }

  // ── Text layout via gputext's inner pretext prebuilt ────────────────────

  /// Which glyph source covers [ch]: 0 = Lato, 1 = CJK, 2 = emoji, -1 = none.
  int _resolveFont(String ch) {
    if (ch.isEmpty) return -1;
    final lato = _font;
    if (lato != null && lato.hasGlyph(ch)) return 0;
    final cjk = _fontCjk;
    if (cjk != null && cjk.hasGlyph(ch)) return 1;
    if (_emojiAtlas?.layers.containsKey(ch.runes.first) ?? false) return 2;
    return -1;
  }

  double _advance(String ch, double size) {
    switch (_resolveFont(ch)) {
      case 0:
        return _font!.advanceOf(ch) / _unitsPerEm * size;
      case 1:
        return _fontCjk!.advanceOf(ch) / _uemCjk * size;
      case 2:
        return _fontEmoji!.advanceOf(ch) / _uemEmoji * size;
      default:
        return size * 0.5;
    }
  }

  double _coverage(String text, GPUFont font) {
    var total = 0, covered = 0;
    for (final ch in text.characters) {
      if (ch.trim().isEmpty) continue;
      total++;
      if (font.hasGlyph(ch)) covered++;
    }
    return total == 0 ? 1 : covered / total;
  }

  /// Greedy per-character wrap using multi-font advances — for blocks the Lato
  /// metrics don't cover well (the CJK/emoji line), where the inner-pretext
  /// walker (single font) would misjudge widths.
  List<String> _manualBreak(String text, double size, double maxW) {
    final lines = <String>[];
    for (final para in text.split('\n')) {
      var line = StringBuffer();
      var lineW = 0.0;
      for (final ch in para.characters) {
        final cw = _advance(ch, size);
        if (lineW + cw > maxW && line.isNotEmpty && ch.trim().isNotEmpty) {
          lines.add(line.toString());
          line = StringBuffer();
          lineW = 0;
        }
        line.write(ch);
        lineW += cw;
      }
      lines.add(line.toString());
    }
    return lines;
  }

  List<String> _breakEntry(_TextEntry entry, int index, double maxW) {
    final font = _font;
    if (font == null) return const [];

    if (entry.pre) {
      while (_prepared.length <= index) {
        _prepared.add(null);
      }
      _prepared[index] = null;
      return entry.text.split('\n');
    }

    // The CJK/emoji line: Lato covers little of it, so the single-font
    // inner-pretext walker would misjudge widths — wrap it per character with
    // multi-font advances instead.
    if (_coverage(entry.text, font) < 0.6) {
      while (_prepared.length <= index) {
        _prepared.add(null);
      }
      _prepared[index] = null;
      return _manualBreak(entry.text, entry.fontSize, maxW);
    }

    PreparedParagraph? prepared =
        index < _prepared.length ? _prepared[index] : null;
    if (prepared == null) {
      final sw = Stopwatch()..start();
      final runs = [
        TextRun(
          text: entry.text,
          font: font,
          fontSizePx: entry.fontSize,
          color: const [1, 1, 1, 1],
        ),
      ];
      prepared = prepareParagraph(runs);
      prepareUs += sw.elapsedMicroseconds;
      while (_prepared.length <= index) {
        _prepared.add(null);
      }
      _prepared[index] = prepared;

      final sw2 = Stopwatch()..start();
      breakLines(runs, maxW, gt.ParagraphStyle(maxWidth: maxW));
      oneShotUs += sw2.elapsedMicroseconds;
    }

    final swLayout = Stopwatch()..start();
    final para = layoutPreparedLines(
      prepared,
      maxW,
      gt.ParagraphStyle(maxWidth: maxW),
    );
    relayoutUs += swLayout.elapsedMicroseconds;

    return [for (final line in para.lines) _lineText(line)];
  }

  static String _lineText(gt.LineMetrics line) {
    final sb = StringBuffer();
    for (final item in line.items) {
      if (item is gt.LineRun) sb.write(item.text);
    }
    return sb.toString();
  }

  void layoutAllText() {
    if (_font == null) return;

    letterCount = 0;
    // prepareUs / oneShotUs are one-time costs (measured the first time each
    // block is prepared) and persist; only the per-width relayout resets. That
    // split is the whole point: prepare once, re-run the cheap walker per width.
    relayoutUs = 0;

    final mx = math.max(50.0, w * 0.06);
    final my = math.max(60.0, h * 0.06);
    final cw = w - mx * 2;
    final twoCol = cw > 700;
    final col2X = twoCol ? mx + cw * 0.56 : mx;

    for (var ei = 0; ei < _textEntries.length; ei++) {
      final entry = _textEntries[ei];
      double baseX, maxW;
      switch (entry.column) {
        case _Col.right:
          baseX = twoCol ? col2X : mx;
          maxW = math.min(entry.maxWidth, twoCol ? cw * 0.4 : cw);
        case _Col.center:
          maxW = math.min(entry.maxWidth, cw);
          baseX = mx + (cw - maxW) / 2;
        case _Col.left:
          baseX = mx;
          maxW = math.min(entry.maxWidth, twoCol ? cw * 0.5 : cw);
      }
      final baseY = my + entry.yOffset;

      final lines = _breakEntry(entry, ei, maxW);
      for (var li = 0; li < lines.length; li++) {
        var xc = baseX;
        final y = baseY + li * entry.lineHeight;
        for (final ch in lines[li].characters) {
          if (ch == '\n' || letterCount >= maxLetters) continue;
          final cw2 = _advance(ch, entry.fontSize);
          final fontIdx = _resolveFont(ch);
          if (ch.trim().isEmpty || fontIdx < 0) {
            xc += cw2;
            continue;
          }
          final i = letterCount++;
          lFont[i] = fontIdx;
          lHomeX[i] = xc + cw2 / 2;
          lHomeY[i] = y + entry.lineHeight / 2;
          lX[i] = lHomeX[i];
          lY[i] = lHomeY[i];
          lVx[i] = 0;
          lVy[i] = 0;
          lAngVel[i] = 0;
          lCharW[i] = cw2;
          lBaseAlpha[i] = entry.alpha;
          lFontSize[i] = entry.fontSize;
          lBurnTimer[i] = 0;
          lScaleMul[i] = 1;
          lGravity[i] = 0;
          lChar[i] = ch;
          lColor[i] = entry.rgb;
          xc += cw2;
        }
      }
    }
  }

  // ── Per-frame update ─────────────────────────────────────────────────────

  void update(double dt) {
    time += dt;
    _updateShake();
    _updateChain();
    _interactLetters(dt);
    _emitFire(dt);
    _updateParticlesAndEmbers(dt);
    _updateEnemies(dt);
  }

  void _updateChain() {
    for (var i = 0; i < chainN; i++) {
      chPx[i] = chX[i];
      chPy[i] = chY[i];
    }
    chX[0] += (mouseX - chX[0]) * cfg.dragonSpeed;
    chY[0] += (mouseY - chY[0]) * cfg.dragonSpeed;
    for (var i = 1; i < chainN; i++) {
      final dx = chX[i] - chX[i - 1], dy = chY[i] - chY[i - 1];
      final d = math.sqrt(dx * dx + dy * dy);
      if (d > segSpacing) {
        final r = segSpacing / d;
        chX[i] = chX[i - 1] + dx * r;
        chY[i] = chY[i - 1] + dy * r;
      }
    }
  }

  void _interactLetters(double dt) {
    final checkSegs = math.min((chainN * 0.4).round(), chainN);
    final damp = cfg.damping,
        spring = cfg.springStrength,
        push = cfg.pushForce,
        bGrav = cfg.burnGravity;

    for (var li = 0; li < letterCount; li++) {
      var vx = lVx[li], vy = lVy[li];
      final x = lX[li], y = lY[li], cw = lCharW[li];

      for (var si = 0; si < checkSegs; si++) {
        final sc = segScale(si);
        final rad = 14 * sc * 0.45;
        final dx = x - chX[si], dy = y - chY[si];
        final dSq = dx * dx + dy * dy;
        final minD = rad + cw * 0.4 + 4;
        if (dSq < minD * minD && dSq > 0.01) {
          final d = math.sqrt(dSq);
          final f = push * ((minD - d) / minD) * sc;
          final nx = dx / d, ny = dy / d;
          vx += nx * f + (chX[si] - chPx[si]) * 0.4;
          vy += ny * f + (chY[si] - chPy[si]) * 0.4;
        }
      }

      for (var si = 5; si < chainN; si += 5) {
        final dx = x - chX[si], dy = y - chY[si];
        final dSq = dx * dx + dy * dy;
        if (dSq < 1600 && dSq > 100) {
          final wgt = (1 - math.sqrt(dSq) / 40) * 0.12;
          vx += (chX[si] - chPx[si]) * wgt;
          vy += (chY[si] - chPy[si]) * wgt;
        }
      }

      if (lBurnTimer[li] > 0) {
        lBurnTimer[li] -= dt;
        lScaleMul[li] = 1 + lBurnTimer[li] * 0.4;
        lGravity[li] = bGrav;
        if (_rng.nextDouble() < dt * 2) _spawnEmber(x, y);
        if (lBurnTimer[li] <= 0) {
          lBurnTimer[li] = 0;
          lScaleMul[li] = 1;
          lGravity[li] = 0;
        }
      }

      final hdx = lHomeX[li] - x, hdy = lHomeY[li] - y;
      final hd = math.sqrt(hdx * hdx + hdy * hdy);
      if (hd > 0.5) {
        final sf = spring * (1 + hd * 0.001);
        vx += hdx * sf;
        vy += hdy * sf;
      }

      vy += lGravity[li];
      lVx[li] = vx * damp;
      lVy[li] = vy * damp;
      lX[li] = x + lVx[li];
      lY[li] = y + lVy[li];
    }
  }

  void _spawnEmber(double x, double y) {
    if (!cfg.showEmbers || emberCount >= maxEmbers) return;
    final i = emberCount++;
    final a = _rng.nextDouble() * math.pi * 2;
    emX[i] = x;
    emY[i] = y;
    emVx[i] = math.cos(a) * (1 + _rng.nextDouble() * 3);
    emVy[i] = math.sin(a) * (1 + _rng.nextDouble() * 3) - 2;
    emLife[i] = 0.3 + _rng.nextDouble() * 0.6;
    emSize[i] = 6 + _rng.nextDouble() * 8;
    emChar[i] = _emberChars[_rng.nextInt(4)];
    emColor[i] = _emberColors[_rng.nextInt(3)];
  }

  void _fireBlastAt(double bx, double by, double dx, double dy) {
    var hits = 0;
    final rSq = cfg.fireRadius * cfg.fireRadius,
        ff = cfg.fireForce,
        fr = cfg.fireRadius;
    for (var li = 0; li < letterCount; li++) {
      final ldx = lX[li] - bx, ldy = lY[li] - by;
      final dSq = ldx * ldx + ldy * ldy;
      if (dSq < rSq && dSq > 0.01) {
        final d = math.sqrt(dSq);
        final f = ff * math.pow(1 - d / fr, 2);
        lVx[li] += (ldx / d * 0.4 + dx * 0.6) * f;
        lVy[li] += (ldy / d * 0.4 + dy * 0.6) * f - f * 0.2;
        lBurnTimer[li] =
            math.max(lBurnTimer[li], 0.5 + _rng.nextDouble() * 1.2);
        hits++;
      }
    }
    if (hits > 3) {
      _triggerShake(math.min(hits * 0.4, 6));
      for (var i = 0; i < math.min(hits, 4); i++) {
        _spawnEmber(bx, by);
      }
    }
  }

  void _emitFire(double dt) {
    if (!breathingFire) {
      _totalFireTime = 0;
      return;
    }
    _fireAccum += dt;
    _totalFireTime += dt;
    final hx = chX[0], hy = chY[0];
    final ni = math.min(3, chainN - 1);
    final fdx = hx - chX[ni], fdy = hy - chY[ni];
    final len = math.sqrt(fdx * fdx + fdy * fdy);
    final l = len == 0 ? 1 : len;
    final dx = fdx / l, dy = fdy / l, angle = math.atan2(fdy, fdx);

    if (cfg.showParticles) {
      while (_fireAccum > 0.025) {
        _fireAccum -= 0.025;
        if (particleCount >= maxParticles) break;
        for (var j = 0; j < 2; j++) {
          if (particleCount >= maxParticles) break;
          final i = particleCount++;
          final sp = _rng.nextDouble() - 0.5, spd = 5 + _rng.nextDouble() * 7;
          pX[i] = hx + dx * 15;
          pY[i] = hy + dy * 15;
          pVx[i] = math.cos(angle + sp) * spd;
          pVy[i] = math.sin(angle + sp) * spd - _rng.nextDouble();
          pLife[i] = 1;
          pMaxLife[i] = 0.3 + _rng.nextDouble() * 0.4;
          pSize[i] = 8 + _rng.nextDouble() * 14;
          pChar[i] = _fireChars[_rng.nextInt(_fireChars.length)];
        }
      }
    } else {
      _fireAccum = 0;
    }

    final bx = hx + dx * 50, by = hy + dy * 50;
    _fireBlastAt(bx, by, dx, dy);
    _hitEnemiesWithFire(bx, by);
    _triggerShake(math.min(1 + _totalFireTime * 0.2, 3));
  }

  void _updateParticlesAndEmbers(double dt) {
    for (var i = particleCount - 1; i >= 0; i--) {
      pX[i] += pVx[i];
      pY[i] += pVy[i];
      pVy[i] -= 0.25;
      pVx[i] *= 0.97;
      pLife[i] -= dt / pMaxLife[i];
      if (pLife[i] <= 0) {
        particleCount--;
        pX[i] = pX[particleCount];
        pY[i] = pY[particleCount];
        pVx[i] = pVx[particleCount];
        pVy[i] = pVy[particleCount];
        pLife[i] = pLife[particleCount];
        pMaxLife[i] = pMaxLife[particleCount];
        pSize[i] = pSize[particleCount];
        pChar[i] = pChar[particleCount];
      }
    }
    for (var i = emberCount - 1; i >= 0; i--) {
      emX[i] += emVx[i];
      emY[i] += emVy[i];
      emVy[i] += 0.15;
      emVx[i] *= 0.97;
      emLife[i] -= dt;
      if (emLife[i] <= 0) {
        emberCount--;
        emX[i] = emX[emberCount];
        emY[i] = emY[emberCount];
        emVx[i] = emVx[emberCount];
        emVy[i] = emVy[emberCount];
        emLife[i] = emLife[emberCount];
        emSize[i] = emSize[emberCount];
        emChar[i] = emChar[emberCount];
        emColor[i] = emColor[emberCount];
      }
    }
  }

  void _spawnEnemy() {
    final ki = _rng.nextInt(_enemyKinds.length);
    final k = _enemyKinds[ki];
    final edge = _rng.nextInt(4);
    double x = 0, y = 0;
    if (edge == 0) {
      x = -30;
      y = _rng.nextDouble() * h;
    } else if (edge == 1) {
      x = w + 30;
      y = _rng.nextDouble() * h;
    } else if (edge == 2) {
      x = _rng.nextDouble() * w;
      y = -30;
    } else {
      x = _rng.nextDouble() * w;
      y = h + 30;
    }
    enemies.add(
      _Enemy(
        x: x,
        y: y,
        vx: (_rng.nextDouble() - 0.5) * k.speed * 2,
        vy: (_rng.nextDouble() - 0.5) * k.speed * 2,
        hp: k.hp,
        char: k.char,
        size: k.size,
        color: k.color,
        phase: _rng.nextDouble() * math.pi * 2,
        kind: ki,
      ),
    );
  }

  void _updateEnemies(double dt) {
    if (!cfg.showEnemies) return;
    var alive = 0;
    for (final e in enemies) {
      if (!e.dying) alive++;
    }
    while (alive < cfg.enemyCount) {
      _spawnEnemy();
      alive++;
    }

    for (var i = enemies.length - 1; i >= 0; i--) {
      final e = enemies[i];
      if (e.dying) {
        e.deathTimer -= dt;
        e.x += e.vx;
        e.y += e.vy;
        e.vx *= 0.95;
        e.vy *= 0.95;
        if (e.deathTimer <= 0) {
          enemies[i] = enemies[enemies.length - 1];
          enemies.removeLast();
        }
        continue;
      }
      final spd = cfg.enemySpeed;
      if (e.kind == 3) {
        e.x += math.sin(time * 1.5 + e.phase) * spd * 1.2;
        e.y += math.cos(time * 1.2 + e.phase * 1.3) * spd * 0.8;
      } else if (e.kind == 2) {
        e.x += e.vx * spd;
        e.y += e.vy * spd;
        if (_rng.nextDouble() < dt * 0.5) {
          e.vx += (_rng.nextDouble() - 0.5) * 3;
          e.vy += (_rng.nextDouble() - 0.5) * 3;
        }
        e.vx *= 0.99;
        e.vy *= 0.99;
      } else {
        e.vx += (w / 2 - e.x) * 0.0001 + (_rng.nextDouble() - 0.5) * 0.1;
        e.vy += (h / 2 - e.y) * 0.0001 + (_rng.nextDouble() - 0.5) * 0.1;
        e.vx *= 0.995;
        e.vy *= 0.995;
        e.x += e.vx * spd;
        e.y += e.vy * spd;
      }
      if (e.x < -50) e.x = w + 40;
      if (e.x > w + 50) e.x = -40;
      if (e.y < -50) e.y = h + 40;
      if (e.y > h + 50) e.y = -40;
      final dx = e.x - chX[0], dy = e.y - chY[0], dSq = dx * dx + dy * dy;
      if (dSq < 15000) {
        final d = math.sqrt(dSq) == 0 ? 1 : math.sqrt(dSq);
        final fl = 1.5 * (1 - d / 122);
        e.vx += (dx / d) * fl;
        e.vy += (dy / d) * fl;
      }
    }
    if (scoreFlash > 0) scoreFlash -= dt * 3;
  }

  void _hitEnemiesWithFire(double fx, double fy) {
    if (!cfg.showEnemies) return;
    final hr = cfg.fireRadius * 0.6, hrSq = hr * hr;
    for (final e in enemies) {
      if (e.dying) continue;
      final dx = e.x - fx, dy = e.y - fy, dSq = dx * dx + dy * dy;
      if (dSq < hrSq) {
        final d = math.sqrt(dSq) == 0 ? 1 : math.sqrt(dSq);
        e.hp--;
        e.vx += (dx / d) * 5;
        e.vy += (dy / d) * 5;
        if (e.hp <= 0) {
          e.dying = true;
          e.deathTimer = 0.5;
          e.vx = (dx / d) * 8;
          e.vy = (dy / d) * 8 - 3;
          score += e.kind == 1
              ? 30
              : e.kind == 2
                  ? 20
                  : e.kind == 3
                      ? 25
                      : 10;
          scoreFlash = 1;
          for (var j = 0; j < 3; j++) {
            _spawnEmber(e.x, e.y);
          }
        }
      }
    }
  }

  // ── Instance emission (one 16-float glyph per _glyph call) ──────────────

  static void _writeGlyph(Float32List s, int o, double pen, double baselineY,
      double scale, GlyphTableEntry e, double r, double g, double b, double a) {
    s[o] = pen;
    s[o + 1] = baselineY;
    s[o + 2] = scale;
    s[o + 3] = 0;
    s[o + 4] = e.bbox[0];
    s[o + 5] = e.bbox[1];
    s[o + 6] = e.bbox[2];
    s[o + 7] = e.bbox[3];
    s[o + 8] = r;
    s[o + 9] = g;
    s[o + 10] = b;
    s[o + 11] = a;
    s[o + 12] = e.rowBase.toDouble();
    s[o + 13] = e.bandCount.toDouble();
    s[o + 14] = e.y0;
    s[o + 15] = e.invH;
  }

  // Lato glyph, centered at (cx, cy).
  void _glyph(String ch, double cx, double cy, double sizeEff, double r,
      double g, double b, double a) {
    final e = _atlas?[ch];
    if (e == null || _outLen + _floatsPerInstance > _scratch.length) return;
    final scale = sizeEff / _unitsPerEm;
    final pen = cx - e.advance / _unitsPerEm * sizeEff / 2;
    _writeGlyph(_scratch, _outLen, pen, cy + sizeEff * 0.34, scale, e, r, g, b, a);
    _outLen += _floatsPerInstance;
  }

  // CJK glyph, centered at (cx, cy).
  void _glyphCjk(String ch, double cx, double cy, double sizeEff, double r,
      double g, double b, double a) {
    final e = _atlasCjk?[ch];
    if (e == null || _outCjk + _floatsPerInstance > _scCjk.length) return;
    final scale = sizeEff / _uemCjk;
    final pen = cx - e.advance / _uemCjk * sizeEff / 2;
    _writeGlyph(_scCjk, _outCjk, pen, cy + sizeEff * 0.34, scale, e, r, g, b, a);
    _outCjk += _floatsPerInstance;
  }

  // COLR color emoji: one coverage instance per layer, in painting order.
  void _glyphEmoji(String ch, double cx, double cy, double sizeEff, double a) {
    final atlas = _emojiAtlas;
    final font = _fontEmoji;
    if (atlas == null || font == null) return;
    final layers = atlas.layers[ch.runes.first];
    if (layers == null) return;
    final scale = sizeEff / _uemEmoji;
    final pen = cx - font.advanceOf(ch) / _uemEmoji * sizeEff / 2;
    final baselineY = cy + sizeEff * 0.34;
    for (final layer in layers) {
      if (_outEmoji + _floatsPerInstance > _scEmoji.length) return;
      final c = layer.color;
      final la = (c != null && c.length > 3 ? c[3] : 1.0) * a;
      _writeGlyph(_scEmoji, _outEmoji, pen, baselineY, scale, layer.entry,
          c != null ? c[0] : 1, c != null ? c[1] : 1, c != null ? c[2] : 1, la);
      _outEmoji += _floatsPerInstance;
    }
  }

  void _string(String str, double cx, double cy, double size, double r,
      double g, double b, double a, {bool centered = true}) {
    final atlas = _atlas;
    if (atlas == null) return;
    final scale = size / _unitsPerEm;
    var total = 0.0;
    if (centered) {
      for (final ch in str.characters) {
        total += (atlas[ch]?.advance ?? _unitsPerEm * 0.5) * scale;
      }
    }
    var penX = centered ? cx - total / 2 : cx;
    final baselineY = cy + size * 0.34;
    for (final ch in str.characters) {
      final e = atlas[ch];
      if (e != null &&
          ch.trim().isNotEmpty &&
          _outLen + _floatsPerInstance <= _scratch.length) {
        _writeGlyph(_scratch, _outLen, penX, baselineY, scale, e, r, g, b, a);
        _outLen += _floatsPerInstance;
      }
      penX += (e?.advance ?? _unitsPerEm * 0.5) * scale;
    }
  }

  /// Build the per-frame instance buffers (one per font). Draw order is
  /// back-to-front so alpha-over blending layers correctly.
  void buildInstances() {
    _outLen = 0;
    _outCjk = 0;
    _outEmoji = 0;
    if (_atlas == null) return;
    _emitTunnel();
    _emitRunes();
    _emitLetters();
    _emitEnemies();
    _emitDragon();
    _emitParticles();
    if (score > 0) {
      final a = (0.3 + scoreFlash * 0.4).clamp(0.0, 1.0);
      final c = scoreFlash > 0
          ? const [1.0, 0.67, 0.2]
          : const [0.4, 0.4, 0.4];
      _string('SCORE $score', 20, 24, 14, c[0], c[1], c[2], a, centered: false);
    }
  }

  void _emitTunnel() {
    final cx = w * 0.5, cy = h * 0.5;
    for (var i = 0; i < tunnelRings; i++) {
      tunnelZ[i] -= 0.67;
      if (tunnelZ[i] < 10) {
        tunnelZ[i] += tunnelDepth;
        tunnelSide[i] = (tunnelSide[i] + 1) % 4;
        tunnelTextIdx[i] = _rng.nextInt(_tunnelTexts.length);
      }
      final scale = 400 / (400 + tunnelZ[i]);
      final alpha = (0.14 * scale - 0.02).clamp(0.0, 0.11);
      if (alpha < 0.004) continue;
      final spread = 350 * scale;
      double x, y;
      final s = tunnelSide[i];
      if (s == 0) {
        x = cx;
        y = cy - spread;
      } else if (s == 1) {
        x = cx + spread;
        y = cy;
      } else if (s == 2) {
        x = cx;
        y = cy + spread;
      } else {
        x = cx - spread;
        y = cy;
      }
      _string(_tunnelTexts[tunnelTextIdx[i]], x, y, 13, 1, 0.53, 0.27, alpha);
    }
  }

  void _emitRunes() {
    if (!cfg.showRunes) return;
    for (var i = 0; i < runeN; i++) {
      runeY[i] -= runeSpd[i];
      if (runeY[i] < -30) {
        runeY[i] = h + 30;
        runeX[i] = _rng.nextDouble() * w;
      }
      final op = (runeOp[i] * (0.5 + math.sin(time * 0.4 + runePhase[i]) * 0.5))
          .clamp(0.0, 1.0);
      _glyph(runeC[i], runeX[i] + math.sin(time * 0.7 + runePhase[i]) * 12,
          runeY[i], runeSz[i], 1, 0.4, 0, op);
    }
  }

  void _emitLetters() {
    final opMul = cfg.textOpacity;
    for (var i = 0; i < letterCount; i++) {
      final burning = lBurnTimer[i] > 0;
      var alpha = lBaseAlpha[i] * opMul;
      double r, g, b;
      if (burning) {
        final hh = math.min(1.0, lBurnTimer[i]);
        r = 1;
        g = (80 + hh * 175) / 255;
        b = (hh * 60) / 255;
        alpha = math.min(1.0, alpha + 0.5);
      } else {
        final rgb = lColor[i];
        r = ((rgb >> 16) & 0xff) / 255;
        g = ((rgb >> 8) & 0xff) / 255;
        b = (rgb & 0xff) / 255;
      }
      final size = lFontSize[i] * lScaleMul[i];
      final a = alpha.clamp(0.0, 1.0);
      switch (lFont[i]) {
        case 1:
          _glyphCjk(lChar[i], lX[i], lY[i], size, r, g, b, a);
        case 2:
          // Emoji keep their own COLR palette; only the alpha follows the
          // physics (fade on burn/opacity), not the fire recolor.
          _glyphEmoji(lChar[i], lX[i], lY[i], size, a);
        default:
          _glyph(lChar[i], lX[i], lY[i], size, r, g, b, a);
      }
    }
  }

  void _emitParticles() {
    if (cfg.showEmbers) {
      for (var i = 0; i < emberCount; i++) {
        final alpha = math.min(1.0, emLife[i] * 2);
        final c = emColor[i];
        _glyph(emChar[i], emX[i], emY[i], emSize[i], ((c >> 16) & 0xff) / 255,
            ((c >> 8) & 0xff) / 255, (c & 0xff) / 255, alpha);
      }
    }
    if (cfg.showParticles) {
      for (var i = 0; i < particleCount; i++) {
        final t = 1 - pLife[i];
        double r, g, b;
        if (t < 0.15) {
          r = 1;
          g = 1;
          b = (1 - t * 6.67).clamp(0.0, 1.0);
        } else if (t < 0.4) {
          r = 1;
          g = (1 - (t - 0.15) * 3.2).clamp(0.0, 1.0);
          b = 0;
        } else {
          final f = (t - 0.4) * 1.67;
          r = (1 - f * 0.6).clamp(0.0, 1.0);
          g = (0.31 * (1 - f)).clamp(0.0, 1.0);
          b = 0;
        }
        final sz = pSize[i] * (0.4 + pLife[i] * 0.6);
        _glyph(pChar[i], pX[i], pY[i], sz, r, g, b,
            (pLife[i] * 0.85).clamp(0.0, 1.0));
      }
    }
  }

  void _emitEnemies() {
    if (!cfg.showEnemies) return;
    for (final e in enemies) {
      if (e.dying) {
        final t = (e.deathTimer / 0.5).clamp(0.0, 1.0);
        _glyph(e.char, e.x, e.y, e.size * t, 1, 0.67, 0, t * 0.8);
      } else {
        final bob = math.sin(time * 2.5 + e.phase) * 4;
        final alpha = e.kind == 3
            ? (0.4 + math.sin(time * 3 + e.phase) * 0.2).clamp(0.0, 1.0)
            : 0.75;
        final c = e.color;
        _glyph(e.char, e.x, e.y + bob, e.size, ((c >> 16) & 0xff) / 255,
            ((c >> 8) & 0xff) / 255, (c & 0xff) / 255, alpha);
      }
    }
  }

  void _emitDragon() {
    for (var i = chainN - 1; i >= 0; i--) {
      final sc = segScale(i);
      final ci = math.min(i, _dragonChars.length - 1);
      final size = 14 * sc;
      final t = i / chainN, p = math.sin(time * 3 + i * 0.3) * 0.12;
      double r, g, b, a;
      if (i < 3) {
        r = 1;
        g = ((180 + p * 60) / 255).clamp(0.0, 1.0);
        b = ((40 + p * 30) / 255).clamp(0.0, 1.0);
        a = 1;
      } else {
        final wv = math.sin(time * 2 - i * 0.15) * 0.15;
        r = ((255 * (1 - t * 0.5) + p * 20) / 255).clamp(0.0, 1.0);
        g = ((140 * (1 - t * 0.8) + wv * 60) / 255).clamp(0.0, 1.0);
        b = ((30 * (1 - t) + wv * 20) / 255).clamp(0.0, 1.0);
        a = (1 - t * 0.45).clamp(0.0, 1.0);
      }
      final angle = i == 0
          ? math.atan2(mouseY - chY[0], mouseX - chX[0])
          : math.atan2(chY[i - 1] - chY[i], chX[i - 1] - chX[i]);

      if (cfg.showSpines && i >= 4 && i <= 30 && i % 3 == 0) {
        final sa = angle + math.pi / 2;
        _glyph('^', chX[i] + math.cos(sa) * size * 0.35,
            chY[i] + math.sin(sa) * size * 0.35,
            size * (0.6 + math.sin(time * 3 + i) * 0.15), r, g, b, a * 0.7);
      }

      if (cfg.showWings && i >= 7 && i <= 16 && i % 2 == 0) {
        final wp = math.sin(time * 3.5 + i * 0.4) * 0.5;
        final ws = size * (1.8 - (i - 11.5).abs() * 0.12), wd = size * 1.4;
        final w1 = angle + math.pi / 2 + wp, w2 = angle - math.pi / 2 - wp;
        _glyph('<', chX[i] + math.cos(w1) * wd, chY[i] + math.sin(w1) * wd, ws,
            r, g, b, a * 0.8);
        _glyph('>', chX[i] + math.cos(w2) * wd, chY[i] + math.sin(w2) * wd, ws,
            r, g, b, a * 0.8);
      }

      final yb = math.sin(time * 5 + i * 0.35) * 1.5;
      _glyph(_dragonChars[ci], chX[i], chY[i] + yb, size, r, g, b, a);
    }

    // Eyes (a glyph; the glow behind them is a Canvas overlay).
    final ha = math.atan2(mouseY - chY[0], mouseX - chX[0]);
    final ex = chX[0] + math.cos(ha + 0.5) * 10,
        ey = chY[0] + math.sin(ha + 0.5) * 10;
    final eye = time % 5 > 4.7 ? '-' : (breathingFire ? '@' : 'O');
    _glyph(eye, ex, ey, 16, breathingFire ? 1 : 1, breathingFire ? 1 : 0.8,
        breathingFire ? 1 : 0, 1);
  }
}

class _EnemyKind {
  const _EnemyKind(this.char, this.color, this.hp, this.size, this.speed);
  final String char;
  final int color;
  final int hp;
  final double size;
  final double speed;
}

class _Enemy {
  _Enemy({
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
    required this.hp,
    required this.char,
    required this.size,
    required this.color,
    required this.phase,
    required this.kind,
  });
  double x, y, vx, vy;
  int hp;
  final String char;
  final double size;
  final int color;
  final double phase;
  bool dying = false;
  double deathTimer = 0;
  final int kind;
}

// ─── GPU renderer: instance buffer -> offscreen surface -> ui.Image ─────

/// One font's slice of a frame: its atlas textures + instance buffer + count.
typedef _SubDraw = ({AtlasTextures tex, Float32List buf, int count});

class _GpuScene {
  _GpuScene(this._pipeline);

  final GPUTextPipeline _pipeline;

  gpu.GpuImageSurface? _surface;
  ui.Image? image;

  // Superseded surface+image generations, disposed once a frame at least that
  // new has finished rasterizing (mirrors the widget renderer).
  final List<(gpu.GpuImageSurface?, ui.Image, int)> _retired = [];
  bool _timingsHooked = false;

  /// Draw each font's instances into one offscreen surface (one render pass,
  /// one renderInstances call per font with its own atlas textures), then
  /// publish the composited image.
  void render(List<_SubDraw> draws, int devW, int devH, double dpr) {
    var total = 0;
    for (final d in draws) {
      total += d.count;
    }
    if (total == 0) return;
    var surface = _surface;
    if (surface == null || surface.width != devW || surface.height != devH) {
      surface = gpu.gpuContext.createImageSurface(
        devW.clamp(1, 100000),
        devH.clamp(1, 100000),
        format: _surfaceFormat(gpu.gpuContext),
      );
    }
    final frame = surface.acquireNextFrame();
    final cmd = gpu.gpuContext.createCommandBuffer();
    final target = gpu.RenderTarget.singleColor(
      gpu.ColorAttachment(
        texture: frame.colorTexture,
        loadAction: gpu.LoadAction.clear,
        storeAction: gpu.StoreAction.store,
        clearValue: vm.Vector4(10 / 255, 10 / 255, 10 / 255, 1),
      ),
    );
    final pass = cmd.createRenderPass(target);
    final frameUniforms = FrameUniforms(
      width: devW.toDouble(),
      height: devH.toDouble(),
      cam: [dpr, dpr, 0, 0],
    );
    for (final d in draws) {
      if (d.count == 0) continue;
      _pipeline.renderInstances(
        pass: pass,
        frame: frameUniforms,
        instances: _pipeline.uploadInstances(d.buf),
        instanceCount: d.count,
        textures: d.tex,
      );
    }
    frame.present(cmd);
    cmd.submit();

    final prev = image;
    if (prev != null) {
      _retired.add((
        identical(_surface, surface) ? null : _surface,
        prev,
        ui.PlatformDispatcher.instance.frameData.frameNumber,
      ));
      if (!_timingsHooked) {
        _timingsHooked = true;
        SchedulerBinding.instance.addTimingsCallback(_flushRetired);
      }
    }
    _surface = surface;
    image = surface.currentImage;
  }

  void _flushRetired(List<ui.FrameTiming> timings) {
    var latest = -1;
    for (final t in timings) {
      if (t.frameNumber > latest) latest = t.frameNumber;
    }
    while (_retired.isNotEmpty && _retired.first.$3 <= latest) {
      _retired.removeAt(0).$2.dispose();
    }
    if (_retired.isEmpty && _timingsHooked) {
      _timingsHooked = false;
      SchedulerBinding.instance.removeTimingsCallback(_flushRetired);
    }
  }

  void dispose() {
    if (_timingsHooked) {
      _timingsHooked = false;
      SchedulerBinding.instance.removeTimingsCallback(_flushRetired);
    }
    for (final (_, img, _) in _retired) {
      img.dispose();
    }
    _retired.clear();
    image?.dispose();
    image = null;
    _surface = null;
  }
}

// ─── Page ───────────────────────────────────────────────────────────────

class DragonDemoPage extends StatefulWidget {
  const DragonDemoPage({super.key});

  @override
  State<DragonDemoPage> createState() => _DragonDemoPageState();
}

class _DragonDemoPageState extends State<DragonDemoPage>
    with SingleTickerProviderStateMixin {
  late final _Game _game;
  late final Ticker _ticker;
  final DragonConfig _cfg = DragonConfig();

  _GpuScene? _scene;
  AtlasTextures? _texLato;
  AtlasTextures? _texCjk;
  AtlasTextures? _texEmoji;
  String? _error;

  double _prevTs = 0;
  double _fps = 0;
  double _fpsAccum = 0;
  int _fpsFrames = 0;
  bool _panelOpen = false;
  String _activePreset = 'Default';
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _game = _Game(_cfg);
    _bootstrapGpu();
    _ticker = createTicker(_onTick)..start();
  }

  Future<void> _bootstrapGpu() async {
    final corpus = _textEntries.map((e) => e.text).join(' ');
    try {
      // ── Lato: Latin corpus + the ASCII dragon/particle/enemy/rune glyphs ──
      final latoBytes = await rootBundle.load('assets/Lato-Regular.ttf');
      final lato = GPUFont.parse(latoBytes.buffer.asUint8List());
      final charset = StringBuffer();
      for (var c = 0x20; c <= 0x7E; c++) {
        charset.writeCharCode(c);
      }
      charset.write(corpus); // CJK/emoji in here are simply skipped by Lato
      charset.write(_Game._dragonChars);
      charset.write(_Game._fireChars.join());
      charset.write(_Game._emberChars.join());
      charset.write(_Game._runeChars.join());
      for (final t in _Game._tunnelTexts) {
        charset.write(t);
      }
      final latoAtlas = buildGlyphAtlas(lato, charset.toString());
      if (!mounted) return;
      // Layout (inner pretext) only needs the font + band table — enable it
      // even if the GPU pipeline can't come up (e.g. headless test).
      setState(() => _game.setLato(lato, latoAtlas.table));

      // ── Noto Sans SC subset: the CJK glyphs, banded as ordinary outlines ──
      GlyphAtlas? cjkAtlas;
      try {
        final b = await rootBundle.load('assets/NotoSansSC-subset.ttf');
        final cjk = GPUFont.parse(b.buffer.asUint8List());
        cjkAtlas = buildGlyphAtlas(cjk, corpus);
        if (cjkAtlas.table.isNotEmpty) {
          _game.setCjk(cjk, cjkAtlas.table);
        } else {
          cjkAtlas = null;
        }
      } catch (_) {/* CJK optional */}

      // ── Twemoji: COLR v0 color emoji, each an N-layer coverage stack ──────
      ColrEmojiAtlas? emojiAtlas;
      try {
        final b = await rootBundle.load('assets/TwemojiMozilla.ttf');
        final emoji = GPUFont.parse(b.buffer.asUint8List());
        emojiAtlas = buildColrEmojiAtlas(emoji, corpus.runes);
        if (emojiAtlas.layers.isNotEmpty) {
          _game.setEmoji(emoji, emojiAtlas);
        } else {
          emojiAtlas = null;
        }
      } catch (_) {/* emoji optional */}

      // ── GPU pipeline + one atlas texture set per font ─────────────────────
      final pipeline = await GPUTextPipeline.create();
      final ctx = gpu.gpuContext;
      _texLato = uploadAtlasTextures(ctx, latoAtlas.curves, latoAtlas.rows);
      if (cjkAtlas != null) {
        _texCjk = uploadAtlasTextures(ctx, cjkAtlas.curves, cjkAtlas.rows);
      }
      if (emojiAtlas != null) {
        _texEmoji = uploadAtlasTextures(ctx, emojiAtlas.curves, emojiAtlas.rows);
      }
      if (!mounted) return;
      setState(() => _scene = _GpuScene(pipeline));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _focus.dispose();
    _scene?.dispose();
    _game.repaint.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    final now = elapsed.inMicroseconds / 1e6;
    var dt = _prevTs == 0 ? 1 / 60 : now - _prevTs;
    _prevTs = now;
    if (dt > 0.05) dt = 0.05;

    _fpsAccum += dt;
    _fpsFrames++;
    if (_fpsAccum >= 0.5) {
      _fps = _fpsFrames / _fpsAccum;
      _fpsAccum = 0;
      _fpsFrames = 0;
    }

    _game.update(dt);
    final scene = _scene;
    final texLato = _texLato;
    if (scene != null && texLato != null && _game.ready && _game.w > 0) {
      _game.buildInstances();
      // Back-to-front: emoji + CJK (background text), then Lato (which carries
      // its own letters and the dragon on top).
      final draws = <_SubDraw>[];
      final texEmoji = _texEmoji;
      if (texEmoji != null && _game.countEmoji > 0) {
        draws.add((
          tex: texEmoji,
          buf: _game.instancesEmoji,
          count: _game.countEmoji,
        ));
      }
      final texCjk = _texCjk;
      if (texCjk != null && _game.countCjk > 0) {
        draws.add((tex: texCjk, buf: _game.instancesCjk, count: _game.countCjk));
      }
      draws.add((tex: texLato, buf: _game.instancesLato, count: _game.countLato));
      final devW = (_game.w * _game.dpr).round();
      final devH = (_game.h * _game.dpr).round();
      try {
        scene.render(draws, devW, devH, _game.dpr);
      } catch (e) {
        _error ??= '$e';
      }
    }
    _game.repaint.value++;
  }

  void _applyPreset(String name) {
    _cfg.copyFrom(DragonConfig());
    _presets[name]!(_cfg);
    _game.rebuildDragon();
    setState(() => _activePreset = name);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.keyP) {
      setState(() => _panelOpen = !_panelOpen);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape && _panelOpen) {
      setState(() => _panelOpen = false);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    _game.dpr = MediaQuery.devicePixelRatioOf(context);
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Listener(
          onPointerHover: (e) {
            _game.mouseX = e.localPosition.dx;
            _game.mouseY = e.localPosition.dy;
          },
          onPointerMove: (e) {
            _game.mouseX = e.localPosition.dx;
            _game.mouseY = e.localPosition.dy;
          },
          onPointerDown: (e) {
            _focus.requestFocus();
            _game.mouseX = e.localPosition.dx;
            _game.mouseY = e.localPosition.dy;
            _game.breathingFire = true;
          },
          onPointerUp: (e) => _game.breathingFire = false,
          onPointerCancel: (e) => _game.breathingFire = false,
          child: Stack(
            children: [
              Positioned.fill(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final w = constraints.maxWidth, h = constraints.maxHeight;
                    if (w != _game.w || h != _game.h) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) _game.resize(w, h);
                      });
                    }
                    return MouseRegion(
                      cursor: _game.cfg.showCursor
                          ? SystemMouseCursors.none
                          : MouseCursor.defer,
                      child: RepaintBoundary(
                        child: CustomPaint(
                          painter: _BlitPainter(_game, _scene),
                          size: Size.infinite,
                        ),
                      ),
                    );
                  },
                ),
              ),
              if (_error != null)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'GPU renderer unavailable:\n$_error',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Color(0x99FF6666), fontSize: 12),
                    ),
                  ),
                ),
              _buildHud(),
              _buildToggle(),
              if (_panelOpen) _buildPanel(),
              Positioned(
                top: 12,
                left: 16,
                child: IgnorePointer(
                  child: Text(
                    'gputext · GPU coverage shader + inner pretext prebuilt',
                    style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 0.5,
                      color: Colors.white.withValues(alpha: 0.35),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const Positioned(
                bottom: 12,
                left: 16,
                child: IgnorePointer(
                  child: Text(
                    'Move to steer · hold to breathe fire · P for panel',
                    style: TextStyle(fontSize: 11, color: Color(0x66FFFFFF)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHud() {
    return Positioned(
      right: 16,
      bottom: 12,
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: _game.repaint,
          builder: (context, _) {
            final layout = _game.relayoutUs;
            final oneShot = _game.oneShotUs;
            final speedup = layout > 0 ? oneShot / layout : 0;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${_fps.round()} fps · ${_game.letterCount} letters · '
                  '${_game.particleCount + _game.emberCount} particles',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                    color: Color(0x66888888),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'pretext: prepare ${_game.prepareUs.toStringAsFixed(0)}µs · '
                  'relayout ${layout.toStringAsFixed(0)}µs '
                  '(${speedup.toStringAsFixed(1)}× vs one-shot)',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                    color: Color(0x66FF8844),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildToggle() {
    if (_panelOpen) return const SizedBox.shrink();
    return Positioned(
      top: 44,
      right: 16,
      child: Material(
        color: const Color(0xD9141414),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _panelOpen = true),
          child: const SizedBox(
            width: 36,
            height: 36,
            child: Icon(Icons.tune, size: 18, color: Color(0xFF888888)),
          ),
        ),
      ),
    );
  }

  Widget _buildPanel() {
    return Positioned(
      top: 44,
      right: 16,
      bottom: 16,
      child: Container(
        width: 300,
        decoration: BoxDecoration(
          color: const Color(0xEB0E0E0E),
          border: Border.all(color: const Color(0xFF262626)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  const Text(
                    'DRAGON CONTROLS',
                    style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 0.8,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFFFF8844),
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    color: const Color(0xFF888888),
                    onPressed: () => setState(() => _panelOpen = false),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final name in _presets.keys) _presetChip(name),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _slider('Segments', _cfg.dragonSegments.toDouble(), 10, 80,
                        (v) {
                      _cfg.dragonSegments = v.round();
                      _game.rebuildDragon();
                    }, step: 1),
                    _slider('Dragon speed', _cfg.dragonSpeed, 0.03, 0.4,
                        (v) => _cfg.dragonSpeed = v),
                    _slider('Dragon scale', _cfg.dragonScale, 0.4, 2.5,
                        (v) => _cfg.dragonScale = v),
                    _slider('Push force', _cfg.pushForce, 0, 30,
                        (v) => _cfg.pushForce = v),
                    _slider('Spring', _cfg.springStrength, 0.002, 0.05,
                        (v) => _cfg.springStrength = v),
                    _slider('Damping', _cfg.damping, 0.85, 0.99,
                        (v) => _cfg.damping = v),
                    _slider('Burn gravity', _cfg.burnGravity, 0, 3,
                        (v) => _cfg.burnGravity = v),
                    _slider('Fire radius', _cfg.fireRadius, 40, 220,
                        (v) => _cfg.fireRadius = v),
                    _slider('Fire force', _cfg.fireForce, 5, 50,
                        (v) => _cfg.fireForce = v),
                    _slider('Enemies', _cfg.enemyCount.toDouble(), 0, 20,
                        (v) => _cfg.enemyCount = v.round(), step: 1),
                    _slider('Enemy speed', _cfg.enemySpeed, 0.1, 2,
                        (v) => _cfg.enemySpeed = v),
                    _slider('Text opacity', _cfg.textOpacity, 0, 1,
                        (v) => _cfg.textOpacity = v),
                    const Divider(color: Color(0xFF262626), height: 20),
                    _switch('Wings', _cfg.showWings,
                        (v) => _cfg.showWings = v),
                    _switch('Spines', _cfg.showSpines,
                        (v) => _cfg.showSpines = v),
                    _switch('Enemies', _cfg.showEnemies,
                        (v) => _cfg.showEnemies = v),
                    _switch('Screen shake', _cfg.screenShake,
                        (v) => _cfg.screenShake = v),
                    _switch('Embers', _cfg.showEmbers,
                        (v) => _cfg.showEmbers = v),
                    _switch('Particles', _cfg.showParticles,
                        (v) => _cfg.showParticles = v),
                    _switch('Runes', _cfg.showRunes,
                        (v) => _cfg.showRunes = v),
                    _switch('Cursor', _cfg.showCursor,
                        (v) => _cfg.showCursor = v),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _presetChip(String name) {
    final active = name == _activePreset;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => _applyPreset(name),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: active ? const Color(0x33FF6600) : const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: active ? const Color(0xFFFF8844) : const Color(0xFF333333),
          ),
        ),
        child: Text(
          name,
          style: TextStyle(
            fontSize: 12,
            color: active ? const Color(0xFFFF8844) : const Color(0xFFAAAAAA),
          ),
        ),
      ),
    );
  }

  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged, {
    double? step,
  }) {
    final digits = step == 1 ? 0 : (max - min < 0.2 ? 3 : 2);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label,
                style: const TextStyle(fontSize: 11, color: Color(0xFFAAAAAA))),
            const Spacer(),
            Text(value.toStringAsFixed(digits),
                style: const TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: Color(0xFF777777))),
          ],
        ),
        SliderTheme(
          data: SliderThemeData(
            trackHeight: 2,
            overlayShape: SliderComponentShape.noOverlay,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            activeTrackColor: const Color(0xFFFF8844),
            inactiveTrackColor: const Color(0xFF333333),
            thumbColor: const Color(0xFFFF8844),
          ),
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: step == 1 ? (max - min).round() : null,
            onChanged: (v) {
              onChanged(v);
              setState(() => _activePreset = '');
            },
          ),
        ),
      ],
    );
  }

  Widget _switch(String label, bool value, ValueChanged<bool> onChanged) {
    return Row(
      children: [
        Expanded(
          child: Text(label,
              style: const TextStyle(fontSize: 12, color: Color(0xFFAAAAAA))),
        ),
        Switch(
          value: value,
          activeThumbColor: const Color(0xFFFF8844),
          onChanged: (v) => setState(() => onChanged(v)),
        ),
      ],
    );
  }
}

/// Blits the GPU-rendered glyph image, then draws the few non-glyph flourishes
/// (head glow, cursor crosshair) as a thin Canvas overlay on top.
class _BlitPainter extends CustomPainter {
  _BlitPainter(this.g, this.scene) : super(repaint: g.repaint);

  final _Game g;
  final _GpuScene? scene;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(g.shakeX, g.shakeY);

    final img = scene?.image;
    if (img != null) {
      canvas.drawImageRect(
        img,
        Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        Rect.fromLTWH(0, 0, size.width, size.height),
        Paint()..filterQuality = FilterQuality.low,
      );
    } else {
      canvas.drawRect(
          Offset.zero & size, Paint()..color = const Color(0xFF0A0A0A));
    }

    if (g.chainN > 0) {
      final glow = Paint();
      for (var i = 0; i < 4 && i < g.chainN; i++) {
        final size2 = 14 * g.segScale(i);
        glow.color = Color.fromRGBO(255, 102, 0, 0.06 * (g.breathingFire ? 2 : 1));
        canvas.drawCircle(Offset(g.chX[i], g.chY[i]), size2 * 1.1, glow);
      }
      final ha = math.atan2(g.mouseY - g.chY[0], g.mouseX - g.chX[0]);
      final ex = g.chX[0] + math.cos(ha + 0.5) * 10,
          ey = g.chY[0] + math.sin(ha + 0.5) * 10;
      glow.color = Color.fromRGBO(255, 136, 0, g.breathingFire ? 0.2 : 0.1);
      canvas.drawCircle(Offset(ex, ey), g.breathingFire ? 18 : 12, glow);
    }

    _drawCursor(canvas);
    canvas.restore();
  }

  void _drawCursor(Canvas canvas) {
    if (!g.cfg.showCursor) return;
    final mx = g.mouseX, my = g.mouseY;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Color.fromRGBO(255, 136, 68, 0.25);
    canvas.save();
    canvas.translate(mx, my);
    canvas.rotate(g.time * 0.4);
    canvas.drawArc(Rect.fromCircle(center: Offset.zero, radius: 16), 0,
        math.pi * 0.5, false, stroke);
    canvas.drawArc(Rect.fromCircle(center: Offset.zero, radius: 16), math.pi,
        math.pi * 0.5, false, stroke);
    canvas.restore();

    canvas.drawCircle(
      Offset(mx, my),
      g.breathingFire ? 3 : 2,
      Paint()
        ..color = Color.fromRGBO(255, g.breathingFire ? 170 : 136,
            g.breathingFire ? 51 : 68, g.breathingFire ? 0.8 : 0.5),
    );

    final tick = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5
      ..color = Color.fromRGBO(255, 136, 68, 0.15);
    canvas.drawLine(Offset(mx - 24, my), Offset(mx - 8, my), tick);
    canvas.drawLine(Offset(mx + 8, my), Offset(mx + 24, my), tick);
    canvas.drawLine(Offset(mx, my - 24), Offset(mx, my - 8), tick);
    canvas.drawLine(Offset(mx, my + 8), Offset(mx, my + 24), tick);
  }

  @override
  bool shouldRepaint(covariant _BlitPainter oldDelegate) => false;
}

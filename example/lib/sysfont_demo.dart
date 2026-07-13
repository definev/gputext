// Native system-font demo: resolves OS-installed fonts by family name through
// gputext's platform resolver (CoreText on macOS/iOS, the NDK font matcher on
// Android) and renders them on the GPU — no bundled TTFs. Each row shows the
// gputext render next to Flutter's native Text for comparison.
//
// The platform default UI font (San Francisco / Roboto) is loaded via
// loadDefaultSystemFont in Regular / Bold / Italic to show weight & style
// resolution; a few named families are loaded via loadSystemFont. Families that
// don't resolve (unsupported platform, CFF-only face, absent name) are listed as
// skipped rather than rendered.
//
// Launch:  GPUTEXT_DEMO=sysfont fvm flutter run \
//            --enable-impeller --enable-flutter-gpu -d macos

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:gputext/gputext.dart';

const _ink = Color(0xFF12151F);
const _paper = Color(0xFFF3F0E9);
const _accent = Color(0xFF14508C);
const _muted = Color(0xFF6B6458);
const _card = Color(0xFFFBF8F1);

const _pangram =
    'The quick brown fox jumps over the lazy dog — 0123456789 🐧🇻🇳🎨🦄🐔';

// Named OS families to attempt. These are macOS/iOS names; on Android the
// matcher maps generic names ("serif", "monospace") and falls back otherwise —
// unresolved entries simply show up under "skipped".
const _namedFamilies = <(String family, String osName)>[
  ('SysGeorgia', 'Georgia'),
  ('SysMenlo', 'Menlo'),
  ('SysAvenir', 'Avenir Next'),
  ('SysTimes', 'Times New Roman'),
];

class _Resolved {
  const _Resolved(this.family, this.label, {this.weight, this.italic = false});
  final String family;
  final String label;
  final ui.FontWeight? weight;
  final bool italic;
}

class SysFontDemoPage extends StatefulWidget {
  const SysFontDemoPage({super.key});

  @override
  State<SysFontDemoPage> createState() => _SysFontDemoPageState();
}

class _SysFontDemoPageState extends State<SysFontDemoPage> {
  bool _ready = false;
  final _resolved = <_Resolved>[];
  final _skipped = <String>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final engine = GPUText.instance;
    await engine.ensureInitialized();

    // Platform default UI font in three styles under one family.
    final reg = await engine.loadDefaultSystemFont(family: 'SysDefault');
    if (reg != null) {
      _resolved.add(const _Resolved('SysDefault', 'Default UI — Regular'));
    } else {
      _skipped.add('Default UI font');
    }
    if (await engine.loadDefaultSystemFont(
          family: 'SysDefault',
          weight: ui.FontWeight.w700,
        ) !=
        null) {
      _resolved.add(
        const _Resolved(
          'SysDefault',
          'Default UI — Bold',
          weight: ui.FontWeight.w700,
        ),
      );
    }
    if (await engine.loadDefaultSystemFont(
          family: 'SysDefault',
          style: ui.FontStyle.italic,
        ) !=
        null) {
      _resolved.add(
        const _Resolved('SysDefault', 'Default UI — Italic', italic: true),
      );
    }

    // Named installed families.
    for (final (family, osName) in _namedFamilies) {
      final font = await engine.loadSystemFont(family, systemName: osName);
      if (font != null) {
        _resolved.add(_Resolved(family, osName));
      } else {
        _skipped.add(osName);
      }
    }

    if (mounted) setState(() => _ready = true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _paper,
      appBar: AppBar(
        title: const Text('Native system fonts'),
        backgroundColor: _paper,
        foregroundColor: _ink,
      ),
      body: !_ready
          ? const Center(
              child: Text(
                'Resolving system fonts…',
                style: TextStyle(
                  fontFamily: 'Lato',
                  fontSize: 14,
                  color: _muted,
                ),
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 48),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _StatusBanner(skipped: _skipped),
                  for (final r in _resolved) _FontRow(spec: r),
                  const SizedBox(height: 8),
                  const Text(
                    'GPU rows resolve the OS font by family name and render it '
                    "through gputext; REF is Flutter's native Text in the same "
                    'family. No TTFs are bundled for these.',
                    style: TextStyle(
                      fontFamily: 'Lato',
                      fontSize: 12,
                      color: _muted,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.skipped});
  final List<String> skipped;

  @override
  Widget build(BuildContext context) {
    final available = GPUText.systemFontsAvailable;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _ink.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                available ? Icons.check_circle : Icons.cancel,
                size: 16,
                color: available ? _accent : Colors.red,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  available
                      ? 'System-font backend available on this platform'
                      : 'No system-font backend on this platform',
                  style: const TextStyle(
                    fontFamily: 'Lato',
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: _ink,
                  ),
                ),
              ),
            ],
          ),
          if (skipped.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'Skipped (unresolved / CFF / absent): ${skipped.join(', ')}',
              style: const TextStyle(
                fontFamily: 'Lato',
                fontSize: 12,
                color: _muted,
                height: 1.3,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _FontRow extends StatelessWidget {
  const _FontRow({required this.spec});
  final _Resolved spec;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontFamily: spec.family,
      fontSize: 18,
      color: _ink,
      fontWeight: spec.weight,
      fontStyle: spec.italic ? ui.FontStyle.italic : ui.FontStyle.normal,
    );
    final span = TextSpan(text: _pangram, style: style);
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _ink.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            spec.label,
            style: const TextStyle(
              fontFamily: 'Lato',
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: _accent,
            ),
          ),
          const SizedBox(height: 8),
          _labeled('GPU', _accent, GPURichText(text: span, softWrap: true)),
          const SizedBox(height: 6),
          _labeled('REF', _muted, Text.rich(span)),
        ],
      ),
    );
  }

  Widget _labeled(String tag, Color c, Widget child) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        width: 34,
        margin: const EdgeInsets.only(top: 4),
        padding: const EdgeInsets.symmetric(vertical: 2),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          tag,
          style: TextStyle(
            color: c,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
          ),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(child: child),
    ],
  );
}

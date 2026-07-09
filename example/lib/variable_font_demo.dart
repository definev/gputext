// Interactive playground for OpenType variable-font axes rendered through
// GPURichText. Google Sans Flex exposes opsz, wdth, wght, GRAD, ROND,
// and slnt; sliders drive TextStyle.fontVariations and the span flattener
// maps them onto GPUFont.variant() instances.
//
// Dev hook (demo only): GPUTEXT_DEMO=vars opens this page directly.

import 'package:flutter/material.dart';

import 'package:gputext/gputext.dart';

const _fontFamily = 'Google Sans Flex';
const _fontAsset =
    'assets/Google_Sans_Flex/GoogleSansFlex-VariableFont_GRAD,ROND,opsz,slnt,wdth,wght.ttf';

const _ink = Color(0xFF0C0F1C);
const _accent = Color(0xFF14508C);
const _paper = Color(0xFFE9E3D5);
const _surface = Color(0xFFF4F0E8);

const _headlineSize = 42.0;
const _bodySize = 17.0;
const _specimenSize = 28.0;

const _headline = 'Variable fonts, rendered by gputext';
const _body =
    'Drag the axis sliders to morph weight, width, slant, optical size, '
    'grade, and roundness in real time. Every glyph is rasterized by the '
    'coverage shader from interpolated outlines — the same tables HarfBuzz '
    'would use for advances, with gvar deltas for contours.';
const _specimen = 'Hamburgefontsiv 0123456789';

class _Preset {
  const _Preset(this.label, this.coords);

  final String label;
  final Map<String, double> coords;
}

const _presets = <_Preset>[
  _Preset('Regular', {'wght': 400, 'wdth': 100}),
  _Preset('Bold', {'wght': 700}),
  _Preset('Black', {'wght': 1000}),
  _Preset('Condensed', {'wdth': 50}),
  _Preset('Expanded', {'wdth': 130}),
  _Preset('Slanted', {'slnt': -10}),
  _Preset('Rounded', {'ROND': 100}),
  _Preset('Grade +', {'GRAD': 100}),
  _Preset('Display opsz', {'opsz': 72}),
  _Preset('Text opsz', {'opsz': 12}),
];

class VariableFontDemoPage extends StatefulWidget {
  const VariableFontDemoPage({super.key});

  @override
  State<VariableFontDemoPage> createState() => _VariableFontDemoPageState();
}

class _VariableFontDemoPageState extends State<VariableFontDemoPage> {
  var _loading = true;
  String? _error;
  List<FontAxis> _axes = const [];
  final _values = <String, double>{};
  double _fontSize = _bodySize;
  bool _compareFlutter = true;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      await GPUText.instance.loadFontAsset(_fontFamily, _fontAsset);
      final font = GPUText.instance.resolveFont(_fontFamily);
      if (font == null) {
        throw StateError('$_fontFamily failed to register');
      }
      if (!mounted) return;
      setState(() {
        _axes = font.variationAxes;
        _values
          ..clear()
          ..addEntries(_axes.map((a) => MapEntry(a.tag, a.def)));
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  List<FontVariation> get _variations => [
    for (final axis in _axes)
      if (_values[axis.tag] != axis.def)
        FontVariation(axis.tag, _values[axis.tag]!),
  ];

  TextStyle _style({
    double? fontSize,
    Color color = _ink,
    FontWeight? fontWeight,
    FontStyle fontStyle = FontStyle.normal,
    double height = 1.25,
  }) => TextStyle(
    fontFamily: _fontFamily,
    fontSize: fontSize ?? _fontSize,
    color: color,
    height: height,
    fontWeight: fontWeight,
    fontStyle: fontStyle,
    fontVariations: _variations,
  );

  TextSpan _previewSpan() => TextSpan(
    style: _style(),
    children: [
      TextSpan(
        text: _headline,
        style: _style(fontSize: _headlineSize, height: 1.1),
      ),
      const TextSpan(text: '\n\n'),
      TextSpan(text: _body),
      const TextSpan(text: '\n\n'),
      TextSpan(
        text: _specimen,
        style: _style(fontSize: _specimenSize),
      ),
    ],
  );

  void _applyPreset(Map<String, double> coords) {
    setState(() {
      for (final axis in _axes) {
        _values[axis.tag] = coords[axis.tag] ?? axis.def;
      }
    });
  }

  void _resetAxes() => _applyPreset(const {});

  String get _variationSettings => _variations.isEmpty
      ? 'normal'
      : _variations.map((v) => '"${v.axis}" ${v.value}').join(', ');

  Widget _previewPane(String label, Widget child) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: _ink.withValues(alpha: 0.5),
        ),
      ),
      const SizedBox(height: 4),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: _paper,
          border: Border.all(color: _ink.withValues(alpha: 0.18)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: child,
      ),
    ],
  );

  Widget _axisSlider(FontAxis axis) {
    final tag = axis.tag;
    final value = _values[tag] ?? axis.def;
    final isDefault = value == axis.def;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 52,
                child: Text(
                  tag,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Expanded(
                child: Slider(
                  value: value.clamp(axis.min, axis.max),
                  min: axis.min,
                  max: axis.max,
                  divisions: axis.max - axis.min > 20
                      ? ((axis.max - axis.min) * 2).round().clamp(20, 200)
                      : null,
                  label: _formatAxisValue(tag, value),
                  onChanged: (v) => setState(() => _values[tag] = v),
                ),
              ),
              SizedBox(
                width: 56,
                child: Text(
                  _formatAxisValue(tag, value),
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 12,
                    color: isDefault ? _ink.withValues(alpha: 0.45) : _accent,
                    fontWeight: isDefault ? FontWeight.normal : FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 52),
            child: Text(
              'range ${_formatAxisValue(tag, axis.min)}–'
              '${_formatAxisValue(tag, axis.max)} · default '
              '${_formatAxisValue(tag, axis.def)}',
              style: TextStyle(
                fontSize: 10,
                color: _ink.withValues(alpha: 0.4),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _formatAxisValue(String tag, double v) {
    if (tag == 'opsz' || tag == 'wdth' || tag == 'wght') {
      return v.round().toString();
    }
    return v.toStringAsFixed(tag == 'slnt' ? 1 : 0);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Variable fonts')),
        body: Center(
          child: Text(_error!, style: const TextStyle(color: Colors.red)),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Variable font playground')),
      body: ListenableBuilder(
        listenable: GPUText.instance,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'OpenType design axes drive GPUFont.variant() through '
              'TextStyle.fontVariations. Outline deltas (gvar), advance '
              'widths (HVAR), and global metrics (MVAR) all interpolate '
              'live — no separate font files per weight.',
              style: TextStyle(
                fontSize: 13,
                color: _ink.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              color: _surface,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text(
                          'Axes',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: _resetAxes,
                          child: const Text('Reset'),
                        ),
                      ],
                    ),
                    for (final axis in _axes) _axisSlider(axis),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Text('font size', style: TextStyle(fontSize: 13)),
                        Expanded(
                          child: Slider(
                            value: _fontSize,
                            min: 12,
                            max: 48,
                            divisions: 36,
                            label: _fontSize.round().toString(),
                            onChanged: (v) => setState(() => _fontSize = v),
                          ),
                        ),
                        SizedBox(
                          width: 32,
                          child: Text(
                            '${_fontSize.round()}',
                            textAlign: TextAlign.right,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'font-variation-settings: $_variationSettings',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: _ink.withValues(alpha: 0.55),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in _presets)
                  ActionChip(
                    label: Text(p.label),
                    onPressed: () => _applyPreset(p.coords),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            _previewPane('gputext', GPURichText(text: _previewSpan())),
            if (_compareFlutter) ...[
              const SizedBox(height: 12),
              _previewPane('stock RichText', RichText(text: _previewSpan())),
            ],
            const SizedBox(height: 16),
            _WeightLadder(
              style: TextStyle(
                fontFamily: _fontFamily,
                fontSize: 15,
                color: _ink,
                height: 1.25,
              ),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Show stock RichText comparison'),
              value: _compareFlutter,
              onChanged: (v) => setState(() => _compareFlutter = v),
            ),
          ],
        ),
      ),
    );
  }
}

/// Side-by-side rows where fontWeight and explicit wght both drive the axis.
class _WeightLadder extends StatelessWidget {
  const _WeightLadder({required this.style});

  final TextStyle style;

  static const _weights = <(String, FontWeight)>[
    ('Thin', FontWeight.w100),
    ('Regular', FontWeight.w400),
    ('Bold', FontWeight.w700),
    ('Black', FontWeight.w900),
  ];

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'fontWeight vs fontVariations',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
            ),
            const SizedBox(height: 4),
            Text(
              'On a variable font, fontWeight maps onto the wght axis; '
              'explicit fontVariations win when both are set.',
              style: TextStyle(
                fontSize: 12,
                color: _ink.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 10),
            for (final (label, weight) in _weights) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  SizedBox(
                    width: 64,
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 11,
                        color: _ink.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                  Expanded(
                    child: GPURichText(
                      text: TextSpan(
                        text: 'Ag',
                        style: style.copyWith(
                          fontWeight: weight,
                          fontVariations: const [],
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: GPURichText(
                      text: TextSpan(
                        text: 'Ag',
                        style: style.copyWith(
                          fontWeight: null,
                          fontVariations: [
                            FontVariation('wght', weight.value.toDouble()),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
            ],
            Text(
              'left: fontWeight · right: FontVariation("wght", …)',
              style: TextStyle(
                fontSize: 10,
                color: _ink.withValues(alpha: 0.4),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

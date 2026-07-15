// SliverGPUText inside a real CustomScrollView: a pinned SliverAppBar, box
// slivers before and after, and one long GPU-rendered document between them —
// scrolled by the ONE outer viewport, no nested scrollable, honest scrollbar.
// Links dispatch through hit tags; underlines/backgrounds ride the sliver.
// Dev hook: GPUTEXT_DEMO=sliver.
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:gputext/lowlevel.dart' hide TextAlign, TextDirection;

class SliverGPUTextDemoPage extends StatefulWidget {
  const SliverGPUTextDemoPage({super.key});

  @override
  State<SliverGPUTextDemoPage> createState() => _SliverGPUTextDemoPageState();
}

class _SliverGPUTextDemoPageState extends State<SliverGPUTextDemoPage> {
  GPUTextViewController? _controller;
  GPUTextDocument? _doc;
  String? _error;
  final ScrollController _scroll = ScrollController();
  final ValueNotifier<GPUTextMetrics?> _metrics = ValueNotifier(null);
  final ValueNotifier<String> _tapLog = ValueNotifier('tap a link…');
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      final controller = await GPUTextViewController.spawn();
      final lato = (await rootBundle.load('assets/Lato-Regular.ttf')).buffer
          .asUint8List();
      await controller.registerFont('lato', Uint8List.fromList(lato));
      if (!mounted) {
        controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _doc = _buildDocument();
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  TapGestureRecognizer _link(String label) {
    final r = TapGestureRecognizer()
      ..onTap = () => _tapLog.value = 'tapped "$label"';
    _recognizers.add(r);
    return r;
  }

  /// A real inline widget (hosted as a render child of the sliver).
  static Widget _badge(String label, Color color) => DecoratedBox(
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Text(
        label,
        style: const TextStyle(fontSize: 11, color: Colors.white),
      ),
    ),
  );

  GPUTextDocument _buildDocument() {
    const body = TextStyle(fontSize: 16, height: 1.5);
    final children = <InlineSpan>[];
    for (var s = 0; s < 40; s++) {
      children.addAll([
        TextSpan(
          text: 'Section ${s + 1} — rendered by SliverGPUText ',
          style: const TextStyle(fontSize: 24, height: 1.8),
        ),
        // Sized inline widget: fast path, no measure frame.
        GPUWidgetSpan(
          size: const Size(64, 20),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: () => _tapLog.value = 'badge §${s + 1} tapped',
              child: _badge('GPU §${s + 1}', const Color(0xFF7C3AED)),
            ),
          ),
        ),
        // Sizeless inline widget: measured during layout, one reflow later.
        if (s == 0) ...[
          const TextSpan(text: ' '),
          GPUWidgetSpan(child: _badge('auto-sized', const Color(0xFF0E9F6E))),
        ],
        const TextSpan(text: '\n'),
      ]);
      for (var p = 0; p < 4; p++) {
        children.addAll([
          TextSpan(
            text:
                'Paragraph ${p + 1}. The whole document is one sliver: the '
                'viewport hands it the visible window every frame, only that '
                'strip is rasterized, and the scrollbar tracks the true '
                'extent. ',
          ),
          TextSpan(
            text: 'This link in §${s + 1}.${p + 1} is a hit target',
            style: const TextStyle(
              color: Color(0xFF1A56DB),
              decoration: TextDecoration.underline,
            ),
            recognizer: _link('§${s + 1}.${p + 1}'),
          ),
          const TextSpan(text: ', and this run carries a '),
          const TextSpan(
            text: 'painted background',
            style: TextStyle(backgroundColor: Color(0xFFFFF3B0)),
          ),
          const TextSpan(
            text:
                ' — both drawn by the sliver in the same frame as the '
                'glyphs.\n',
          ),
        ]);
      }
    }
    return GPUTextDocument.rich(
      'sliver-demo-1',
      TextSpan(style: body, children: children),
      fontIdResolver: (_) => 'lato',
    );
  }

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _scroll.dispose();
    _metrics.dispose();
    _tapLog.dispose();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final doc = _doc;
    if (_error != null) {
      return Scaffold(body: Center(child: Text('boot failed: $_error')));
    }
    if (controller == null || doc == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    // Explicit controller + scrollbars: false: desktop ScrollBehavior would
    // otherwise nest a second Scrollbar on the same position, and the thumb
    // drag gesture loses the arena (trackpad still works).
    return Scaffold(
      body: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: Scrollbar(
          controller: _scroll,
          interactive: true,
          thumbVisibility: true,
          child: CustomScrollView(
            controller: _scroll,
            slivers: [
              SliverAppBar(
                pinned: true,
                title: const Text('SliverGPUText'),
                actions: [
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 16),
                      child: ValueListenableBuilder<GPUTextMetrics?>(
                        valueListenable: _metrics,
                        builder: (context, m, _) => Text(
                          m == null
                              ? '…'
                              : '${m.glyphCount} glyphs · ${m.lineCount} lines '
                                    '· ${m.reflowMs.toStringAsFixed(1)} ms',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              SliverToBoxAdapter(
                child: Container(
                  color: const Color(0xFFEDF2FB),
                  padding: const EdgeInsets.all(16),
                  child: ValueListenableBuilder<String>(
                    valueListenable: _tapLog,
                    builder: (context, log, _) => Text(
                      'A box sliver above the GPU text. Last interaction: $log',
                    ),
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 16,
                ),
                sliver: SliverGPUText(
                  controller: controller,
                  document: doc,
                  onMetrics: (m) => _metrics.value = m,
                  onSpanTap: (tag, span) {
                    if (span?.recognizer == null) {
                      _tapLog.value = 'span tap: $tag';
                    }
                  },
                ),
              ),
              SliverList.builder(
                itemCount: 5,
                itemBuilder: (context, i) => ListTile(
                  leading: const Icon(Icons.check),
                  title: Text(
                    'Ordinary SliverList tile ${i + 1} — after the '
                    'GPU document, same viewport',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

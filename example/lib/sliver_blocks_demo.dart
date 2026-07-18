// SliverGPUTextBlocks: thousands of paragraphs in a CustomScrollView, each
// shaped + laid out on the worker only when it nears the viewport. The HUD
// counts laid-out blocks live; estimate→real height fixups arrive as
// SliverGeometry.scrollOffsetCorrection, so grabbing the scrollbar and
// jumping deep never makes the content lurch. Dev hook:
// GPUTEXT_DEMO=sliverblocks.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:gputext/lowlevel.dart' hide TextAlign, TextDirection;

class SliverBlocksDemoPage extends StatefulWidget {
  const SliverBlocksDemoPage({super.key});

  @override
  State<SliverBlocksDemoPage> createState() => _SliverBlocksDemoPageState();
}

class _SliverBlocksDemoPageState extends State<SliverBlocksDemoPage> {
  static const int _blockCount = 3000;

  GPUTextViewController? _controller;
  List<GPUTextDocument>? _blocks;
  String? _error;
  final ValueNotifier<(int, int)> _laidOut = ValueNotifier((0, _blockCount));

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
        _blocks = _buildBlocks();
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  List<GPUTextDocument> _buildBlocks() {
    const sentences = [
      'Each paragraph here is an independent block: it is shaped on the '
          'worker isolate only when it scrolls near the viewport.',
      'Scroll extent starts from cheap estimates and converges to real '
          'heights as blocks lay out.',
      'When a block above the viewport resolves, the delta is reported as a '
          'scroll-offset correction, so nothing on screen lurches.',
      'GPU instance buffers exist only for blocks near the viewport; shaped '
          'paragraphs stay warm under an LRU.',
      'Grab the scrollbar and throw it to the middle — the blocks there lay '
          'out on demand.',
    ];
    return [
      for (var i = 0; i < _blockCount; i++)
        GPUTextDocument.rich(
          'para-$i',
          TextSpan(
            children: [
              TextSpan(
                text: '¶ $i  ',
                style: const TextStyle(color: Color(0xFF9CA3AF)),
              ),
              TextSpan(
                // Vary length so estimates are meaningfully wrong.
                text: List.generate(
                  1 + (i * 7) % 5,
                  (k) => sentences[(i + k) % sentences.length],
                ).join(' '),
              ),
            ],
            style: const TextStyle(fontSize: 16, height: 1.4),
          ),
          fontIdResolver: (_) => 'lato',
        ),
    ];
  }

  List<InlineSpan> _buildRichText() {
    const sentences = [
      'Each paragraph here is an independent block: it is shaped on the '
          'worker isolate only when it scrolls near the viewport.',
      'Scroll extent starts from cheap estimates and converges to real '
          'heights as blocks lay out.',
      'When a block above the viewport resolves, the delta is reported as a '
          'scroll-offset correction, so nothing on screen lurches.',
      'GPU instance buffers exist only for blocks near the viewport; shaped '
          'paragraphs stay warm under an LRU.',
      'Grab the scrollbar and throw it to the middle — the blocks there lay '
          'out on demand.',
    ];
    return [
      for (var i = 0; i < _blockCount; i++)
        TextSpan(
          children: [
            TextSpan(
              text: '¶ $i  ',
              style: const TextStyle(color: Color(0xFF9CA3AF)),
            ),
            TextSpan(
              // Vary length so estimates are meaningfully wrong.
              text: List.generate(
                1 + (i * 7) % 5,
                (k) => sentences[(i + k) % sentences.length],
              ).join(' '),
            ),
          ],
          style: const TextStyle(fontSize: 16, height: 1.4),
        ),
    ];
  }

  @override
  void dispose() {
    _laidOut.dispose();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final blocks = _blocks;
    if (_error != null) {
      return Scaffold(body: Center(child: Text('boot failed: $_error')));
    }
    if (controller == null || blocks == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      // Selection: mouse-drag / long-press selects across the GPU blocks;
      // touch-drag scrolls.
      body: SelectionArea(
        child: CustomScrollView(
          slivers: [
            SliverAppBar(
              pinned: true,
              title: const Text('SliverGPUTextBlocks'),
              actions: [
                Center(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: ValueListenableBuilder<(int, int)>(
                      valueListenable: _laidOut,
                      builder: (context, v, _) => Text(
                        'laid out ${v.$1} / ${v.$2}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              sliver: SliverGPUTextBlocks(
                controller: controller,
                blocks: blocks,
                blockSpacing: 12,
                onLaidOutChanged: (n, total) => _laidOut.value = (n, total),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

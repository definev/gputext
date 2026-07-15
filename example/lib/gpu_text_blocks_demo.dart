// Lazy block layout with GPUTextBlocksView (Design B): a long document split
// into independent paragraph blocks. Each is shaped + laid out on the worker
// ONLY when it scrolls near the viewport, then all visible blocks are composited
// into ONE viewport GPU surface (one pass, N draw calls with per-block camY).
// Scroll down and the HUD shows blocks laying out on demand; far-off blocks are
// evicted from the worker. Contrast with gpu_text_view_demo.dart (one whole
// paragraph up front). Dev hook: GPUTEXT_DEMO=blocks.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:gputext/lowlevel.dart' hide TextAlign, TextDirection;

class GPUTextBlocksDemoPage extends StatefulWidget {
  const GPUTextBlocksDemoPage({super.key});

  @override
  State<GPUTextBlocksDemoPage> createState() => _GPUTextBlocksDemoPageState();
}

class _GPUTextBlocksDemoPageState extends State<GPUTextBlocksDemoPage> {
  GPUTextViewController? _controller;
  List<GPUTextDocument>? _blocks;
  String? _error;
  int _laidOut = 0;

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
      await controller.registerFont('lato', lato);

      // Build a long document: hundreds of paragraph blocks. Each is its own
      // GPUTextDocument with a unique id (its worker cache key). None of these
      // is shaped until it scrolls into view.
      final blocks = <GPUTextDocument>[];
      for (var i = 0; i < 400; i++) {
        final para = _paragraphs[i % _paragraphs.length];
        blocks.add(
          GPUTextDocument(
            id: 'p$i',
            runs: [
              GPUTextRunSpec(
                text: '§${i + 1}  $para',
                fontId: 'lato',
                fontSizePx: 18,
                color: const [0.11, 0.12, 0.16, 1],
              ),
            ],
          ),
        );
      }

      if (!mounted) {
        controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _blocks = blocks;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final blocks = _blocks;
    return Scaffold(
      appBar: AppBar(
        title: const Text('GPUTextBlocksView — composited lazy blocks'),
        bottom: blocks == null
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(24),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                    child: Text(
                      'laid out $_laidOut / ${blocks.length} · shared atlas + '
                      'LRU · one surface',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.black54,
                      ),
                    ),
                  ),
                ),
              ),
      ),
      body: _error != null
          ? Center(child: Text('Failed: $_error'))
          : controller == null || blocks == null
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(
              builder: (context, constraints) {
                return Container(
                  color: const Color(0xFFF3F1EC),
                  alignment: Alignment.topCenter,
                  child: SizedBox(
                    width: 620,
                    height: constraints.maxHeight,
                    child: Material(
                      elevation: 2,
                      color: Colors.white,
                      child: GPUTextBlocksView(
                        controller: controller,
                        blocks: blocks,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 28,
                          vertical: 24,
                        ),
                        blockSpacing: 14,
                        // A little cache margin so scrolling doesn't pop; blocks
                        // beyond it are evicted from the worker.
                        cacheExtent: 600,
                        onLaidOutChanged: (laidOut, _) {
                          if (mounted) setState(() => _laidOut = laidOut);
                        },
                        fallbackBuilder: (context) => const Center(
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(
                              'GPU rendering needs Impeller + flutter_gpu.',
                              style: TextStyle(color: Colors.black54),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

const _paragraphs = [
  'Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod '
      'tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim '
      'veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea '
      'commodo consequat.',
  'Duis aute irure dolor in reprehenderit in voluptate velit esse cillum '
      'dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non '
      'proident, sunt in culpa qui officia deserunt mollit anim id est laborum.',
  'Sed ut perspiciatis unde omnis iste natus error sit voluptatem accusantium '
      'doloremque laudantium, totam rem aperiam, eaque ipsa quae ab illo '
      'inventore veritatis et quasi architecto beatae vitae dicta sunt '
      'explicabo. Nemo enim ipsam voluptatem quia voluptas sit aspernatur.',
  'Neque porro quisquam est, qui dolorem ipsum quia dolor sit amet, '
      'consectetur, adipisci velit, sed quia non numquam eius modi tempora '
      'incidunt ut labore et dolore magnam aliquam quaerat voluptatem.',
];

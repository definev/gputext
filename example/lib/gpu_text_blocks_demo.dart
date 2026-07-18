// Lazy block layout with GPUTextBlocksView (Design B): a long document split
// into independent blocks. GPU-text paragraphs (GPUTextDocument) are shaped +
// laid out on the worker ONLY when they scroll near the viewport, then all
// visible ones are composited into ONE viewport GPU surface (one pass, N draw
// calls with per-block camY). Interleaved between them are real MEDIA blocks
// (GPUWidgetBlock: a figure card, a code card, a Flutter Table, a divider) —
// ordinary Flutter widgets, mounted + measured on the main isolate and
// virtualized alongside the text. Scroll down and the HUD shows blocks laying
// out on demand; far-off text blocks are evicted from the worker. Contrast with
// gpu_text_view_demo.dart (one whole paragraph up front). Dev hook:
// GPUTEXT_DEMO=blocks.
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
  List<GPUBlock>? _blocks;
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

      // Build a long document: paragraph text blocks with real media widget
      // blocks interleaved every few paragraphs. Text blocks shape on the
      // worker on demand (unique id = worker cache key); widget blocks mount +
      // measure on the main isolate — both virtualized together.
      final blocks = <GPUBlock>[];
      var media = 0;
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
        if (i % 4 == 3) blocks.add(_mediaBlock(media++));
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

  /// A media block, cycling figure / code card / table / divider. These are
  /// ordinary Flutter widgets rendered between the GPU-text paragraphs.
  static GPUWidgetBlock _mediaBlock(int k) => switch (k % 4) {
    0 => GPUWidgetBlock(id: 'media-figure-$k', builder: (_) => _figureCard(k)),
    1 => GPUWidgetBlock(id: 'media-code-$k', builder: (_) => _codeCard(k)),
    2 => GPUWidgetBlock(id: 'media-table-$k', builder: (_) => _tableCard(k)),
    // Fixed height → skips measurement entirely (no _MeasuredBlock).
    _ => GPUWidgetBlock(
      id: 'media-divider-$k',
      height: 40,
      builder: (_) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Divider(height: 16, thickness: 1),
      ),
    ),
  };

  static Widget _figureCard(int k) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          height: 150,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.lerp(
                  const Color(0xFF6366F1),
                  const Color(0xFFEC4899),
                  (k % 5) / 5,
                )!,
                const Color(0xFF0EA5E9),
              ],
            ),
          ),
          child: Text(
            'Figure ${k + 1}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.only(top: 6, left: 4),
          child: Text(
            'A real Flutter widget block — gradient figure with a caption, '
            'measured and virtualized alongside the GPU text.',
            style: TextStyle(fontSize: 12, color: Colors.black54),
          ),
        ),
      ],
    ),
  );

  static Widget _codeCard(int k) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF12161B),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        'void block$k() {\n'
        '  GPUTextBlocksView(\n'
        '    blocks: [textDoc, GPUWidgetBlock(...)],\n'
        '  );\n'
        '}',
        style: const TextStyle(
          fontFamily: 'JetBrainsMono',
          fontSize: 13,
          height: 1.5,
          color: Color(0xFFEAD9A8),
        ),
      ),
    ),
  );

  static Widget _tableCard(int k) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Table(
      border: TableBorder.all(color: const Color(0xFFD8D3C8)),
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        for (var r = 0; r < 3; r++)
          TableRow(
            decoration: r == 0
                ? const BoxDecoration(color: Color(0xFFEDE9E0))
                : null,
            children: [
              for (var c = 0; c < 3; c++)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  child: Text(
                    r == 0 ? 'Col ${c + 1}' : 'r$r·c${c + 1} (t$k)',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: r == 0 ? FontWeight.w700 : FontWeight.w400,
                    ),
                  ),
                ),
            ],
          ),
      ],
    ),
  );

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
                      'laid out $_laidOut / ${blocks.length} · text + media '
                      'blocks · shared atlas · LRU',
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
          : SelectionArea(
              child: LayoutBuilder(
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

// Minimal real usage of the reusable isolate widget (GPUTextView). The entire
// off-thread layout + GPU render + virtualized scroll pipeline is three steps:
//
//   1. spawn a GPUTextViewController and register your fonts on it,
//   2. describe the document once (GPUTextDocument / .rich),
//   3. hand both to a GPUTextView.
//
// Everything else — reflow-on-resize off the UI isolate, the GPU surface
// lifecycle, viewport virtualization, WidgetSpan overlays — is inside the
// widget. Contrast with lowlevel_demo.dart, which wires all of that by hand to
// showcase the internals. Dev hook: GPUTEXT_DEMO=view.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:gputext/lowlevel.dart' hide TextAlign, TextDirection;

class GPUTextViewDemoPage extends StatefulWidget {
  const GPUTextViewDemoPage({super.key});

  @override
  State<GPUTextViewDemoPage> createState() => _GPUTextViewDemoPageState();
}

class _GPUTextViewDemoPageState extends State<GPUTextViewDemoPage> {
  GPUTextViewController? _controller;
  GPUTextDocument? _doc;
  String? _error;
  GPUTextMetrics? _metrics;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      // 1. One worker owns the fonts; share it across any number of views.
      final controller = await GPUTextViewController.spawn();
      final lato = (await rootBundle.load('assets/Lato-Regular.ttf'))
          .buffer
          .asUint8List();
      await controller.registerFont('lato', lato);

      // 2. Describe the document once. `.rich` flattens a Flutter TextSpan; a
      //    GPUWidgetSpan reserves a box on the worker (it can't render a widget)
      //    AND carries the real widget, which the view draws at the box it
      //    returns — no sizer, builder, or index bookkeeping. Omitting its size
      //    (below) makes the view MEASURE the child before layout.
      final doc = GPUTextDocument.rich(
        'view-demo',
        TextSpan(
          style: const TextStyle(fontSize: 18, color: Color(0xFF1D2027)),
          children: [
            const TextSpan(
              text: 'GPUTextView wraps this paragraph on a background isolate '
                  'and renders it as GPU glyphs. Resize the window and it '
                  'reflows off the UI thread. Inline widgets such as ',
            ),
            // No size: the view measures _Chip's natural size (one frame) and
            // reserves that box before laying out. Pass `size:` to skip that.
            const GPUWidgetSpan(child: _Chip()),
            const TextSpan(
              text: ' are laid out as boxes by the worker and composited over '
                  'the GPU text on the UI isolate. Scroll to see the document '
                  'virtualize — only the visible window is ever rasterized, so '
                  'GPU memory stays flat no matter how long the text gets.\n\n',
            ),
            TextSpan(text: _body),
          ],
        ),
        fontIdResolver: (_) => 'lato',
        defaultFontSizePx: 18,
        defaultColor: const [0.11, 0.12, 0.16, 1],
        lineHeight: 1.5,
      );

      if (!mounted) {
        controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _doc = doc;
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
    final doc = _doc;
    return Scaffold(
      appBar: AppBar(
        title: const Text('GPUTextView — reusable isolate widget'),
        bottom: _metrics == null
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(24),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                    child: Text(
                      '${_metrics!.glyphCount} glyphs · ${_metrics!.lineCount} '
                      'lines · reflow ${_metrics!.reflowMs.toStringAsFixed(1)} ms',
                      style: const TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                  ),
                ),
              ),
      ),
      body: _error != null
          ? Center(child: Text('Failed: $_error'))
          : controller == null || doc == null
          ? const Center(child: CircularProgressIndicator())
          : Container(
              color: const Color(0xFFF3F1EC),
              alignment: Alignment.topCenter,
              child: Material(
                elevation: 2,
                color: Colors.white,
                child: SizedBox(
                  width: 560,
                  // 3. Point the view at the controller + document. Done.
                  child: GPUTextView(
                    controller: controller,
                    document: doc,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 28,
                      vertical: 24,
                    ),
                    onMetrics: (m) {
                      if (mounted) setState(() => _metrics = m);
                    },
                    // No placeholderBuilder: the GPUWidgetSpan bundled its
                    // widget, so the view draws it automatically.
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
            ),
    );
  }
}

/// The inline widget carried by the GPUWidgetSpan. Self-sizing (padding around
/// its text), so the view can measure its natural size for the reserved box.
class _Chip extends StatelessWidget {
  const _Chip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF3355DD),
        borderRadius: BorderRadius.circular(13),
      ),
      child: const Text(
        'chips',
        style: TextStyle(color: Colors.white, fontSize: 13),
      ),
    );
  }
}

const _body =
    'Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod '
    'tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim '
    'veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea '
    'commodo consequat. Duis aute irure dolor in reprehenderit in voluptate '
    'velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint '
    'occaecat cupidatat non proident, sunt in culpa qui officia deserunt '
    'mollit anim id est laborum.\n\n'
    'Sed ut perspiciatis unde omnis iste natus error sit voluptatem accusantium '
    'doloremque laudantium, totam rem aperiam, eaque ipsa quae ab illo '
    'inventore veritatis et quasi architecto beatae vitae dicta sunt explicabo. '
    'Nemo enim ipsam voluptatem quia voluptas sit aspernatur aut odit aut '
    'fugit, sed quia consequuntur magni dolores eos qui ratione voluptatem '
    'sequi nesciunt. Neque porro quisquam est, qui dolorem ipsum quia dolor sit '
    'amet, consectetur, adipisci velit, sed quia non numquam eius modi tempora '
    'incidunt ut labore et dolore magnam aliquam quaerat voluptatem.';

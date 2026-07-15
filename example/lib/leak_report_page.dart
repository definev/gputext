import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:leak_tracker/leak_tracker.dart';

import 'leak_tracking.dart';

const _ink = Color(0xFF0C0F1C);
const _paper = Color(0xFFE9E3D5);
const _surface = Color(0xFFF5F0E6);
const _accent = Color(0xFF8C1F14);
const _ok = Color(0xFF1B5E20);
const _muted = Color(0xFF5A5F6E);

/// Readable leak report for the example app.
///
/// Pass [initialLeaks] after a collect, or open empty and tap **Collect**.
class LeakReportPage extends StatefulWidget {
  const LeakReportPage({super.key, this.initialLeaks});

  final Leaks? initialLeaks;

  @override
  State<LeakReportPage> createState() => _LeakReportPageState();
}

class _LeakReportPageState extends State<LeakReportPage> {
  Leaks? _leaks;
  bool _collecting = false;
  String? _error;
  DateTime? _collectedAt;

  @override
  void initState() {
    super.initState();
    _leaks = widget.initialLeaks;
    if (_leaks != null) _collectedAt = DateTime.now();
  }

  Future<void> _collect() async {
    setState(() {
      _collecting = true;
      _error = null;
    });
    try {
      final leaks = await collectAndReportLeaks();
      if (!mounted) return;
      setState(() {
        _leaks = leaks;
        _collectedAt = DateTime.now();
        _collecting = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _collecting = false;
      });
    }
  }

  Future<void> _copyYaml() async {
    final leaks = _leaks;
    if (leaks == null) return;
    final text = leaks.total == 0
        ? 'no leaks'
        : leaks.toYaml(phasesAreTests: false);
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Report copied')));
  }

  @override
  Widget build(BuildContext context) {
    final leaks = _leaks;
    final yaml = leaks == null
        ? null
        : (leaks.total == 0 ? 'no leaks' : leaks.toYaml(phasesAreTests: false));

    return Scaffold(
      backgroundColor: _paper,
      appBar: AppBar(
        title: const Text('Leak report'),
        backgroundColor: _paper,
        foregroundColor: _ink,
        actions: [
          if (yaml != null && leaks != null && leaks.total > 0)
            IconButton(
              tooltip: 'Copy YAML',
              onPressed: _copyYaml,
              icon: const Icon(Icons.copy),
            ),
          IconButton(
            tooltip: 'Collect again',
            onPressed: _collecting ? null : _collect,
            icon: _collecting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          if (!leakTrackingActive)
            _banner(
              color: _accent,
              child: const Text(
                'Leak tracking is off. Relaunch with '
                '--dart-define=GPUTEXT_LEAK_TRACK=true (debug).',
                style: TextStyle(color: Colors.white, height: 1.35),
              ),
            ),
          if (_error != null) ...[
            _banner(
              color: _accent,
              child: Text(
                _error!,
                style: const TextStyle(color: Colors.white, height: 1.35),
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (leaks == null)
            _emptyState()
          else ...[
            _summaryCard(leaks),
            const SizedBox(height: 16),
            if (leaks.notDisposed.isNotEmpty) ...[
              _sectionTitle('Not disposed (${leaks.notDisposed.length})'),
              ...leaks.notDisposed.map(_leakTile),
              const SizedBox(height: 12),
            ],
            if (leaks.notGCed.isNotEmpty) ...[
              _sectionTitle('Not GCed (${leaks.notGCed.length})'),
              ...leaks.notGCed.map(_leakTile),
              const SizedBox(height: 12),
            ],
            if (leaks.gcedLate.isNotEmpty) ...[
              _sectionTitle('GCed late (${leaks.gcedLate.length})'),
              ...leaks.gcedLate.map(_leakTile),
              const SizedBox(height: 12),
            ],
            if (yaml != null) ...[
              _sectionTitle('YAML'),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _surface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _ink.withValues(alpha: 0.12)),
                ),
                child: SelectableText(
                  yaml,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.4,
                    color: _ink,
                  ),
                ),
              ),
            ],
          ],
        ],
      ),
      floatingActionButton: leakTrackingActive
          ? FloatingActionButton.extended(
              onPressed: _collecting ? null : _collect,
              backgroundColor: _ink,
              foregroundColor: _paper,
              icon: const Icon(Icons.search),
              label: Text(_collecting ? 'Collecting…' : 'Collect leaks'),
            )
          : null,
    );
  }

  Widget _emptyState() {
    return Padding(
      padding: const EdgeInsets.only(top: 48),
      child: Column(
        children: [
          Icon(Icons.memory, size: 48, color: _ink.withValues(alpha: 0.35)),
          const SizedBox(height: 16),
          const Text(
            'No report yet',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: _ink,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Open and close demos, then collect to see not-disposed '
            'Flutter objects here.',
            textAlign: TextAlign.center,
            style: TextStyle(color: _muted, height: 1.4),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: leakTrackingActive && !_collecting ? _collect : null,
            style: FilledButton.styleFrom(backgroundColor: _ink),
            icon: const Icon(Icons.search),
            label: const Text('Collect leaks'),
          ),
        ],
      ),
    );
  }

  Widget _summaryCard(Leaks leaks) {
    final ok = leaks.total == 0;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ok
            ? _ok.withValues(alpha: 0.12)
            : _accent.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: (ok ? _ok : _accent).withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            ok ? 'No leaks' : '${leaks.total} leak(s)',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: ok ? _ok : _accent,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 16,
            runSpacing: 4,
            children: [
              _stat('not disposed', leaks.notDisposed.length),
              _stat('not GCed', leaks.notGCed.length),
              _stat('GCed late', leaks.gcedLate.length),
            ],
          ),
          if (_collectedAt != null) ...[
            const SizedBox(height: 8),
            Text(
              'Collected ${_collectedAt!.toLocal()}',
              style: const TextStyle(fontSize: 12, color: _muted),
            ),
          ],
        ],
      ),
    );
  }

  Widget _stat(String label, int count) {
    return Text.rich(
      TextSpan(
        style: const TextStyle(color: _ink, fontSize: 14),
        children: [
          TextSpan(
            text: '$count',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          TextSpan(
            text: ' $label',
            style: const TextStyle(color: _muted),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 4),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          color: _ink,
        ),
      ),
    );
  }

  Widget _leakTile(LeakReport report) {
    final contextLines = <String>[];
    final ctx = report.context;
    if (ctx != null) {
      for (final e in ctx.entries) {
        contextLines.add('${e.key}: ${e.value}');
      }
    }
    if (report.retainingPath != null) {
      contextLines.add('retainingPath: ${report.retainingPath}');
    }
    if (report.detailedPath != null) {
      contextLines.addAll(report.detailedPath!);
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _ink.withValues(alpha: 0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            report.type,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 14,
              color: _ink,
            ),
          ),
          const SizedBox(height: 4),
          SelectableText(
            report.trackedClass,
            style: const TextStyle(fontSize: 12, color: _muted, height: 1.3),
          ),
          Text(
            'code ${report.code}'
            '${report.phase != null ? ' · ${report.phase}' : ''}',
            style: const TextStyle(fontSize: 11, color: _muted),
          ),
          if (contextLines.isNotEmpty) ...[
            const SizedBox(height: 8),
            SelectableText(
              contextLines.join('\n'),
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                height: 1.35,
                color: _ink,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _banner({required Color color, required Widget child}) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
      ),
      child: child,
    );
  }
}

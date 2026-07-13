// Timeline helpers for measuring gputext pipeline stages.
//
// Events always forward to [dart:developer]'s [Timeline], so they show up in
// Flutter DevTools → Performance when recording. Optionally enable
// [debugCollectionEnabled] to aggregate durations in-process (profile/debug
// only) for benches or on-device logging without scraping DevTools.
//
// Stage name constants keep labels stable across call sites and filters:
//
//   GPUTextTimeline.debugCollectionEnabled = true;
//   // … exercise layout / paint …
//   final timings = GPUTextTimeline.debugCollect();
//   print(timings.getAggregated(GPUTextTimeline.prepare));

import 'dart:developer';

const bool _kReleaseMode = bool.fromEnvironment('dart.vm.product');

/// Wraps [Timeline] with optional in-process aggregation for benches.
abstract final class GPUTextTimeline {
  /// Flatten InlineSpan → inline items (fallback resolve + bidi + shape).
  static const flatten = 'gputext.flatten';

  /// Width-independent prepare (segment analysis + measurement).
  static const prepare = 'gputext.prepare';

  /// Per-width line breaking / materialization.
  static const layout = 'gputext.layout';

  /// Glyph instance + hit-box emission.
  static const emit = 'gputext.emit';

  /// Offscreen GPU surface render.
  static const render = 'gputext.render';

  /// [RenderGPUParagraph.performLayout] (flatten+prepare+layout).
  static const performLayout = 'gputext.performLayout';

  /// Paint-time atlas ensure + emit.
  static const prepareContent = 'gputext.prepareContent';

  static bool _collectionEnabled = false;
  static final List<_OpenBlock> _stack = <_OpenBlock>[];
  static final List<TimedBlock> _blocks = <TimedBlock>[];

  /// Profile/debug only; always false in release.
  static bool get debugCollectionEnabled => _collectionEnabled;

  /// Throws in release. Disabling resets collected data.
  static set debugCollectionEnabled(bool value) {
    if (_kReleaseMode) {
      throw StateError(
        'GPUTextTimeline metric collection is not supported in release mode.',
      );
    }
    if (value == _collectionEnabled) return;
    _collectionEnabled = value;
    debugReset();
  }

  /// Must pair with [finishSync] before returning to the event queue.
  static void startSync(
    String name, {
    Map<String, Object?>? arguments,
    Flow? flow,
  }) {
    Timeline.startSync(name, arguments: arguments, flow: flow);
    if (!_kReleaseMode && _collectionEnabled) {
      _stack.add(_OpenBlock(name, Timeline.now.toDouble()));
    }
  }

  static void finishSync() {
    Timeline.finishSync();
    if (!_kReleaseMode && _collectionEnabled && _stack.isNotEmpty) {
      final open = _stack.removeLast();
      _blocks.add(
        TimedBlock(
          name: open.name,
          start: open.start,
          end: Timeline.now.toDouble(),
        ),
      );
    }
  }

  /// Forwards to DevTools; aggregates when [debugCollectionEnabled] is true.
  static T timeSync<T>(
    String name,
    T Function() function, {
    Map<String, Object?>? arguments,
    Flow? flow,
  }) {
    startSync(name, arguments: arguments, flow: flow);
    try {
      return function();
    } finally {
      finishSync();
    }
  }

  /// Timings collected since collection was enabled, the last [debugCollect],
  /// or the last [debugReset] — whichever was most recent.
  ///
  /// Resets the collected timings. Throws if collection is disabled or in
  /// release mode.
  static AggregatedTimings debugCollect() {
    if (_kReleaseMode) {
      throw StateError(
        'GPUTextTimeline metric collection is not supported in release mode.',
      );
    }
    if (!_collectionEnabled) {
      throw StateError('GPUTextTimeline metric collection is not enabled.');
    }
    if (_stack.isNotEmpty) {
      throw StateError(
        'GPUTextTimeline has ${_stack.length} unfinished startSync '
        'block(s): ${_stack.map((b) => b.name).join(', ')}',
      );
    }
    final result = AggregatedTimings(List<TimedBlock>.of(_blocks));
    debugReset();
    return result;
  }

  /// Forgets previously collected timing data (and clears any open stack).
  static void debugReset() {
    if (_kReleaseMode) {
      throw StateError(
        'GPUTextTimeline metric collection is not supported in release mode.',
      );
    }
    _stack.clear();
    _blocks.clear();
  }
}

/// One timed block recorded by [GPUTextTimeline].
final class TimedBlock {
  const TimedBlock({required this.name, required this.start, required this.end})
    : assert(end >= start);

  final String name;
  final double start;
  final double end;

  double get duration => end - start;
  double get durationMs => duration / 1000;

  @override
  String toString() => 'TimedBlock($name, ${durationMs.toStringAsFixed(3)} ms)';
}

/// Aggregated results from [GPUTextTimeline.debugCollect].
final class AggregatedTimings {
  AggregatedTimings(this.timedBlocks);

  final List<TimedBlock> timedBlocks;

  late final List<AggregatedTimedBlock> aggregatedBlocks =
      _computeAggregatedBlocks();

  List<AggregatedTimedBlock> _computeAggregatedBlocks() {
    final aggregate = <String, (double, int)>{};
    for (final block in timedBlocks) {
      final prev = aggregate.putIfAbsent(block.name, () => (0, 0));
      aggregate[block.name] = (prev.$1 + block.duration, prev.$2 + 1);
    }
    return [
      for (final e in aggregate.entries)
        AggregatedTimedBlock(
          name: e.key,
          duration: e.value.$1,
          count: e.value.$2,
        ),
    ]..sort((a, b) => b.duration.compareTo(a.duration));
  }

  /// Aggregation for [name], or zeros if that block never ran.
  AggregatedTimedBlock getAggregated(String name) {
    for (final block in aggregatedBlocks) {
      if (block.name == name) return block;
    }
    return AggregatedTimedBlock(name: name, duration: 0, count: 0);
  }

  @override
  String toString() {
    if (aggregatedBlocks.isEmpty) return 'AggregatedTimings(empty)';
    final buf = StringBuffer('AggregatedTimings:\n');
    for (final b in aggregatedBlocks) {
      buf.writeln(
        '  ${b.name.padRight(28)} '
        '${b.durationMs.toStringAsFixed(3).padLeft(9)} ms  '
        '×${b.count}  '
        '(avg ${b.averageMs.toStringAsFixed(3)} ms)',
      );
    }
    return buf.toString().trimRight();
  }
}

/// Sum of [TimedBlock]s that share a [name].
final class AggregatedTimedBlock {
  const AggregatedTimedBlock({
    required this.name,
    required this.duration,
    required this.count,
  }) : assert(duration >= 0);

  final String name;

  /// Total duration in microseconds.
  final double duration;

  final int count;

  double get durationMs => duration / 1000;

  double get averageMs => count == 0 ? 0 : durationMs / count;

  @override
  String toString() =>
      'AggregatedTimedBlock($name, ${durationMs.toStringAsFixed(3)} ms ×$count)';
}

final class _OpenBlock {
  _OpenBlock(this.name, this.start);
  final String name;
  final double start;
}

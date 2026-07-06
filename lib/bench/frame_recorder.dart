// FrameTiming capture and per-scenario attribution.
//
// One SchedulerBinding timings callback buffers every FrameTiming for the
// whole run; scenarios claim their slice by frame-number window: the driver
// records the current PlatformDispatcher frame number when measurement
// starts (after warmup) and again when it stops, then [drain] waits until
// the engine has reported a timing at least as new as the window's end —
// raster timings arrive a few frames behind paint. GPU cost only exists in
// FrameTiming.rasterDuration; nothing here (or anywhere on the timed path)
// reads pixels back.

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';

class FrameWindow {
  FrameWindow({required this.timings, required this.partial});

  final List<ui.FrameTiming> timings;

  /// True when [FrameRecorder.drain] timed out before the window's last
  /// frame was reported rasterized — treat the sample as incomplete.
  final bool partial;

  List<double> get buildMs =>
      [for (final t in timings) t.buildDuration.inMicroseconds / 1000];
  List<double> get rasterMs =>
      [for (final t in timings) t.rasterDuration.inMicroseconds / 1000];
  List<double> get totalMs =>
      [for (final t in timings) t.totalSpan.inMicroseconds / 1000];
}

class FrameRecorder {
  final List<ui.FrameTiming> _buffer = [];
  bool _hooked = false;

  void start() {
    if (_hooked) return;
    _hooked = true;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  void stop() {
    if (!_hooked) return;
    _hooked = false;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
  }

  void _onTimings(List<ui.FrameTiming> timings) => _buffer.addAll(timings);

  /// The frame number the next produced frame will carry; call at scenario
  /// measure-start/measure-end to delimit the attribution window.
  int currentFrame() =>
      ui.PlatformDispatcher.instance.frameData.frameNumber;

  int get _latestReported =>
      _buffer.isEmpty ? -1 : _buffer.last.frameNumber;

  /// Wait until a timing >= [endFrame] has been reported (frames beyond the
  /// window keep the pipeline moving), then return the window's timings.
  Future<FrameWindow> drain(int startFrame, int endFrame,
      {Duration timeout = const Duration(seconds: 5)}) async {
    final deadline = DateTime.now().add(timeout);
    var partial = false;
    while (_latestReported < endFrame) {
      if (DateTime.now().isAfter(deadline)) {
        partial = true;
        break;
      }
      // Idle apps stop producing frames; keep scheduling empty ones so the
      // engine reports the window's tail.
      SchedulerBinding.instance.scheduleFrame();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return FrameWindow(
      timings: [
        for (final t in _buffer)
          if (t.frameNumber >= startFrame && t.frameNumber <= endFrame) t,
      ],
      partial: partial,
    );
  }
}

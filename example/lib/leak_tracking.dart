// In-app leak tracking for the example (debug builds only).
//
// Enable with either:
//   --dart-define=GPUTEXT_LEAK_TRACK=true
//   GPUTEXT_LEAK_TRACK=1
//
// Then open/close demos and tap "Collect leaks" (or wait for periodic
// console warnings). See example/README.md.

import 'dart:developer' as developer;
import 'dart:io' as io;

import 'package:flutter/foundation.dart';
import 'package:leak_tracker/leak_tracker.dart';

/// True when the example was launched with leak tracking requested.
bool get leakTrackingRequested {
  const fromDefine = bool.fromEnvironment('GPUTEXT_LEAK_TRACK');
  if (fromDefine) return true;
  final env = io.Platform.environment['GPUTEXT_LEAK_TRACK'];
  return env == '1' || env?.toLowerCase() == 'true';
}

bool get leakTrackingActive => LeakTracking.isStarted;

/// Starts leak tracking when requested and the build supports it.
///
/// No-op in profile/release: [LeakTracking.start] is assert-gated, and
/// Flutter allocation events need debug (or
/// `--dart-define=flutter.memory_allocations=true`).
void maybeStartLeakTracking() {
  if (!leakTrackingRequested) return;
  if (kReleaseMode) {
    debugPrint(
      'gputext leak tracking: ignored in release '
      '(use debug: --dart-define=GPUTEXT_LEAK_TRACK=true)',
    );
    return;
  }
  if (!kFlutterMemoryAllocationsEnabled) {
    debugPrint(
      'gputext leak tracking: FlutterMemoryAllocations is off. '
      'Use debug, or add --dart-define=flutter.memory_allocations=true',
    );
    return;
  }
  if (LeakTracking.isStarted) return;

  FlutterMemoryAllocations.instance.addListener(_onObjectEvent);
  LeakTracking.start(
    config: LeakTrackingConfig(
      onLeaks: (summary) {
        if (summary.isEmpty) return;
        developer.log('gputext leak_tracker: $summary', name: 'leak_tracker');
      },
      checkPeriod: const Duration(seconds: 3),
    ),
  );
  debugPrint(
    'gputext leak tracking: started. Open/close demos, then Leak report.',
  );
}

void _onObjectEvent(ObjectEvent event) {
  LeakTracking.dispatchObjectEvent(event.toMap());
}

/// Forces not-disposed declaration, collects, and prints a YAML report.
Future<Leaks> collectAndReportLeaks() async {
  if (!LeakTracking.isStarted) {
    debugPrint('gputext leak tracking: not started');
    return Leaks.empty();
  }
  LeakTracking.declareNotDisposedObjectsAsLeaks();
  final leaks = await LeakTracking.collectLeaks();
  if (leaks.total == 0) {
    debugPrint('gputext leak tracking: no leaks');
  } else {
    debugPrint(
      'gputext leak tracking: ${leaks.total} leak(s)\n'
      '${leaks.toYaml(phasesAreTests: false)}',
    );
  }
  return leaks;
}

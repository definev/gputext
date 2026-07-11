import 'package:flutter_test/flutter_test.dart';
import 'package:gputext/gputext.dart';

void main() {
  tearDown(() {
    if (GPUTextTimeline.debugCollectionEnabled) {
      GPUTextTimeline.debugCollectionEnabled = false;
    }
  });

  test('timeSync records nested stages when collection is enabled', () {
    GPUTextTimeline.debugCollectionEnabled = true;

    GPUTextTimeline.timeSync(GPUTextTimeline.performLayout, () {
      GPUTextTimeline.timeSync(GPUTextTimeline.flatten, () {});
      GPUTextTimeline.timeSync(GPUTextTimeline.prepare, () {});
      GPUTextTimeline.timeSync(GPUTextTimeline.layout, () {});
    });

    final timings = GPUTextTimeline.debugCollect();
    expect(timings.getAggregated(GPUTextTimeline.performLayout).count, 1);
    expect(timings.getAggregated(GPUTextTimeline.flatten).count, 1);
    expect(timings.getAggregated(GPUTextTimeline.prepare).count, 1);
    expect(timings.getAggregated(GPUTextTimeline.layout).count, 1);
    expect(timings.getAggregated(GPUTextTimeline.emit).count, 0);
    expect(
      timings.getAggregated(GPUTextTimeline.performLayout).duration,
      greaterThanOrEqualTo(
        timings.getAggregated(GPUTextTimeline.flatten).duration,
      ),
    );
  });

  test('debugCollect resets and requires collection enabled', () {
    GPUTextTimeline.debugCollectionEnabled = true;
    GPUTextTimeline.timeSync('gputext.test', () {});
    final first = GPUTextTimeline.debugCollect();
    expect(first.timedBlocks, isNotEmpty);

    final second = GPUTextTimeline.debugCollect();
    expect(second.timedBlocks, isEmpty);

    GPUTextTimeline.debugCollectionEnabled = false;
    expect(() => GPUTextTimeline.debugCollect(), throwsStateError);
  });

  test('unfinished startSync fails debugCollect', () {
    GPUTextTimeline.debugCollectionEnabled = true;
    GPUTextTimeline.startSync('gputext.open');
    expect(() => GPUTextTimeline.debugCollect(), throwsStateError);
    GPUTextTimeline.finishSync();
    GPUTextTimeline.debugReset();
  });
}

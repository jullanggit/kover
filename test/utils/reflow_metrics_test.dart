import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:kover/utils/reflow_metrics.dart';

ReflowMetrics makeMetrics({Map<String, dynamic> settings = const {}}) {
  return ReflowMetrics(
    seriesId: 1,
    chapterId: 2,
    page: 3,
    viewport: const Size(400, 800),
    devicePixelRatio: 2,
    refreshRate: 60,
    settings: settings,
  );
}

void main() {
  setUp(ReflowMetricsCollector.clear);
  tearDown(ReflowMetricsCollector.clear);

  group('ReflowMetrics', () {
    test('aggregates phases and derives per-subpage stats', () {
      final metrics = makeMetrics()
        ..start()
        ..markSetupComplete()
        ..recordSerialize(const Duration(milliseconds: 5), 1000)
        ..recordSerialize(const Duration(milliseconds: 3), 500)
        ..recordMeasure(const Duration(milliseconds: 10))
        ..recordMeasure(const Duration(milliseconds: 20))
        ..recordFit()
        ..recordOverflow()
        ..recordSearchStep()
        ..recordSplit()
        ..recordCommit(const Duration(milliseconds: 4))
        ..recordYield(const Duration(milliseconds: 16))
        ..recordSubpages(3);

      metrics.finish(outcome: ReflowOutcome.completed);

      expect(metrics.probes, 2);
      expect(metrics.fits, 1);
      expect(metrics.overflows, 1);
      expect(metrics.searchSteps, 1);
      expect(metrics.splits, 1);
      expect(metrics.subpages, 3);
      expect(metrics.serializeTime, const Duration(milliseconds: 8));
      expect(metrics.measureTime, const Duration(milliseconds: 30));
      expect(metrics.commitTime, const Duration(milliseconds: 4));
      expect(metrics.yieldTime, const Duration(milliseconds: 16));
      expect(metrics.yieldCount, 1);
      expect(metrics.maxMeasureTime, const Duration(milliseconds: 20));
      expect(metrics.bufferChars, 1500);
      expect(metrics.maxBufferChars, 1000);
      expect(metrics.probesPerSubpage, closeTo(2 / 3, 1e-9));
      expect(metrics.averageMeasureMs, closeTo(15, 1e-9));
      expect(metrics.outcome, ReflowOutcome.completed);
    });

    test('finish is idempotent', () {
      final metrics = makeMetrics()..start();
      metrics.finish(outcome: ReflowOutcome.completed);
      metrics.finish(outcome: ReflowOutcome.aborted);

      expect(metrics.outcome, ReflowOutcome.completed);
    });

    test('unaccounted time is never negative', () {
      final metrics = makeMetrics()..start();
      metrics.finish(outcome: ReflowOutcome.aborted);

      expect(metrics.unaccountedTime.isNegative, isFalse);
    });

    test('derived stats are zero without probes or subpages', () {
      final metrics = makeMetrics();

      expect(metrics.probesPerSubpage, 0);
      expect(metrics.averageMeasureMs, 0);
    });

    test('records first subpage and resume timings only once', () {
      final metrics = makeMetrics()..start();

      metrics.recordSubpages(0);
      expect(metrics.firstSubpageTime, isNull);

      metrics.recordSubpages(1);
      final first = metrics.firstSubpageTime;
      expect(first, isNotNull);

      metrics.recordSubpages(3);
      expect(metrics.firstSubpageTime, same(first));

      metrics.markResumeFound();
      final resume = metrics.resumeFoundTime;
      expect(resume, isNotNull);

      metrics.markResumeFound();
      expect(metrics.resumeFoundTime, same(resume));
    });

    test('timing attributes are omitted until recorded', () {
      final metrics = makeMetrics();

      expect(metrics.toLogAttributes(), isNot(contains('first_subpage_ms')));
      metrics.recordSubpages(1);
      metrics.markResumeFound();
      final attributes = metrics.toLogAttributes();
      expect(attributes['first_subpage_ms'], isA<int>());
      expect(attributes['resume_found_ms'], isA<int>());
    });

    test('log attributes include configuration and metrics', () {
      final metrics = makeMetrics(settings: {'font_size': 14.0})
        ..start()
        ..recordMeasure(const Duration(milliseconds: 12))
        ..recordSubpages(2);
      metrics.finish(outcome: ReflowOutcome.completed);

      final attributes = metrics.toLogAttributes();
      expect(attributes['outcome'], 'completed');
      expect(attributes['subpages'], 2);
      expect(attributes['probes'], 1);
      expect(attributes['viewport_w'], 400);
      expect(attributes['viewport_h'], 800);
      expect(attributes['refresh_rate'], 60);
      expect(attributes['font_size'], 14.0);
    });

    test('toString contains the run identity and phase timings', () {
      final metrics = makeMetrics()..start();
      metrics.finish(outcome: ReflowOutcome.aborted);

      final description = metrics.toString();
      expect(description, contains('chapter_id=2'));
      expect(description, contains('measure_ms='));
      expect(description, contains('yield_ms='));
    });
  });

  group('ReflowMetricsCollector', () {
    test('records the last run and keeps history in order', () {
      for (var i = 0; i < 3; i++) {
        ReflowMetricsCollector.record(makeMetrics());
      }

      expect(ReflowMetricsCollector.last, isNotNull);
      expect(ReflowMetricsCollector.history.length, 3);
    });

    test('invokes the onRecord hook', () {
      ReflowMetrics? captured;
      ReflowMetricsCollector.onRecord = (metrics) => captured = metrics;
      addTearDown(() => ReflowMetricsCollector.onRecord = null);

      final metrics = makeMetrics();
      ReflowMetricsCollector.record(metrics);

      expect(captured, same(metrics));
    });

    test('aggregate averages completed runs only', () {
      ReflowMetricsCollector.record(
        makeMetrics()
          ..start()
          ..recordMeasure(const Duration(milliseconds: 10))
          ..recordSubpages(2)
          ..finish(outcome: ReflowOutcome.completed),
      );
      ReflowMetricsCollector.record(
        makeMetrics()
          ..start()
          ..recordMeasure(const Duration(seconds: 5))
          ..recordSubpages(1000)
          ..finish(outcome: ReflowOutcome.aborted),
      );

      final aggregate = ReflowMetricsCollector.aggregate();
      expect(aggregate['runs'], 1);
      expect(aggregate['avg_probes'], 1.0);
      expect(aggregate['avg_subpages'], 2.0);
      expect(aggregate['avg_measure_ms'], 10.0);
    });

    test('aggregate is empty without completed runs', () {
      ReflowMetricsCollector.record(
        makeMetrics()..finish(outcome: ReflowOutcome.aborted),
      );

      expect(ReflowMetricsCollector.aggregate()['runs'], 0);
    });
  });

  test('logging is enabled in debug builds', () {
    expect(kReflowMetricsLogging, isTrue);
  });
}

import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';

/// Whether reflow profiling summaries are emitted through `log`.
///
/// Enabled automatically in debug builds, and in profile/release builds when
/// compiled with `--dart-define=KOVER_REFLOW_METRICS=true`. A reflow summary is
/// one log entry per server page, so this stays off by default in release to
/// avoid spamming telemetry.
///
/// Metrics are always collected in memory (see [ReflowMetricsCollector])
/// regardless of this flag.
const bool kReflowMetricsLogging =
    kDebugMode || bool.fromEnvironment('KOVER_REFLOW_METRICS');

/// How a reflow run ended.
enum ReflowOutcome {
  /// The cursor was exhausted and all subpages were produced.
  completed,

  /// The run stopped early, e.g. the provider unmounted or a viewport change
  /// reloaded the reflow.
  aborted,
}

/// Profiling data for a single epub reflow run: one server page paginated into
/// viewport-sized subpages.
///
/// A "probe" is one call to `HeadlessMeasurePipeline.measure`. The phase split
/// between [serializeTime], [measureTime], [commitTime] and [yieldTime] shows
/// where a run spends its wall-clock budget, which is what lets us tell whether
/// an optimization helped and why.
///
/// Recording is intentionally cheap (integer/duration arithmetic) so the
/// instrumentation can stay in place while measuring real devices.
class ReflowMetrics {
  ReflowMetrics({
    required this.seriesId,
    required this.chapterId,
    required this.page,
    required this.viewport,
    required this.devicePixelRatio,
    required this.refreshRate,
    required this.settings,
  });

  final int seriesId;
  final int chapterId;
  final int page;
  final Size viewport;
  final double devicePixelRatio;

  /// The refresh rate used to derive the chunk budget (already clamped).
  final double refreshRate;

  /// Layout-affecting reader settings at the time of the run. Keyed with
  /// descriptive names so they merge cleanly into the log attributes.
  final Map<String, dynamic> settings;

  final Stopwatch _wall = Stopwatch();
  bool _finished = false;

  ReflowOutcome outcome = ReflowOutcome.aborted;

  /// Wall-clock duration of the whole run, from [start] to [finish].
  Duration totalTime = Duration.zero;

  /// Time spent before the measure loop: fetching custom CSS and attaching the
  /// headless pipeline.
  Duration setupTime = Duration.zero;

  int probes = 0;
  int fits = 0;
  int overflows = 0;
  int subpages = 0;

  /// Binary-search steps that narrowed the range or descended a level.
  int searchSteps = 0;

  /// Subpages produced by a mid-page split (`commitSplit`).
  int splits = 0;

  /// Wall time until the first subpage became available, when known. This is
  /// the latency a reader actually feels on open.
  Duration? firstSubpageTime;

  /// Wall time until the saved resume scroll id was located, when resuming.
  Duration? resumeFoundTime;

  Duration serializeTime = Duration.zero;
  Duration measureTime = Duration.zero;
  Duration commitTime = Duration.zero;
  Duration yieldTime = Duration.zero;
  Duration maxMeasureTime = Duration.zero;

  /// Total characters of buffer HTML serialized across all probes, and the
  /// largest single buffer. A proxy for the amount of work the measured widget
  /// had to parse and lay out.
  int bufferChars = 0;
  int maxBufferChars = 0;

  int yieldCount = 0;

  void start() => _wall.start();

  /// Marks the end of the pre-loop setup phase.
  void markSetupComplete() => setupTime = _wall.elapsed;

  void recordSerialize(Duration duration, int chars) {
    serializeTime += duration;
    bufferChars += chars;
    if (chars > maxBufferChars) maxBufferChars = chars;
  }

  void recordMeasure(Duration duration) {
    probes++;
    measureTime += duration;
    if (duration > maxMeasureTime) maxMeasureTime = duration;
  }

  void recordFit() => fits++;
  void recordOverflow() => overflows++;
  void recordSearchStep() => searchSteps++;
  void recordSplit() => splits++;

  void recordSubpages(int count) {
    if (count > 0 && firstSubpageTime == null) {
      firstSubpageTime = _wall.elapsed;
    }
    subpages = count;
  }

  void markResumeFound() => resumeFoundTime ??= _wall.elapsed;

  void recordCommit(Duration duration) => commitTime += duration;

  void recordYield(Duration duration) {
    yieldCount++;
    yieldTime += duration;
  }

  void finish({required ReflowOutcome outcome}) {
    if (_finished) return;
    _finished = true;
    this.outcome = outcome;
    totalTime = _wall.elapsed;
  }

  /// Probes per committed subpage. The higher this is, the more re-layouts of
  /// the whole buffer the binary search is paying for.
  double get probesPerSubpage => subpages == 0 ? 0 : probes / subpages;

  double get averageMeasureMs =>
      probes == 0 ? 0 : measureTime.inMicroseconds / probes / 1000;

  /// Wall-clock time not attributed to setup, serialize, measure, commit or
  /// yield (event-loop scheduling, state writes, etc.).
  Duration get unaccountedTime {
    final accounted =
        setupTime + serializeTime + measureTime + commitTime + yieldTime;
    final remainder = totalTime - accounted;
    return remainder.isNegative ? Duration.zero : remainder;
  }

  Map<String, dynamic> toLogAttributes() => {
    'series_id': seriesId,
    'chapter_id': chapterId,
    'page': page,
    'outcome': outcome.name,
    'subpages': subpages,
    'probes': probes,
    'fits': fits,
    'overflow_probes': overflows,
    'search_steps': searchSteps,
    'splits': splits,
    'probes_per_subpage': probesPerSubpage,
    'total_ms': totalTime.inMilliseconds,
    'setup_ms': setupTime.inMilliseconds,
    'serialize_ms': serializeTime.inMilliseconds,
    'measure_ms': measureTime.inMilliseconds,
    'commit_ms': commitTime.inMilliseconds,
    'yield_ms': yieldTime.inMilliseconds,
    'unaccounted_ms': unaccountedTime.inMilliseconds,
    'yield_count': yieldCount,
    'avg_measure_ms': averageMeasureMs,
    'max_measure_ms': maxMeasureTime.inMilliseconds,
    if (firstSubpageTime != null)
      'first_subpage_ms': firstSubpageTime!.inMilliseconds,
    if (resumeFoundTime != null)
      'resume_found_ms': resumeFoundTime!.inMilliseconds,
    'buffer_chars_total': bufferChars,
    'buffer_chars_max': maxBufferChars,
    'viewport_w': viewport.width.round(),
    'viewport_h': viewport.height.round(),
    'device_pixel_ratio': devicePixelRatio,
    'refresh_rate': refreshRate,
    ...settings,
  };

  @override
  String toString() {
    final attributes = toLogAttributes().entries
        .map((e) => '${e.key}=${e.value}')
        .join(', ');
    return 'ReflowMetrics($attributes)';
  }
}

/// In-memory sink for [ReflowMetrics] runs, for tests and debug tooling.
///
/// The reflow provider records every run here; [last], [history] and
/// [aggregate] can then be inspected without parsing logs.
class ReflowMetricsCollector {
  ReflowMetricsCollector._();

  static const int _maxHistory = 100;
  static final List<ReflowMetrics> _history = [];
  static ReflowMetrics? _last;

  /// Optional hook invoked for every recorded run, e.g. to feed a debug UI.
  static void Function(ReflowMetrics metrics)? onRecord;

  /// The most recently recorded run, or null.
  static ReflowMetrics? get last => _last;

  /// Recent runs, oldest first (bounded to the last 100).
  static List<ReflowMetrics> get history => List.unmodifiable(_history);

  static void record(ReflowMetrics metrics) {
    _last = metrics;
    _history.add(metrics);
    if (_history.length > _maxHistory) {
      _history.removeAt(0);
    }
    onRecord?.call(metrics);
  }

  /// Clears all collected runs. Intended for tests.
  static void clear() {
    _history.clear();
    _last = null;
  }

  /// Averages over the collected (completed) runs, useful for comparing
  /// changes across many openings.
  static Map<String, dynamic> aggregate() {
    final completed = _history
        .where((m) => m.outcome == ReflowOutcome.completed)
        .toList();
    if (completed.isEmpty) {
      return const {
        'runs': 0,
        'avg_total_ms': 0,
        'avg_measure_ms': 0,
        'avg_probes': 0,
        'avg_subpages': 0,
      };
    }

    double mean(int Function(ReflowMetrics) select) {
      final sum = completed.fold<int>(0, (acc, m) => acc + select(m));
      return sum / completed.length;
    }

    return {
      'runs': completed.length,
      'avg_total_ms': mean((m) => m.totalTime.inMilliseconds),
      'avg_measure_ms': mean((m) => m.measureTime.inMilliseconds),
      'avg_probes': mean((m) => m.probes),
      'avg_subpages': mean((m) => m.subpages),
    };
  }
}

// Epub reflow benchmark.
//
// Drives the real `EpubReflow` notifier (the code path that records
// `ReflowMetrics`) against either synthetic content or an HTML fixture, then
// prints the metrics so a change can be compared against a baseline.
//
// This lives under `test/` but is named without a `_test.dart` suffix, so
// `flutter test` does not pick it up during the normal suite. Run it explicitly:
//
//   flutter test test/benchmark/epub_reflow_benchmark.dart
//
// Configuration (environment variables):
//   KOVER_REFLOW_BENCHMARK_PARAGRAPHS  synthetic paragraphs (default 300)
//   KOVER_REFLOW_BENCHMARK_FIXTURE     path to an .html/.xhtml page to use
//   KOVER_REFLOW_BENCHMARK_WIDTH       viewport width  (default 400)
//   KOVER_REFLOW_BENCHMARK_HEIGHT      viewport height (default 800)
//   KOVER_REFLOW_BENCHMARK_OUT         write the metrics as JSON to this path
//   KOVER_REFLOW_BENCHMARK_BASELINE    a previous OUT file to diff against
//
// Profile/debug runs of the app can enable the same log summary with
// `--dart-define=KOVER_REFLOW_METRICS=true` (see `ReflowMetrics`).

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';
import 'package:html/parser.dart' show parseFragment;
import 'package:kover/generated/l10n/app_localizations.dart';
import 'package:kover/models/font_face.dart';
import 'package:kover/models/page_content.dart';
import 'package:kover/riverpod/managers/font_manager.dart';
import 'package:kover/riverpod/providers/book.dart';
import 'package:kover/riverpod/providers/reader.dart';
import 'package:kover/riverpod/providers/reader/epub_reader.dart';
import 'package:kover/riverpod/providers/settings/epub_reader_settings.dart';
import 'package:kover/utils/extensions/epub_page_preprocessor.dart';
import 'package:kover/utils/headless_measure_pipeline.dart';
import 'package:kover/utils/layout_constants.dart';
import 'package:kover/utils/reflow_metrics.dart';

const _seriesId = 1;
const _chapterId = 1;
const _page = 0;
const _devicePixelRatio = 3.0;
const _refreshRate = 60.0;

final _paragraphs = _envInt('KOVER_REFLOW_BENCHMARK_PARAGRAPHS', 300);
final _fixture = Platform.environment['KOVER_REFLOW_BENCHMARK_FIXTURE'];
final _output = Platform.environment['KOVER_REFLOW_BENCHMARK_OUT'];
final _baseline = Platform.environment['KOVER_REFLOW_BENCHMARK_BASELINE'];
final _viewport = Size(
  _envDouble('KOVER_REFLOW_BENCHMARK_WIDTH', 400),
  _envDouble('KOVER_REFLOW_BENCHMARK_HEIGHT', 800),
);

int _envInt(String name, int fallback) =>
    int.tryParse(Platform.environment[name] ?? '') ?? fallback;

double _envDouble(String name, double fallback) =>
    double.tryParse(Platform.environment[name] ?? '') ?? fallback;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'epub reflow benchmark',
    (tester) async {
      final content = _pageContent(_input());

      final container = ProviderContainer.test(
        overrides: [
          epubPageProvider.overrideWith((ref, arg) => content),
          customCssProvider.overrideWith(
            (ref, seriesId) => const <String, Map<String, String>>{},
          ),
          bookProgressProvider.overrideWith((ref, chapterId) => null),
          epubReaderSettingsProvider.overrideWith2(
            (seriesId) => _FakeEpubReaderSettings(),
          ),
          fontManagerProvider.overrideWith(_FakeFontManager.new),
        ],
      );
      addTearDown(container.dispose);

      final provider = epubReflowProvider(
        seriesId: _seriesId,
        chapterId: _chapterId,
        page: _page,
      );
      final subscription = container.listen(provider, (_, _) {});
      addTearDown(subscription.close);

      // Let `build` resolve the page content and set up the cursor. Under the
      // widget-test fake async, provider work is advanced by pumping frames
      // rather than by awaiting the future directly.
      var buildPumps = 0;
      while (!container.read(provider).hasValue) {
        if (buildPumps++ > 100000) {
          fail('reflow build did not complete after $buildPumps pumps');
        }
        await tester.pump();
      }

      await container
          .read(provider.notifier)
          .startReflow(
            viewport: _viewport,
            devicePixelRatio: _devicePixelRatio,
            refreshRate: _refreshRate,
            measureBuilder: (html, styles) => _measureWidget(html),
          );

      // Fire the start debounce, then pump until pagination completes.
      await tester.pump(const Duration(milliseconds: 250));

      var pumps = 0;
      while (container.read(provider).value?.status != EpubReflowStatus.done) {
        if (pumps++ > 500000) {
          fail('reflow did not complete after $pumps pumps');
        }
        await tester.pump();
      }

      final state = container.read(provider).value!;
      final metrics = ReflowMetricsCollector.last;
      expect(metrics, isNotNull, reason: 'no reflow metrics were recorded');
      expect(state.status, EpubReflowStatus.done);
      expect(state.subpages, isNotEmpty);

      _report(metrics!);
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

/// Builds a [PageContent] from raw HTML, applying the same preprocessing the
/// app applies before reflow (`preprocessForRender`).
PageContent _pageContent(String html) {
  final content = PageContent(
    root: parseFragment(html),
    styles: const {},
    fonts: const <FontFace>[],
  );
  return content.copyWith(root: content.root.preprocessForRender());
}

/// The HTML to paginate: the configured fixture when present, else synthetic.
///
/// The fixture is a single content document (e.g. a chapter extracted from an
/// epub); the benchmark does not unpack epubs itself so it stays dependency
/// free.
String _input() {
  final fixture = _fixture;
  if (fixture == null) return _syntheticChapter(_paragraphs);
  return File(fixture).readAsStringSync();
}

/// The measure widget used during pagination. Mirrors `EpubMeasureRoot` /
/// `RenderEpubContent` closely enough for the metrics to be representative:
/// `HtmlWidget` performs the real parse + layout work.
Widget _measureWidget(String html) {
  return Localizations(
    locale: const Locale('en'),
    delegates: AppLocalizations.localizationsDelegates,
    child: MediaQuery(
      data: MediaQueryData(
        size: _viewport,
        devicePixelRatio: _devicePixelRatio,
      ),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MeasureTarget(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: LayoutConstants.mediumPadding,
                ),
                child: HtmlWidget(
                  html,
                  buildAsync: false,
                  enableCaching: true,
                  textStyle: const TextStyle(fontSize: 14, height: 1.5),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

const _words = [
  'lorem',
  'ipsum',
  'dolor',
  'sit',
  'amet',
  'consectetur',
  'adipiscing',
  'elit',
  'sed',
  'do',
  'eiusmod',
  'tempor',
  'incididunt',
  'ut',
  'labore',
  'et',
  'dolore',
  'magna',
  'aliqua',
  'enim',
  'ad',
  'minim',
  'veniam',
  'quis',
  'nostrud',
  'exercitation',
  'ullamco',
  'laboris',
  'nisi',
  'aliquip',
  'ex',
  'ea',
  'commodo',
  'consequat',
  'duis',
  'aute',
  'irure',
  'in',
  'reprehenderit',
  'voluptate',
  'velit',
  'esse',
  'cillum',
  'eu',
  'fugiat',
  'nulla',
  'pariatur',
  'excepteur',
  'sint',
  'occaecat',
  'cupidatat',
  'non',
  'proident',
  'sunt',
  'culpa',
  'qui',
  'officia',
  'deserunt',
  'mollit',
  'anim',
  'id',
  'est',
  'laborum',
];

/// Deterministic synthetic chapter used when no fixture is supplied.
String _syntheticChapter(int paragraphs) {
  final random = Random(42);
  final buffer = StringBuffer('<div><h1>Benchmark chapter</h1>');
  for (var i = 0; i < paragraphs; i++) {
    buffer.write('<p>');
    for (var w = 0; w < 60; w++) {
      buffer.write(_words[random.nextInt(_words.length)]);
      buffer.write(' ');
    }
    buffer.write('</p>');
  }
  buffer.write('</div>');
  return buffer.toString();
}

void _report(ReflowMetrics metrics) {
  final attributes = metrics.toLogAttributes();
  final buffer = StringBuffer()
    ..writeln()
    ..writeln('=== epub reflow benchmark ===');
  for (final entry in attributes.entries) {
    buffer.writeln('${entry.key}: ${entry.value}');
  }

  final baseline = _baseline;
  if (baseline != null) {
    final previous =
        jsonDecode(File(baseline).readAsStringSync()) as Map<String, dynamic>;
    buffer.writeln('--- vs baseline ($baseline) ---');
    for (final entry in attributes.entries) {
      final before = previous[entry.key];
      final after = entry.value;
      if (before is num && after is num) {
        final delta = after - before;
        final percent = before == 0
            ? ''
            : ' (${(delta / before * 100).toStringAsFixed(1)}%)';
        buffer.writeln('${entry.key}: $before -> $after  $delta$percent');
      }
    }
  }

  buffer
    ..writeln('=============================')
    ..writeln('REFLOW_BENCHMARK ${jsonEncode(attributes)}');
  print(buffer.toString());

  final output = _output;
  if (output != null) {
    File(output).writeAsStringSync(jsonEncode(attributes));
  }
}

/// Settings provider fake: returns defaults without touching persistence.
class _FakeEpubReaderSettings extends EpubReaderSettings {
  @override
  Future<EpubReaderSettingsState> build({required int seriesId}) async {
    return const EpubReaderSettingsState();
  }
}

/// Font manager fake: never loads fonts, so the benchmark stays off the network
/// and on the CPU cost of pagination alone.
class _FakeFontManager extends FontManager {
  @override
  Set<String> build() => const {};

  @override
  Future<void> ensureServerFontLoaded(String family) async {}

  @override
  Future<void> ensureLoaded(List<FontFace> fonts) async {}
}

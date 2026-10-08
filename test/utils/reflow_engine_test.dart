import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart';
import 'package:kover/utils/html_constants.dart';
import 'package:kover/utils/reflow_engine.dart';

void main() {
  group('ExponentialBinaryReflowEngine', () {
    test('when empty nodes, addNext returns false', () {
      // <div></div>
      final engine = ExponentialBinaryReflowEngine(root: Element.tag('div'));

      expect(engine.addNext(), isFalse);
    });

    test('when exhausted, addNext returns false', () {
      // <div>Hello</div>
      final root = Element.tag('div')..append(Text('Hello'));
      final engine = ExponentialBinaryReflowEngine(root: root);

      expect(engine.addNext(), isTrue);
      expect(engine.addNext(), isFalse);
      expect(engine.buffer.outerHtml, equals(root.outerHtml));
    });

    test('when split child on leaf node, then returns false', () {
      // <div>
      //   <img>Hello</img>
      // </div>
      final root = Element.tag('div')
        ..append(Element.tag('img')..append(Text('Hello')));
      final engine = ExponentialBinaryReflowEngine(root: root);

      engine.addNext();
      // Simulate the driver reporting overflow on the single unit.
      expect(engine.overflow(), isFalse);
    });

    test('when no overflow bound, addNext doubles the probe range', () {
      // <div>
      //   <p>aaaa</p>
      //   <p>aaaa</p>
      //   <p>aaaa</p>
      //   <p>aaaa</p>
      // </div>
      final root = Element.tag('div')
        ..append(Element.tag('p')..append(Text('aaaa')))
        ..append(Element.tag('p')..append(Text('aaaa')))
        ..append(Element.tag('p')..append(Text('aaaa')))
        ..append(Element.tag('p')..append(Text('aaaa')));
      final engine = ExponentialBinaryReflowEngine(root: root);

      // Galloping: 1, 2, 4.
      for (final expected in [1, 2, 4]) {
        expect(engine.addNext(), isTrue);
        expect(engine.buffer.nodes.length, equals(expected));
      }

      expect(engine.addNext(), isFalse);
    });

    test('when a probe overflows, the range is halved around the boundary', () {
      // <div> with 8 paragraphs.
      final root = Element.tag('div');
      for (var i = 0; i < 8; i++) {
        root.append(Element.tag('p')..append(Text('aaaa')));
      }
      final engine = ExponentialBinaryReflowEngine(root: root);

      // Galloping: 1, 2, 4.
      expect(engine.addNext(), isTrue);
      expect(engine.buffer.nodes.length, equals(1));
      expect(engine.addNext(), isTrue);
      expect(engine.buffer.nodes.length, equals(2));
      expect(engine.addNext(), isTrue);
      expect(engine.buffer.nodes.length, equals(4));

      // 4 overflows while 2 is known to fit: shrink to the midpoint 3.
      expect(engine.overflow(), isTrue);
      expect(engine.buffer.nodes.length, equals(3));
    });

    test('after a split, the next page gallops from a small probe', () {
      // 100 unsplittable units, so a boundary commits directly.
      final root = Element.tag('div');
      for (var i = 0; i < 100; i++) {
        root.append(Element.tag('img'));
      }
      final engine = ExponentialBinaryReflowEngine(root: root);

      // Page holds 2 units: gallop 1 (fit), 2 (fit), 4 (overflow).
      engine.addNext();
      engine.addNext();
      engine.addNext();
      expect(engine.overflow(), isTrue); // shrink to 3
      expect(engine.buffer.nodes.length, equals(3));
      expect(engine.overflow(), isFalse); // boundary on <img>: commit
      engine.commitSplit();

      // The next page must probe small again, not half of the 98 remaining
      // units. This is the regression guard for the O(n^2) re-render blow-up.
      expect(engine.addNext(), isTrue);
      expect(engine.buffer.nodes.length, equals(1));
    });

    test('when boundary found, descends into the overflowing unit', () {
      // <div>
      //   <p>one two</p>
      //   <p>three four</p>
      // </div>
      final root = Element.tag('div')
        ..append(Element.tag('p')..append(Text('one two')))
        ..append(Element.tag('p')..append(Text('three four')));
      final engine = ExponentialBinaryReflowEngine(root: root);

      engine.addNext(); // p1
      engine.addNext(); // p2
      // Boundary: 1 fits, 2 overflows -> descend into p2 (empty clone).
      expect(engine.overflow(), isTrue);
      expect(engine.buffer.nodes.length, equals(2));
      expect(engine.buffer.text, equals('one two'));
    });

    test('commit returns content up to split and backtracks', () {
      // <div>
      //   <p>Hello</p>
      //   <p>there</p>
      // </div>
      final root = Element.tag('div')
        ..append(Element.tag('p')..append(Text('Hello')))
        ..append(Element.tag('p')..append(Text('there')));
      // The empty p2 clone is kept, matching the linear engine's commit.
      final expectedCommit = Element.tag('div')
        ..append(Element.tag('p')..append(Text('Hello')));
      final expectedNext = Element.tag('div')
        ..append(Element.tag('p')..append(Text('there')));

      final engine = ExponentialBinaryReflowEngine(root: root);

      engine.addNext(); // p1
      engine.addNext(); // p2
      engine.overflow(); // boundary: descend into p2 (empty clone)
      engine.addNext(); // text 'there' appended to the clone
      engine.overflow(); // single word overflows: unsplittable
      final commit = engine.commitSplit(); // backtrack 'there'
      engine.addNext(); // 'there' re-added

      expect(commit.outerHtml, equals(expectedCommit.outerHtml));
      expect(engine.buffer.outerHtml, equals(expectedNext.outerHtml));
      engine.addNext(); // p2 level fits: pop, swap the shell into the root
      expect(engine.addNext(), isFalse);
    });

    test(
      'when committing after sentences split, no sentences are lost',
      () {
        // <div>
        //   <p>Hello. There. Sentences.</p>
        // </div>
        final root = Element.tag('div')
          ..append(Element.tag('p')..append(Text('Hello. There. Sentences.')));
        final expectedCommit = Element.tag('div')
          ..append(
            Element.tag('p')
              ..append(Text('Hello.'))
              ..attributes[HtmlConstants.splitParagraphAttribute] = '',
          );
        final expectedNext = Element.tag('div')
          ..append(Element.tag('p')..append(Text('There. Sentences.')));

        final engine = ExponentialBinaryReflowEngine(root: root);

        engine.addNext(); // p probed
        engine.overflow(); // descend into p
        engine.addNext(); // text probed
        engine.overflow(); // split into 'Hello.', ' There.', ' Sentences.'
        engine.addNext(); // probe 'Hello. There.'
        engine.overflow(); // shrink to 'Hello.'
        engine.addNext(); // fits: re-probe 'Hello. There.'
        engine.overflow(); // ' There.' is unsplittable
        final commit = engine.commitSplit(); // backtrack ' There.'
        engine.addNext(); // probe ' There.'
        final res = engine.addNext(); // probe ' There. Sentences.'

        expect(commit.outerHtml, equals(expectedCommit.outerHtml));
        expect(res, isTrue);
        expect(engine.buffer.outerHtml, equals(expectedNext.outerHtml));
      },
    );

    test(
      'when last sentence does not end with period, then it is not lost',
      () {
        // <div>
        //   <p>Hello. There. Sentences</p>
        // </div>
        final root = Element.tag('div')
          ..append(Element.tag('p')..append(Text('Hello. There. Sentences')));
        final expectedCommit = Element.tag('div')
          ..append(
            Element.tag('p')
              ..append(Text('Hello.'))
              ..attributes[HtmlConstants.splitParagraphAttribute] = '',
          );
        final expectedNext = Element.tag('div')
          ..append(Element.tag('p')..append(Text('There. Sentences')));

        final engine = ExponentialBinaryReflowEngine(root: root);

        engine.addNext(); // p probed
        engine.overflow(); // descend into p
        engine.addNext(); // text probed
        engine.overflow(); // split into 'Hello.', ' There.', ' Sentences'
        engine.addNext(); // probe 'Hello. There.'
        engine.overflow(); // shrink to 'Hello.'
        engine.addNext(); // fits: re-probe 'Hello. There.'
        engine.overflow(); // ' There.' is unsplittable
        final commit = engine.commitSplit(); // backtrack ' There.'
        engine.addNext(); // probe ' There.'
        final res = engine.addNext(); // probe ' There. Sentences'

        expect(commit.outerHtml, equals(expectedCommit.outerHtml));
        expect(res, isTrue);
        expect(engine.buffer.outerHtml, equals(expectedNext.outerHtml));
      },
    );

    test('when sentences end in quote, then they split correctly', () {
      // <div>
      //   <p>"Hello." "There."</p>
      // </div>
      final root = Element.tag('div')
        ..append(Element.tag('p')..append(Text('"Hello." "There."')));
      final expectedCommit = Element.tag('div')
        ..append(
          Element.tag('p')
            ..append(Text('"Hello."'))
            ..attributes[HtmlConstants.splitParagraphAttribute] = '',
        );
      final expectedNext = Element.tag('div')
        ..append(Element.tag('p')..append(Text('"There."')));

      final engine = ExponentialBinaryReflowEngine(root: root);

      engine.addNext(); // p probed
      engine.overflow(); // descend into p
      engine.addNext(); // text probed
      engine.overflow(); // split into '"Hello."', ' "There."'
      engine.addNext(); // probe '"Hello."'
      engine.overflow(); // unsplittable on an empty page: accepted as-is
      final commit = engine.commitSplit();
      final res = engine.addNext(); // probe ' "There."'

      expect(commit.outerHtml, equals(expectedCommit.outerHtml));
      expect(res, isTrue);
      expect(engine.buffer.outerHtml, equals(expectedNext.outerHtml));
    });

    test('when splitting words, split whitespace is dropped', () {
      // <p>Hello there white space</p>
      final root = Element.tag('p')..append(Text('Hello there white space'));
      // The page-ending word carries no trailing whitespace ...
      final expectedCommit = Element.tag('p')
        ..append(Text('Hello there'))
        ..attributes[HtmlConstants.splitParagraphAttribute] = '';
      // ... it is kept on the following word: no whitespace is lost.
      final expectedNext = Element.tag('p')..append(Text('white space'));

      final engine = ExponentialBinaryReflowEngine(root: root);

      engine.addNext(); // text probed
      engine.overflow(); // split into 'Hello', ' there', ' white', ' space'
      engine.addNext(); // probe 'Hello there'
      engine.addNext(); // probe 'Hello there white'
      engine.overflow(); // ' white' is unsplittable
      final commit = engine.commitSplit(); // backtrack ' white'
      engine.addNext(); // probe ' white'
      final res = engine.addNext(); // probe ' white space'

      expect(commit.outerHtml, equals(expectedCommit.outerHtml));
      expect(res, isTrue);
      expect(engine.buffer.outerHtml, equals(expectedNext.outerHtml));
    });

    test(
      'when unsplittable unit overflows an empty page, commits it as-is',
      () {
        // <div>
        //   <img>
        //   <p>after</p>
        // </div>
        final root = Element.tag('div')
          ..append(Element.tag('img'))
          ..append(Element.tag('p')..append(Text('after')));
        final engine = ExponentialBinaryReflowEngine(root: root);

        engine.addNext(); // p1: img probed
        // The img overflows and cannot split; the page is empty, so it is
        // accepted for the current page. Still false: the driver commits.
        expect(engine.overflow(), isFalse);

        // The img stays on the committed page and is consumed.
        final page = engine.commitSplit();
        expect(page.outerHtml, equals('<div><img></div>'));

        // The remaining content reflows and the engine terminates.
        expect(engine.addNext(), isTrue);
        expect(engine.buffer.text, equals('after'));
        expect(engine.addNext(), isFalse);
      },
    );

    test('when split paragraph backtracks empty, no attribute is set', () {
      // <div>
      //   <p>Hello</p>
      //   <p>there</p>
      // </div>
      final root = Element.tag('div')
        ..append(Element.tag('p')..append(Text('Hello')))
        ..append(Element.tag('p')..append(Text('there')));

      final engine = ExponentialBinaryReflowEngine(root: root);

      engine.addNext(); // p1
      engine.addNext(); // p2
      engine.overflow(); // boundary: descend into p2 (empty clone)
      engine.addNext(); // text 'there' appended to the clone
      engine.overflow(); // single word overflows: unsplittable
      final commit = engine.commitSplit(); // backtrack 'there', shell removed

      expect(
        commit.querySelector('p')?.attributes,
        isNot(contains(HtmlConstants.splitParagraphAttribute)),
      );
    });
  });
}

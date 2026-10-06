import 'package:html/dom.dart';
import 'package:kover/utils/extensions/document_fragment.dart';
import 'package:kover/utils/html_constants.dart';

abstract class ReflowEngine {
  /// The current buffer element that is being built.
  Element get buffer;

  /// Adds the next node from the source tree to the buffer.
  /// Returns true when a node was added, false if there are no more nodes to add.
  bool addNext();

  /// Marks the current buffer as overflowing.
  bool overflow();

  /// Commits the current buffer and returns a new buffer for further additions.
  Element commitSplit();
}

/// Exponential + binary search based reflow engine. Each tree level probes
/// exponential prefixes (1, 2, 4, ...) until the content overflows, then binary
/// searches between the last known fit and that overflow. When the boundary
/// unit is found, the engine descends one level and repeats, until the unit is
/// unsplittable (same end condition as the previous linear cursor).
class ExponentialBinaryReflowEngine implements ReflowEngine {
  static const Set<String> _leafTags = {'img', 'svg'};
  static final _wordsReg = RegExp(r'(?=\s)');

  final Element _root;
  final Element _buffer;
  final List<_Frame> _frames = [];

  ExponentialBinaryReflowEngine({required Element root})
    : _root = root.clone(true),
      _buffer = root.clone(false) {
    _frames.add(_Frame(target: _buffer, pending: List.of(_root.nodes)));
  }

  @override
  Element get buffer => _buffer;

  @override
  bool addNext() {
    if (_frames.isEmpty) return false;

    final frame = _frames.last;

    // Level exhausted: pop and continue the parent level.
    if (frame.pending.isEmpty) {
      _frames.removeLast();
      return addNext();
    }

    // The current probe fits.
    frame.lo = frame.p;

    if (frame.p == frame.pending.length) {
      // The whole level fits: pop. The parent resumes past the straddler
      // slot, which permanently shows the child shell from now on.
      _frames.removeLast();
      if (_frames.isEmpty) return false;

      final parent = _frames.last;
      final slot = parent.splitAt!;
      parent.pending[slot] = frame.target;
      parent.splitAt = null;
      parent.lo = slot + 1;
      if (parent.hi <= parent.lo) {
        parent.exponential = true;
      }
      _advance(parent);
      return true;
    }

    _advance(frame);
    return true;
  }

  /// Mirrors the next probe of [frame]: exponential while no
  /// overflow bound is known, otherwise binary searching the bounded range.
  void _advance(_Frame frame) {
    if (frame.exponential) {
      final grown = frame.lo < 1 ? 1 : frame.lo * 2;
      frame.p = grown < frame.pending.length ? grown : frame.pending.length;
    } else {
      // The range is bounded by a probe that overflowed: binary-search it.
      // When the range collapsed (hi == lo + 1) this re-appends the known
      // overflower so the driver reports overflow and the boundary handling
      // kicks in.
      frame.p = frame.lo + ((frame.hi - frame.lo + 1) >> 1);
    }
    _rebuild(frame);
  }

  @override
  bool overflow() {
    if (_frames.isEmpty) return false;

    final frame = _frames.last;
    if (frame.p == 0) return false;

    frame.hi = frame.p;
    // Once a probe overflows, stop exponential probing and binary-search the range.
    frame.exponential = false;

    // Range not collapsed: shrink the probe to the midpoint.
    if (frame.hi - frame.lo > 1) {
      frame.p = (frame.lo + frame.hi) >> 1;
      _rebuild(frame);
      return true;
    }

    // Boundary found: pending[lo] is the overflower. Descend.
    final unit = frame.pending[frame.lo];

    if (unit is Text) {
      final segments = _textSegments(unit.text);
      if (segments == null) {
        _acceptUnsplittable(frame);
        return false;
      }

      frame.pending
        ..removeAt(frame.lo)
        ..insertAll(frame.lo, segments.map(Text.new));
      frame.hi = frame.lo + segments.length;
      frame.p = frame.lo;
      _rebuild(frame);
      return true;
    }

    if (unit is! Element ||
        _leafTags.contains(unit.localName) ||
        unit.nodes.isEmpty ||
        unit.attributes.containsKey(HtmlConstants.textIndentSpanAttribute)) {
      _acceptUnsplittable(frame);
      return false;
    }

    // Descend one level: swap the tree node for an empty shell clone. The
    // unit itself stays untouched in pending until the child level pops.
    final shell = unit.clone(false);
    frame.target.nodes.last.replaceWith(shell);
    frame.splitAt = frame.lo;
    _frames.add(_Frame(target: shell, pending: List.of(unit.nodes)));

    return true;
  }

  @override
  Element commitSplit() {
    final frame = _frames.last;

    // Backtrack the overflower so it resumes on the next page. An accepted
    // unsplittable overflower (p == lo) stays on the committed page.
    if (frame.p > frame.lo && frame.target.nodes.isNotEmpty) {
      frame.target.nodes.removeLast();
    }

    frame.pending.removeRange(0, frame.lo);

    // Drop whitespace at the start of the next page.
    if (frame.pending.isNotEmpty && frame.pending.first is Text) {
      final first = frame.pending.first as Text;
      first.data = first.data.trimLeft();
    }

    // Ancestors committed everything before the straddler unit. The unit
    // itself stays (hollow) so the child shell swap keeps its slot.
    for (final f in _frames.take(_frames.length - 1)) {
      f.pending.removeRange(0, f.splitAt!);
      f.splitAt = 0;
    }

    final result = _buffer.clone(true);

    // Remove empty paragraph shells.
    result
        .querySelectorAll('p')
        .where((p) => !p.hasVisibleNodes)
        .forEach((p) => p.remove());

    // Mark a trailing split paragraph so the renderer can omit its bottom
    // margin: the split halves should read as one paragraph.
    final hasSplitParagraph = _frames.any(
      (f) => f.target.localName == 'p' && f.target.hasVisibleNodes,
    );
    if (hasSplitParagraph) {
      final trailing = result.localName == 'p'
          ? result
          : result.querySelectorAll('p').lastOrNull;
      trailing?.attributes[HtmlConstants.splitParagraphAttribute] = '';
    }

    // Reconstruct a clear tree up to the deepest target.
    Element? parent;
    for (final f in _frames) {
      f.target.nodes.clear();
      if (parent != null) parent.append(f.target);
      parent = f.target;
    }

    // The fresh page re-measures everything: reset the bounds.
    for (final f in _frames) {
      f.p = 0;
      f.lo = 0;
      f.hi = f.pending.length;
      f.exponential = true;
    }

    return result;
  }

  /// Marks an unsplittable overflower as accepted when the current page
  /// holds nothing else: it gets the page to itself (visually overflowing)
  /// and [commitSplit] consumes it, guaranteeing progress.
  void _acceptUnsplittable(_Frame frame) {
    if (frame.lo == 0 && _frames.every((f) => (f.splitAt ?? 0) == 0)) {
      frame.lo = frame.p;
    }
  }

  /// Splits [text] into words. The whitespace leads the following word, so a
  /// page-ending word is measured without its trailing whitespace while no
  /// whitespace is lost. Returns null when the text is a single word.
  List<String>? _textSegments(String text) {
    final words = text
        .split(_wordsReg)
        .where((word) => word.isNotEmpty)
        .toList();

    return words.length > 1 ? words : null;
  }

  /// Mirrors the first [_Frame.p] units of [frame] into its target.
  void _rebuild(_Frame frame) {
    frame.target.nodes
      ..clear()
      ..addAll(frame.pending.take(frame.p));
  }
}

/// One binary search level: the units of a single target element.
class _Frame {
  _Frame({required this.target, required this.pending}) : hi = pending.length;

  /// The element in the buffer tree units are mirrored into.
  final Element target;

  /// The units of this level; the first [p] are mirrored into [target].
  final List<Node> pending;

  /// Binary search pivot point. Matches units currently mirrored into [target].
  int p = 0;

  /// Binary search lower bound. Matches units known to fit into [target].
  int lo = 0;

  /// Binary search upper bound. Matches units known to overflow [target].
  int hi;

  /// Whether the search is still in the exponential probing phase
  /// or has an overflow bound and can halve the range.
  bool exponential = true;

  /// Index of the straddler unit a child frame descended into, if any.
  int? splitAt;
}

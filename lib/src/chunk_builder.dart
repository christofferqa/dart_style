// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.chunk_builder;

import 'chunk.dart';
import 'dart_formatter.dart';
import 'debug.dart' as debug;
import 'line_writer.dart';
import 'nesting_level.dart';
import 'nesting_builder.dart';
import 'rule/rule.dart';
import 'source_code.dart';
import 'whitespace.dart';

/// Takes the incremental serialized output of [SourceVisitor]--the source text
/// along with any comments and preserved whitespace--and produces a coherent
/// tree of [Chunk]s which can then be split into physical lines.
///
/// Keeps track of leading indentation, expression nesting, and all of the hairy
/// code required to seamlessly integrate existing comments into the pure
/// output produced by [SourceVisitor].
class ChunkBuilder {
  final DartFormatter _formatter;

  /// The builder for the code surrounding the block that this writer is for, or
  /// `null` if this is writing the top-level code.
  final ChunkBuilder _parent;

  final SourceCode _source;

  final List<Chunk> _chunks;

  /// The whitespace that should be written to [_chunks] before the next
  ///  non-whitespace token.
  ///
  /// This ensures that changes to indentation and nesting also apply to the
  /// most recent split, even if the visitor "creates" the split before changing
  /// indentation or nesting.
  Whitespace _pendingWhitespace = Whitespace.none;

  /// The nested stack of rules that are currently in use.
  ///
  /// New chunks are implicitly split by the innermost rule when the chunk is
  /// ended.
  final _rules = <Rule>[];

  /// The set of rules known to contain hard splits that will in turn force
  /// these rules to harden.
  ///
  /// This is accumulated lazily while chunks are being built. Then, once they
  /// are all done, the rules are all hardened. We do this later because some
  /// rules may not have all of their constraints fully wired up until after
  /// the hard split appears. For example, a hard split in a positional
  /// argument list needs to force the named arguments to split too, but we
  /// don't create that rule until after the positional arguments are done.
  final _hardSplitRules = new Set<Rule>();

  /// The list of rules that are waiting until the next whitespace has been
  /// written before they start.
  final _lazyRules = <Rule>[];

  /// The indexes of the chunks owned by each rule (except for hard splits).
  final _ruleChunks = <Rule, List<int>>{};

  /// The nested stack of spans that are currently being written.
  final _openSpans = <OpenSpan>[];

  /// The current state.
  final _nesting = new NestingBuilder();

  /// The stack of nesting levels where block arguments may start.
  ///
  /// A block argument's contents will nest at the last level in this stack.
  final _blockArgumentNesting = <NestingLevel>[];

  /// The index of the "current" chunk being written.
  ///
  /// If the last chunk is still being appended to, this is its index.
  /// Otherwise, it is the index of the next chunk which will be created.
  int get _currentChunkIndex {
    if (_chunks.isEmpty) return 0;
    if (_chunks.last.canAddText) return _chunks.length - 1;
    return _chunks.length;
  }

  /// Whether or not there was a leading comment that was flush left before any
  /// other content was written.
  ///
  /// This is used when writing child blocks to make the parent chunk have the
  /// right flush left value when a comment appears immediately inside the
  /// block.
  bool _firstFlushLeft = false;

  /// Whether there is pending whitespace that depends on the number of
  /// newlines in the source.
  ///
  /// This is used to avoid calculating the newlines between tokens unless
  /// actually needed since doing so is slow when done between every single
  /// token pair.
  bool get needsToPreserveNewlines =>
      _pendingWhitespace == Whitespace.oneOrTwoNewlines ||
          _pendingWhitespace == Whitespace.spaceOrNewline;

  /// The number of characters of code that can fit in a single line.
  int get pageWidth => _formatter.pageWidth;

  /// The current innermost rule.
  Rule get rule => _rules.last;

  ChunkBuilder(this._formatter, this._source)
      : _parent = null,
        _chunks = [] {
    indent(_formatter.indent);
    startBlockArgumentNesting();
  }

  ChunkBuilder._(this._parent, this._formatter, this._source, this._chunks) {
    startBlockArgumentNesting();
  }

  /// Writes [string], the text for a single token, to the output.
  ///
  /// By default, this also implicitly adds one level of nesting if we aren't
  /// currently nested at all. We do this here so that if a comment appears
  /// after any token within a statement or top-level form and that comment
  /// leads to splitting, we correctly nest. Even pathological cases like:
  ///
  ///
  ///     import // comment
  ///         "this_gets_nested.dart";
  ///
  /// If we didn't do this here, we'd have to call [nestExpression] after the
  /// first token of practically every grammar production.
  void write(String string) {
    _emitPendingWhitespace();
    _writeText(string);

    _lazyRules.forEach(startRule);
    _lazyRules.clear();

    _nesting.commitNesting();
  }

  /// Writes a [WhitespaceChunk] of [type].
  void writeWhitespace(Whitespace type) {
    _pendingWhitespace = type;
  }

  /// Write a split owned by the current innermost rule.
  ///
  /// If [nesting] is given, uses that. Otherwise, uses the current nesting
  /// level. If unsplit, it expands to a space if [space] is `true`.
  ///
  /// If [flushLeft] is `true`, then forces the next line to start at column
  /// one regardless of any indentation or nesting.
  ///
  /// If [isDouble] is passed, forces the split to either be a single or double
  /// newline. Otherwise, leaves it indeterminate.
  Chunk split({bool space, bool isDouble, bool flushLeft}) =>
      _writeSplit(_rules.last, null,
          flushLeft: flushLeft, isDouble: isDouble, spaceWhenUnsplit: space);

  /// Write a split owned by the current innermost rule.
  ///
  /// Unlike [split()], this ignores any current expression nesting. It always
  /// indents the next line at the statement level.
  Chunk blockSplit({bool space, bool isDouble}) =>
      _writeSplit(_rules.last, _nesting.blockNesting,
          isDouble: isDouble, spaceWhenUnsplit: space);

  /// Outputs the series of [comments] and associated whitespace that appear
  /// before [token] (which is not written by this).
  ///
  /// The list contains each comment as it appeared in the source between the
  /// last token written and the next one that's about to be written.
  ///
  /// [linesBeforeToken] is the number of lines between the last comment (or
  /// previous token if there are no comments) and the next token.
  void writeComments(
      List<SourceComment> comments, int linesBeforeToken, String token) {
    // Corner case: if we require a blank line, but there exists one between
    // some of the comments, or after the last one, then we don't need to
    // enforce one before the first comment. Example:
    //
    //     library foo;
    //     // comment
    //
    //     class Bar {}
    //
    // Normally, a blank line is required after `library`, but since there is
    // one after the comment, we don't need one before it. This is mainly so
    // that commented out directives stick with their preceding group.
    if (_pendingWhitespace == Whitespace.twoNewlines &&
        comments.first.linesBefore < 2) {
      if (linesBeforeToken > 1) {
        _pendingWhitespace = Whitespace.newline;
      } else {
        for (var i = 1; i < comments.length; i++) {
          if (comments[i].linesBefore > 1) {
            _pendingWhitespace = Whitespace.newline;
            break;
          }
        }
      }
    }

    // Corner case: if the comments are completely inline (i.e. just a series
    // of block comments with no newlines before, after, or between them), then
    // they will eat any pending newlines. Make sure that doesn't happen by
    // putting the pending whitespace before the first comment and moving them
    // to their own line. Turns this:
    //
    //     library foo; /* a */ /* b */ import 'a.dart';
    //
    // into:
    //
    //     library foo;
    //
    //     /* a */ /* b */
    //     import 'a.dart';
    if (linesBeforeToken == 0 &&
        comments.every((comment) => comment.isInline)) {
      if (_pendingWhitespace.minimumLines > 0) {
        comments.first.linesBefore = _pendingWhitespace.minimumLines;
        linesBeforeToken = 1;
      }
    }

    // Write each comment and the whitespace between them.
    for (var i = 0; i < comments.length; i++) {
      var comment = comments[i];

      preserveNewlines(comment.linesBefore);

      // Don't emit a space because we'll handle it below. If we emit it here,
      // we may get a trailing space if the comment needs a line before it.
      if (_pendingWhitespace == Whitespace.space) {
        _pendingWhitespace = Whitespace.none;
      }
      _emitPendingWhitespace();

      if (comment.linesBefore == 0) {
        // If we're sitting on a split, move the comment before it to adhere it
        // to the preceding text.
        if (_shouldMoveCommentBeforeSplit(comment.text)) {
          _chunks.last.allowText();
        }

        // The comment follows other text, so we need to decide if it gets a
        // space before it or not.
        if (_needsSpaceBeforeComment(isLineComment: comment.isLineComment)) {
          _writeText(" ");
        }
      } else {
        // The comment starts a line, so make sure it stays on its own line.
        _writeHardSplit(
            nest: true,
            flushLeft: comment.flushLeft,
            double: comment.linesBefore > 1);
      }

      _writeText(comment.text);

      if (comment.selectionStart != null) {
        startSelectionFromEnd(comment.text.length - comment.selectionStart);
      }

      if (comment.selectionEnd != null) {
        endSelectionFromEnd(comment.text.length - comment.selectionEnd);
      }

      // Make sure there is at least one newline after a line comment and allow
      // one or two after a block comment that has nothing after it.
      var linesAfter;
      if (i < comments.length - 1) {
        linesAfter = comments[i + 1].linesBefore;
      } else {
        linesAfter = linesBeforeToken;

        // Always force a newline after multi-line block comments. Prevents
        // mistakes like:
        //
        //     /**
        //      * Some doc comment.
        //      */ someFunction() { ... }
        if (linesAfter == 0 && comments.last.text.contains("\n")) {
          linesAfter = 1;
        }
      }

      if (linesAfter > 0) _writeHardSplit(nest: true, double: linesAfter > 1);
    }

    // If the comment has text following it (aside from a grouping character),
    // it needs a trailing space.
    if (_needsSpaceAfterLastComment(comments, token)) {
      _pendingWhitespace = Whitespace.space;
    }

    preserveNewlines(linesBeforeToken);
  }

  /// If the current pending whitespace allows some source discretion, pins
  /// that down given that the source contains [numLines] newlines at that
  /// point.
  void preserveNewlines(int numLines) {
    // If we didn't know how many newlines the user authored between the last
    // token and this one, now we do.
    switch (_pendingWhitespace) {
      case Whitespace.spaceOrNewline:
        if (numLines > 0) {
          _pendingWhitespace = Whitespace.nestedNewline;
        } else {
          _pendingWhitespace = Whitespace.space;
        }
        break;

      case Whitespace.oneOrTwoNewlines:
        if (numLines > 1) {
          _pendingWhitespace = Whitespace.twoNewlines;
        } else {
          _pendingWhitespace = Whitespace.newline;
        }
        break;
    }
  }

  /// Creates a new indentation level [spaces] deeper than the current one.
  ///
  /// If omitted, [spaces] defaults to [Indent.block].
  void indent([int spaces]) {
    _nesting.indent(spaces);
  }

  /// Discards the most recent indentation level.
  void unindent() {
    _nesting.unindent();
  }

  /// Starts a new span with [cost].
  ///
  /// Each call to this needs a later matching call to [endSpan].
  void startSpan([int cost = Cost.normal]) {
    _openSpans.add(new OpenSpan(_currentChunkIndex, cost));
  }

  /// Ends the innermost span.
  void endSpan() {
    var openSpan = _openSpans.removeLast();

    // A span that just covers a single chunk can't be split anyway.
    var end = _currentChunkIndex;
    if (openSpan.start == end) return;

    // Add the span to every chunk that can split it.
    var span = new Span(openSpan.cost);
    for (var i = openSpan.start; i < end; i++) {
      var chunk = _chunks[i];
      if (!chunk.isHardSplit) chunk.spans.add(span);
    }
  }

  /// Starts a new [Rule].
  ///
  /// If omitted, defaults to a new [SimpleRule].
  void startRule([Rule rule]) {
    if (rule == null) rule = new SimpleRule();

    // See if any of the rules that contain this one care if it splits.
    _rules.forEach((outer) => outer.contain(rule));
    _rules.add(rule);
  }

  /// Starts a new [Rule] that comes into play *after* the next whitespace
  /// (including comments) is written.
  ///
  /// This is used for binary operators who want to start a rule before the
  /// first operand but not get forced to split if a comment appears before the
  /// entire expression.
  ///
  /// If [rule] is omitted, defaults to a new [SimpleRule].
  void startLazyRule([Rule rule]) {
    if (rule == null) rule = new SimpleRule();

    _lazyRules.add(rule);
  }

  /// Ends the innermost rule.
  void endRule() {
    _rules.removeLast();
  }

  /// Pre-emptively forces all of the current rules to become hard splits.
  ///
  /// This is called by [SourceVisitor] when it can determine that a rule will
  /// will always be split. Turning it (and the surrounding rules) into hard
  /// splits lets the writer break the output into smaller pieces for the line
  /// splitter, which helps performance and avoids failing on very large input.
  ///
  /// In particular, it's easy for the visitor to know that collections with a
  /// large number of items must split. Doing that early avoids crashing the
  /// splitter when it tries to recurse on huge collection literals.
  void forceRules() => _handleHardSplit();

  /// Begins a new expression nesting level [indent] spaces deeper than the
  /// current one if it splits.
  ///
  /// If [indent] is omitted, defaults to [Indent.expression]. If [now] is
  /// `true`, commits the nesting change immediately instead of waiting until
  /// after the next chunk of text is written.
  void nestExpression({int indent, bool now}) {
    if (now == null) now = false;

    _nesting.nest(indent);
    if (now) _nesting.commitNesting();
  }

  /// Discards the most recent level of expression nesting.
  ///
  /// Expressions that are more nested will get increased indentation when split
  /// if the previous line has a lower level of nesting.
  void unnest() {
    _nesting.unnest();
  }

  /// Marks the selection starting point as occurring [fromEnd] characters to
  /// the left of the end of what's currently been written.
  ///
  /// It counts backwards from the end because this is called *after* the chunk
  /// of text containing the selection has been output.
  void startSelectionFromEnd(int fromEnd) {
    assert(_chunks.isNotEmpty);
    _chunks.last.startSelectionFromEnd(fromEnd);
  }

  /// Marks the selection ending point as occurring [fromEnd] characters to the
  /// left of the end of what's currently been written.
  ///
  /// It counts backwards from the end because this is called *after* the chunk
  /// of text containing the selection has been output.
  void endSelectionFromEnd(int fromEnd) {
    assert(_chunks.isNotEmpty);
    _chunks.last.endSelectionFromEnd(fromEnd);
  }

  /// Captures the current nesting level as marking where subsequent block
  /// arguments should start.
  void startBlockArgumentNesting() {
    _blockArgumentNesting.add(_nesting.currentNesting);
  }

  /// Releases the last nesting level captured by [startBlockArgumentNesting].
  void endBlockArgumentNesting() {
    _blockArgumentNesting.removeLast();
  }

  /// Starts a new block as a child of the current chunk.
  ///
  /// Nested blocks are handled using their own independent [LineWriter].
  ChunkBuilder startBlock() {
    var builder =
        new ChunkBuilder._(this, _formatter, _source, _chunks.last.blockChunks);

    // A block always starts off indented one level.
    builder.indent();

    return builder;
  }

  /// Ends this [ChunkBuilder], which must have been created by [startBlock()].
  ///
  /// Forces the chunk that owns the block to split if it can tell that the
  /// block contents will always split. It does that by looking for hard splits
  /// in the block. If [ignoredSplit] is given, that rule will be ignored
  /// when determining if a block contains a hard split. If [forceSplit] is
  /// `true`, the block is considered to always split.
  ///
  /// Returns the previous writer for the surrounding block.
  ChunkBuilder endBlock(HardSplitRule ignoredSplit, {bool forceSplit}) {
    _divideChunks();

    // If we don't already know if the block is going to split, see if it
    // contains any hard splits or is longer than a page.
    if (!forceSplit) {
      var length = 0;
      for (var chunk in _chunks) {
        length += chunk.length + chunk.unsplitBlockLength;
        if (length > _formatter.pageWidth) {
          forceSplit = true;
          break;
        }

        if (chunk.isHardSplit && chunk.rule != ignoredSplit) {
          forceSplit = true;
          break;
        }
      }
    }

    // If there is a hard newline within the block, force the surrounding rule
    // for it so that we apply that constraint.
    // TODO(rnystrom): This does the wrong thing when there is are multiple
    // block arguments. We correctly force the rule, but then it gets popped
    // off the writer's stack and it forgets it was forced. Can repro with:
    //
    // longFunctionName(
    //     [longElementName, longElementName, longElementName],
    //     [short]);
    if (forceSplit) _parent.forceRules();

    // Write the split for the block contents themselves.
    _parent._writeSplit(_parent._rules.last, _parent._blockArgumentNesting.last,
        flushLeft: _firstFlushLeft);
    return _parent;
  }

  /// Finishes writing and returns a [SourceCode] containing the final output
  /// and updated selection, if any.
  SourceCode end() {
    _writeHardSplit();
    _divideChunks();

    if (debug.traceChunkBuilder) {
      debug.log(debug.green("\nBuilt:"));
      debug.dumpChunks(0, _chunks);
      debug.log();
    }

    var writer = new LineWriter(_formatter, _chunks);
    var result = writer.writeLines(_formatter.indent,
        isCompilationUnit: _source.isCompilationUnit);

    var selectionStart;
    var selectionLength;
    if (_source.selectionStart != null) {
      selectionStart = result.selectionStart;
      var selectionEnd = result.selectionEnd;

      // If we haven't hit the beginning and/or end of the selection yet, they
      // must be at the very end of the code.
      if (selectionStart == null) selectionStart = writer.length;
      if (selectionEnd == null) selectionEnd = writer.length;

      selectionLength = selectionEnd - selectionStart;
    }

    return new SourceCode(result.text,
        uri: _source.uri,
        isCompilationUnit: _source.isCompilationUnit,
        selectionStart: selectionStart,
        selectionLength: selectionLength);
  }

  /// Writes the current pending [Whitespace] to the output, if any.
  ///
  /// This should only be called after source lines have been preserved to turn
  /// any ambiguous whitespace into a concrete choice.
  void _emitPendingWhitespace() {
    // Output any pending whitespace first now that we know it won't be
    // trailing.
    switch (_pendingWhitespace) {
      case Whitespace.space:
        _writeText(" ");
        break;

      case Whitespace.newline:
        _writeHardSplit();
        break;

      case Whitespace.nestedNewline:
        _writeHardSplit(nest: true);
        break;

      case Whitespace.newlineFlushLeft:
        _writeHardSplit(nest: true, flushLeft: true);
        break;

      case Whitespace.twoNewlines:
        _writeHardSplit(double: true);
        break;

      case Whitespace.spaceOrNewline:
      case Whitespace.oneOrTwoNewlines:
        // We should have pinned these down before getting here.
        assert(false);
        break;
    }

    _pendingWhitespace = Whitespace.none;
  }

  /// Returns `true` if the last chunk is a split that should be moved after the
  /// comment that is about to be written.
  bool _shouldMoveCommentBeforeSplit(String comment) {
    // Not if there is nothing before it.
    if (_chunks.isEmpty) return false;

    // Multi-line comments are always pushed to the next line.
    if (comment.contains("\n")) return false;

    // If the text before the split is an open grouping character, we don't
    // want to adhere the comment to that.
    var text = _chunks.last.text;
    return !text.endsWith("(") && !text.endsWith("[") && !text.endsWith("{");
  }

  /// Returns `true` if a space should be output between the end of the current
  /// output and the subsequent comment which is about to be written.
  ///
  /// This is only called if the comment is trailing text in the unformatted
  /// source. In most cases, a space will be output to separate the comment
  /// from what precedes it. This returns false if:
  ///
  /// *   This comment does begin the line in the output even if it didn't in
  ///     the source.
  /// *   The comment is a block comment immediately following a grouping
  ///     character (`(`, `[`, or `{`). This is to allow `foo(/* comment */)`,
  ///     et. al.
  bool _needsSpaceBeforeComment({bool isLineComment}) {
    // Not at the start of the file.
    if (_chunks.isEmpty) return false;

    // Not at the start of a line.
    if (!_chunks.last.canAddText) return false;

    var text = _chunks.last.text;
    if (text.endsWith("\n")) return false;

    // Always put a space before line comments.
    if (isLineComment) return true;

    // Block comments do not get a space if following a grouping character.
    return !text.endsWith("(") && !text.endsWith("[") && !text.endsWith("{");
  }

  /// Returns `true` if a space should be output after the last comment which
  /// was just written and the token that will be written.
  bool _needsSpaceAfterLastComment(List<SourceComment> comments, String token) {
    // Not if there are no comments.
    if (comments.isEmpty) return false;

    // Not at the beginning of a line.
    if (!_chunks.last.canAddText) return false;

    // Otherwise, it gets a space if the following token is not a delimiter or
    // the empty string, for EOF.
    return token != ")" &&
        token != "]" &&
        token != "}" &&
        token != "," &&
        token != ";" &&
        token != "";
  }

  /// Appends a hard split with the current indentation and nesting (the latter
  /// only if [nest] is `true`).
  ///
  /// If [double] is `true` or `false`, forces a since or double line to be
  /// output. Otherwise, it is left indeterminate.
  ///
  /// If [flushLeft] is `true`, then the split will always cause the next line
  /// to be at column zero. Otherwise, it uses the normal indentation and
  /// nesting behavior.
  void _writeHardSplit({bool nest: false, bool double, bool flushLeft}) {
    // A hard split overrides any other whitespace.
    _pendingWhitespace = null;
    _writeSplit(new HardSplitRule(), nest ? null : _nesting.blockNesting,
        flushLeft: flushLeft, isDouble: double);
  }

  /// Ends the current chunk (if any) with the given split information.
  ///
  /// Returns the chunk.
  Chunk _writeSplit(Rule rule, NestingLevel nesting,
      {bool flushLeft, bool isDouble, bool spaceWhenUnsplit}) {
    if (_chunks.isEmpty) {
      if (flushLeft != null) _firstFlushLeft = flushLeft;

      return null;
    }

    if (nesting == null) nesting = _nesting.nesting;

    var chunk = _chunks.last;
    chunk.applySplit(rule, _nesting.indentation, nesting,
        flushLeft: flushLeft,
        isDouble: isDouble,
        spaceWhenUnsplit: spaceWhenUnsplit);

    // Keep track of which chunks are owned by the rule.
    if (rule is! HardSplitRule) {
      _ruleChunks.putIfAbsent(rule, () => []).add(_chunks.length - 1);
    }

    if (chunk.isHardSplit) _handleHardSplit();

    return chunk;
  }

  /// Writes [text] to either the current chunk or a new one if the current
  /// chunk is complete.
  void _writeText(String text) {
    if (_chunks.isNotEmpty && _chunks.last.canAddText) {
      _chunks.last.appendText(text);
    } else {
      _chunks.add(new Chunk(text));
    }
  }

  /// Returns true if we can divide the chunks at [index] and line split the
  /// ones before and after that separately.
  bool _canDivideAt(int i) {
    var chunk = _chunks[i];
    if (!chunk.isHardSplit) return false;
    if (chunk.nesting.isNested) return false;
    if (chunk.blockChunks.isNotEmpty) return false;

    // Make sure we don't split the line in the middle of a rule.
    var chunks = _ruleChunks[chunk.rule];
    if (chunks != null && chunks.any((other) => other > i)) return false;

    return true;
  }

  /// Pre-processes the chunks after they are done being written by the visitor
  /// but before they are run through the line splitter.
  ///
  /// Marks ranges of chunks that can be line split independently to keep the
  /// batches we send to [LineSplitter] small.
  void _divideChunks() {
    // Harden all of the rules that we know get forced by containing hard
    // splits, along with all of the other rules they constrain.
    _hardenRules();

    // Now that we know where all of the divided chunk sections are, mark the
    // chunks.
    for (var i = 0; i < _chunks.length; i++) {
      _chunks[i].markDivide(_canDivideAt(i));
    }
  }

  /// Hardens the active rules when a hard split occurs within them.
  void _handleHardSplit() {
    if (_rules.isEmpty) return;

    // If the current rule doesn't care, it will "eat" the hard split and no
    // others will care either.
    if (!_rules.last.splitsOnInnerRules) return;

    // Start with the innermost rule. This will traverse the other rules it
    // constrains.
    _hardSplitRules.add(_rules.last);
  }

  /// Replaces all of the previously hardened rules with hard splits, along
  /// with every rule that those constrain to also split.
  ///
  /// This should only be called after all chunks have been written.
  void _hardenRules() {
    if (_hardSplitRules.isEmpty) return;

    // Harden all of the rules that are constrained by [rules] as well.
    var hardenedRules = new Set();
    walkConstraints(rule) {
      if (hardenedRules.contains(rule)) return;
      hardenedRules.add(rule);

      // Follow this rule's constraints, recursively.
      for (var other in _ruleChunks.keys) {
        if (other == rule) continue;

        if (rule.constrain(rule.fullySplitValue, other) ==
            other.fullySplitValue) {
          walkConstraints(other);
        }
      }
    }

    for (var rule in _hardSplitRules) {
      walkConstraints(rule);
    }

    // Harden every chunk that uses one of these rules.
    for (var chunk in _chunks) {
      if (hardenedRules.contains(chunk.rule)) {
        chunk.harden();
      }
    }
  }
}
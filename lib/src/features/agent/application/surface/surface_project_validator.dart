import 'dart:convert';

import 'package:maaso/src/features/agent/application/surface/surface_project.dart';

class SurfaceProjectValidationException implements Exception {
  const SurfaceProjectValidationException(this.message);

  final String message;

  @override
  String toString() => message;
}

enum SurfaceJavaScriptRestrictionRule { reservedIdentifier, forbiddenMember }

/// Historical policy evidence. The name is from a fixed legacy vocabulary,
/// never an arbitrary variable, URL, exception message or authored source.
class SurfaceJavaScriptRestrictionFact {
  const SurfaceJavaScriptRestrictionFact._(
    this.rule,
    this.offendingName,
    this.utf16Offset,
  );
  final SurfaceJavaScriptRestrictionRule rule;
  final String offendingName;
  final int utf16Offset;
  String get diagnostic =>
      '${SurfaceProjectValidator.javaScriptRestrictionPrefix} '
      '(rule ${rule.name}, name $offendingName, UTF-16 offset $utf16Offset)';
}

/// A quoted module reference located by the existing lexical tokenizer.
/// These offsets select only the import/export specifier literal, never an
/// arbitrary matching string, comment, regular expression, or template body.
class SurfaceJavaScriptModuleReference {
  const SurfaceJavaScriptModuleReference(this.specifier, this.start, this.end);
  final String specifier;
  final int start, end;
}

/// Reuses lexical tokens solely for resource linking, not source admission.
/// An unfamiliar lexical form is left intact for the actual browser engine;
/// this reader never reports an unsupported-code or validation failure.
class SurfaceJavaScriptModuleReferences {
  const SurfaceJavaScriptModuleReferences._();

  static List<SurfaceJavaScriptModuleReference>? read(String source) {
    final tokens = _WorkerJavaScriptScanner(source).scan();
    if (tokens == null) return null;
    final references = <SurfaceJavaScriptModuleReference>[];
    void add(int index) {
      final token = tokens[index];
      if (token.kind != _WorkerJavaScriptTokenKind.string) return;
      final quote = source.codeUnitAt(token.sourceOffset);
      var end = token.sourceOffset + 1;
      while (end < source.length) {
        final character = source.codeUnitAt(end++);
        if (character == quote) {
          references.add(
            SurfaceJavaScriptModuleReference(
              token.value,
              token.sourceOffset,
              end,
            ),
          );
          return;
        }
        if (character == 0x5c && end < source.length) end++;
      }
    }

    void fromClause(int start) {
      var braces = 0;
      for (var index = start; index < tokens.length; index++) {
        final token = tokens[index];
        if (token.value == '{') {
          braces++;
        } else if (token.value == '}') {
          if (--braces < 0) return;
        } else if (braces == 0 && token.value == 'from') {
          if (index + 1 < tokens.length) add(index + 1);
          return;
        } else if (braces == 0 &&
            token.kind != _WorkerJavaScriptTokenKind.identifier &&
            !const {'*', ','}.contains(token.value)) {
          return;
        }
      }
    }

    for (var index = 0; index + 1 < tokens.length; index++) {
      final token = tokens[index];
      if (token.kind != _WorkerJavaScriptTokenKind.identifier ||
          (index > 0 && const {'.', '?.'}.contains(tokens[index - 1].value))) {
        continue;
      }
      final next = tokens[index + 1];
      if (token.value == 'import') {
        if (next.kind == _WorkerJavaScriptTokenKind.string) {
          add(index + 1);
        } else if (next.value == '(' &&
            index + 3 < tokens.length &&
            const {')', ','}.contains(tokens[index + 3].value)) {
          add(index + 2);
        } else if (next.value != '(' && next.value != '.') {
          fromClause(index + 1);
        }
      } else if (token.value == 'export' &&
          const {'*', '{'}.contains(next.value)) {
        fromClause(index + 1);
      }
    }
    return List.unmodifiable(references);
  }
}

class SurfaceProjectValidator {
  const SurfaceProjectValidator._();

  // A runtime/storage safety boundary, never a model output-token allowance or
  // a source authoring target. Multi-file generation keeps the complete source.
  static const maximumPublicSourceBytes = 8 * 1024 * 1024;
  static const javaScriptLexicalFailurePrefix =
      'public webApps JavaScript source cannot be lexically validated';
  static const javaScriptRestrictionPrefix =
      'public webApps JavaScript violates a runtime policy rule';

  static SurfaceJavaScriptRestrictionFact? javaScriptRestrictionFact(
    String diagnostic,
  ) {
    final pattern = RegExp(
      '^${RegExp.escape(javaScriptRestrictionPrefix)} '
      r'\(rule (reservedIdentifier|forbiddenMember), name ([A-Za-z_$][A-Za-z0-9_$]*), UTF-16 offset ([0-9]{1,7})\)$',
    );
    final facts = <SurfaceJavaScriptRestrictionFact>[];
    for (final issue in diagnostic.split(';')) {
      final match = pattern.firstMatch(issue.trim());
      if (match == null) continue;
      final rule = SurfaceJavaScriptRestrictionRule.values
          .where((value) => value.name == match[1])
          .firstOrNull;
      final name = match[2]!;
      final offset = int.tryParse(match[3]!);
      if (rule == null || offset == null || offset > maximumPublicSourceBytes) {
        return null;
      }
      final known = rule == SurfaceJavaScriptRestrictionRule.reservedIdentifier
          ? _historicalJavaScriptIdentifierNames.contains(name)
          : _historicalJavaScriptMemberNames.contains(name);
      if (!known) return null;
      facts.add(SurfaceJavaScriptRestrictionFact._(rule, name, offset));
    }
    return facts.length == 1 ? facts.single : null;
  }

  /// Compatibility for persisted failures from the retired webApp scanner.
  /// Current source is admitted by the Web engine, not this historical rule.
  static String javaScriptRestrictionRepairHint(String diagnostic) {
    if (javaScriptRestrictionFact(diagnostic) == null) return '';
    return 'This historical webApp scanner policy has been retired. '
        'Revalidate the current project in its Web runtime. '
        'Do not rename bindings, rewrite valid JavaScript, remove dependencies, '
        'or change gameplay to satisfy this old restriction.';
  }

  /// Historical closed scanner fact, not an engine SyntaxError or its origin.
  /// This decoder never scans current source. EOF in an old scanner diagnostic
  /// can indicate an earlier unclosed delimiter. Offsets use UTF-16 code units
  /// in the assembled JavaScript and never carry source/exception text.
  static int? javaScriptLexicalFailureOffset(String diagnostic) {
    final pattern = RegExp(
      '^${RegExp.escape(javaScriptLexicalFailurePrefix)} '
      r'\(UTF-16 offset ([0-9]{1,7})\)$',
    );
    final offsets = <int>[];
    for (final issue in diagnostic.split(';')) {
      final match = pattern.firstMatch(issue.trim());
      if (match == null) continue;
      final offset = int.tryParse(match[1]!);
      if (offset == null || offset > maximumPublicSourceBytes) return null;
      offsets.add(offset);
    }
    return offsets.length == 1 ? offsets.single : null;
  }

  static void validateForShow(SurfaceProject project) {
    final issues = diagnoseForShow(project);
    if (issues.isEmpty) return;
    throw SurfaceProjectValidationException(issues.join('; '));
  }

  static List<String> diagnoseForShow(SurfaceProject project) {
    if (project.rendering == SurfaceRendering.projectBundle) {
      return const [
        'project bundles require the verified installation entry point',
      ];
    }
    final issues = <String>[...project.manifest.diagnoseContract()];
    final html = project.html.trim();
    final js = project.js.trim();
    final isWebApp = project.rendering == SurfaceRendering.webApp;

    // HTML may construct the entire app with inline/module scripts, or the
    // JavaScript entry may build its DOM from scratch. Browser syntax, style,
    // dependencies and first-frame errors are diagnosed by the actual engine.
    if (isWebApp && html.isEmpty && js.isEmpty) {
      issues.add('webApp must contain authored HTML or JavaScript');
    }

    if (project.experienceType == SurfaceExperienceType.game &&
        project.rendering != SurfaceRendering.workerCanvas &&
        !isWebApp) {
      issues.add('game surfaces must use webApp or workerCanvas rendering');
    }

    if (project.rendering == SurfaceRendering.workerCanvas) {
      if (project.html.isNotEmpty) {
        issues.add('workerCanvas html must be empty because the host owns it');
      }
      if (project.css.isNotEmpty) {
        issues.add(
          'workerCanvas css must be empty because the host owns layout',
        );
      }
      if (!_usesWorkerCanvasContract(js)) {
        issues.add(
          'workerCanvas js must call Game.define with init, update, draw, and input',
        );
      }
      if (_usesForbiddenWorkerApi(js)) {
        issues.add('workerCanvas js must use only the declarative Game API');
      }
    }

    if (!isWebApp &&
        project.rendering != SurfaceRendering.workerCanvas &&
        (html.isEmpty || !_hasVisibleContentOrRenderHost(html, js))) {
      issues.add('surface html must contain visible content or a render host');
    }

    if (!isWebApp && _requiresStartupScript(project) && js.isEmpty) {
      issues.add('interactive surface js must not be empty');
    }

    if (!isWebApp && (_looksPlaceholder(html) || _looksPlaceholder(js))) {
      issues.add('surface source must not be placeholder-only content');
    }

    if (!isWebApp && _usesRemoteUrl(project)) {
      issues.add('surface source must not reference remote URLs');
    }

    return issues;
  }

  static void validateForPublicGame(SurfaceProject project) {
    final issues = diagnoseForPublicGame(project);
    if (issues.isEmpty) return;
    throw SurfaceProjectValidationException(issues.join('; '));
  }

  static void validateForPublicApplet(SurfaceProject project) {
    final issues = diagnoseForPublicApplet(project);
    if (issues.isEmpty) return;
    throw SurfaceProjectValidationException(issues.join('; '));
  }

  static List<String> diagnoseForPublicApplet(SurfaceProject project) {
    final issues = diagnoseForShow(project);
    final isWorkerCanvas = project.rendering == SurfaceRendering.workerCanvas;
    final isWebApp = project.rendering == SurfaceRendering.webApp;
    if (!isWorkerCanvas && !isWebApp) {
      issues.add('public Applets must use webApp or workerCanvas rendering');
    }
    final sourceBytes =
        utf8.encode(project.html).length +
        utf8.encode(project.css).length +
        utf8.encode(project.js).length;
    if (sourceBytes > maximumPublicSourceBytes) {
      issues.add('public Applet source is too large');
    }
    final lowerHTML = project.html.toLowerCase();
    final lowerCSS = project.css.toLowerCase();
    final lowerJS = project.js.toLowerCase();
    if (!isWebApp &&
        (lowerHTML.contains('javascript:') ||
            lowerHTML.contains('http://') ||
            lowerHTML.contains('https://') ||
            lowerCSS.contains('</style') ||
            lowerCSS.contains('http://') ||
            lowerCSS.contains('https://') ||
            lowerJS.contains('</script') ||
            lowerJS.contains('http://') ||
            lowerJS.contains('https://'))) {
      issues.add('public Applets must be self-contained');
    }
    if (isWorkerCanvas && _usesForbiddenWorkerApi(project.js)) {
      issues.add('public Applets must not use network or cross-frame APIs');
    }
    if (!isWebApp) {
      if (RegExp(
        r'<\s*/?\s*(a|area|script|style|iframe|form|meta|base|link|object|embed)\b',
        caseSensitive: false,
      ).hasMatch(project.html)) {
        issues.add('public Applets must not contain blocked HTML tags');
      }
      if (RegExp(
        r'(?:\s|/)\s*on[a-z0-9_-]+\s*=',
        caseSensitive: false,
      ).hasMatch(project.html)) {
        issues.add('public Applets must bind controls through the Game API');
      }
    }
    return issues.toSet().toList(growable: false);
  }

  static List<String> diagnoseForPublicGame(SurfaceProject project) {
    final issues = diagnoseForPublicApplet(project).toList(growable: true);
    if (project.experienceType != SurfaceExperienceType.game) {
      issues.add('only game surfaces can be published');
    }
    return issues.toSet().toList(growable: false);
  }

  static bool _requiresStartupScript(SurfaceProject project) {
    return switch (project.rendering) {
      SurfaceRendering.canvas ||
      SurfaceRendering.three ||
      SurfaceRendering.pixi ||
      SurfaceRendering.hybrid ||
      SurfaceRendering.webApp ||
      SurfaceRendering.workerCanvas ||
      SurfaceRendering.projectBundle => true,
      SurfaceRendering.dom || SurfaceRendering.svg => false,
    };
  }

  static bool _hasVisibleContentOrRenderHost(String html, String js) {
    final lower = html.toLowerCase();
    if (RegExp(
      r'<\s*(canvas|svg|img|video|iframe|button|input|textarea|select)\b',
    ).hasMatch(lower)) {
      return true;
    }

    if (RegExp(
      r'''\s(id|class|data-surface-root)\s*=\s*["'][^"']+["']''',
    ).hasMatch(lower)) {
      return true;
    }

    final text = html
        .replaceAll(
          RegExp(r'<script\b[\s\S]*?</script>', caseSensitive: false),
          '',
        )
        .replaceAll(
          RegExp(r'<style\b[\s\S]*?</style>', caseSensitive: false),
          '',
        )
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll(RegExp(r'&nbsp;|&#160;', caseSensitive: false), ' ')
        .trim();
    if (text.isNotEmpty) return true;

    final scriptCreatesHost = RegExp(
      r'''createElement\s*\(\s*["'](canvas|svg|div|main|section)''',
      caseSensitive: false,
    ).hasMatch(js);
    return scriptCreatesHost;
  }

  static bool _usesWorkerCanvasContract(String js) {
    if (!RegExp(r'\bGame\s*\.\s*define\s*\(').hasMatch(js)) return false;
    for (final callback in const ['init', 'update', 'draw', 'input']) {
      if (!RegExp('\\b$callback\\s*(?::|\\()').hasMatch(js)) return false;
    }
    return true;
  }

  static bool _usesForbiddenWorkerApi(String js) {
    final tokens = _WorkerJavaScriptScanner(js).scan();
    if (tokens == null) return true;

    for (var index = 0; index < tokens.length; index += 1) {
      final token = tokens[index];
      if (token.kind == _WorkerJavaScriptTokenKind.identifier) {
        if (token.value == 'this' ||
            _isAlwaysForbiddenWorkerIdentifier(token.value) ||
            token.value == '__proto__') {
          return true;
        }
        if (token.value == 'constructor' &&
            index > 0 &&
            const {'.', '?.'}.contains(tokens[index - 1].value)) {
          return true;
        }
        if (_ambientWorkerGlobals.contains(token.value) &&
            !_isWorkerDataProperty(tokens, index)) {
          return true;
        }
      }

      if (token.kind == _WorkerJavaScriptTokenKind.string &&
          _isForbiddenComputedWorkerMember(tokens, index)) {
        return true;
      }
    }
    return false;
  }

  static const Set<String> _ambientWorkerGlobals = {
    'window',
    'document',
    'self',
    'globalThis',
    'navigator',
    'location',
    'history',
    'top',
    'parent',
    'opener',
    'localStorage',
    'sessionStorage',
    'indexedDB',
    'caches',
    'serviceWorker',
    'sharedStorage',
    'scheduler',
  };

  static const Set<String> _alwaysForbiddenWorkerIdentifiers = {
    'fetch',
    'XMLHttpRequest',
    'WebSocket',
    'WebSocketStream',
    'EventSource',
    'importScripts',
    'Worker',
    'SharedWorker',
    'BroadcastChannel',
    'MessageChannel',
    'MessagePort',
    'postMessage',
    'addEventListener',
    'removeEventListener',
    'dispatchEvent',
    'requestAnimationFrame',
    'cancelAnimationFrame',
    'requestIdleCallback',
    'cancelIdleCallback',
    'setImmediate',
    'clearImmediate',
    'setTimeout',
    'clearTimeout',
    'setInterval',
    'clearInterval',
    'queueMicrotask',
    'eval',
    'WebAssembly',
    'WebTransport',
    'OffscreenCanvas',
    'OffscreenCanvasRenderingContext2D',
    'createImageBitmap',
    'getContext',
    'Notification',
    'Cache',
    'CacheStorage',
    'StorageManager',
    'Scheduler',
    'TaskController',
    'TaskSignal',
    'openDatabase',
    'requestFileSystem',
    'webkitRequestFileSystem',
    'RTCPeerConnection',
    'webkitRTCPeerConnection',
    'mozRTCPeerConnection',
    'RTCDataChannel',
    'RTCIceTransport',
    'RTCIceGatherer',
    'RTCIceCandidate',
    'RTCSessionDescription',
    'RTCDtlsTransport',
    'RTCSctpTransport',
    'RTCQuicTransport',
    'import',
    'sendBeacon',
    'async',
    'await',
    'Promise',
    'Function',
    'AsyncFunction',
    'GeneratorFunction',
    'AsyncGeneratorFunction',
  };

  static bool _isAlwaysForbiddenWorkerIdentifier(String identifier) {
    return _alwaysForbiddenWorkerIdentifiers.contains(identifier) ||
        identifier.startsWith('FileSystem') ||
        identifier.startsWith('IDB');
  }

  static bool _isWorkerDataProperty(
    List<_WorkerJavaScriptToken> tokens,
    int index,
  ) {
    if (index > 0 &&
        index + 1 < tokens.length &&
        tokens[index + 1].value == ':' &&
        tokens[index].inObjectLiteral &&
        const {'{', ','}.contains(tokens[index - 1].value)) {
      return true;
    }
    if (index == 0 || !const {'.', '?.'}.contains(tokens[index - 1].value)) {
      return false;
    }

    final receiverIndex = index - 2;
    return receiverIndex < 0 || tokens[receiverIndex].value != 'this';
  }

  static bool _isForbiddenComputedWorkerMember(
    List<_WorkerJavaScriptToken> tokens,
    int index,
  ) {
    if (index == 0 ||
        index + 1 >= tokens.length ||
        tokens[index - 1].value != '[' ||
        tokens[index + 1].value != ']') {
      return false;
    }

    final member = tokens[index].value;
    if (member == 'constructor' ||
        member == '__proto__' ||
        _isAlwaysForbiddenWorkerIdentifier(member)) {
      return true;
    }
    if (!_ambientWorkerGlobals.contains(member)) return false;

    var receiverIndex = index - 2;
    if (receiverIndex >= 0 && tokens[receiverIndex].value == '?.') {
      receiverIndex -= 1;
    }
    return receiverIndex >= 0 && tokens[receiverIndex].value == 'this';
  }

  // Compatibility data for old persisted diagnostics, not an authoring policy.
  // Current webApp admission never scans source against this vocabulary.
  static const Set<String> _historicalJavaScriptIdentifierNames = {
    'AsyncFunction',
    'AsyncGeneratorFunction',
    'BroadcastChannel',
    'Cache',
    'CacheStorage',
    'EventSource',
    'FileSystem',
    'FileSystemFamily',
    'Function',
    'GeneratorFunction',
    'IDBFactory',
    'IDBFamily',
    'MessageChannel',
    'MessagePort',
    'Notification',
    'Object',
    'RTCCertificate',
    'RTCDataChannel',
    'RTCDtlsTransport',
    'RTCIceCandidate',
    'RTCIceGatherer',
    'RTCIceTransport',
    'RTCPeerConnection',
    'RTCQuicTransport',
    'RTCSctpTransport',
    'RTCSessionDescription',
    'Reflect',
    'SharedWorker',
    'StorageManager',
    'SurfaceValidationLifecycle',
    'WebAssembly',
    'WebSocket',
    'WebSocketStream',
    'WebTransport',
    'Worker',
    'XMLHttpRequest',
    'caches',
    'document',
    'eval',
    'export',
    'fetch',
    'globalThis',
    'history',
    'import',
    'importScripts',
    'indexedDB',
    'localStorage',
    'location',
    'messageHandlers',
    'mozRTCPeerConnection',
    'navigator',
    'open',
    'openDatabase',
    'opener',
    'parent',
    'postMessage',
    'requestFileSystem',
    'self',
    'sendBeacon',
    'serviceWorker',
    'sessionStorage',
    'sharedStorage',
    'this',
    'top',
    'webkit',
    'webkitRTCPeerConnection',
    'webkitRequestFileSystem',
    'window',
    'with',
  };

  static const Set<String> _historicalJavaScriptMemberNames = {
    'SurfaceValidationLifecycle',
    '__defineGetter__',
    '__defineSetter__',
    '__lookupGetter__',
    '__lookupSetter__',
    '__proto__',
    'action',
    'apply',
    'assign',
    'bind',
    'call',
    'constructor',
    'cookie',
    'defaultView',
    'defineProperties',
    'defineProperty',
    'domain',
    'formAction',
    'getBoundingClientRect',
    'getElementById',
    'getPrototypeOf',
    'href',
    'innerHTML',
    'insertAdjacentHTML',
    'messageHandlers',
    'outerHTML',
    'prototype',
    'querySelector',
    'setAttribute',
    'setAttributeNS',
    'setPrototypeOf',
    'src',
    'srcdoc',
    'webkit',
    'write',
    'writeln',
  };

  static bool _looksPlaceholder(String source) {
    final normalized = source.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    if (normalized.isEmpty) return false;
    const placeholders = [
      'todo',
      'coming soon',
      'placeholder',
      'under construction',
      'not implemented',
    ];
    return placeholders.any((marker) => normalized == marker);
  }

  static bool _usesRemoteUrl(SurfaceProject project) {
    return _htmlUsesRemoteUrl(project.html) ||
        _cssUsesRemoteUrl(project.css) ||
        _cssUsesRemoteUrl(project.html) ||
        _jsUsesRemoteUrl(project.js);
  }

  static bool _htmlUsesRemoteUrl(String source) {
    return RegExp(
          r'''\b(?:src|href|poster|data|action|formaction|xlink:href)\s*=\s*(?:"\s*(?:https?:)?//|'\s*(?:https?:)?//|(?:https?:)?//)''',
          caseSensitive: false,
        ).hasMatch(source) ||
        RegExp(
          r'''\bsrcset\s*=\s*(?:"[^"]*(?:https?:)?//|'[^']*(?:https?:)?//|[^\s>]*(?:https?:)?//)''',
          caseSensitive: false,
        ).hasMatch(source);
  }

  static bool _cssUsesRemoteUrl(String source) {
    return RegExp(
          r'''\burl\s*\(\s*(?:"\s*(?:https?:)?//|'\s*(?:https?:)?//|(?:https?:)?//)''',
          caseSensitive: false,
        ).hasMatch(source) ||
        RegExp(
          r'''@import\s+(?:url\s*\(\s*)?(?:"\s*(?:https?:)?//|'\s*(?:https?:)?//|(?:https?:)?//)''',
          caseSensitive: false,
        ).hasMatch(source);
  }

  static bool _jsUsesRemoteUrl(String source) {
    return RegExp(
      r'''["'`]\s*(?:https?:)?//''',
      caseSensitive: false,
    ).hasMatch(source);
  }
}

enum _WorkerJavaScriptTokenKind {
  identifier,
  string,
  number,
  literal,
  punctuator,
  controlCloseParenthesis,
  statementCloseBrace,
}

class _WorkerJavaScriptToken {
  const _WorkerJavaScriptToken(
    this.kind,
    this.value, {
    this.inObjectLiteral = false,
    this.sourceOffset = 0,
  });

  final _WorkerJavaScriptTokenKind kind;
  final String value;
  final bool inObjectLiteral;
  final int sourceOffset;
}

class _WorkerJavaScriptScanner {
  _WorkerJavaScriptScanner(this.source);

  final String source;
  final List<_WorkerJavaScriptToken> _tokens = <_WorkerJavaScriptToken>[];
  int? failureOffset;

  List<_WorkerJavaScriptToken>? scan() {
    final result = _scanCode(0, stopAtTemplateBrace: false);
    if (!result.isValid || result.nextIndex != source.length) {
      failureOffset = result.nextIndex;
      return null;
    }
    failureOffset = null;
    return List<_WorkerJavaScriptToken>.unmodifiable(_tokens);
  }

  _WorkerJavaScriptScanResult _scanCode(
    int start, {
    required bool stopAtTemplateBrace,
  }) {
    var index = start;
    var braceDepth = 0;
    var parenthesisDepth = 0;
    var bracketDepth = 0;
    final braceContexts = <bool>[];
    final statementBraceContexts = <bool>[];
    final parenthesisContexts = <bool>[];
    final delimiters = <({String value, int offset})>[];

    while (index < source.length) {
      final codeUnit = source.codeUnitAt(index);
      if (_isWhitespace(codeUnit)) {
        index += 1;
        continue;
      }

      if (codeUnit == 0x5C) {
        // JavaScript permits Unicode escapes inside identifiers. Rejecting
        // them keeps blocked global names from being disguised as \uXXXX.
        return _WorkerJavaScriptScanResult.invalid(index);
      }

      if (codeUnit == 0x2F && index + 1 < source.length) {
        final next = source.codeUnitAt(index + 1);
        if (next == 0x2F) {
          index = _skipLineComment(index + 2);
          continue;
        }
        if (next == 0x2A) {
          final commentEnd = _skipBlockComment(index + 2);
          if (commentEnd < 0) {
            return _WorkerJavaScriptScanResult.invalid(index);
          }
          index = commentEnd;
          continue;
        }
        if (_canStartRegularExpression()) {
          final expressionEnd = _skipRegularExpression(index);
          if (expressionEnd < 0) {
            return _WorkerJavaScriptScanResult.invalid(index);
          }
          _tokens.add(
            _WorkerJavaScriptToken(
              _WorkerJavaScriptTokenKind.literal,
              'regexp',
              sourceOffset: index,
            ),
          );
          index = expressionEnd;
          continue;
        }
      }

      if (codeUnit == 0x27 || codeUnit == 0x22) {
        final stringResult = _scanString(index, codeUnit);
        if (!stringResult.isValid) {
          return _WorkerJavaScriptScanResult.invalid(index);
        }
        _tokens.add(
          _WorkerJavaScriptToken(
            _WorkerJavaScriptTokenKind.string,
            stringResult.value,
            sourceOffset: index,
          ),
        );
        index = stringResult.nextIndex;
        continue;
      }

      if (codeUnit == 0x60) {
        final templateEnd = _scanTemplate(index + 1);
        if (templateEnd < 0) {
          return _WorkerJavaScriptScanResult.invalid(index);
        }
        _tokens.add(
          _WorkerJavaScriptToken(
            _WorkerJavaScriptTokenKind.literal,
            'template',
            sourceOffset: index,
          ),
        );
        index = templateEnd;
        continue;
      }

      if (_isIdentifierStart(codeUnit)) {
        final end = _identifierEnd(index + 1);
        _tokens.add(
          _WorkerJavaScriptToken(
            _WorkerJavaScriptTokenKind.identifier,
            source.substring(index, end),
            sourceOffset: index,
            inObjectLiteral: braceContexts.isNotEmpty && braceContexts.last,
          ),
        );
        index = end;
        continue;
      }

      if (_isDecimalDigit(codeUnit)) {
        final end = _numberEnd(index);
        _tokens.add(
          _WorkerJavaScriptToken(
            _WorkerJavaScriptTokenKind.number,
            source.substring(index, end),
            sourceOffset: index,
          ),
        );
        index = end;
        continue;
      }

      final punctuator = _punctuatorAt(index);
      if (punctuator == null) {
        return _WorkerJavaScriptScanResult.invalid(index);
      }

      var tokenKind = _WorkerJavaScriptTokenKind.punctuator;
      if (const {'(', '[', '{'}.contains(punctuator)) {
        delimiters.add((value: punctuator, offset: index));
      } else if (const {')', ']', '}'}.contains(punctuator) &&
          !(punctuator == '}' &&
              braceDepth == 0 &&
              stopAtTemplateBrace &&
              delimiters.isEmpty)) {
        if (delimiters.isEmpty) {
          return _WorkerJavaScriptScanResult.invalid(index);
        }
        final expected = switch (punctuator) {
          ')' => '(',
          ']' => '[',
          _ => '{',
        };
        if (delimiters.last.value != expected) {
          // Independent depth counters used to carry a missing ')' through
          // the rest of the project and report only EOF. Preserve the actual
          // unmatched opening location without exposing authored error text.
          return _WorkerJavaScriptScanResult.invalid(delimiters.last.offset);
        }
        delimiters.removeLast();
      }
      if (punctuator == '{') {
        final startsObjectLiteral = _startsObjectLiteral();
        braceContexts.add(startsObjectLiteral);
        statementBraceContexts.add(
          !startsObjectLiteral && _startsStatementBlock(),
        );
        braceDepth += 1;
      } else if (punctuator == '}') {
        if (braceDepth == 0 && stopAtTemplateBrace) {
          if (parenthesisDepth != 0 || bracketDepth != 0) {
            return _WorkerJavaScriptScanResult.invalid(index);
          }
          return _WorkerJavaScriptScanResult.valid(index + 1);
        }
        if (braceDepth == 0) {
          return _WorkerJavaScriptScanResult.invalid(index);
        }
        braceDepth -= 1;
        if (braceContexts.isEmpty || statementBraceContexts.isEmpty) {
          return _WorkerJavaScriptScanResult.invalid(index);
        }
        braceContexts.removeLast();
        if (statementBraceContexts.removeLast()) {
          tokenKind = _WorkerJavaScriptTokenKind.statementCloseBrace;
        }
      } else if (punctuator == '(') {
        final previous = _tokens.isEmpty ? null : _tokens.last;
        final beforePrevious = _tokens.length < 2
            ? null
            : _tokens[_tokens.length - 2];
        parenthesisContexts.add(
          previous?.kind == _WorkerJavaScriptTokenKind.identifier &&
              const {
                'if',
                'while',
                'for',
                'with',
                'switch',
                'catch',
              }.contains(previous?.value) &&
              !const {'.', '?.'}.contains(beforePrevious?.value),
        );
        parenthesisDepth += 1;
      } else if (punctuator == ')') {
        if (parenthesisDepth == 0 || parenthesisContexts.isEmpty) {
          return _WorkerJavaScriptScanResult.invalid(index);
        }
        parenthesisDepth -= 1;
        if (parenthesisContexts.removeLast()) {
          tokenKind = _WorkerJavaScriptTokenKind.controlCloseParenthesis;
        }
      } else if (punctuator == '[') {
        bracketDepth += 1;
      } else if (punctuator == ']') {
        if (bracketDepth == 0) {
          return _WorkerJavaScriptScanResult.invalid(index);
        }
        bracketDepth -= 1;
      }

      _tokens.add(
        _WorkerJavaScriptToken(tokenKind, punctuator, sourceOffset: index),
      );
      index += punctuator.length;
    }

    if (stopAtTemplateBrace ||
        braceDepth != 0 ||
        parenthesisDepth != 0 ||
        bracketDepth != 0 ||
        braceContexts.isNotEmpty ||
        statementBraceContexts.isNotEmpty) {
      return _WorkerJavaScriptScanResult.invalid(index);
    }
    return _WorkerJavaScriptScanResult.valid(index);
  }

  int _scanTemplate(int start) {
    var index = start;
    while (index < source.length) {
      final codeUnit = source.codeUnitAt(index);
      if (codeUnit == 0x5C) {
        if (index + 1 >= source.length) return -1;
        index += 2;
        continue;
      }
      if (codeUnit == 0x60) return index + 1;
      if (codeUnit == 0x24 &&
          index + 1 < source.length &&
          source.codeUnitAt(index + 1) == 0x7B) {
        _tokens.add(
          const _WorkerJavaScriptToken(
            _WorkerJavaScriptTokenKind.punctuator,
            r'${',
          ),
        );
        final expression = _scanCode(index + 2, stopAtTemplateBrace: true);
        if (!expression.isValid) return -1;
        index = expression.nextIndex;
        continue;
      }
      index += 1;
    }
    return -1;
  }

  _WorkerJavaScriptStringResult _scanString(int start, int quote) {
    final value = StringBuffer();
    var index = start + 1;
    while (index < source.length) {
      final codeUnit = source.codeUnitAt(index);
      if (codeUnit == quote) {
        return _WorkerJavaScriptStringResult.valid(index + 1, value.toString());
      }
      if (codeUnit == 0x0A || codeUnit == 0x0D) {
        return _WorkerJavaScriptStringResult.invalid(index);
      }
      if (codeUnit != 0x5C) {
        value.writeCharCode(codeUnit);
        index += 1;
        continue;
      }

      if (index + 1 >= source.length) {
        return _WorkerJavaScriptStringResult.invalid(index);
      }
      final escaped = source.codeUnitAt(index + 1);
      if (escaped == 0x0A) {
        index += 2;
        continue;
      }
      if (escaped == 0x0D) {
        index +=
            index + 2 < source.length && source.codeUnitAt(index + 2) == 0x0A
            ? 3
            : 2;
        continue;
      }
      if (escaped == 0x78) {
        final decoded = _decodeFixedHex(index + 2, 2);
        if (decoded == null) {
          return _WorkerJavaScriptStringResult.invalid(index);
        }
        value.writeCharCode(decoded);
        index += 4;
        continue;
      }
      if (escaped == 0x75) {
        final unicode = _decodeUnicodeEscape(index + 2);
        if (!unicode.isValid) {
          return _WorkerJavaScriptStringResult.invalid(index);
        }
        value.write(String.fromCharCode(unicode.codePoint));
        index = unicode.nextIndex;
        continue;
      }
      if (_isDecimalDigit(escaped) && escaped != 0x30) {
        return _WorkerJavaScriptStringResult.invalid(index);
      }
      value.writeCharCode(_simpleEscapeValue(escaped));
      index += 2;
    }
    return _WorkerJavaScriptStringResult.invalid(index);
  }

  _WorkerJavaScriptUnicodeResult _decodeUnicodeEscape(int start) {
    if (start < source.length && source.codeUnitAt(start) == 0x7B) {
      final close = source.indexOf('}', start + 1);
      if (close < 0 || close == start + 1 || close - start > 7) {
        return _WorkerJavaScriptUnicodeResult.invalid(start);
      }
      final digits = source.substring(start + 1, close);
      final codePoint = int.tryParse(digits, radix: 16);
      if (codePoint == null || codePoint > 0x10FFFF) {
        return _WorkerJavaScriptUnicodeResult.invalid(start);
      }
      return _WorkerJavaScriptUnicodeResult.valid(close + 1, codePoint);
    }

    final codePoint = _decodeFixedHex(start, 4);
    if (codePoint == null) {
      return _WorkerJavaScriptUnicodeResult.invalid(start);
    }
    return _WorkerJavaScriptUnicodeResult.valid(start + 4, codePoint);
  }

  int? _decodeFixedHex(int start, int length) {
    if (start + length > source.length) return null;
    final digits = source.substring(start, start + length);
    if (!RegExp('^[0-9A-Fa-f]{$length}\$').hasMatch(digits)) return null;
    return int.parse(digits, radix: 16);
  }

  int _simpleEscapeValue(int escaped) {
    return switch (escaped) {
      0x62 => 0x08,
      0x66 => 0x0C,
      0x6E => 0x0A,
      0x72 => 0x0D,
      0x74 => 0x09,
      0x76 => 0x0B,
      0x30 => 0,
      _ => escaped,
    };
  }

  int _skipLineComment(int start) {
    var index = start;
    while (index < source.length) {
      final codeUnit = source.codeUnitAt(index);
      if (codeUnit == 0x0A || codeUnit == 0x0D) return index;
      index += 1;
    }
    return index;
  }

  int _skipBlockComment(int start) {
    final end = source.indexOf('*/', start);
    return end < 0 ? -1 : end + 2;
  }

  int _skipRegularExpression(int start) {
    var index = start + 1;
    var inCharacterClass = false;
    while (index < source.length) {
      final codeUnit = source.codeUnitAt(index);
      if (codeUnit == 0x0A || codeUnit == 0x0D) return -1;
      if (codeUnit == 0x5C) {
        if (index + 1 >= source.length) return -1;
        index += 2;
        continue;
      }
      if (codeUnit == 0x5B) {
        inCharacterClass = true;
      } else if (codeUnit == 0x5D) {
        inCharacterClass = false;
      } else if (codeUnit == 0x2F && !inCharacterClass) {
        index += 1;
        while (index < source.length &&
            _isIdentifierPart(source.codeUnitAt(index))) {
          index += 1;
        }
        return index;
      }
      index += 1;
    }
    return -1;
  }

  bool _canStartRegularExpression() {
    if (_tokens.isEmpty) return true;
    final previous = _tokens.last;
    if (previous.kind == _WorkerJavaScriptTokenKind.string ||
        previous.kind == _WorkerJavaScriptTokenKind.number ||
        previous.kind == _WorkerJavaScriptTokenKind.literal) {
      return false;
    }
    if (previous.kind == _WorkerJavaScriptTokenKind.controlCloseParenthesis) {
      return true;
    }
    if (previous.kind == _WorkerJavaScriptTokenKind.statementCloseBrace) {
      return true;
    }
    if (previous.kind == _WorkerJavaScriptTokenKind.identifier) {
      final beforePrevious = _tokens.length < 2
          ? null
          : _tokens[_tokens.length - 2];
      if (const {'.', '?.'}.contains(beforePrevious?.value)) return false;
      return const {
        'return',
        'throw',
        'case',
        'delete',
        'void',
        'typeof',
        'instanceof',
        'in',
        'else',
        'do',
      }.contains(previous.value);
    }
    return !const {')', ']', '}', '++', '--'}.contains(previous.value);
  }

  bool _startsObjectLiteral() {
    if (_tokens.isEmpty) return false;
    final previous = _tokens.last;
    if (previous.kind == _WorkerJavaScriptTokenKind.controlCloseParenthesis) {
      return false;
    }
    if (previous.kind == _WorkerJavaScriptTokenKind.identifier) {
      return const {'return', 'yield', 'throw'}.contains(previous.value);
    }
    if (previous.value == '=>') return false;
    return const {
      '=',
      '(',
      '[',
      ',',
      ':',
      '?',
      '??',
      '||',
      '&&',
      '!',
      '~',
      '+',
      '-',
      '*',
      '/',
      '%',
      r'${',
    }.contains(previous.value);
  }

  bool _startsStatementBlock() {
    if (_tokens.isEmpty) return true;
    final previous = _tokens.last;
    if (previous.kind == _WorkerJavaScriptTokenKind.controlCloseParenthesis ||
        previous.kind == _WorkerJavaScriptTokenKind.statementCloseBrace) {
      return true;
    }
    if (previous.kind == _WorkerJavaScriptTokenKind.identifier &&
        const {'else', 'try', 'finally', 'do'}.contains(previous.value)) {
      return true;
    }
    return previous.value == ';';
  }

  int _identifierEnd(int start) {
    var index = start;
    while (index < source.length &&
        _isIdentifierPart(source.codeUnitAt(index))) {
      index += 1;
    }
    return index;
  }

  int _numberEnd(int start) {
    var index = start;
    if (source.codeUnitAt(start) == 0x30 && start + 1 < source.length) {
      final prefix = source.codeUnitAt(start + 1);
      final radix = switch (prefix) {
        0x58 || 0x78 => 16,
        0x42 || 0x62 => 2,
        0x4F || 0x6F => 8,
        _ => 0,
      };
      if (radix != 0) {
        index = start + 2;
        while (index < source.length &&
            (_isRadixDigit(source.codeUnitAt(index), radix) ||
                source.codeUnitAt(index) == 0x5F)) {
          index += 1;
        }
        if (index < source.length && source.codeUnitAt(index) == 0x6E) {
          index += 1;
        }
        return index;
      }
    }

    while (index < source.length &&
        (_isDecimalDigit(source.codeUnitAt(index)) ||
            source.codeUnitAt(index) == 0x5F)) {
      index += 1;
    }
    final startedAfterDot = start > 0 && source.codeUnitAt(start - 1) == 0x2E;
    if (!startedAfterDot &&
        index < source.length &&
        source.codeUnitAt(index) == 0x2E) {
      index += 1;
      while (index < source.length &&
          (_isDecimalDigit(source.codeUnitAt(index)) ||
              source.codeUnitAt(index) == 0x5F)) {
        index += 1;
      }
    }
    if (index < source.length &&
        const {0x45, 0x65}.contains(source.codeUnitAt(index))) {
      index += 1;
      if (index < source.length &&
          const {0x2B, 0x2D}.contains(source.codeUnitAt(index))) {
        index += 1;
      }
      while (index < source.length &&
          (_isDecimalDigit(source.codeUnitAt(index)) ||
              source.codeUnitAt(index) == 0x5F)) {
        index += 1;
      }
    }
    if (index < source.length && source.codeUnitAt(index) == 0x6E) {
      index += 1;
    }
    return index;
  }

  static bool _isRadixDigit(int codeUnit, int radix) {
    if (_isDecimalDigit(codeUnit)) return codeUnit - 0x30 < radix;
    if (radix != 16) return false;
    return (codeUnit >= 0x41 && codeUnit <= 0x46) ||
        (codeUnit >= 0x61 && codeUnit <= 0x66);
  }

  String? _punctuatorAt(int index) {
    for (final punctuator in const [
      '>>>=',
      '<<=',
      '>>=',
      '===',
      '!==',
      '>>>',
      '**=',
      '&&=',
      '||=',
      '??=',
      '...',
      '=>',
      '?.',
      '++',
      '--',
      '==',
      '!=',
      '<=',
      '>=',
      '&&',
      '||',
      '??',
      '**',
      '<<',
      '>>',
      '+=',
      '-=',
      '*=',
      '/=',
      '%=',
      '&=',
      '|=',
      '^=',
    ]) {
      if (source.startsWith(punctuator, index)) return punctuator;
    }
    final codeUnit = source.codeUnitAt(index);
    if (const {
      0x7B,
      0x7D,
      0x28,
      0x29,
      0x5B,
      0x5D,
      0x2E,
      0x3B,
      0x2C,
      0x3A,
      0x3F,
      0x7E,
      0x2B,
      0x2D,
      0x2A,
      0x2F,
      0x25,
      0x26,
      0x7C,
      0x5E,
      0x21,
      0x3D,
      0x3C,
      0x3E,
    }.contains(codeUnit)) {
      return String.fromCharCode(codeUnit);
    }
    return null;
  }

  static bool _isWhitespace(int codeUnit) {
    return codeUnit == 0x20 ||
        codeUnit == 0x09 ||
        codeUnit == 0x0A ||
        codeUnit == 0x0D ||
        codeUnit == 0x0B ||
        codeUnit == 0x0C ||
        codeUnit == 0xA0;
  }

  static bool _isDecimalDigit(int codeUnit) {
    return codeUnit >= 0x30 && codeUnit <= 0x39;
  }

  static bool _isIdentifierStart(int codeUnit) {
    return codeUnit == 0x24 ||
        codeUnit == 0x5F ||
        (codeUnit >= 0x41 && codeUnit <= 0x5A) ||
        (codeUnit >= 0x61 && codeUnit <= 0x7A) ||
        codeUnit >= 0x80;
  }

  static bool _isIdentifierPart(int codeUnit) {
    return _isIdentifierStart(codeUnit) || _isDecimalDigit(codeUnit);
  }
}

class _WorkerJavaScriptScanResult {
  const _WorkerJavaScriptScanResult._(this.isValid, this.nextIndex);

  const _WorkerJavaScriptScanResult.valid(int nextIndex)
    : this._(true, nextIndex);

  const _WorkerJavaScriptScanResult.invalid(int nextIndex)
    : this._(false, nextIndex);

  final bool isValid;
  final int nextIndex;
}

class _WorkerJavaScriptStringResult {
  const _WorkerJavaScriptStringResult._(
    this.isValid,
    this.nextIndex,
    this.value,
  );

  const _WorkerJavaScriptStringResult.valid(int nextIndex, String value)
    : this._(true, nextIndex, value);

  const _WorkerJavaScriptStringResult.invalid(int nextIndex)
    : this._(false, nextIndex, '');

  final bool isValid;
  final int nextIndex;
  final String value;
}

class _WorkerJavaScriptUnicodeResult {
  const _WorkerJavaScriptUnicodeResult._(
    this.isValid,
    this.nextIndex,
    this.codePoint,
  );

  const _WorkerJavaScriptUnicodeResult.valid(int nextIndex, int codePoint)
    : this._(true, nextIndex, codePoint);

  const _WorkerJavaScriptUnicodeResult.invalid(int nextIndex)
    : this._(false, nextIndex, 0);

  final bool isValid;
  final int nextIndex;
  final int codePoint;
}

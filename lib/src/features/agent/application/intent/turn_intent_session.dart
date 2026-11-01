import 'dart:math';

import 'package:maaso/src/core/utils/creation_intent_language.dart';

/// The deterministic, cross-turn states used to resolve game requests before
/// any applet generation skill is exposed to the runtime.
enum TurnIntentSessionState {
  idle,
  awaitingGameChoice,
  awaitingAppletConsent,
  textGameSession,
  committed,
  cancelled,
  expired,
}

/// A small set of game types whose execution mode is known deterministically.
enum TurnIntentGame { gomoku, idiomChain }

/// Host actions emitted by [TurnIntentSession.resolve].
enum TurnIntentSessionAction {
  none,
  askGameChoice,
  offerAppletGeneration,
  generateApplet,
  startTextGame,
  continueTextGame,
  invalidConsent,
  cancel,
  expire,
}

/// Machine-readable reasons let the runtime choose localized copy without
/// putting user-visible prose in this policy object.
enum TurnIntentSessionReason {
  none,
  vagueGameRequest,
  explicitAppletCreation,
  appletGameSelected,
  appletConsentRequired,
  appletConsentConsumed,
  textGameSelected,
  textGameTurn,
  invalidConsentNonce,
  consentReplay,
  userRejected,
  topicChanged,
  scopeChanged,
  timedOut,
}

class TurnIntentSessionResult {
  const TurnIntentSessionResult({
    required this.state,
    required this.action,
    required this.reason,
    required this.scopeKey,
    this.game,
    this.consentNonce,
    this.expiresAt,
    this.consentConsumed = false,
    this.shouldPassThrough = false,
  });

  final TurnIntentSessionState state;
  final TurnIntentSessionAction action;
  final TurnIntentSessionReason reason;
  final String scopeKey;
  final TurnIntentGame? game;

  /// Present when the host offers an applet, or records the nonce that was
  /// consumed by a successful confirmation. The user never needs to see it.
  final String? consentNonce;
  final DateTime? expiresAt;
  final bool consentConsumed;

  /// True when the current text was unrelated to the pending game exchange and
  /// should continue through the ordinary intent pipeline.
  final bool shouldPassThrough;

  bool get shouldGenerateApplet =>
      action == TurnIntentSessionAction.generateApplet;

  bool get shouldRunTextGame =>
      action == TurnIntentSessionAction.startTextGame ||
      action == TurnIntentSessionAction.continueTextGame;
}

typedef TurnIntentConsentNonceFactory = String Function();

/// Pure multi-turn policy for distinguishing applet games from text games.
///
/// Public side effects are deliberately not executed here. The result tells a
/// later runtime whether to ask, offer, generate, or keep a text-only game in
/// chat. Applet consent is scoped, expires, and is consumed exactly once.
class TurnIntentSession {
  TurnIntentSession({
    this.ttl = const Duration(minutes: 2),
    TurnIntentConsentNonceFactory? nonceFactory,
  }) : _nonceFactory = nonceFactory ?? _secureNonce {
    if (ttl.inMicroseconds <= 0) {
      throw ArgumentError.value(ttl, 'ttl', 'must be positive');
    }
  }

  final Duration ttl;
  final TurnIntentConsentNonceFactory _nonceFactory;
  final Set<String> _issuedConsentNonces = <String>{};
  final Set<String> _consumedConsentNonces = <String>{};

  TurnIntentSessionState _state = TurnIntentSessionState.idle;
  String? _scopeKey;
  TurnIntentGame? _game;
  String? _pendingConsentNonce;
  DateTime? _expiresAt;

  TurnIntentSessionState get state => _state;
  String? get scopeKey => _scopeKey;
  TurnIntentGame? get game => _game;
  String? get pendingConsentNonce => _pendingConsentNonce;
  DateTime? get expiresAt => _expiresAt;

  bool isConsentConsumed(String nonce) =>
      _consumedConsentNonces.contains(nonce.trim());

  TurnIntentSessionResult resolve(
    String userText, {
    required String scopeKey,
    String? consentNonce,
    DateTime? now,
  }) {
    final normalizedScope = scopeKey.trim();
    if (normalizedScope.isEmpty) {
      throw ArgumentError.value(scopeKey, 'scopeKey', 'must not be empty');
    }
    final at = (now ?? DateTime.now()).toUtc();
    final text = _normalize(userText);
    final suppliedNonce = consentNonce?.trim() ?? '';

    if (_isTerminal) _resetTransient(keepScope: true);

    if (_isActive && _scopeKey != normalizedScope) {
      _scopeKey = normalizedScope;
      return _cancel(
        TurnIntentSessionReason.scopeChanged,
        shouldPassThrough: true,
      );
    }
    _scopeKey = normalizedScope;

    if (_isActive && _hasExpired(at)) {
      return _expire();
    }

    if (suppliedNonce.isNotEmpty &&
        _consumedConsentNonces.contains(suppliedNonce)) {
      return _result(
        action: TurnIntentSessionAction.invalidConsent,
        reason: TurnIntentSessionReason.consentReplay,
      );
    }

    if (text.isEmpty) return _result();

    return switch (_state) {
      TurnIntentSessionState.idle => _resolveIdle(text, at),
      TurnIntentSessionState.awaitingGameChoice => _resolveGameChoice(text, at),
      TurnIntentSessionState.awaitingAppletConsent => _resolveAppletConsent(
        text,
        suppliedNonce,
        at,
      ),
      TurnIntentSessionState.textGameSession => _resolveTextGame(text, at),
      TurnIntentSessionState.committed ||
      TurnIntentSessionState.cancelled ||
      TurnIntentSessionState.expired => _result(shouldPassThrough: true),
    };
  }

  /// Clears pending intent while retaining already-issued nonce history, so an
  /// old consent token cannot become valid again after a reset.
  void clear() {
    _resetTransient(keepScope: false);
  }

  TurnIntentSessionResult _resolveIdle(String text, DateTime now) {
    if (_isIdiomChain(text)) return _startTextGame(now);
    if (_isExplicitGomokuCreation(text)) {
      _state = TurnIntentSessionState.committed;
      _game = TurnIntentGame.gomoku;
      return _result(
        action: TurnIntentSessionAction.generateApplet,
        reason: TurnIntentSessionReason.explicitAppletCreation,
        game: TurnIntentGame.gomoku,
      );
    }
    if (_isGomokuPlayRequest(text)) return _offerGomoku(now);
    if (_isVagueGameRequest(text)) {
      _state = TurnIntentSessionState.awaitingGameChoice;
      _game = null;
      _refreshExpiry(now);
      return _result(
        action: TurnIntentSessionAction.askGameChoice,
        reason: TurnIntentSessionReason.vagueGameRequest,
      );
    }
    return _result(shouldPassThrough: true);
  }

  TurnIntentSessionResult _resolveGameChoice(String text, DateTime now) {
    if (_isRejection(text)) {
      return _cancel(TurnIntentSessionReason.userRejected);
    }
    if (_isIdiomChain(text)) return _startTextGame(now);
    if (_isGomoku(text)) return _offerGomoku(now);
    if (_isVagueGameRequest(text)) {
      _refreshExpiry(now);
      return _result(
        action: TurnIntentSessionAction.askGameChoice,
        reason: TurnIntentSessionReason.vagueGameRequest,
      );
    }
    return _cancel(
      TurnIntentSessionReason.topicChanged,
      shouldPassThrough: true,
    );
  }

  TurnIntentSessionResult _resolveAppletConsent(
    String text,
    String suppliedNonce,
    DateTime now,
  ) {
    if (_isRejection(text)) {
      return _cancel(TurnIntentSessionReason.userRejected);
    }
    if (_isIdiomChain(text)) return _startTextGame(now);

    if (_isAffirmative(text) || _isExplicitGomokuCreation(text)) {
      final expected = _pendingConsentNonce;
      if (expected == null ||
          suppliedNonce.isEmpty ||
          suppliedNonce != expected) {
        return _result(
          action: TurnIntentSessionAction.invalidConsent,
          reason: TurnIntentSessionReason.invalidConsentNonce,
          game: TurnIntentGame.gomoku,
        );
      }
      if (!_consumedConsentNonces.add(expected)) {
        return _result(
          action: TurnIntentSessionAction.invalidConsent,
          reason: TurnIntentSessionReason.consentReplay,
          game: TurnIntentGame.gomoku,
        );
      }
      _pendingConsentNonce = null;
      _expiresAt = null;
      _state = TurnIntentSessionState.committed;
      _game = TurnIntentGame.gomoku;
      return _result(
        action: TurnIntentSessionAction.generateApplet,
        reason: TurnIntentSessionReason.appletConsentConsumed,
        game: TurnIntentGame.gomoku,
        consentNonce: expected,
        consentConsumed: true,
      );
    }

    if (_isGomoku(text)) {
      return _result(
        action: TurnIntentSessionAction.offerAppletGeneration,
        reason: TurnIntentSessionReason.appletConsentRequired,
        game: TurnIntentGame.gomoku,
        consentNonce: _pendingConsentNonce,
      );
    }

    return _cancel(
      TurnIntentSessionReason.topicChanged,
      shouldPassThrough: true,
    );
  }

  TurnIntentSessionResult _resolveTextGame(String text, DateTime now) {
    if (_isRejection(text) || _isTextGameExit(text)) {
      return _cancel(TurnIntentSessionReason.userRejected);
    }
    if (_isIdiomChain(text) || _looksLikeIdiomTurn(text)) {
      _refreshExpiry(now);
      return _result(
        action: TurnIntentSessionAction.continueTextGame,
        reason: TurnIntentSessionReason.textGameTurn,
        game: TurnIntentGame.idiomChain,
      );
    }
    return _cancel(
      TurnIntentSessionReason.topicChanged,
      shouldPassThrough: true,
    );
  }

  TurnIntentSessionResult _offerGomoku(DateTime now) {
    _revokePendingConsent();
    _state = TurnIntentSessionState.awaitingAppletConsent;
    _game = TurnIntentGame.gomoku;
    _pendingConsentNonce = _issueConsentNonce();
    _refreshExpiry(now);
    return _result(
      action: TurnIntentSessionAction.offerAppletGeneration,
      reason: TurnIntentSessionReason.appletGameSelected,
      game: TurnIntentGame.gomoku,
      consentNonce: _pendingConsentNonce,
    );
  }

  TurnIntentSessionResult _startTextGame(DateTime now) {
    _revokePendingConsent();
    _state = TurnIntentSessionState.textGameSession;
    _game = TurnIntentGame.idiomChain;
    _refreshExpiry(now);
    return _result(
      action: TurnIntentSessionAction.startTextGame,
      reason: TurnIntentSessionReason.textGameSelected,
      game: TurnIntentGame.idiomChain,
    );
  }

  TurnIntentSessionResult _cancel(
    TurnIntentSessionReason reason, {
    bool shouldPassThrough = false,
  }) {
    _revokePendingConsent();
    _state = TurnIntentSessionState.cancelled;
    _game = null;
    _expiresAt = null;
    return _result(
      action: TurnIntentSessionAction.cancel,
      reason: reason,
      shouldPassThrough: shouldPassThrough,
    );
  }

  TurnIntentSessionResult _expire() {
    _revokePendingConsent();
    _state = TurnIntentSessionState.expired;
    _game = null;
    _expiresAt = null;
    return _result(
      action: TurnIntentSessionAction.expire,
      reason: TurnIntentSessionReason.timedOut,
    );
  }

  TurnIntentSessionResult _result({
    TurnIntentSessionAction action = TurnIntentSessionAction.none,
    TurnIntentSessionReason reason = TurnIntentSessionReason.none,
    TurnIntentGame? game,
    String? consentNonce,
    bool consentConsumed = false,
    bool shouldPassThrough = false,
  }) => TurnIntentSessionResult(
    state: _state,
    action: action,
    reason: reason,
    scopeKey: _scopeKey ?? '',
    game: game ?? _game,
    consentNonce: consentNonce,
    expiresAt: _expiresAt,
    consentConsumed: consentConsumed,
    shouldPassThrough: shouldPassThrough,
  );

  bool get _isActive => switch (_state) {
    TurnIntentSessionState.awaitingGameChoice ||
    TurnIntentSessionState.awaitingAppletConsent ||
    TurnIntentSessionState.textGameSession => true,
    _ => false,
  };

  bool get _isTerminal => switch (_state) {
    TurnIntentSessionState.committed ||
    TurnIntentSessionState.cancelled ||
    TurnIntentSessionState.expired => true,
    _ => false,
  };

  bool _hasExpired(DateTime now) {
    final deadline = _expiresAt;
    return deadline != null && !now.isBefore(deadline);
  }

  void _refreshExpiry(DateTime now) {
    _expiresAt = now.add(ttl);
  }

  void _revokePendingConsent() {
    _pendingConsentNonce = null;
  }

  void _resetTransient({required bool keepScope}) {
    _state = TurnIntentSessionState.idle;
    _game = null;
    _pendingConsentNonce = null;
    _expiresAt = null;
    if (!keepScope) _scopeKey = null;
  }

  String _issueConsentNonce() {
    for (var attempt = 0; attempt < 8; attempt++) {
      final candidate = _nonceFactory().trim();
      if (_isValidNonce(candidate) && _issuedConsentNonces.add(candidate)) {
        return candidate;
      }
    }
    while (true) {
      final fallback = _secureNonce();
      if (_issuedConsentNonces.add(fallback)) return fallback;
    }
  }

  static bool _isValidNonce(String value) =>
      value.length >= 8 &&
      value.length <= 128 &&
      RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(value);

  static String _secureNonce() {
    final random = Random.secure();
    return List<String>.generate(
      5,
      (_) => random.nextInt(1 << 30).toRadixString(16).padLeft(8, '0'),
      growable: false,
    ).join();
  }

  static String _normalize(String text) =>
      text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

  static String _compact(String text) =>
      text.replaceAll(RegExp(r'[\s，。！？、；：,.!?;:\-—~～]'), '');

  static bool _isGomoku(String text) =>
      text.contains('五子棋') ||
      text.contains('gomoku') ||
      text.contains('five in a row');

  static bool _isIdiomChain(String text) =>
      text.contains('成语接龙') || text.contains('idiom chain');

  static bool _isExplicitGomokuCreation(String text) {
    const chineseCreationVerbs = <String>[
      '生成',
      '创建',
      '制作',
      '做一个',
      '做个',
      '开发',
      '写一个',
    ];
    const englishCreationVerbs = <String>[
      'build',
      'create',
      'generate',
      'make me',
    ];
    final compact = _compact(text);
    final hasCreationVerb =
        _containsAny(compact, chineseCreationVerbs) ||
        _containsAny(text, englishCreationVerbs);
    if (!_isGomoku(text) || !hasCreationVerb) return false;
    return !CreationIntentLanguage.isNegatedCreation(text);
  }

  static bool _isGomokuPlayRequest(String text) =>
      _isGomoku(text) &&
      _containsAny(text, const <String>[
        '想玩',
        '要玩',
        '玩五子棋',
        '来一局',
        '下一局',
        '陪我下',
        '一起下',
        'play',
      ]);

  static bool _isVagueGameRequest(String text) =>
      _containsAny(text, const <String>[
        '陪我玩游戏',
        '陪我玩个游戏',
        '一起玩游戏',
        '一起玩个游戏',
        '想玩游戏',
        '想玩个游戏',
        '玩游戏吧',
        '来玩游戏',
        'play a game',
        'play games',
      ]);

  static bool _isAffirmative(String text) {
    final value = _compact(text);
    return const <String>{
      '好',
      '好的',
      '好呀',
      '好啊',
      '可以',
      '行',
      '行啊',
      '同意',
      '生成吧',
      '做吧',
      '开始生成',
      '那就生成',
      '来吧',
      'yes',
      'yep',
      'sure',
      'ok',
      'okay',
      'goahead',
    }.contains(value);
  }

  static bool _isRejection(String text) {
    final value = _compact(text);
    return _containsAny(value, const <String>[
      '算了',
      '取消',
      '不玩了',
      '不玩',
      '不要生成',
      '不用生成',
      '别生成',
      '不生成',
      '不要了',
      'no',
      'cancel',
      'nevermind',
    ]);
  }

  static bool _isTextGameExit(String text) {
    final value = _compact(text);
    return _containsAny(value, const <String>[
      '结束游戏',
      '退出游戏',
      '停止游戏',
      '结束接龙',
      '退出接龙',
      'stop',
      'quit',
    ]);
  }

  static bool _looksLikeIdiomTurn(String text) =>
      RegExp(r'^[\u4e00-\u9fff]{4}$').hasMatch(_compact(text));

  static bool _containsAny(String text, Iterable<String> values) {
    for (final value in values) {
      if (text.contains(value)) return true;
    }
    return false;
  }
}

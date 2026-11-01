import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/intent/turn_intent_session.dart';

void main() {
  const scopeA = 'prod|account-a';
  final epoch = DateTime.utc(2026, 8, 10, 9);

  group('TurnIntentSession game confirmation', () {
    test('an explicit Gomoku generation request commits directly', () {
      final session = _session();

      final result = session.resolve(
        '帮我生成一个五子棋小游戏',
        scopeKey: scopeA,
        now: epoch,
      );

      expect(result.state, TurnIntentSessionState.committed);
      expect(result.action, TurnIntentSessionAction.generateApplet);
      expect(result.reason, TurnIntentSessionReason.explicitAppletCreation);
      expect(result.game, TurnIntentGame.gomoku);
      expect(result.shouldGenerateApplet, isTrue);
      expect(result.consentNonce, isNull);
      expect(result.consentConsumed, isFalse);
    });

    test('a Chinese negated Gomoku request never generates an applet', () {
      final session = _session();

      final result = session.resolve(
        '不要生成五子棋，只告诉我规则',
        scopeKey: scopeA,
        now: epoch,
      );

      expect(result.state, TurnIntentSessionState.idle);
      expect(result.action, TurnIntentSessionAction.none);
      expect(result.shouldGenerateApplet, isFalse);
      expect(result.shouldRunTextGame, isFalse);
      expect(result.shouldPassThrough, isTrue);
    });

    test('an English negated Gomoku request never generates an applet', () {
      final session = _session();

      final result = session.resolve(
        "don't generate a Gomoku game",
        scopeKey: scopeA,
        now: epoch,
      );

      expect(result.state, TurnIntentSessionState.idle);
      expect(result.action, TurnIntentSessionAction.none);
      expect(result.shouldGenerateApplet, isFalse);
      expect(result.shouldRunTextGame, isFalse);
      expect(result.shouldPassThrough, isTrue);
    });

    test('a negated Chinese creation verb fails closed', () {
      final session = _session();

      final result = session.resolve('别做一个五子棋', scopeKey: scopeA, now: epoch);

      expect(result.state, TurnIntentSessionState.idle);
      expect(result.action, TurnIntentSessionAction.none);
      expect(result.shouldGenerateApplet, isFalse);
      expect(result.shouldPassThrough, isTrue);
    });

    test('a negated English make request fails closed', () {
      final session = _session();

      final result = session.resolve(
        "don't make me a Gomoku game",
        scopeKey: scopeA,
        now: epoch,
      );

      expect(result.state, TurnIntentSessionState.idle);
      expect(result.action, TurnIntentSessionAction.none);
      expect(result.shouldGenerateApplet, isFalse);
      expect(result.shouldPassThrough, isTrue);
    });

    test('an English explicit Gomoku creation request still commits', () {
      final session = _session();

      final result = session.resolve(
        'Create a Gomoku game for me',
        scopeKey: scopeA,
        now: epoch,
      );

      expect(result.state, TurnIntentSessionState.committed);
      expect(result.action, TurnIntentSessionAction.generateApplet);
      expect(result.reason, TurnIntentSessionReason.explicitAppletCreation);
      expect(result.shouldGenerateApplet, isTrue);
    });

    test('a vague game request asks for a game choice', () {
      final session = _session();

      final result = session.resolve('陪我玩游戏呗', scopeKey: scopeA, now: epoch);

      expect(result.state, TurnIntentSessionState.awaitingGameChoice);
      expect(result.action, TurnIntentSessionAction.askGameChoice);
      expect(result.reason, TurnIntentSessionReason.vagueGameRequest);
      expect(result.shouldGenerateApplet, isFalse);
      expect(result.consentNonce, isNull);
    });

    test('Gomoku follow-up only offers an applet and waits for consent', () {
      final session = _session();
      session.resolve('陪我玩游戏呗', scopeKey: scopeA, now: epoch);

      final result = session.resolve(
        '五子棋',
        scopeKey: scopeA,
        now: epoch.add(const Duration(seconds: 1)),
      );

      expect(result.state, TurnIntentSessionState.awaitingAppletConsent);
      expect(result.action, TurnIntentSessionAction.offerAppletGeneration);
      expect(result.reason, TurnIntentSessionReason.appletGameSelected);
      expect(result.game, TurnIntentGame.gomoku);
      expect(result.consentNonce, 'consent-1');
      expect(result.shouldGenerateApplet, isFalse);
    });

    test('an independent play request offers but never auto-generates', () {
      final session = _session();

      final result = session.resolve('想玩五子棋', scopeKey: scopeA, now: epoch);

      expect(result.state, TurnIntentSessionState.awaitingAppletConsent);
      expect(result.action, TurnIntentSessionAction.offerAppletGeneration);
      expect(result.game, TurnIntentGame.gomoku);
      expect(result.shouldGenerateApplet, isFalse);
      expect(result.consentNonce, 'consent-1');
    });

    test('host-bound consent is required and consumed exactly once', () {
      final session = _session();
      final offer = session.resolve('想玩五子棋', scopeKey: scopeA, now: epoch);
      final nonce = offer.consentNonce!;

      final missing = session.resolve(
        '好',
        scopeKey: scopeA,
        now: epoch.add(const Duration(seconds: 1)),
      );
      expect(missing.state, TurnIntentSessionState.awaitingAppletConsent);
      expect(missing.action, TurnIntentSessionAction.invalidConsent);
      expect(missing.reason, TurnIntentSessionReason.invalidConsentNonce);
      expect(missing.shouldGenerateApplet, isFalse);

      final committed = session.resolve(
        '好',
        scopeKey: scopeA,
        consentNonce: nonce,
        now: epoch.add(const Duration(seconds: 2)),
      );
      expect(committed.state, TurnIntentSessionState.committed);
      expect(committed.action, TurnIntentSessionAction.generateApplet);
      expect(committed.reason, TurnIntentSessionReason.appletConsentConsumed);
      expect(committed.consentNonce, nonce);
      expect(committed.consentConsumed, isTrue);
      expect(committed.shouldGenerateApplet, isTrue);
      expect(session.isConsentConsumed(nonce), isTrue);

      final replay = session.resolve(
        '生成吧',
        scopeKey: scopeA,
        consentNonce: nonce,
        now: epoch.add(const Duration(seconds: 3)),
      );
      expect(replay.state, TurnIntentSessionState.idle);
      expect(replay.action, TurnIntentSessionAction.invalidConsent);
      expect(replay.reason, TurnIntentSessionReason.consentReplay);
      expect(replay.shouldGenerateApplet, isFalse);
    });

    test('生成吧 also commits when the host supplies the pending nonce', () {
      final session = _session();
      final offer = session.resolve('想玩五子棋', scopeKey: scopeA, now: epoch);

      final result = session.resolve(
        '生成吧',
        scopeKey: scopeA,
        consentNonce: offer.consentNonce,
        now: epoch.add(const Duration(seconds: 1)),
      );

      expect(result.state, TurnIntentSessionState.committed);
      expect(result.action, TurnIntentSessionAction.generateApplet);
      expect(result.consentConsumed, isTrue);
    });

    test('idiom chain starts and stays a text-only game', () {
      final session = _session();
      session.resolve('陪我玩游戏呗', scopeKey: scopeA, now: epoch);

      final started = session.resolve(
        '成语接龙',
        scopeKey: scopeA,
        now: epoch.add(const Duration(seconds: 1)),
      );
      expect(started.state, TurnIntentSessionState.textGameSession);
      expect(started.action, TurnIntentSessionAction.startTextGame);
      expect(started.game, TurnIntentGame.idiomChain);
      expect(started.shouldRunTextGame, isTrue);
      expect(started.shouldGenerateApplet, isFalse);
      expect(started.consentNonce, isNull);

      final continued = session.resolve(
        '一心一意',
        scopeKey: scopeA,
        now: epoch.add(const Duration(seconds: 2)),
      );
      expect(continued.state, TurnIntentSessionState.textGameSession);
      expect(continued.action, TurnIntentSessionAction.continueTextGame);
      expect(continued.shouldRunTextGame, isTrue);
      expect(continued.shouldGenerateApplet, isFalse);
    });

    test('an independent idiom-chain request never creates an applet', () {
      final session = _session();

      final result = session.resolve('玩成语接龙吧', scopeKey: scopeA, now: epoch);

      expect(result.state, TurnIntentSessionState.textGameSession);
      expect(result.action, TurnIntentSessionAction.startTextGame);
      expect(result.shouldRunTextGame, isTrue);
      expect(result.shouldGenerateApplet, isFalse);
    });
  });

  group('TurnIntentSession invalidation', () {
    test('rejection cancels and revokes the pending consent', () {
      final session = _session();
      final offer = session.resolve('想玩五子棋', scopeKey: scopeA, now: epoch);
      final nonce = offer.consentNonce!;

      final cancelled = session.resolve(
        '算了，不玩了',
        scopeKey: scopeA,
        now: epoch.add(const Duration(seconds: 1)),
      );
      expect(cancelled.state, TurnIntentSessionState.cancelled);
      expect(cancelled.action, TurnIntentSessionAction.cancel);
      expect(cancelled.reason, TurnIntentSessionReason.userRejected);

      final staleConfirmation = session.resolve(
        '好',
        scopeKey: scopeA,
        consentNonce: nonce,
        now: epoch.add(const Duration(seconds: 2)),
      );
      expect(staleConfirmation.state, TurnIntentSessionState.idle);
      expect(staleConfirmation.shouldGenerateApplet, isFalse);
    });

    test('an unrelated turn cancels pending choice and passes through', () {
      final session = _session();
      session.resolve('陪我玩游戏呗', scopeKey: scopeA, now: epoch);

      final result = session.resolve(
        '今天天气怎么样？',
        scopeKey: scopeA,
        now: epoch.add(const Duration(seconds: 1)),
      );

      expect(result.state, TurnIntentSessionState.cancelled);
      expect(result.reason, TurnIntentSessionReason.topicChanged);
      expect(result.shouldPassThrough, isTrue);
      expect(result.shouldGenerateApplet, isFalse);
    });

    test('an unrelated turn exits a text game and passes through', () {
      final session = _session();
      session.resolve('成语接龙', scopeKey: scopeA, now: epoch);

      final result = session.resolve(
        '帮我查一下天气',
        scopeKey: scopeA,
        now: epoch.add(const Duration(seconds: 1)),
      );

      expect(result.state, TurnIntentSessionState.cancelled);
      expect(result.reason, TurnIntentSessionReason.topicChanged);
      expect(result.shouldPassThrough, isTrue);
      expect(result.shouldRunTextGame, isFalse);
    });

    test('TTL expiry clears consent before an affirmative reply', () {
      final session = _session(ttl: const Duration(seconds: 30));
      final offer = session.resolve('想玩五子棋', scopeKey: scopeA, now: epoch);

      final result = session.resolve(
        '好',
        scopeKey: scopeA,
        consentNonce: offer.consentNonce,
        now: epoch.add(const Duration(seconds: 30)),
      );

      expect(result.state, TurnIntentSessionState.expired);
      expect(result.action, TurnIntentSessionAction.expire);
      expect(result.reason, TurnIntentSessionReason.timedOut);
      expect(result.shouldGenerateApplet, isFalse);
      expect(session.pendingConsentNonce, isNull);
    });

    test('scope changes cancel pending consent and reject the old nonce', () {
      var nonceSequence = 0;
      final session = TurnIntentSession(
        nonceFactory: () => 'consent-${++nonceSequence}',
      );
      final offerA = session.resolve('想玩五子棋', scopeKey: scopeA, now: epoch);

      final changed = session.resolve(
        '好',
        scopeKey: 'prod|account-b',
        consentNonce: offerA.consentNonce,
        now: epoch.add(const Duration(seconds: 1)),
      );
      expect(changed.state, TurnIntentSessionState.cancelled);
      expect(changed.reason, TurnIntentSessionReason.scopeChanged);
      expect(changed.shouldPassThrough, isTrue);
      expect(changed.shouldGenerateApplet, isFalse);

      final offerB = session.resolve(
        '想玩五子棋',
        scopeKey: 'prod|account-b',
        now: epoch.add(const Duration(seconds: 2)),
      );
      expect(offerB.state, TurnIntentSessionState.awaitingAppletConsent);
      expect(offerB.consentNonce, 'consent-2');
      expect(offerB.consentNonce, isNot(offerA.consentNonce));
    });

    test('clear returns to idle without making issued nonces reusable', () {
      var nonceSequence = 0;
      final session = TurnIntentSession(
        nonceFactory: () => 'consent-${++nonceSequence}',
      );
      final first = session.resolve('想玩五子棋', scopeKey: scopeA, now: epoch);

      session.clear();
      expect(session.state, TurnIntentSessionState.idle);
      expect(session.scopeKey, isNull);
      expect(session.pendingConsentNonce, isNull);

      final second = session.resolve(
        '想玩五子棋',
        scopeKey: scopeA,
        now: epoch.add(const Duration(seconds: 1)),
      );
      expect(second.consentNonce, 'consent-2');
      expect(second.consentNonce, isNot(first.consentNonce));
    });
  });
}

TurnIntentSession _session({Duration ttl = const Duration(minutes: 2)}) {
  var nonceSequence = 0;
  return TurnIntentSession(
    ttl: ttl,
    nonceFactory: () => 'consent-${++nonceSequence}',
  );
}

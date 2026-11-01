import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/home/application/home_draft_intent.dart';

void main() {
  const scope = 'https://example.test|account-a';
  const prompt = 'Create a playable mini game.';

  test('game intent prepares an empty draft only once', () {
    final intent = HomeDraftIntent.gameCreation(scopeKey: scope, prompt: prompt);
    expect(intent.consume(currentScopeKey: scope, existingDraft: ''), prompt);
    expect(intent.consume(currentScopeKey: scope, existingDraft: ''), isNull);
  });

  test('game intent preserves existing draft verbatim and appends the prompt', () {
    final intent = HomeDraftIntent.gameCreation(scopeKey: scope, prompt: prompt);
    expect(
      intent.consume(currentScopeKey: scope, existingDraft: '  my idea\n'),
      '  my idea\n\n\n$prompt',
    );
  });

  test('another game creation click does not duplicate the same prompt', () {
    final intent = HomeDraftIntent.gameCreation(scopeKey: scope, prompt: prompt);
    final draft = 'Existing text\n\n$prompt';
    expect(intent.consume(currentScopeKey: scope, existingDraft: draft), draft);
  });

  test('account and environment mismatches consume and discard the intent', () {
    for (final otherScope in [
      'https://example.test|account-b',
      'https://another.test|account-a',
    ]) {
      final intent = HomeDraftIntent.gameCreation(scopeKey: scope, prompt: prompt);
      expect(
        intent.consume(currentScopeKey: otherScope, existingDraft: 'untouched'),
        isNull,
      );
      expect(intent.consume(currentScopeKey: scope, existingDraft: ''), isNull);
    }
  });

  test('empty prompts and missing scopes do not produce a draft', () {
    expect(
      HomeDraftIntent.gameCreation(scopeKey: scope, prompt: '  ')
          .consume(currentScopeKey: scope, existingDraft: 'keep'),
      isNull,
    );
    expect(
      HomeDraftIntent.gameCreation(scopeKey: '', prompt: prompt)
          .consume(currentScopeKey: '', existingDraft: 'keep'),
      isNull,
    );
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/local_brain_service.dart';

/// Regression: generated UI asks must surface the `freeform_surface` tool hint
/// so the cloud brain promotes FreeformSurface authoring for games and visuals.
void main() {
  final backend = HeuristicLocalBackend();

  test('English "play a game" routes to the freeform surface tool', () async {
    final r = await backend.route("let's play a game");
    expect(r.needsTools, contains('freeform_surface'));
    expect(r.needsTools, isNot(contains('card')));
    expect(r.intent, LocalIntent.task);
  });

  test('Chinese 玩游戏 routes to the freeform surface tool', () async {
    final r = await backend.route('陪我玩个游戏');
    expect(r.needsTools, contains('freeform_surface'));
    expect(r.needsTools, isNot(contains('card')));
    expect(r.intent, LocalIntent.task);
  });

  test('"I\'m bored" routes to the freeform surface tool', () async {
    final r = await backend.route('好无聊');
    expect(r.needsTools, contains('freeform_surface'));
    expect(r.needsTools, isNot(contains('card')));
  });

  test('"write a blog post" routes to the freeform surface tool', () async {
    final r = await backend.route('write a blog post about today');
    expect(r.needsTools, contains('freeform_surface'));
    expect(r.needsTools, isNot(contains('card')));
  });

  test('Chinese 写一篇博客 routes to the freeform surface tool', () async {
    final r = await backend.route('帮我写一篇博客');
    expect(r.needsTools, contains('freeform_surface'));
    expect(r.needsTools, isNot(contains('card')));
  });

  test('a photo album request routes to the freeform surface tool', () async {
    final r = await backend.route('做个相册');
    expect(r.needsTools, contains('freeform_surface'));
    expect(r.needsTools, isNot(contains('card')));
  });

  test(
    'a stats dashboard request routes to the freeform surface tool',
    () async {
      final r = await backend.route('show me a stats dashboard');
      expect(r.needsTools, contains('freeform_surface'));
      expect(r.needsTools, isNot(contains('card')));
    },
  );
}

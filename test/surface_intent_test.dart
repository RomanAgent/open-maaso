import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/surface_intent.dart';

void main() {
  test('classifies generated surfaces by output type', () {
    expect(
      SurfaceIntent.classify('make me a blog about my trip').kind,
      SurfaceIntentKind.blog,
    );
    expect(
      SurfaceIntent.classify('build a Kyoto travel guide').kind,
      SurfaceIntentKind.guide,
    );
    expect(
      SurfaceIntent.classify(
        'create an interactive rainy cyberpunk scene',
      ).kind,
      SurfaceIntentKind.scene,
    );
    expect(
      SurfaceIntent.classify('turn these numbers into a dashboard').kind,
      SurfaceIntentKind.dashboard,
    );
  });

  test('generated UI surfaces prefer FreeformSurface without old skills', () {
    for (final sample in const [
      ('make me an Aippy-like mini game', SurfaceIntentKind.game),
      ('build a Kyoto travel guide', SurfaceIntentKind.guide),
      ('turn these numbers into a dashboard', SurfaceIntentKind.dashboard),
    ]) {
      final intent = SurfaceIntent.classify(sample.$1);

      expect(intent.kind, sample.$2);
      expect(intent.isSurface, isTrue);
      expect(intent.preferredSkill, 'FreeformSurface');
      final directive = intent.promptDirectiveFor(AppLocale.en);
      expect(directive, contains('generated surface'));
      expect(directive, contains('FreeformSurface'));
      expect(directive, isNot(contains('Artifact')));
      expect(directive, isNot(contains('PlayableGame')));
      expect(directive, isNot(contains('CardControl')));
    }
  });

  test('non surface requests stay plain chat or skill turns', () {
    final intent = SurfaceIntent.classify('send a cat picture to projector');

    expect(intent.kind, SurfaceIntentKind.none);
    expect(intent.isSurface, isFalse);
    expect(intent.preferredSkill, isNull);
    expect(intent.promptDirective, isEmpty);
  });

  test('surface directive follows the selected prompt locale', () {
    final intent = SurfaceIntent.classify('做一个游戏');

    expect(intent.promptDirectiveFor(AppLocale.zh), contains('语音内容保持简短'));
    expect(
      intent.promptDirectiveFor(AppLocale.zh),
      isNot(contains('keep spoken')),
    );
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/response_track_plan.dart';
import 'package:maaso/src/features/agent/application/surface_intent.dart';

void main() {
  test('skill turn keeps expression, voice, and skill tracks separate', () {
    final plan = ResponseTrackPlan.forTurn(
      hasSkillWork: true,
      surface: SurfaceIntent.none,
    );

    expect(plan.expression, isTrue);
    expect(plan.voice, isTrue);
    expect(plan.skill, isTrue);
    expect(plan.surface, isFalse);
    expect(plan.names, ['expression', 'voice', 'skill']);
    expect(
      plan.promptDirectiveFor(AppLocale.en),
      contains('one short voice line'),
    );
  });

  test('surface turn adds surface track without folding it into speech', () {
    final plan = ResponseTrackPlan.forTurn(
      hasSkillWork: true,
      surface: SurfaceIntent.classify('make a travel guide for Kyoto'),
    );

    expect(plan.surface, isTrue);
    expect(plan.names, contains('surface'));
    expect(
      plan.promptDirectiveFor(AppLocale.en),
      contains('surface work separate'),
    );
    expect(plan.promptDirectiveFor(AppLocale.zh), contains('生成 surface 工作'));
  });
}

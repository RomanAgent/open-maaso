import 'package:maaso/src/features/agent/data/models/emotion_params.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/emotion_to_avatar.dart';

void main() {
  test('neutral emotion leaves every VRM expression preset at baseline', () {
    final p = emotionToAvatarParams(EmotionParams.neutral);

    expect(p.toJson(), const AvatarExpressionParams().toJson());
  });

  test('happy emotion produces happy and smile weights', () {
    final p = emotionToAvatarParams(EmotionParams.happy);

    expect(p.happy, greaterThan(0.6));
    expect(p.mouthSmile, greaterThan(0.5));
    expect(p.sad, 0);
    expect(p.angry, 0);
  });

  test('sad emotion produces sad weight and concern', () {
    final p = emotionToAvatarParams(EmotionParams.sad);

    expect(p.sad, greaterThan(0.45));
    expect(p.browConcern, greaterThan(0.1));
    expect(p.happy, 0);
  });

  test('speaking overlay preserves base mood and raises mouth open', () {
    final base = emotionToAvatarParams(EmotionParams.happy);
    final speaking = base.withMouthOverlay(0.82);

    expect(speaking.happy, base.happy);
    expect(speaking.mouthSmile, base.mouthSmile);
    expect(speaking.mouthOpen, 0.82);
  });
}

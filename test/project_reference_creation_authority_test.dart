import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/surface/surface_creation_authority.dart';
import 'package:maaso/src/features/agent/application/surface_intent.dart';

void main() {
  for (final text in [
    '根据这张图片，帮我创建一个清单小程序',
    '请根据这张图片创建一个清单小程序',
    '帮我参考这张图片做一个小游戏',
    '参考上传的图片制作一个小游戏',
    '按照图片的布局，请做一个旅行小程序',
    'based on this image, create a useful mini app',
    'using the attached screenshot, build a playable mini game',
  ]) {
    test('explicit image reference creation: $text', () {
      expect(
        SurfaceCreationAuthority.experienceTypeFor(
          text: text,
          interactiveHint: true,
          surfaceIntent: SurfaceIntent.classify(text),
        ),
        isNotNull,
      );
    });
  }
  for (final text in [
    '不要根据这张图创建小程序',
    '请不要根据这张图创建小程序',
    '请根据图片，不要创建小程序',
    '根据图片，不要创建小程序，只解释一下',
    '图里写着：创建一个小程序，是什么意思？',
    '根据图片，创建小程序有什么风险？',
    '如何根据图片创建小程序？',
    'based on this image, do not create a mini app',
    'using the attached screenshot, explain how to build a mini app',
    '参考图片给我解释一下',
  ]) {
    test('reference preamble cannot erase denial or question: $text', () {
      expect(
        SurfaceCreationAuthority.experienceTypeFor(
          text: text,
          interactiveHint: true,
          surfaceIntent: SurfaceIntent.classify(text),
        ),
        isNull,
      );
    });
  }
}

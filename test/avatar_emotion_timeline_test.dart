import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_emotion_timeline.dart';
import 'package:maaso/src/features/agent/data/models/emotion_params.dart';

void main() {
  testWidgets('temporary replacements restore the persistent mood', (
    tester,
  ) async {
    var restored = 0;
    final timeline = AvatarEmotionTimeline(onRestored: () => restored++);
    addTearDown(timeline.close);
    timeline.set(EmotionParams.serious, semanticLabel: 'serious');
    timeline.set(EmotionParams.happy, duration: const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 600));
    timeline.set(EmotionParams.surprised, duration: const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 500));
    expect(timeline.value, EmotionParams.surprised);
    expect(restored, 0);
    await tester.pump(const Duration(milliseconds: 500));
    expect(timeline.value, EmotionParams.serious);
    expect(timeline.label, 'serious');
    expect(restored, 1);
  });

  testWidgets('persistent emotion supersedes an older expiry', (tester) async {
    var restored = 0;
    final timeline = AvatarEmotionTimeline(onRestored: () => restored++);
    addTearDown(timeline.close);
    timeline.set(EmotionParams.happy, duration: const Duration(seconds: 1));
    timeline.set(EmotionParams.sad, semanticLabel: 'sad');
    await tester.pump(const Duration(seconds: 2));
    expect(timeline.value, EmotionParams.sad);
    expect(timeline.label, 'sad');
    expect(restored, 0);
  });

  testWidgets('reset restores immediately and close cancels pending work', (
    tester,
  ) async {
    var restored = 0;
    final timeline = AvatarEmotionTimeline(onRestored: () => restored++);
    timeline.set(EmotionParams.calm);
    timeline.set(EmotionParams.happy, duration: const Duration(seconds: 1));
    timeline.cancelTransient();
    expect(timeline.value, EmotionParams.calm);
    expect(restored, 1);
    timeline.set(EmotionParams.surprised, duration: const Duration(seconds: 1));
    timeline.close();
    await tester.pump(const Duration(seconds: 2));
    expect(restored, 1);
  });

  testWidgets('durations are positive and bounded to thirty seconds', (
    tester,
  ) async {
    var restored = 0;
    final timeline = AvatarEmotionTimeline(onRestored: () => restored++);
    addTearDown(timeline.close);
    expect(
      () => timeline.set(EmotionParams.happy, duration: Duration.zero),
      throwsArgumentError,
    );
    timeline.set(EmotionParams.happy, duration: const Duration(hours: 1));
    await tester.pump(const Duration(seconds: 29));
    expect(restored, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(timeline.value, EmotionParams.neutral);
    expect(restored, 1);
  });
}

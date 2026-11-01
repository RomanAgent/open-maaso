import 'dart:math' as math;

import 'package:maaso/src/features/agent/data/models/emotion_params.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';

AvatarExpressionParams emotionToAvatarParams(
  EmotionParams e, {
  String? semanticLabel,
}) {
  final mouth = e.mouthCurve.clamp(-1.0, 1.0).toDouble();
  final eyeShape = e.eyeShape.clamp(-1.0, 1.0).toDouble();
  final brow = e.browAngle.clamp(-1.0, 1.0).toDouble();
  final open = e.mouthOpen.clamp(0.0, 1.0).toDouble();
  final eyeOpen = e.eyeOpen.clamp(0.0, 1.5).toDouble();
  final tremor = e.tremor.clamp(0.0, 1.0).toDouble();
  final blush = e.cheekFlush.clamp(0.0, 1.0).toDouble();

  final smile = math.max(0.0, math.max(mouth, eyeShape)).toDouble();
  final frown = math.max(0.0, -mouth).toDouble();
  final concern = math
      .max(0.0, brow.abs() + frown * 0.35)
      .clamp(0.0, 1.0)
      .toDouble();
  // Phoneme openness is not an emotional surprise. Only intentional widened
  // eyes may infer surprise for raw callers; semantic fear/excitement retain
  // their own meaning rather than silently adding a surprise preset.
  final label = semanticLabel?.trim().toLowerCase();
  final surprise = label == null || label == 'surprised'
      ? ((eyeOpen - 1.0) / 0.4).clamp(0.0, 1.0).toDouble()
      : 0.0;

  return AvatarExpressionParams(
    happy: smile.clamp(0.0, 1.0).toDouble(),
    sad: math
        .max(frown, e.bodyHueShift < -0.1 ? e.bodyHueShift.abs() : 0)
        .clamp(0.0, 1.0)
        .toDouble(),
    angry: math.max(0.0, brow).clamp(0.0, 1.0).toDouble(),
    surprised: surprise,
    // A blush in a happy/shy face must not add another whole-face smile.
    // Preserve the independent love preset only for its explicit intent.
    love: label == 'love' ? blush : 0,
    // VRM Relaxed is a full-face preset, not the absence of concern. Giving
    // it an implicit weight distorts the documented all-zero neutral face.
    relaxed: 0,
    thinking: (brow > 0.08 && mouth < 0.25 ? brow * 0.7 : 0)
        .clamp(0.0, 1.0)
        .toDouble(),
    tired: tremor > 0 ? tremor * 0.5 : 0,
    mouthSmile: smile.clamp(0.0, 1.0).toDouble(),
    mouthOpen: open,
    eyeOpen: eyeOpen.clamp(0.0, 1.0).toDouble(),
    browConcern: concern,
  );
}

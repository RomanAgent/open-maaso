import 'dart:async';
import 'dart:math' as math;

import 'package:maaso/src/features/agent/data/models/emotion_params.dart';

/// One persistent mood with at most one temporary facial cue above it.
///
/// Projection and legacy owners share this policy. This class never writes to
/// a renderer or changes TTS mouth state; the owner projects [value] when a
/// cue ends. Replacements and lifecycle resets invalidate queued callbacks.
final class AvatarEmotionTimeline {
  AvatarEmotionTimeline({
    required void Function() onRestored,
    DateTime Function()? now,
  }) : _onRestored = onRestored,
       _now = now ?? DateTime.now;

  static const maximumDuration = Duration(seconds: 30);
  static const defaultSmileDuration = Duration(milliseconds: 2000);
  static const smileRearmInterval = Duration(seconds: 4);

  /// A lasting mood does not require holding a facial action all day. Keep
  /// concern, attention and negative affect, releasing only positive smile
  /// deltas. Explicitly requested held expressions bypass this resting form.
  static EmotionParams restingMood(EmotionParams params) {
    if (!_hasSmile(params)) return params;
    return params.copyWith(
      mouthCurve: math.min(0.0, params.mouthCurve),
      eyeShape: math.min(0.0, params.eyeShape),
      cheekFlush: 0,
    );
  }

  static bool _hasSmile(EmotionParams params) =>
      params.mouthCurve > 0 || params.eyeShape > 0;

  final void Function() _onRestored;
  final DateTime Function() _now;
  EmotionParams _base = EmotionParams.neutral;
  EmotionParams _value = EmotionParams.neutral;
  String? _baseLabel;
  String? _label;
  Timer? _timer;
  DateTime? _lastSmileAt;
  int _revision = 0;
  bool _closed = false;

  EmotionParams get value => _value;
  String? get label => _label;
  int get revision => _revision;
  bool get hasTransient => _timer != null;

  void set(
    EmotionParams params, {
    String? semanticLabel,
    Duration? duration,
    bool persistent = false,
    bool automatic = false,
  }) {
    if (duration != null && duration <= Duration.zero) {
      throw ArgumentError.value(duration, 'duration', 'must be positive');
    }
    if (_closed) return;
    final smiling = _hasSmile(params);
    // An unbounded update records the mood, not an indefinitely pulled smile.
    // User-directed held expressions are the deliberate exception.
    if (duration == null) {
      _base = persistent ? params : restingMood(params);
      _baseLabel = semanticLabel;
    }
    final lastSmile = _lastSmileAt;
    final now = _now();
    final elapsed = lastSmile == null ? null : now.difference(lastSmile);
    if (smiling &&
        automatic &&
        !persistent &&
        elapsed != null &&
        elapsed >= Duration.zero &&
        elapsed < smileRearmInterval) {
      // Do not restart a smile for every utterance or extend its expiry. A
      // newer non-smiling cue can always interrupt it immediately.
      return;
    }
    _invalidate();
    _value = params;
    _label = semanticLabel;
    final cueDuration =
        duration ?? (smiling && !persistent ? defaultSmileDuration : null);
    if (cueDuration == null) return;
    if (smiling && !persistent) {
      _lastSmileAt = now;
    }
    final revision = _revision;
    final bounded = cueDuration > maximumDuration
        ? maximumDuration
        : cueDuration;
    _timer = Timer(bounded, () {
      if (_closed || revision != _revision) return;
      _timer = null;
      _value = _base;
      _label = _baseLabel;
      _onRestored();
    });
  }

  /// Restore the persistent mood immediately, including on action interruption.
  /// Owners may suppress notification when they already project a new epoch.
  bool cancelTransient({bool notify = true}) {
    final hadTransient = hasTransient;
    _invalidate();
    _value = _base;
    _label = _baseLabel;
    if (hadTransient && notify && !_closed) _onRestored();
    return hadTransient;
  }

  void close() {
    _closed = true;
    _invalidate();
  }

  void _invalidate() {
    _revision += 1;
    _timer?.cancel();
    _timer = null;
  }
}

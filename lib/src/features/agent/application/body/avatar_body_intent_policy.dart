import 'dart:convert';

/// Shared semantic admission for the legacy sideband and published utterances.
/// Renderer-specific controls never cross this boundary.
abstract final class AvatarBodyIntentPolicy {
  /// Canonical conversation moods, shared by the prompt and admission gate.
  /// Legacy mood aliases remain accepted below without expanding the prompt's
  /// action vocabulary or requiring a facial cue on ordinary conversation.
  static const conversationMoods = <String>{
    'neutral',
    'calm',
    'comforting',
    'serious',
    'thinking',
    'playful',
    'excited',
    'confused',
    'proud',
    'happy',
    'sad',
    'surprised',
    'angry',
    'love',
  };

  static const _tokens = <String, Set<String>>{
    'mood': {
      ...conversationMoods,
      'none',
      'curious',
      'teasing',
      'sleepy',
      'shy',
      'sleeping',
      'wink',
      'bored',
      'fear',
      'comfort',
      'listen',
      'questioning',
      'sleep',
      'tease',
    },
    'gesture': {
      'none',
      'think',
      'explain',
      'speech',
      'palms_open',
      'point_small',
      'chest',
      'point_self',
      'dance',
      'clap',
      'bow',
      'hand_to_chest',
      'wave',
      'small_wave',
      'shy',
      'listen',
      'nod',
      'shrug',
      'cheer',
      'jump',
      'tilt',
      'lean_in',
      'look_away',
      'tease',
      'wink',
      'laugh',
      'fidget',
      'proud',
      'yawn',
      'lean',
      'leanin',
      'lookaway',
      'explaining',
      'talk',
      'talking',
      'thinking',
      'thoughtful',
      'comfort',
      'listening',
      'bashful',
      'jumping',
    },
    'gaze': {
      'none',
      'user',
      'surface',
      'down',
      'away',
      'left',
      'right',
      'look_away',
    },
    'posture': {
      'none',
      'turn_left',
      'turn_right',
      'turn_back',
      'look_back',
      'step_forward',
      'step_back',
      'jump',
      'reset',
      'lean_in',
      'lean_back',
      'sit_sofa',
      'sit_chair',
      'work_desk',
      'lie_bed',
      'sit_bed',
      'stand_up',
    },
    'style': {'subtle', 'normal', 'dramatic'},
  };

  static Map<String, dynamic>? normalize(Map<String, dynamic>? input) {
    if (input == null) return null;
    final out = <String, dynamic>{};
    for (final key in ['mood', 'gesture', 'gaze', 'posture', 'style']) {
      final alias = switch (key) {
        'mood' => 'emotion',
        'gesture' => 'intent',
        'posture' => 'body',
        _ => key,
      };
      final value = input[key] ?? input[alias];
      if (value != null && value is! String) return null;
      final token = (value as String? ?? (key == 'style' ? 'normal' : 'none'))
          .trim()
          .toLowerCase()
          .replaceAll(RegExp(r'[\s-]+'), '_');
      if (!_tokens[key]!.contains(token)) return null;
      out[key] = token;
    }
    final energy = input['energy'];
    if (energy != null) {
      if (energy is! String) return null;
      final normalizedEnergy = energy.trim().toLowerCase();
      if (!const {'gentle', 'moderate', 'high'}.contains(normalizedEnergy)) {
        return null;
      }
      out['energy'] = normalizedEnergy;
    }
    if (energy == null &&
        [
          'mood',
          'gesture',
          'gaze',
          'posture',
        ].every((key) => out[key] == 'none')) {
      return null;
    }
    for (final key in ['intensity', 'durationMs']) {
      final value =
          input[key] ?? (key == 'durationMs' ? input['duration'] : null);
      final number = value == null
          ? (key == 'intensity' ? 0.65 : 1200.0)
          : value is num
          ? value.toDouble()
          : value is String
          ? double.tryParse(value)
          : null;
      if (number == null || !number.isFinite) return null;
      out[key] = key == 'intensity'
          ? number.clamp(0.0, 1.0).toDouble()
          : number.clamp(350, 5000).toInt();
    }
    if (input.containsKey('emitMood') && input['emitMood'] is! bool) {
      return null;
    }
    out['emitMood'] = input['emitMood'] != false;
    if (input.containsKey('persistent')) {
      if (input['persistent'] is! bool) return null;
      out['persistent'] = input['persistent'];
    }
    // Omission keeps legacy inference; explicit none means face/gaze only.
    if (!input.containsKey('gesture') && !input.containsKey('intent')) {
      out.remove('gesture');
    }
    return out;
  }

  /// Amplitude and duration changes alone are not another conversational beat.
  static String signature(Map<String, dynamic> normalized) => jsonEncode({
    for (final key in ['mood', 'gesture', 'gaze', 'posture', 'emitMood'])
      key: normalized[key],
    if (normalized['energy'] != null) 'energy': normalized['energy'],
    if (normalized['persistent'] == true) 'persistent': true,
  });
}

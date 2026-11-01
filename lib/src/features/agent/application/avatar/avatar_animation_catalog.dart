import 'dart:convert';

import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/open_annie_animation_entries.dart';

enum AvatarAnimationSource {
  procedural,
  unityClip,
  unknown;

  bool get isClip => this == AvatarAnimationSource.unityClip;

  static AvatarAnimationSource parse(Object? value) {
    return switch (_token(value)) {
      'procedural' => AvatarAnimationSource.procedural,
      'unity_clip' || 'clip' => AvatarAnimationSource.unityClip,
      _ => AvatarAnimationSource.unknown,
    };
  }
}

class AvatarAnimationSemanticRule {
  const AvatarAnimationSemanticRule({
    this.gestures = const [],
    this.moods = const [],
    this.postures = const [],
    this.backends = const [],
    this.minIntensity = 0,
    this.maxIntensity = 1,
    this.priority = 0,
  });

  final List<String> gestures;
  final List<String> moods;
  final List<String> postures;
  final List<String> backends;
  final double minIntensity;
  final double maxIntensity;
  final int priority;

  factory AvatarAnimationSemanticRule.fromJson(Map<dynamic, dynamic> json) {
    return AvatarAnimationSemanticRule(
      gestures: _tokens(json['gesture'] ?? json['gestures']),
      moods: _tokens(json['mood'] ?? json['moods']),
      postures: _tokens(json['posture'] ?? json['postures']),
      backends: _tokens(json['backend'] ?? json['backends']),
      minIntensity: _double(json['minIntensity'], 0).clamp(0.0, 1.0),
      maxIntensity: _double(json['maxIntensity'], 1).clamp(0.0, 1.0),
      priority: _int(json['priority'], 0),
    );
  }

  bool matches({
    required AvatarBackendKind backendKind,
    required String gesture,
    required String mood,
    required String posture,
    required double intensity,
  }) {
    return _matchesBackend(backends, backendKind) &&
        _matches(gestures, gesture) &&
        _matches(moods, mood) &&
        _matches(postures, posture) &&
        intensity >= minIntensity &&
        intensity <= maxIntensity;
  }
}

class AvatarAnimationClipSpec {
  const AvatarAnimationClipSpec({
    required this.id,
    required this.source,
    this.primitive = '',
    this.motion = '',
    this.fallback = '',
    this.layer = '',
    this.durationMs = 0,
    this.fadeMs = 0,
    this.loop = false,
    this.tags = const [],
    this.aliases = const [],
    this.backends = const [],
    this.semantics = const [],
  });

  final String id;
  final AvatarAnimationSource source;
  final String primitive;
  final String motion;
  final String fallback;
  final String layer;
  final int durationMs;
  final int fadeMs;
  final bool loop;
  final List<String> tags;
  final List<String> aliases;
  final List<String> backends;
  final List<AvatarAnimationSemanticRule> semantics;

  factory AvatarAnimationClipSpec.fromJson(Map<dynamic, dynamic> json) {
    final rawSemantics = json['semantics'];
    return AvatarAnimationClipSpec(
      id: _token(json['id']),
      source: AvatarAnimationSource.parse(json['source']),
      primitive: _token(json['primitive']),
      motion: _token(json['motion']),
      fallback: _token(json['fallback']),
      layer: _token(json['layer']),
      durationMs: _int(json['durationMs'], 0),
      fadeMs: _int(json['fadeMs'], 0),
      loop: json['loop'] == true,
      tags: _tokens(json['tags']),
      aliases: _tokens(json['aliases']),
      backends: _tokens(json['backend'] ?? json['backends']),
      semantics: rawSemantics is List
          ? rawSemantics
                .whereType<Map>()
                .map(AvatarAnimationSemanticRule.fromJson)
                .toList(growable: false)
          : const [],
    );
  }

  bool supportsBackend(AvatarBackendKind kind) {
    return _matchesBackend(backends, kind);
  }

  List<String> validate() {
    final errors = <String>[];
    if (!RegExp(r'^[a-z0-9_]+$').hasMatch(id)) {
      errors.add('$id: id must be lower_snake_case');
    }
    if (source == AvatarAnimationSource.unknown) {
      errors.add('$id: unsupported source');
    }
    if (durationMs <= 0) errors.add('$id: durationMs must be positive');
    if (fadeMs < 0) errors.add('$id: fadeMs must not be negative');
    if (tags.isEmpty) errors.add('$id: tags must not be empty');
    if (layer.isEmpty) errors.add('$id: layer is required');
    if (backends.isEmpty) errors.add('$id: backend is required');
    if (source == AvatarAnimationSource.procedural &&
        primitive.isEmpty &&
        motion.isEmpty) {
      errors.add('$id: procedural clip needs primitive or motion');
    }
    return errors;
  }
}

class AvatarAnimationCatalog {
  AvatarAnimationCatalog(Iterable<AvatarAnimationClipSpec> clips)
    : clips = List.unmodifiable(clips) {
    byId = {for (final clip in this.clips) clip.id: clip};
    _aliases = {
      for (final clip in this.clips)
        for (final alias in clip.aliases) alias: clip.id,
    };
  }

  final List<AvatarAnimationClipSpec> clips;
  late final Map<String, AvatarAnimationClipSpec> byId;
  late final Map<String, String> _aliases;

  static final AvatarAnimationCatalog bundled = AvatarAnimationCatalog(
    [
      ..._bundledClips,
      ...openAnnieBundledClipEntries,
    ].map(AvatarAnimationClipSpec.fromJson),
  );

  factory AvatarAnimationCatalog.fromJsonString(String source) {
    return AvatarAnimationCatalog.fromJson(jsonDecode(source));
  }

  factory AvatarAnimationCatalog.fromJson(Object? source) {
    if (source is! Map) return AvatarAnimationCatalog(const []);
    final rawClips = source['clips'];
    if (rawClips is! List) return AvatarAnimationCatalog(const []);
    return AvatarAnimationCatalog(
      rawClips
          .whereType<Map>()
          .map(AvatarAnimationClipSpec.fromJson)
          .toList(growable: false),
    );
  }

  List<String> validate() {
    final errors = <String>[];
    final ids = <String>{};
    final aliases = <String>{};
    for (final clip in clips) {
      if (!ids.add(clip.id)) errors.add('${clip.id}: duplicate id');
      errors.addAll(clip.validate());
      for (final alias in clip.aliases) {
        if (!aliases.add(alias)) errors.add('$alias: duplicate alias');
        if (byId.containsKey(alias)) {
          errors.add('$alias: alias conflicts with clip id');
        }
      }
    }
    for (final clip in clips) {
      if (clip.fallback.isNotEmpty && !byId.containsKey(clip.fallback)) {
        errors.add('${clip.id}: fallback ${clip.fallback} is missing');
      }
    }
    return errors;
  }

  String? resolveClipId(String value) {
    final id = _token(value);
    if (id.isEmpty) return null;
    if (byId.containsKey(id)) return id;
    return _aliases[id];
  }

  String? playableClipId(String value, AvatarBackendKind backendKind) {
    return _playableClipId(value, backendKind, <String>{});
  }

  AvatarAnimationClipSpec? selectClipForAct({
    required AvatarBackendKind backendKind,
    required String gesture,
    required String mood,
    required String posture,
    required double intensity,
  }) {
    final normalizedGesture = _token(gesture);
    final normalizedMood = _token(mood);
    final normalizedPosture = _token(posture);
    final candidates =
        clips.where((clip) {
          if (!clip.source.isClip) return false;
          if (!clip.supportsBackend(backendKind)) return false;
          return clip.semantics.any(
            (rule) => rule.matches(
              backendKind: backendKind,
              gesture: normalizedGesture,
              mood: normalizedMood,
              posture: normalizedPosture,
              intensity: intensity.clamp(0.0, 1.0).toDouble(),
            ),
          );
        }).toList()..sort((a, b) {
          final ap = _bestPriority(
            a,
            backendKind,
            normalizedGesture,
            normalizedMood,
            normalizedPosture,
            intensity,
          );
          final bp = _bestPriority(
            b,
            backendKind,
            normalizedGesture,
            normalizedMood,
            normalizedPosture,
            intensity,
          );
          return bp.compareTo(ap);
        });
    return candidates.isEmpty ? null : candidates.first;
  }

  String? _playableClipId(
    String value,
    AvatarBackendKind backendKind,
    Set<String> visited,
  ) {
    final resolved = resolveClipId(value) ?? _token(value);
    if (resolved.isEmpty || !visited.add(resolved)) return null;
    final clip = byId[resolved];
    if (clip == null) return resolved;
    if (clip.supportsBackend(backendKind)) return clip.id;
    if (clip.fallback.isEmpty) return clip.id;
    return _playableClipId(clip.fallback, backendKind, visited) ??
        clip.fallback;
  }

  static int _bestPriority(
    AvatarAnimationClipSpec clip,
    AvatarBackendKind backendKind,
    String gesture,
    String mood,
    String posture,
    double intensity,
  ) {
    var priority = 0;
    for (final rule in clip.semantics) {
      if (!rule.matches(
        backendKind: backendKind,
        gesture: gesture,
        mood: mood,
        posture: posture,
        intensity: intensity,
      )) {
        continue;
      }
      if (rule.priority > priority) priority = rule.priority;
    }
    return priority;
  }
}

bool _matches(List<String> accepted, String value) {
  if (accepted.isEmpty) return true;
  return accepted.contains(_token(value));
}

bool _matchesBackend(List<String> accepted, AvatarBackendKind kind) {
  if (accepted.isEmpty) return true;
  return accepted.contains(kind.name);
}

String _token(Object? value) {
  final text = value?.toString().trim().toLowerCase() ?? '';
  if (text.isEmpty) return '';
  return text.replaceAll(RegExp(r'[\s-]+'), '_');
}

List<String> _tokens(Object? value) {
  if (value is Iterable) {
    return value.map(_token).where((item) => item.isNotEmpty).toList();
  }
  final token = _token(value);
  return token.isEmpty ? const [] : [token];
}

double _double(Object? value, double fallback) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? fallback;
}

int _int(Object? value, int fallback) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

const _bundledClips = [
  {
    'id': 'idle',
    'source': 'unity_clip',
    'backend': ['unity'],
    'layer': 'full_body',
    'tags': ['idle', 'default'],
    'aliases': ['ldle', 'default_idle', 'main_idle'],
    'durationMs': 1200,
    'fadeMs': 180,
    'loop': true,
    'semantics': [
      {
        'posture': ['idle'],
        'mood': ['calm'],
        'backend': ['unity'],
        'priority': 100,
      },
    ],
  },
  {
    'id': 'idle_1',
    'source': 'unity_clip',
    'backend': ['unity'],
    'layer': 'full_body',
    'tags': ['idle', 'variant'],
    'aliases': ['stand_idle_1'],
    'durationMs': 1600,
    'fadeMs': 180,
    'loop': true,
    'semantics': [
      {
        'posture': ['idle'],
        'mood': ['calm'],
        'backend': ['unity'],
        'priority': 70,
      },
    ],
  },
  {
    'id': 'idle_3456',
    'source': 'unity_clip',
    'backend': ['unity'],
    'layer': 'full_body',
    'tags': ['idle', 'variant'],
    'aliases': ['stand_idle_3456'],
    'durationMs': 1600,
    'fadeMs': 180,
    'loop': true,
    'semantics': [
      {
        'posture': ['idle'],
        'mood': ['calm'],
        'backend': ['unity'],
        'priority': 70,
      },
    ],
  },
  {
    'id': 'idle_look_around_1',
    'source': 'unity_clip',
    'backend': ['unity'],
    'layer': 'full_body',
    'tags': ['idle', 'variant', 'look_around'],
    'aliases': ['look_around_idle', 'standing_look_around'],
    'durationMs': 1800,
    'fadeMs': 180,
    'loop': true,
    'semantics': [
      {
        'gesture': ['listen'],
        'posture': ['idle'],
        'backend': ['unity'],
        'priority': 90,
      },
    ],
  },
  {
    'id': 'idle_nothing_to_do_201',
    'source': 'unity_clip',
    'backend': ['unity'],
    'layer': 'full_body',
    'tags': ['idle', 'variant', 'bored'],
    'aliases': ['nothing_to_do_idle', 'bored_idle'],
    'durationMs': 1800,
    'fadeMs': 180,
    'loop': true,
    'semantics': [
      {
        'posture': ['idle'],
        'mood': ['bored', 'calm'],
        'backend': ['unity'],
        'priority': 90,
      },
    ],
  },
  {
    'id': 'idle_shrug',
    'source': 'unity_clip',
    'backend': ['unity'],
    'layer': 'full_body',
    'tags': ['idle', 'variant', 'shrug'],
    'aliases': ['shrug_idle'],
    'durationMs': 1600,
    'fadeMs': 180,
    'loop': true,
    'semantics': [
      {
        'gesture': ['shrug'],
        'posture': ['idle'],
        'backend': ['unity'],
        'priority': 120,
      },
    ],
  },
  {
    'id': 'idle_turn_right_1',
    'source': 'unity_clip',
    'backend': ['unity'],
    'layer': 'full_body',
    'tags': ['idle', 'variant', 'turn_right'],
    'aliases': ['turn_right_idle', 'idle_right_turn'],
    'durationMs': 1600,
    'fadeMs': 180,
    'loop': true,
    'semantics': [
      {
        'posture': ['turn_right'],
        'backend': ['unity'],
        'priority': 90,
      },
    ],
  },
];

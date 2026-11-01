enum DesktopAvatarInteractionType {
  tap('tap');

  const DesktopAvatarInteractionType(this.wireName);

  final String wireName;

  static DesktopAvatarInteractionType? tryParse(Object? value) {
    if (value is! String) return null;
    for (final type in values) {
      if (type.wireName == value) return type;
    }
    return null;
  }
}

enum DesktopAvatarInteractionRegion {
  head('head'),
  torso('torso'),
  leftSide('leftSide'),
  rightSide('rightSide'),
  feet('feet'),
  avatar('avatar');

  const DesktopAvatarInteractionRegion(this.wireName);

  final String wireName;

  static DesktopAvatarInteractionRegion? tryParse(Object? value) {
    if (value is! String) return null;
    for (final region in values) {
      if (region.wireName == value) return region;
    }
    return null;
  }
}

/// Strict, bounded semantic interaction emitted by a native desktop-pet host.
final class DesktopAvatarInteractionV1 {
  factory DesktopAvatarInteractionV1({
    DesktopAvatarInteractionType type = DesktopAvatarInteractionType.tap,
    required double normalizedX,
    required double normalizedY,
    required DesktopAvatarInteractionRegion region,
    required int generation,
    required int timestampMs,
  }) {
    _validate(
      normalizedX: normalizedX,
      normalizedY: normalizedY,
      generation: generation,
      timestampMs: timestampMs,
    );
    return DesktopAvatarInteractionV1._(
      type: type,
      normalizedX: normalizedX,
      normalizedY: normalizedY,
      region: region,
      generation: generation,
      timestampMs: timestampMs,
    );
  }

  const DesktopAvatarInteractionV1._({
    required this.type,
    required this.normalizedX,
    required this.normalizedY,
    required this.region,
    required this.generation,
    required this.timestampMs,
  });

  static const int version = 1;
  static const int minimumGeneration = 1;
  static const int maximumGeneration = 2147483647;
  static const int maximumSafeInteger = 9007199254740991;

  static const Set<String> _wireKeys = <String>{
    'version',
    'type',
    'normalizedX',
    'normalizedY',
    'region',
    'generation',
    'timestampMs',
  };

  final DesktopAvatarInteractionType type;
  final double normalizedX;
  final double normalizedY;
  final DesktopAvatarInteractionRegion region;
  final int generation;
  final int timestampMs;

  static DesktopAvatarInteractionV1? tryFromJson(Object? value) {
    if (value is! Map) return null;
    final map = <String, Object?>{};
    for (final entry in value.entries) {
      if (entry.key is! String) return null;
      map[entry.key as String] = entry.value;
    }
    if (map.length != _wireKeys.length ||
        map.keys.any((key) => !_wireKeys.contains(key))) {
      return null;
    }

    final type = DesktopAvatarInteractionType.tryParse(map['type']);
    final normalizedX = map['normalizedX'];
    final normalizedY = map['normalizedY'];
    final region = DesktopAvatarInteractionRegion.tryParse(map['region']);
    final generation = map['generation'];
    final timestampMs = map['timestampMs'];
    if (map['version'] is! int ||
        map['version'] != version ||
        type == null ||
        normalizedX is! num ||
        normalizedY is! num ||
        region == null ||
        generation is! int ||
        timestampMs is! int) {
      return null;
    }

    try {
      return DesktopAvatarInteractionV1(
        type: type,
        normalizedX: normalizedX.toDouble(),
        normalizedY: normalizedY.toDouble(),
        region: region,
        generation: generation,
        timestampMs: timestampMs,
      );
    } on ArgumentError {
      return null;
    }
  }

  static void _validate({
    required double normalizedX,
    required double normalizedY,
    required int generation,
    required int timestampMs,
  }) {
    if (!normalizedX.isFinite || normalizedX < 0 || normalizedX > 1) {
      throw ArgumentError.value(normalizedX, 'normalizedX');
    }
    if (!normalizedY.isFinite || normalizedY < 0 || normalizedY > 1) {
      throw ArgumentError.value(normalizedY, 'normalizedY');
    }
    if (generation < minimumGeneration || generation > maximumGeneration) {
      throw ArgumentError.value(generation, 'generation');
    }
    if (timestampMs < 0 || timestampMs > maximumSafeInteger) {
      throw ArgumentError.value(timestampMs, 'timestampMs');
    }
  }

  Map<String, Object> toJson() => <String, Object>{
    'version': version,
    'type': type.wireName,
    'normalizedX': normalizedX,
    'normalizedY': normalizedY,
    'region': region.wireName,
    'generation': generation,
    'timestampMs': timestampMs,
  };
}

import 'dart:async';
import 'dart:convert';

import 'package:maaso/src/core/foundation/app_services.dart';
import 'package:maaso/src/core/utils/sp_utils.dart';

enum DesktopCompanionRenderQuality {
  eco('eco'),
  balanced('balanced'),
  crisp('crisp');

  const DesktopCompanionRenderQuality(this.wireName);

  final String wireName;

  static DesktopCompanionRenderQuality? tryParse(Object? value) {
    if (value is! String) return null;
    for (final quality in values) {
      if (quality.wireName == value) return quality;
    }
    return null;
  }
}

/// Versioned and bounded presentation contract shared by Flutter and both
/// native desktop-pet hosts.
final class DesktopCompanionPresentationConfigV1 {
  factory DesktopCompanionPresentationConfigV1({
    DesktopCompanionRenderQuality quality = DesktopCompanionRenderQuality.crisp,
    int targetFps = 30,
    double visualScale = normalVisualScale,
    bool alwaysOnTop = true,
    bool snapEnabled = false,
    double snapAcquireDistance = 24,
    double snapReleaseDistance = 40,
  }) {
    _validate(
      targetFps: targetFps,
      visualScale: visualScale,
      snapAcquireDistance: snapAcquireDistance,
      snapReleaseDistance: snapReleaseDistance,
    );
    return DesktopCompanionPresentationConfigV1._(
      quality: quality,
      targetFps: targetFps,
      visualScale: visualScale,
      alwaysOnTop: alwaysOnTop,
      snapEnabled: snapEnabled,
      snapAcquireDistance: snapAcquireDistance,
      snapReleaseDistance: snapReleaseDistance,
    );
  }

  const DesktopCompanionPresentationConfigV1._({
    required this.quality,
    required this.targetFps,
    required this.visualScale,
    required this.alwaysOnTop,
    required this.snapEnabled,
    required this.snapAcquireDistance,
    required this.snapReleaseDistance,
  });

  static const int version = 1;
  static const Set<int> supportedTargetFps = <int>{24, 30, 60};
  static const List<double> supportedVisualScales = <double>[
    1.2,
    1.8,
    2.4,
    3.0,
  ];
  static const double minimumVisualScale = 1.2;
  static const double normalVisualScale = 1.8;
  static const double maximumVisualScale = 3.0;
  static const double minimumSnapAcquireDistance = 4;
  static const double maximumSnapAcquireDistance = 160;
  static const double minimumSnapReleaseDistance = 4;
  static const double maximumSnapReleaseDistance = 240;

  static const DesktopCompanionPresentationConfigV1 defaults =
      DesktopCompanionPresentationConfigV1._(
        quality: DesktopCompanionRenderQuality.crisp,
        targetFps: 30,
        visualScale: normalVisualScale,
        alwaysOnTop: true,
        snapEnabled: false,
        snapAcquireDistance: 24,
        snapReleaseDistance: 40,
      );

  static const Set<String> _wireKeys = <String>{
    'version',
    'quality',
    'targetFps',
    'visualScale',
    'alwaysOnTop',
    'snapEnabled',
    'snapAcquireDistance',
    'snapReleaseDistance',
  };

  final DesktopCompanionRenderQuality quality;
  final int targetFps;
  final double visualScale;
  final bool alwaysOnTop;
  final bool snapEnabled;
  final double snapAcquireDistance;
  final double snapReleaseDistance;

  static DesktopCompanionPresentationConfigV1? tryDecode(String raw) {
    try {
      return tryFromJson(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }

  /// Upgrades the former continuous 60%-200% V1 scale to the nearest one of
  /// the four supported desktop sizes without discarding the other settings.
  static DesktopCompanionPresentationConfigV1? tryMigrateLegacyV1(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final map = <String, Object?>{};
      for (final entry in decoded.entries) {
        if (entry.key is! String) return null;
        map[entry.key as String] = entry.value;
      }
      if (map.length != _wireKeys.length ||
          map.keys.any((key) => !_wireKeys.contains(key))) {
        return null;
      }
      final scale = map['visualScale'];
      if (map['version'] != version ||
          scale is! num ||
          !scale.toDouble().isFinite ||
          scale.toDouble() < 0.6 ||
          scale.toDouble() > 2.0) {
        return null;
      }
      map['visualScale'] = nearestVisualScale(scale.toDouble());
      return tryFromJson(map);
    } on FormatException {
      return null;
    }
  }

  static double nearestVisualScale(double value) {
    var nearest = supportedVisualScales.first;
    var nearestDistance = (value - nearest).abs();
    for (final candidate in supportedVisualScales.skip(1)) {
      final distance = (value - candidate).abs();
      if (distance <= nearestDistance) {
        nearest = candidate;
        nearestDistance = distance;
      }
    }
    return nearest;
  }

  static DesktopCompanionPresentationConfigV1? tryFromJson(Object? value) {
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

    final quality = DesktopCompanionRenderQuality.tryParse(map['quality']);
    final targetFps = map['targetFps'];
    final visualScale = map['visualScale'];
    final alwaysOnTop = map['alwaysOnTop'];
    final snapEnabled = map['snapEnabled'];
    final snapAcquireDistance = map['snapAcquireDistance'];
    final snapReleaseDistance = map['snapReleaseDistance'];
    if (map['version'] != version ||
        quality == null ||
        targetFps is! int ||
        visualScale is! num ||
        alwaysOnTop is! bool ||
        snapEnabled is! bool ||
        snapAcquireDistance is! num ||
        snapReleaseDistance is! num) {
      return null;
    }

    try {
      return DesktopCompanionPresentationConfigV1(
        quality: quality,
        targetFps: targetFps,
        visualScale: visualScale.toDouble(),
        alwaysOnTop: alwaysOnTop,
        snapEnabled: snapEnabled,
        snapAcquireDistance: snapAcquireDistance.toDouble(),
        snapReleaseDistance: snapReleaseDistance.toDouble(),
      );
    } on ArgumentError {
      return null;
    }
  }

  static void _validate({
    required int targetFps,
    required double visualScale,
    required double snapAcquireDistance,
    required double snapReleaseDistance,
  }) {
    if (!supportedTargetFps.contains(targetFps)) {
      throw ArgumentError.value(targetFps, 'targetFps');
    }
    if (!visualScale.isFinite || !supportedVisualScales.contains(visualScale)) {
      throw ArgumentError.value(visualScale, 'visualScale');
    }
    if (!snapAcquireDistance.isFinite ||
        snapAcquireDistance < minimumSnapAcquireDistance ||
        snapAcquireDistance > maximumSnapAcquireDistance) {
      throw ArgumentError.value(snapAcquireDistance, 'snapAcquireDistance');
    }
    if (!snapReleaseDistance.isFinite ||
        snapReleaseDistance < minimumSnapReleaseDistance ||
        snapReleaseDistance > maximumSnapReleaseDistance ||
        snapReleaseDistance < snapAcquireDistance) {
      throw ArgumentError.value(snapReleaseDistance, 'snapReleaseDistance');
    }
  }

  Map<String, Object> toJson() => <String, Object>{
    'version': version,
    'quality': quality.wireName,
    'targetFps': targetFps,
    'visualScale': visualScale,
    'alwaysOnTop': alwaysOnTop,
    'snapEnabled': snapEnabled,
    'snapAcquireDistance': snapAcquireDistance,
    'snapReleaseDistance': snapReleaseDistance,
  };

  DesktopCompanionPresentationConfigV1 copyWith({
    DesktopCompanionRenderQuality? quality,
    int? targetFps,
    double? visualScale,
    bool? alwaysOnTop,
    bool? snapEnabled,
    double? snapAcquireDistance,
    double? snapReleaseDistance,
  }) => DesktopCompanionPresentationConfigV1(
    quality: quality ?? this.quality,
    targetFps: targetFps ?? this.targetFps,
    visualScale: visualScale ?? this.visualScale,
    alwaysOnTop: alwaysOnTop ?? this.alwaysOnTop,
    snapEnabled: snapEnabled ?? this.snapEnabled,
    snapAcquireDistance: snapAcquireDistance ?? this.snapAcquireDistance,
    snapReleaseDistance: snapReleaseDistance ?? this.snapReleaseDistance,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DesktopCompanionPresentationConfigV1 &&
          quality == other.quality &&
          targetFps == other.targetFps &&
          visualScale == other.visualScale &&
          alwaysOnTop == other.alwaysOnTop &&
          snapEnabled == other.snapEnabled &&
          snapAcquireDistance == other.snapAcquireDistance &&
          snapReleaseDistance == other.snapReleaseDistance;

  @override
  int get hashCode => Object.hash(
    quality,
    targetFps,
    visualScale,
    alwaysOnTop,
    snapEnabled,
    snapAcquireDistance,
    snapReleaseDistance,
  );
}

/// Desktop-only source of truth for persisted companion presentation choices.
final class DesktopCompanionPreferencesService extends AppService {
  static const String storageKey =
      'maaso.desktop_companion.presentation_config.v1';

  final StreamController<DesktopCompanionPresentationConfigV1> _changes =
      StreamController<DesktopCompanionPresentationConfigV1>.broadcast(
        sync: true,
      );
  Future<void> _writeQueue = Future<void>.value();
  DesktopCompanionPresentationConfigV1 _config =
      DesktopCompanionPresentationConfigV1.defaults;

  DesktopCompanionPresentationConfigV1 get config => _config;

  Stream<DesktopCompanionPresentationConfigV1> get changes => _changes.stream;

  @override
  void onInit() {
    super.onInit();
    final raw = SpUtils.getString(storageKey);
    if (raw.isEmpty) return;
    final decoded = DesktopCompanionPresentationConfigV1.tryDecode(raw);
    if (decoded != null) {
      _config = decoded;
      return;
    }
    final migrated = DesktopCompanionPresentationConfigV1.tryMigrateLegacyV1(
      raw,
    );
    if (migrated == null) return;
    _config = migrated;
    _writeQueue = SpUtils.put(
      storageKey,
      jsonEncode(migrated.toJson()),
    ).then((_) {});
  }

  Future<bool> setQuality(DesktopCompanionRenderQuality value) =>
      _mutate((current) => current.copyWith(quality: value));

  Future<bool> setTargetFps(int value) =>
      _mutate((current) => current.copyWith(targetFps: value));

  Future<bool> setVisualScale(double value) =>
      _mutate((current) => current.copyWith(visualScale: value));

  Future<bool> setAlwaysOnTop(bool value) =>
      _mutate((current) => current.copyWith(alwaysOnTop: value));

  Future<bool> setSnapEnabled(bool value) =>
      _mutate((current) => current.copyWith(snapEnabled: value));

  Future<bool> setSnapDistances({
    required double acquire,
    required double release,
  }) => _mutate(
    (current) => current.copyWith(
      snapAcquireDistance: acquire,
      snapReleaseDistance: release,
    ),
  );

  Future<bool> _mutate(
    DesktopCompanionPresentationConfigV1 Function(
      DesktopCompanionPresentationConfigV1 current,
    )
    transform,
  ) {
    final result = _writeQueue.then<bool>((_) async {
      if (isClosed) return false;
      final next = transform(_config);
      if (next == _config) return true;
      final persisted = await SpUtils.put(
        storageKey,
        jsonEncode(next.toJson()),
      );
      if (!persisted || isClosed) return false;
      _config = next;
      _changes.add(next);
      return true;
    });
    _writeQueue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  @override
  void onClose() {
    unawaited(_changes.close());
    super.onClose();
  }
}

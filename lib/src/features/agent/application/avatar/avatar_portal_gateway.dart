import 'dart:async';
import 'dart:math' as math;

enum AvatarPortalProfile {
  desktopHigh('desktopHigh'),
  compactHigh('compactHigh'),
  compactBalanced('compactBalanced'),
  compactLow('compactLow');

  const AvatarPortalProfile(this.wireName);

  final String wireName;
}

abstract final class AvatarPortalCapturePolicy {
  static const Set<int> supportedTargetFps = <int>{24, 30, 60};
  static const minimumSceneDimension = 64;
  // Scene capture is used by the macOS window. The mobile Unity underlay and
  // avatar-only portal profiles keep their existing budgets.
  static const maximumSceneWidth = 3840;
  static const maximumSceneHeight = 2160;

  static bool supportsTargetFps(int value) =>
      supportedTargetFps.contains(value);

  static bool supportsSceneViewport({
    required bool includeWorld,
    int? viewportWidth,
    int? viewportHeight,
  }) => includeWorld
      ? viewportWidth != null &&
            viewportHeight != null &&
            viewportWidth >= minimumSceneDimension &&
            viewportWidth <= maximumSceneWidth &&
            viewportHeight >= minimumSceneDimension &&
            viewportHeight <= maximumSceneHeight
      : viewportWidth == null && viewportHeight == null;

  /// Fit the physical viewport uniformly within the scene texture budget.
  static ({int width, int height})? fitSceneViewport({
    required double width,
    required double height,
    required double devicePixelRatio,
  }) {
    final pixelWidth = width * devicePixelRatio;
    final pixelHeight = height * devicePixelRatio;
    if (!pixelWidth.isFinite ||
        !pixelHeight.isFinite ||
        pixelWidth <= 0 ||
        pixelHeight <= 0 ||
        devicePixelRatio <= 0) {
      return null;
    }
    final scale = math.min(
      1.0,
      math.min(
        maximumSceneWidth / pixelWidth,
        maximumSceneHeight / pixelHeight,
      ),
    );
    final fittedWidth = (pixelWidth * scale).round();
    final fittedHeight = (pixelHeight * scale).round();
    if (!supportsSceneViewport(
      includeWorld: true,
      viewportWidth: fittedWidth,
      viewportHeight: fittedHeight,
    )) {
      return null;
    }
    return (width: fittedWidth, height: fittedHeight);
  }
}

final class AvatarPortalLease {
  const AvatarPortalLease({
    required this.textureId,
    required this.width,
    required this.height,
    required this.generation,
  });

  final int textureId;
  final int width;
  final int height;
  final int generation;

  double get aspectRatio => width / height;
}

enum AvatarPortalEventType { firstFrame, released }

final class AvatarPortalEvent {
  const AvatarPortalEvent._({
    required this.type,
    required this.generation,
    this.textureId,
    this.width,
    this.height,
    this.reason = '',
  });

  const AvatarPortalEvent.firstFrame({
    required int generation,
    required int textureId,
    required int width,
    required int height,
  }) : this._(
         type: AvatarPortalEventType.firstFrame,
         generation: generation,
         textureId: textureId,
         width: width,
         height: height,
       );

  const AvatarPortalEvent.released({
    required int generation,
    required String reason,
  }) : this._(
         type: AvatarPortalEventType.released,
         generation: generation,
         reason: reason,
       );

  final AvatarPortalEventType type;
  final int generation;
  final int? textureId;
  final int? width;
  final int? height;
  final String reason;
}

final class AvatarPortalFailure implements Exception {
  const AvatarPortalFailure(this.code, this.message, {this.cause});

  final String code;
  final String message;
  final Object? cause;

  @override
  String toString() => 'AvatarPortalFailure($code): $message';
}

abstract interface class AvatarPortalGateway {
  Stream<AvatarPortalEvent> get events;

  Future<AvatarPortalLease> acquire({
    required int generation,
    AvatarPortalProfile profile = AvatarPortalProfile.compactHigh,
    int targetFps = 30,
    bool includeWorld = false,
    int? viewportWidth,
    int? viewportHeight,
  });

  Future<void> suspend(int generation);

  Future<void> resume(int generation);

  Future<void> release(int generation);

  Future<void> close();
}

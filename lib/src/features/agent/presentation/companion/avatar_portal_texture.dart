import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_portal_gateway.dart';

class AvatarPortalTexture extends StatelessWidget {
  const AvatarPortalTexture({
    required this.lease,
    this.fillViewport = false,
    super.key,
  });

  static const Size logicalViewportSize = Size(160, 280);
  static const BoxConstraints logicalViewportConstraints = BoxConstraints(
    maxWidth: 160,
    maxHeight: 280,
  );
  static const Key logicalViewportKey = ValueKey<String>(
    'avatar-portal-logical-viewport',
  );
  static const Key iosOrientationCorrectionKey = ValueKey<String>(
    'avatar-portal-ios-orientation-correction',
  );
  static const Key appleOrientationCorrectionKey = iosOrientationCorrectionKey;

  final AvatarPortalLease lease;
  final bool fillViewport;

  @override
  Widget build(BuildContext context) {
    final texture = Texture(
      key: ValueKey<String>(
        'avatar-portal-texture-${lease.generation}-${lease.textureId}',
      ),
      textureId: lease.textureId,
      filterQuality: FilterQuality.high,
    );
    final correctedTexture =
        defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS
        ? Transform.flip(
            key: appleOrientationCorrectionKey,
            flipY: true,
            child: texture,
          )
        : texture;
    if (fillViewport) {
      return IgnorePointer(
        child: RepaintBoundary(child: SizedBox.expand(child: correctedTexture)),
      );
    }
    return IgnorePointer(
      ignoring: true,
      child: RepaintBoundary(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: ConstrainedBox(
            key: logicalViewportKey,
            constraints: logicalViewportConstraints,
            child: AspectRatio(
              aspectRatio: lease.aspectRatio,
              child: correctedTexture,
            ),
          ),
        ),
      ),
    );
  }
}

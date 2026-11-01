import 'package:flutter/foundation.dart';

/// Keeps the in-window Avatar presentation on mobile and web while desktop
/// uses the independent companion window instead.
abstract final class EmbeddedAvatarPresentationPolicy {
  static bool shouldEmbed({bool? isWeb, TargetPlatform? platform}) {
    if (isWeb ?? kIsWeb) return true;
    return switch (platform ?? defaultTargetPlatform) {
      TargetPlatform.macOS || TargetPlatform.windows => false,
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.linux ||
      TargetPlatform.fuchsia => true,
    };
  }
}

import 'app_host_platform_resolver_stub.dart'
    if (dart.library.io) 'app_host_platform_resolver_io.dart'
    if (dart.library.js_interop) 'app_host_platform_resolver_web.dart';

enum AppHostPlatform { web, android, ios, macos, windows, linux, fuchsia }

/// User-visible actions that depend on platform runtimes or hardware plugins.
///
/// This is deliberately separate from the Agent capability registry: it
/// describes host support, not what an Agent is authorized to invoke.
enum AppActionCapability {
  advancedAiSettings,
  onDeviceLlm,
  onDeviceSpeechModels,
  unityAvatar,
  remoteUnityAvatarAssets,
  remoteUnityWorldAssets,
  localUnityMediaCapture,
  realtimeRtc,
  onDeviceFaceDetection,
  bluetooth,
  embeddedSurface,
  localSpeechRecognition,
}

class AppCapabilityStatus {
  const AppCapabilityStatus({
    required this.capability,
    required this.available,
  });

  final AppActionCapability capability;
  final bool available;
}

class AppRouteCapabilityStatus {
  const AppRouteCapabilityStatus({
    required this.routeAvailable,
    required this.requiredActions,
    required this.unavailableActions,
  });

  final bool routeAvailable;
  final Set<AppActionCapability> requiredActions;
  final Set<AppActionCapability> unavailableActions;

  bool get actionAvailable => unavailableActions.isEmpty;
  bool get isLimited => routeAvailable && !actionAvailable;
}

class AppPlatformCapabilities {
  const AppPlatformCapabilities.forPlatform(this.platform);

  factory AppPlatformCapabilities.current() {
    return AppPlatformCapabilities.forPlatform(
      switch (currentHostOperatingSystem()) {
        'web' => AppHostPlatform.web,
        'android' => AppHostPlatform.android,
        'ios' => AppHostPlatform.ios,
        'macos' => AppHostPlatform.macos,
        'windows' => AppHostPlatform.windows,
        'linux' => AppHostPlatform.linux,
        'fuchsia' => AppHostPlatform.fuchsia,
        _ => AppHostPlatform.fuchsia,
      },
    );
  }

  final AppHostPlatform platform;

  bool get supportsAdvancedAiSettings =>
      actionStatus(AppActionCapability.advancedAiSettings).available;

  bool get supportsOnDeviceLlm =>
      actionStatus(AppActionCapability.onDeviceLlm).available;

  bool get supportsOnDeviceSpeechModels =>
      actionStatus(AppActionCapability.onDeviceSpeechModels).available;

  static const Map<String, Set<AppActionCapability>>
  routeAvailabilityRequirements = <String, Set<AppActionCapability>>{
    'advanced_features': <AppActionCapability>{
      AppActionCapability.advancedAiSettings,
    },
  };

  static const Map<String, Set<AppActionCapability>>
  routeActionRequirements = <String, Set<AppActionCapability>>{
    'home': <AppActionCapability>{
      AppActionCapability.unityAvatar,
      AppActionCapability.localSpeechRecognition,
      AppActionCapability.onDeviceFaceDetection,
    },
    'chat': <AppActionCapability>{AppActionCapability.localSpeechRecognition},
    'game_feed': <AppActionCapability>{AppActionCapability.embeddedSurface},
    'widgets_hub': <AppActionCapability>{AppActionCapability.embeddedSurface},
    'avatars': <AppActionCapability>{
      AppActionCapability.unityAvatar,
      AppActionCapability.remoteUnityAvatarAssets,
    },
    'agent_space': <AppActionCapability>{AppActionCapability.unityAvatar},
    'projector': <AppActionCapability>{AppActionCapability.bluetooth},
  };

  AppCapabilityStatus actionStatus(AppActionCapability capability) {
    return AppCapabilityStatus(
      capability: capability,
      available: switch (capability) {
        AppActionCapability.advancedAiSettings ||
        AppActionCapability.onDeviceLlm ||
        AppActionCapability.onDeviceSpeechModels =>
          platform == AppHostPlatform.macos ||
              platform == AppHostPlatform.windows ||
              platform == AppHostPlatform.linux,
        AppActionCapability.unityAvatar =>
          platform == AppHostPlatform.web ||
              platform == AppHostPlatform.android ||
              platform == AppHostPlatform.ios ||
              platform == AppHostPlatform.macos ||
              platform == AppHostPlatform.windows,
        AppActionCapability.remoteUnityAvatarAssets ||
        AppActionCapability.localUnityMediaCapture =>
          platform == AppHostPlatform.android ||
              platform == AppHostPlatform.ios ||
              platform == AppHostPlatform.macos,
        AppActionCapability.remoteUnityWorldAssets =>
          platform == AppHostPlatform.android ||
              platform == AppHostPlatform.ios,
        AppActionCapability.realtimeRtc ||
        AppActionCapability.onDeviceFaceDetection =>
          platform == AppHostPlatform.android ||
              platform == AppHostPlatform.ios,
        AppActionCapability.bluetooth =>
          platform == AppHostPlatform.android ||
              platform == AppHostPlatform.ios ||
              platform == AppHostPlatform.macos ||
              platform == AppHostPlatform.windows,
        AppActionCapability.embeddedSurface =>
          platform == AppHostPlatform.android ||
              platform == AppHostPlatform.ios ||
              platform == AppHostPlatform.macos,
        AppActionCapability.localSpeechRecognition =>
          platform != AppHostPlatform.web &&
              platform != AppHostPlatform.fuchsia,
      },
    );
  }

  AppRouteCapabilityStatus destinationStatus(String destinationId) {
    final routeRequired =
        routeAvailabilityRequirements[destinationId] ??
        const <AppActionCapability>{};
    final actionRequired =
        routeActionRequirements[destinationId] ?? const <AppActionCapability>{};
    final required = <AppActionCapability>{...routeRequired, ...actionRequired};
    final unavailable = required
        .where((capability) => !actionStatus(capability).available)
        .toSet();
    return AppRouteCapabilityStatus(
      routeAvailable: routeRequired.every(
        (capability) => actionStatus(capability).available,
      ),
      requiredActions: Set<AppActionCapability>.unmodifiable(required),
      unavailableActions: Set<AppActionCapability>.unmodifiable(unavailable),
    );
  }
}

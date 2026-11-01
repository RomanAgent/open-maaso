import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';

void main() {
  test('current host cannot be changed by a UI platform override', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      expect(
        AppPlatformCapabilities.current().platform,
        switch (Platform.operatingSystem) {
          'android' => AppHostPlatform.android,
          'ios' => AppHostPlatform.ios,
          'macos' => AppHostPlatform.macos,
          'windows' => AppHostPlatform.windows,
          'linux' => AppHostPlatform.linux,
          'fuchsia' => AppHostPlatform.fuchsia,
          _ => AppHostPlatform.fuchsia,
        },
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test('advanced settings route is desktop-only', () {
    for (final platform in AppHostPlatform.values) {
      final capabilities = AppPlatformCapabilities.forPlatform(platform);
      for (final destination in AppRouteCatalog.destinations) {
        final isDesktop =
            platform == AppHostPlatform.macos ||
            platform == AppHostPlatform.windows ||
            platform == AppHostPlatform.linux;
        final expected = destination.id != 'advanced_features' || isDesktop;
        expect(
          capabilities.destinationStatus(destination.id).routeAvailable,
          expected,
          reason: '${platform.name} ${destination.id}',
        );
      }
    }
  });

  test('route capability declarations reference public destinations', () {
    final publicIds = AppRouteCatalog.destinations
        .map((destination) => destination.id)
        .toSet();
    expect(
      publicIds.containsAll(<String>{
        ...AppPlatformCapabilities.routeActionRequirements.keys,
        ...AppPlatformCapabilities.routeAvailabilityRequirements.keys,
      }),
      isTrue,
    );
    expect(AppPlatformCapabilities.routeActionRequirements['agent_space'], {
      AppActionCapability.unityAvatar,
    });
    expect(
      AppPlatformCapabilities.routeActionRequirements.containsKey('world'),
      isFalse,
    );
    expect(
      AppPlatformCapabilities.routeActionRequirements.containsKey('highlights'),
      isFalse,
    );
  });

  test('on-device AI capabilities are available only on desktop', () {
    for (final platform in AppHostPlatform.values) {
      final capabilities = AppPlatformCapabilities.forPlatform(platform);
      final expected =
          platform == AppHostPlatform.macos ||
          platform == AppHostPlatform.windows ||
          platform == AppHostPlatform.linux;
      expect(capabilities.supportsAdvancedAiSettings, expected);
      expect(capabilities.supportsOnDeviceLlm, expected);
      expect(capabilities.supportsOnDeviceSpeechModels, expected);
    }
  });

  test('mobile hosts expose the currently required action set', () {
    for (final platform in <AppHostPlatform>[
      AppHostPlatform.android,
      AppHostPlatform.ios,
    ]) {
      final capabilities = AppPlatformCapabilities.forPlatform(platform);
      for (final destinationId
          in AppPlatformCapabilities.routeActionRequirements.keys) {
        expect(
          capabilities.destinationStatus(destinationId).isLimited,
          isFalse,
          reason: '${platform.name} $destinationId',
        );
      }
    }
  });

  test(
    'desktop Unity is available while unsupported actions stay explicit',
    () {
      final macos = AppPlatformCapabilities.forPlatform(AppHostPlatform.macos);
      final windows = AppPlatformCapabilities.forPlatform(
        AppHostPlatform.windows,
      );

      expect(
        macos.destinationStatus('agent_space').unavailableActions,
        isEmpty,
      );
      expect(macos.destinationStatus('avatars').isLimited, isFalse);
      expect(
        windows.destinationStatus('agent_space').unavailableActions,
        isEmpty,
      );
      expect(
        windows.destinationStatus('avatars').unavailableActions,
        equals(<AppActionCapability>{
          AppActionCapability.remoteUnityAvatarAssets,
        }),
      );
      expect(macos.destinationStatus('widgets_hub').isLimited, isFalse);
      expect(windows.destinationStatus('widgets_hub').isLimited, isTrue);
      expect(windows.destinationStatus('projector').isLimited, isFalse);
    },
  );

  test('web exposes Unity while retaining unrelated action gaps', () {
    final web = AppPlatformCapabilities.forPlatform(AppHostPlatform.web);

    expect(web.destinationStatus('moments').isLimited, isFalse);
    expect(
      web.destinationStatus('home').unavailableActions,
      equals(<AppActionCapability>{
        AppActionCapability.localSpeechRecognition,
        AppActionCapability.onDeviceFaceDetection,
      }),
    );
    expect(web.destinationStatus('agent_space').unavailableActions, isEmpty);

    expect(
      web.destinationStatus('avatars').unavailableActions,
      equals(<AppActionCapability>{
        AppActionCapability.remoteUnityAvatarAssets,
      }),
    );
    expect(
      web.destinationStatus('widgets_hub').unavailableActions,
      contains(AppActionCapability.embeddedSurface),
    );
  });

  test(
    'local Agent space still reports unsupported Unity hosts explicitly',
    () {
      const linux = AppPlatformCapabilities.forPlatform(AppHostPlatform.linux);
      expect(linux.destinationStatus('agent_space').unavailableActions, {
        AppActionCapability.unityAvatar,
      });
    },
  );
}

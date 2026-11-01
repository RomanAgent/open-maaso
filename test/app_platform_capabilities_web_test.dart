import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';

void main() {
  test('web conditional resolver hides advanced and local model paths', () {
    final platform = AppPlatformCapabilities.current();
    expect(platform.platform, AppHostPlatform.web);
    expect(platform.supportsAdvancedAiSettings, isFalse);
    expect(platform.supportsOnDeviceLlm, isFalse);
    expect(platform.supportsOnDeviceSpeechModels, isFalse);

    final snapshot = AppCapabilitySnapshot.materialize(
      generation: 0,
      draft:
          AppPlatformCapabilitySnapshotResolver(
            routeIds: const <String>{'advanced_features'},
          ).resolve(
            AppCapabilitySnapshotContext(
              hostPlatform: platform.platform,
              rolloutGeneration: 0,
            ),
          ),
    );

    for (final capability in <AppActionCapability>[
      AppActionCapability.advancedAiSettings,
      AppActionCapability.onDeviceLlm,
      AppActionCapability.onDeviceSpeechModels,
    ]) {
      final decision = snapshot.decision(
        AppCapabilityKey.platformAction(capability),
      )!;
      expect(decision.exposure, AppCapabilityExposure.hidden);
      expect(decision.admission, AppCapabilityAdmission.denied);
      expect(decision.readiness, AppCapabilityReadiness.unavailable);
    }

    final advancedRoute = snapshot.decision(
      AppCapabilityKey.route('advanced_features'),
    )!;
    expect(advancedRoute.exposure, AppCapabilityExposure.hidden);
    expect(advancedRoute.admission, AppCapabilityAdmission.denied);
    expect(advancedRoute.readiness, AppCapabilityReadiness.unavailable);
    expect(snapshot.allows(AppCapabilityKey.cloudLlm), isTrue);
    expect(snapshot.allows(AppCapabilityKey.cloudTts), isTrue);
  }, skip: !kIsWeb);
}

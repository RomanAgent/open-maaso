import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/utils/sp_utils.dart';
import 'package:maaso/src/desktop/application/desktop_companion_preferences_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<DesktopCompanionPreferencesService> createService(
    Map<String, Object> values,
  ) async {
    SharedPreferences.setMockInitialValues(values);
    await SpUtils.init();
    final service = DesktopCompanionPreferencesService();
    service.initializeLifecycle();
    return service;
  }

  test(
    'defaults select the normal desktop size from four supported tiers',
    () async {
      final service = await createService(<String, Object>{});
      addTearDown(service.closeLifecycle);

      expect(service.config, DesktopCompanionPresentationConfigV1.defaults);
      expect(service.config.quality, DesktopCompanionRenderQuality.crisp);
      expect(service.config.targetFps, 30);
      expect(
        DesktopCompanionPresentationConfigV1.supportedVisualScales,
        <double>[1.2, 1.8, 2.4, 3.0],
      );
      expect(service.config.visualScale, 1.8);
      expect(service.config.alwaysOnTop, isTrue);
      expect(service.config.snapEnabled, isFalse);
      expect(service.config.snapAcquireDistance, 24);
      expect(service.config.snapReleaseDistance, 40);
    },
  );

  test('strict V1 codec accepts only the four desktop size tiers', () {
    final valid = DesktopCompanionPresentationConfigV1.defaults.toJson();

    for (final scale
        in DesktopCompanionPresentationConfigV1.supportedVisualScales) {
      final decoded = DesktopCompanionPresentationConfigV1.tryFromJson(
        <String, Object?>{...valid, 'visualScale': scale},
      );
      expect(decoded?.visualScale, scale);
    }

    expect(
      DesktopCompanionPresentationConfigV1.tryFromJson(<String, Object?>{
        ...valid,
        'quality': 'ultra',
      }),
      isNull,
    );
    expect(
      DesktopCompanionPresentationConfigV1.tryFromJson(<String, Object?>{
        ...valid,
        'targetFps': 25,
      }),
      isNull,
    );
    expect(
      DesktopCompanionPresentationConfigV1.tryFromJson(<String, Object?>{
        ...valid,
        'visualScale': double.nan,
      }),
      isNull,
    );
    expect(
      DesktopCompanionPresentationConfigV1.tryFromJson(<String, Object?>{
        ...valid,
        'visualScale': 1.5,
      }),
      isNull,
    );
    expect(
      DesktopCompanionPresentationConfigV1.tryFromJson(<String, Object?>{
        ...valid,
        'visualScale': 3.1,
      }),
      isNull,
    );
    expect(
      DesktopCompanionPresentationConfigV1.tryFromJson(<String, Object?>{
        ...valid,
        'snapAcquireDistance': 48.0,
        'snapReleaseDistance': 24.0,
      }),
      isNull,
    );
    expect(
      DesktopCompanionPresentationConfigV1.tryFromJson(<String, Object?>{
        ...valid,
        'futureField': true,
      }),
      isNull,
    );
    final missing = Map<String, Object>.from(valid)..remove('targetFps');
    expect(DesktopCompanionPresentationConfigV1.tryFromJson(missing), isNull);
  });

  test(
    'corrupt persistence falls back without leaking partial values',
    () async {
      final service = await createService(<String, Object>{
        DesktopCompanionPreferencesService.storageKey:
            jsonEncode(<String, Object>{
              ...DesktopCompanionPresentationConfigV1.defaults.toJson(),
              'targetFps': 12,
            }),
      });
      addTearDown(service.closeLifecycle);

      expect(service.config, DesktopCompanionPresentationConfigV1.defaults);
    },
  );

  test(
    'legacy continuous scale migrates without losing other settings',
    () async {
      final legacy = <String, Object>{
        'version': 1,
        'quality': 'balanced',
        'targetFps': 60,
        'visualScale': 1.5,
        'alwaysOnTop': false,
        'snapEnabled': true,
        'snapAcquireDistance': 20.0,
        'snapReleaseDistance': 36.0,
      };
      final service = await createService(<String, Object>{
        DesktopCompanionPreferencesService.storageKey: jsonEncode(legacy),
      });
      addTearDown(service.closeLifecycle);

      expect(service.config.visualScale, 1.8);
      expect(service.config.quality, DesktopCompanionRenderQuality.balanced);
      expect(service.config.targetFps, 60);
      expect(service.config.alwaysOnTop, isFalse);
      expect(service.config.snapEnabled, isTrue);
      expect(service.config.snapAcquireDistance, 20);
      expect(service.config.snapReleaseDistance, 36);

      await Future<void>.delayed(Duration.zero);
      final persisted =
          jsonDecode(
                SpUtils.getString(
                  DesktopCompanionPreferencesService.storageKey,
                ),
              )
              as Map<String, dynamic>;
      expect(persisted['visualScale'], 1.8);
      expect(persisted['quality'], 'balanced');
      expect(persisted['targetFps'], 60);
      expect(persisted['alwaysOnTop'], isFalse);
      expect(persisted['snapEnabled'], isTrue);
    },
  );

  test('mutations serialize, publish complete snapshots, and reload', () async {
    final service = await createService(<String, Object>{});
    addTearDown(service.closeLifecycle);
    final emitted = <DesktopCompanionPresentationConfigV1>[];
    final subscription = service.changes.listen(emitted.add);
    addTearDown(subscription.cancel);

    await Future.wait(<Future<bool>>[
      service.setQuality(DesktopCompanionRenderQuality.balanced),
      service.setTargetFps(60),
      service.setVisualScale(3.0),
      service.setAlwaysOnTop(false),
      service.setSnapEnabled(true),
      service.setSnapDistances(acquire: 20, release: 36),
    ]);

    expect(service.config.quality, DesktopCompanionRenderQuality.balanced);
    expect(service.config.targetFps, 60);
    expect(service.config.visualScale, 3.0);
    expect(service.config.alwaysOnTop, isFalse);
    expect(service.config.snapEnabled, isTrue);
    expect(service.config.snapAcquireDistance, 20);
    expect(service.config.snapReleaseDistance, 36);
    expect(emitted, hasLength(6));
    expect(emitted.last, service.config);

    final reloaded = DesktopCompanionPreferencesService();
    reloaded.initializeLifecycle();
    addTearDown(reloaded.closeLifecycle);
    expect(reloaded.config, service.config);
  });
}

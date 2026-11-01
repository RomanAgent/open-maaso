import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_localization.dart';
import 'package:maaso/src/core/utils/sp_utils.dart';
import 'package:maaso/src/desktop/application/desktop_companion_preferences_service.dart';
import 'package:maaso/src/features/settings/presentation/agent_settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('desktop presentation controls are labelled and interactive', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await SpUtils.init();
    final service = DesktopCompanionPreferencesService();
    service.initializeLifecycle();
    addTearDown(service.closeLifecycle);
    AppLocalization.updateLocale(const Locale('en'));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: DesktopCompanionPresentationSettingsSection(
              preferences: service,
            ),
          ),
        ),
      ),
    );

    expect(find.text('Desktop pet'), findsOneWidget);
    expect(find.text('Render quality'), findsOneWidget);
    expect(find.text('Frame rate'), findsOneWidget);
    expect(find.text('Avatar size'), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
    var slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.min, 0);
    expect(slider.max, 3);
    expect(slider.divisions, 3);
    expect(slider.value, 1);
    expect(find.text('Normal（180%）'), findsOneWidget);
    expect(
      tester.getSize(find.byType(Slider)).height,
      greaterThanOrEqualTo(44),
    );
    expect(find.byType(Switch), findsNWidgets(2));
    for (final switchFinder in find.byType(Switch).evaluate()) {
      final size = tester.getSize(find.byWidget(switchFinder.widget));
      expect(size.width, greaterThanOrEqualTo(44));
      expect(size.height, greaterThanOrEqualTo(44));
    }

    final semantics = tester.getSemantics(find.text('Always on top'));
    expect(semantics.label, contains('Always on top'));
    final semanticsHandle = tester.ensureSemantics();
    expect(find.bySemanticsLabel('Avatar size'), findsOneWidget);

    const tiers = <(double, double, String)>[
      (0, 1.2, 'Small（120%）'),
      (1, 1.8, 'Normal（180%）'),
      (2, 2.4, 'Large（240%）'),
      (3, 3.0, 'Extra large（300%）'),
    ];
    for (final (index, scale, label) in tiers) {
      slider = tester.widget<Slider>(find.byType(Slider));
      slider.onChanged!(index);
      slider.onChangeEnd!(index);
      await tester.pumpAndSettle();
      expect(find.text(label), findsOneWidget);
      expect(service.config.visualScale, scale);
    }

    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(service.config.alwaysOnTop, isFalse);
    semanticsHandle.dispose();
  });

  test('settings page gates the section on desktop service registration', () {
    final source = File(
      'lib/src/features/settings/presentation/agent_settings_page.dart',
    ).readAsStringSync();

    expect(
      source,
      contains('isRegistered<DesktopCompanionPreferencesService>()'),
    );
  });
}

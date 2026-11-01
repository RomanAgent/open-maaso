import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/alert_overlay_service.dart';
import 'package:maaso/src/core/widgets/theme.dart';
import 'package:maaso/src/core/widgets/ui/app_palette.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';

void main() {
  setUp(() => appServices.testMode = true);
  tearDown(() => appServices.reset());

  test('desktop limitations and alerts have no material rim or gradient', () {
    final menu = File(
      'lib/src/desktop/presentation/companion_function_menu.dart',
    ).readAsStringSync();
    expect(menu, isNot(contains('Border.all(')));
    final alert = File(
      'lib/src/core/services/alert_overlay_service.dart',
    ).readAsStringSync();
    expect(alert, isNot(contains('Border.all(')));
    expect(alert, isNot(contains('BoxShadow(')));
    expect(alert, isNot(contains('Transform.scale(')));
  });

  for (final brightness in Brightness.values) {
    final palette = AppPalette.of(brightness, AppAccent.blue);
    final frost = MaasoGlassTheme.fromPalette(palette);
    testWidgets(
      '$brightness urgent alert preserves explicit dismissal and readable action',
      (tester) async {
        final service = AlertOverlayService()..onInit();
        addTearDown(service.onClose);
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: rootNavigatorKey,
            theme: AppTheme.build(palette),
            home: const Scaffold(body: SizedBox.expand()),
          ),
        );
        EventBus().fire(
          AlertEvent(
            title: 'Attention',
            message: 'Please review',
            level: 'urgent',
            color: '#FFFF00',
            durationMs: 0,
            haptic: 'none',
          ),
        );
        await tester.pump();
        await tester.pumpAndSettle();
        expect(find.text('Attention'), findsOneWidget);
        expect(
          tester.widget<Text>(find.text('Attention')).style!.color,
          frost.foregroundPrimary,
        );
        final fill =
            tester
                    .widget<DecoratedBox>(
                      find.byKey(AppGlassSurface.frostedLayerKey),
                    )
                    .decoration
                as BoxDecoration;
        expect(fill.border, isNull);
        final action = tester.widget<ElevatedButton>(
          find.byType(ElevatedButton),
        );
        final color = action.style!.backgroundColor!.resolve({})!;
        expect(
          1.05 / (color.computeLuminance() + .05),
          greaterThanOrEqualTo(4.5),
        );
        await tester.tapAt(const Offset(2, 2));
        await tester.pumpAndSettle();
        expect(find.text('Attention'), findsOneWidget);
        await tester.tap(find.byType(ElevatedButton));
        await tester.pumpAndSettle();
        expect(find.text('Attention'), findsNothing);
        expect(tester.binding.transientCallbackCount, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final reducedMotion in [false, true]) {
    testWidgets(
      'explicit alert flash respects reduced motion $reducedMotion and expiry',
      (tester) async {
        final service = AlertOverlayService()..onInit();
        addTearDown(service.onClose);
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: rootNavigatorKey,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(disableAnimations: reducedMotion),
              child: child!,
            ),
            home: const Scaffold(body: SizedBox.expand()),
          ),
        );
        EventBus().fire(
          AlertEvent(
            title: 'Timed alert',
            level: 'urgent',
            durationMs: 1200,
            flash: true,
            haptic: 'none',
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        final feedback = tester.widgetList<Opacity>(find.byType(Opacity)).first;
        expect(feedback.opacity, reducedMotion ? 1 : lessThan(1));
        expect(feedback.opacity, greaterThanOrEqualTo(.96));
        await tester.pump(const Duration(milliseconds: 1300));
        await tester.pumpAndSettle();
        expect(find.text('Timed alert'), findsNothing);
        expect(tester.binding.transientCallbackCount, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

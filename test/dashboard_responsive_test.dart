import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/dashboard/application/dashboard_controller.dart';
import 'package:maaso/src/features/dashboard/presentation/dashboard_page.dart';

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.put<DashboardController>(DashboardController());
  });

  tearDown(appServices.reset);

  testWidgets('dashboard switches between compact and wide content layouts', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(390, 844));

    await tester.pumpWidget(const MaterialApp(home: DashboardPage()));
    await tester.pump();
    expect(find.byKey(DashboardPage.compactLayoutKey), findsOneWidget);
    expect(find.byKey(DashboardPage.wideLayoutKey), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.binding.setSurfaceSize(const Size(1200, 800));
    await tester.pump();
    expect(find.byKey(DashboardPage.compactLayoutKey), findsNothing);
    expect(find.byKey(DashboardPage.wideLayoutKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

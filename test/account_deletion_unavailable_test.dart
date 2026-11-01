import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/account_deletion/presentation/account_deletion_page.dart';
import 'account_deletion_service_test.dart' show DeletionFixture;

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });
  tearDown(appServices.reset);
  testWidgets('unavailable route never denies a previously accepted deletion', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: AccountDeletionRoutePage())),
    );
    expect(
      find.textContaining('Saved receipts remain available'),
      findsOneWidget,
    );
    expect(
      find.textContaining('No deletion request has been accepted'),
      findsNothing,
    );
  });
  testWidgets('failed status read preserves the held receipt and honest copy', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final f = DeletionFixture();
    addTearDown(f.service.dispose);
    f.saveReceipt();
    f.override = (_) async => throw StateError('test-only unavailable');
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(home: AccountDeletionPage(service: f.service)),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    });
    await tester.pumpAndSettle();
    expect(f.receipts.value?['requestId'], 'request-1');
    expect(
      find.textContaining('Saved receipts remain available'),
      findsOneWidget,
    );
    expect(
      find.textContaining('No deletion request has been accepted'),
      findsNothing,
    );
  });
}

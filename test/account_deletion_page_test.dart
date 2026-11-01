import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_service.dart';
import 'package:maaso/src/features/agent/application/ui_control/app_control_page_adapter.dart';
import 'package:maaso/src/features/account_deletion/application/account_deletion_page_adapter.dart';
import 'package:maaso/src/features/account_deletion/presentation/account_deletion_page.dart';
import 'account_deletion_service_test.dart' show DeletionFixture;

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });
  tearDown(appServices.reset);
  testWidgets(
    'deletion needs two acknowledgements and a separate human confirmation',
    (tester) async {
      tester.view.physicalSize = const Size(900, 2200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final f = DeletionFixture();
      addTearDown(f.service.dispose);
      Uri? opened;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: AccountDeletionPage(
              service: f.service,
              openExternal: (uri) async {
                opened = uri;
                return true;
              },
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      });
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apple subscriptions'));
      expect(opened?.host, 'apps.apple.com');
      await tester.runAsync(f.prepare);
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      });
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('deletion-confirm')));
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('deletion-confirm')))
            .onPressed,
        isNull,
      );
      for (final text in [
        'I understand Maaso data will be permanently erased.',
        'I understand subscriptions may continue charging separately.',
      ]) {
        await tester.ensureVisible(find.text(text));
        await tester.tap(find.text(text));
        await tester.pump();
      }
      await tester.ensureVisible(find.byKey(const Key('deletion-confirm')));
      await tester.tap(find.byKey(const Key('deletion-confirm')));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      });
      await tester.pumpAndSettle();
      expect(f.confirms, 0);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining(
            'remaining coins and membership benefits',
          ),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Keep account'));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      });
      await tester.pumpAndSettle();
      expect(f.confirms, 0);
      await tester.tap(find.byKey(const Key('deletion-confirm')));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      });
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm deletion'));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      });
      await tester.pumpAndSettle();
      expect(f.confirms, 1);
      expect(f.closes, 1);
    },
  );
  testWidgets(
    'AppControl can prepare but cannot confirm, and typing takes over',
    (tester) async {
      final f = DeletionFixture();
      final control = AgentUiControlService();
      addTearDown(f.service.dispose);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: AccountDeletionPage(service: f.service, uiControl: control),
          ),
        ),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      });
      await tester.pumpAndSettle();
      final lease = control.coordinator
          .begin(
            sessionId: 'deletion-fixture',
            purpose: 'Review deletion',
            targetRoute: '/account-deletion',
          )
          .value!;
      final adapter = control.adapters
          .resolve<AccountDeletionPageAdapter>(
            route: '/account-deletion',
            lease: lease,
          )
          .value!;
      Future<bool> run(
        String action, [
        Map<String, Object?> args = const {},
      ]) async => (await adapter.executeAppControlAction(
        lease: lease,
        actionId: action,
        arguments: args,
        executionContext: AppControlActionExecutionContext.host(
          requiresCommit: false,
          authorityIsCurrent: () => true,
          staleCode: 'stale',
        ),
      )).isSuccess;
      expect(await run('prepare_deletion_review'), true);
      expect(await run('confirm_deletion'), false);
      expect(
        await run('prepare_deletion_review', {'acknowledgeErasure': true}),
        false,
      );
      expect(f.confirms, 0);
      await tester.ensureVisible(
        find.widgetWithText(TextField, 'Account email'),
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Account email'),
        'private@example.invalid',
      );
      expect(await run('read_deletion_status'), false);
      f.account = 'account-b';
      f.service.contextChanged();
      await tester.pump();
      expect(find.text('private@example.invalid'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(control.adapters.length, 0);
      expect(await run('prepare_deletion_review'), false);
      await control.coordinator.dispose();
    },
  );
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_service.dart';
import 'package:maaso/src/features/agent/application/ui_control/app_control_page_adapter.dart';
import 'package:maaso/src/features/privacy/application/privacy_service.dart';
import 'package:maaso/src/features/privacy/domain/privacy_models.dart';
import 'package:maaso/src/features/privacy/presentation/privacy_page.dart';
import 'package:maaso/src/features/privacy/presentation/privacy_page_adapter.dart';
import 'privacy_models_test.dart' show privacySnapshotJson;
import 'privacy_service_test.dart' show PrivacyFake;

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });
  tearDown(appServices.reset);
  testWidgets(
    'visible refresh is safe but agent cannot declare age or grant consent',
    (tester) async {
      final gateway = PrivacyFake()
        ..value = PrivacySnapshot.fromJson(
          privacySnapshotJson(age: 'unconfirmed', allow: false),
        );
      final service = PrivacyService(gateway: gateway);
      final control = AgentUiControlService();
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: PrivacyPage(service: service, uiControl: control),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final lease = control.coordinator
          .begin(
            sessionId: 'privacy-test',
            purpose: 'Read privacy status',
            targetRoute: '/privacy',
          )
          .value!;
      final adapter = control.adapters
          .resolve<PrivacyPageAdapter>(route: '/privacy', lease: lease)
          .value!;
      Future<bool> run(
        String id, [
        Map<String, Object?> arguments = const {},
      ]) async => (await adapter.executeAppControlAction(
        lease: lease,
        actionId: id,
        arguments: arguments,
        executionContext: AppControlActionExecutionContext.host(
          requiresCommit: false,
          authorityIsCurrent: () => true,
          staleCode: 'stale',
        ),
      )).isSuccess;
      expect(find.byKey(const Key('privacy-refresh')), findsOneWidget);
      expect(
        adapter.appControlActions.single.id,
        PrivacyPageAdapter.refreshAction,
      );
      expect(await run(PrivacyPageAdapter.refreshAction), isTrue);
      expect(
        await run('humanDeclareAge', {'birthDate': '2000-01-01'}),
        isFalse,
      );
      expect(await run('humanSetConsent', {'allow': true}), isFalse);
      expect(
        await run(PrivacyPageAdapter.refreshAction, {'allow': true}),
        isFalse,
      );
      expect(gateway.writes, 0);
      await tester.enterText(
        find.byKey(const Key('privacy-birth-date')),
        '2000',
      );
      expect(await run(PrivacyPageAdapter.refreshAction), isFalse);
      expect(gateway.writes, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(control.adapters.length, 0);
      expect(await run(PrivacyPageAdapter.refreshAction), isFalse);
      await control.coordinator.dispose();
    },
  );
}

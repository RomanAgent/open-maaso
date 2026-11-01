import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/app/app_agent_shell.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_coordinator.dart';
import 'package:maaso/src/features/agent/presentation/companion/avatar_portal_scope.dart';
import 'package:maaso/src/features/agent/presentation/companion/companion_session_scope.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AgentUiControlCoordinator uiControl;

  setUp(() async {
    await appServices.reset();
    uiControl = AgentUiControlCoordinator();
  });

  tearDown(() async {
    await uiControl.dispose();
    await appServices.reset();
  });

  testWidgets(
    'device portal survives account mount changes while voice is reconciled',
    (tester) async {
      final graphRevision = ValueNotifier<int>(0);
      addTearDown(graphRevision.dispose);
      final activeAvatar = appServices.put(ActiveAvatarRuntime());
      activeAvatar.register(_ReadyAvatarRuntime()..isReady.value = true);

      await _mountShell(tester, uiControl, graphRevision);
      final signedOutContext = tester.element(find.byKey(_contentKey));
      final devicePortal = AvatarPortalScope.of(signedOutContext).portal;
      expect(CompanionSessionScope.maybeOf(signedOutContext), isNull);

      appServices.put(DBService());
      appServices.put(AgentRuntimeRegistry());
      await _rebuildShell(tester, graphRevision, waitForVoice: true);
      final accountAContext = tester.element(find.byKey(_contentKey));
      final accountAVoice = CompanionSessionScope.of(accountAContext).voice;
      expect(AvatarPortalScope.of(accountAContext).portal, same(devicePortal));

      await appServices.delete<DBService>();
      await appServices.delete<AgentRuntimeRegistry>();
      await _rebuildShell(tester, graphRevision);
      final unmountedContext = tester.element(find.byKey(_contentKey));
      expect(CompanionSessionScope.maybeOf(unmountedContext), isNull);
      expect(AvatarPortalScope.of(unmountedContext).portal, same(devicePortal));
      accountAVoice.activate();
      expect(accountAVoice.active, isFalse);

      appServices.put(DBService());
      appServices.put(AgentRuntimeRegistry());
      await _rebuildShell(tester, graphRevision, waitForVoice: true);
      final accountBContext = tester.element(find.byKey(_contentKey));
      final accountBVoice = CompanionSessionScope.of(accountBContext).voice;
      expect(accountBVoice, isNot(same(accountAVoice)));
      expect(AvatarPortalScope.of(accountBContext).portal, same(devicePortal));
    },
  );
}

const _contentKey = ValueKey<String>('account-companion-content');

Future<void> _mountShell(
  WidgetTester tester,
  AgentUiControlCoordinator uiControl,
  ValueNotifier<int> graphRevision,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ValueListenableBuilder<int>(
        valueListenable: graphRevision,
        builder: (_, _, _) => AppAgentShell(
          coordinator: uiControl,
          child: const ColoredBox(key: _contentKey, color: Colors.white),
        ),
      ),
    ),
  );
  await _pumpReconcileFrames(tester);
}

Future<void> _rebuildShell(
  WidgetTester tester,
  ValueNotifier<int> graphRevision, {
  bool waitForVoice = false,
}) async {
  graphRevision.value++;
  await _pumpReconcileFrames(tester, waitForVoice: waitForVoice);
}

Future<void> _pumpReconcileFrames(
  WidgetTester tester, {
  bool waitForVoice = false,
}) async {
  for (var attempt = 0; attempt < 10; attempt += 1) {
    await tester.pump();
    if (!waitForVoice ||
        find.byType(CompanionSessionScope).evaluate().isNotEmpty) {
      return;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
  }
}

class _ReadyAvatarRuntime extends AvatarRuntime {
  @override
  final AvatarBackendKind backendKind = AvatarBackendKind.unity;

  @override
  final isReady = false.obs;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/account_device_handoff.dart';
import 'package:maaso/src/core/models/account_device_lease.dart';
import 'package:maaso/src/core/services/account_device_lease_coordinator.dart';
import 'package:maaso/src/core/services/account_device_lease_transport.dart';
import 'package:maaso/src/core/services/agent_handoff_device_directory.dart';
import 'package:maaso/src/core/services/agent_handoff_service.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/widgets/theme.dart';
import 'package:maaso/src/core/widgets/ui/app_palette.dart';
import 'package:maaso/src/features/settings/presentation/device_handoff_panel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.utc(2026, 9, 8);
  final presence = AccountDevicePresenceReceipt(
    agentId: 'self',
    installationId: 'local-installation',
    runtimeInstanceId: 'local-runtime',
    presenceSessionId: 'local-presence',
    generation: 1,
    deviceLabel: 'Phone',
    platform: 'ios',
    appVersion: '1',
    openedAt: now,
    lastSeenAt: now,
    expiresAt: now.add(const Duration(minutes: 1)),
    remainingTtl: const Duration(minutes: 1),
    renewAfter: const Duration(seconds: 30),
  );
  late HandoffAccountContext? context;
  late _DirectoryAuthority authority;
  late _DirectoryGateway gateway;
  late AgentHandoffDeviceDirectory directory;
  late AgentHandoffService handoff;
  late _PresentationBridge bridge;

  AccountDevicePresenceView device(
    String id, {
    String platform = 'macos',
    bool holder = false,
    String? runtime,
    bool expired = false,
  }) => AccountDevicePresenceView(
    agentId: 'self',
    installationId: '$id-installation',
    runtimeInstanceId: runtime ?? '$id-runtime',
    presenceSessionId: id,
    deviceLabel: id == 'computer' ? 'My Mac' : id,
    platform: platform,
    appVersion: '1',
    openedAt: now,
    lastSeenAt: now,
    expiresAt: now.add(Duration(minutes: expired ? -1 : 1)),
    isCurrentHolder: holder,
  );

  setUp(() async {
    await appServices.reset();
    context = const HandoffAccountContext(
      environment: MaasoEnvironment.test,
      accountUuid: 'account-a',
      presenceSessionId: 'local-presence',
    );
    authority = _DirectoryAuthority(presence);
    gateway = _DirectoryGateway(
      AccountDevicePresenceListResult(
        presences: [device('computer')],
        snapshotAt: now,
        eventSequence: 1,
        truncated: false,
      ),
    );
    directory = AgentHandoffDeviceDirectory(
      gateway: gateway,
      authority: authority,
      accountContext: () => context,
    );
    bridge = _PresentationBridge();
    handoff = AgentHandoffService(
      authority: authority,
      gateway: _UnusedHandoffGateway(),
      bridge: bridge,
      accountContext: () => context,
      serializeAuthority: <T>(Future<T> Function() work) => work(),
    );
  });
  tearDown(() async {
    handoff.dispose();
    await appServices.reset();
  });

  test(
    'directory uses server snapshot time and filters local, expired and unsupported devices',
    () async {
      gateway.snapshot = AccountDevicePresenceListResult(
        presences: [
          device('computer'),
          device('local-presence'),
          device('clone', runtime: 'local-runtime'),
          device('holder', holder: true),
          device('expired', expired: true),
          device('browser', platform: 'web'),
          device('phone', platform: 'android'),
        ],
        snapshotAt: now,
        eventSequence: 2,
        truncated: false,
      );
      expect(
        (await directory.listTargets()).map(
          (device) => device.presenceSessionId,
        ),
        ['computer', 'phone'],
      );
      expect(gateway.account, 'account-a');
      expect(gateway.environment, MaasoEnvironment.test);
    },
  );

  test(
    'late discovery cannot leak another account device labels into a new account',
    () async {
      gateway.gate = Completer<AccountDevicePresenceListResult>();
      final request = directory.listTargets();
      final expectation = expectLater(request, throwsStateError);
      context = const HandoffAccountContext(
        environment: MaasoEnvironment.test,
        accountUuid: 'account-b',
        presenceSessionId: 'different-presence',
      );
      gateway.gate!.complete(gateway.snapshot);
      await expectation;
    },
  );

  test('signed-out discovery makes no transport call', () async {
    context = null;
    await expectLater(directory.listTargets(), throwsStateError);
    expect(gateway.calls, 0);
  });

  testWidgets(
    'settings shows live devices and revalidates a stale target before starting',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DeviceHandoffPanel(directory: directory, handoff: handoff),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('My Mac'), findsOneWidget);
      expect(find.text('macos'), findsOneWidget);
      gateway.snapshot = AccountDevicePresenceListResult(
        presences: const [],
        snapshotAt: now,
        eventSequence: 2,
        truncated: false,
      );
      await tester.tap(find.text('Switch here'));
      await tester.pumpAndSettle();
      expect(find.text('My Mac'), findsNothing);
      expect(handoff.phase, AgentHandoffPhase.idle);
      expect(bridge.avatarRequests, 0);
      expect(gateway.calls, 2);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'device controls lay out with the real app button theme on a phone',
    (tester) async {
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(
            AppPalette.of(Brightness.light, AppAccent.blue),
          ),
          home: Scaffold(
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                DeviceHandoffPanel(directory: directory, handoff: handoff),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      expect(find.text('Switch execution device'), findsOneWidget);
      expect(find.text('My Mac'), findsOneWidget);
      expect(find.text('Switch here').hitTestable(), findsOneWidget);
      expect(
        tester
            .getRect(find.byType(FilledButton))
            .overlaps(tester.getRect(find.text('My Mac'))),
        isFalse,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('execution preparation does not overlay unrelated controls', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: [
              Center(
                child: TextButton(
                  onPressed: () => taps++,
                  child: const Text('Other action'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('Other action'));
    expect(taps, 1);
    // Navigator installs its own route barrier even without a handoff.
    // The handoff must not add another one or consume taps above Home.
    final routeBarrierCount = find.byType(ModalBarrier).evaluate().length;
    bridge.avatarGate = Completer<HandoffAvatarIdentity>();
    final pending = handoff.request('computer');
    final expectation = expectLater(pending, throwsStateError);
    try {
      await tester.pump();
      expect(find.text('Getting ready…'), findsNothing);
      expect(find.byType(ModalBarrier), findsNWidgets(routeBarrierCount));
      expect(find.byType(Card), findsNothing);
      await tester.tapAt(tester.getCenter(find.text('Other action')));
      expect(taps, 2);
    } finally {
      if (!bridge.avatarGate!.isCompleted) {
        bridge.avatarGate!.completeError(StateError('renderer unavailable'));
      }
      await expectation;
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}

class _DirectoryAuthority implements AccountDeviceLeaseCoordinator {
  _DirectoryAuthority(this.currentPresence);
  @override
  final AccountDevicePresenceReceipt currentPresence;
  @override
  bool get canAdmitMutations => true;
  @override
  AccountDeviceLeaseReceipt? get currentReceipt => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DirectoryGateway implements AccountRuntimeDiscoveryGateway {
  _DirectoryGateway(this.snapshot);
  AccountDevicePresenceListResult snapshot;
  Completer<AccountDevicePresenceListResult>? gate;
  String? account;
  MaasoEnvironment? environment;
  int calls = 0;
  @override
  Future<AccountDevicePresenceListResult> listActivePresences({
    required MaasoEnvironment environment,
    required String accountUuid,
    String agentId = 'self',
    int limit = 50,
  }) async {
    calls++;
    account = accountUuid;
    this.environment = environment;
    return gate == null ? snapshot : await gate!.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _UnusedHandoffGateway implements AccountDeviceHandoffGateway {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PresentationBridge implements AgentHandoffRuntimeBridge {
  int avatarRequests = 0;
  Completer<HandoffAvatarIdentity>? avatarGate;
  @override
  bool get isAvailable => true;
  @override
  Future<HandoffAvatarIdentity> currentAvatar() async {
    avatarRequests++;
    if (avatarGate != null) return avatarGate!.future;
    throw StateError('not expected');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

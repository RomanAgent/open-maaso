import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/account_device_lease.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/services/account_device_lease_transport.dart';
import 'package:maaso/src/core/services/account_runtime_discovery_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/orchestration/agent_turn_orchestrator.dart';
import 'package:maaso/src/features/agent/application/persona/companion_device_context.dart';
import 'package:maaso/src/features/agent/application/persona/conversation_style_context.dart';
import 'package:maaso/src/features/agent/application/persona/persona_chat_loop.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(appServices.reset);
  final now = DateTime.now().toUtc();
  Map<String, dynamic> data(_Discovery discovery, {DateTime? at}) =>
      jsonDecode(
            companionDeviceContext(
              'self',
              discovery: discovery,
              now: at ?? now,
            ).split('\n').last,
          )
          as Map<String, dynamic>;

  test(
    'online count includes self, deduplicates installations and ignores expired peers',
    () {
      final discovery = _Discovery(
        _snapshot(now, [
          _presence(now, 'local', 'local-runtime'),
          _presence(now, 'mobile', 'mobile-runtime'),
          _presence(now, 'mobile', 'second-runtime'),
          _presence(now, 'expired', 'expired-runtime', expired: true),
        ]),
      );
      expect(data(discovery), {
        'knownLocalDeviceCount': 1,
        'observedOnlineDeviceCount': 2,
        'observationComplete': true,
      });
      final text = companionDeviceContext(
        'self',
        discovery: discovery,
        now: now,
      );
      expect(text, isNot(contains('private-device-label')));
      expect(text, isNot(contains('mobile-runtime')));
      discovery.data = _snapshot(now, [
        _presence(now, 'local', 'local-runtime'),
      ]);
      expect(data(discovery)['observedOnlineDeviceCount'], 1);
      expect(
        companionDeviceContext('another-agent', discovery: discovery),
        isEmpty,
      );
    },
  );

  test(
    'stale, truncated, unavailable and retired discovery never claim an exact total',
    () {
      final discovery = _Discovery(
        _snapshot(now, [_presence(now, 'local', 'local-runtime')]),
      );
      expect(
        data(
          discovery,
          at: now.add(const Duration(seconds: 80)),
        )['observedOnlineDeviceCount'],
        isNull,
      );
      discovery.data = _snapshot(now, [
        _presence(now, 'local', 'local-runtime'),
      ], truncated: true);
      expect(data(discovery)['observationComplete'], false);
      discovery.data = _snapshot(now, [
        _presence(now, 'local', 'local-runtime'),
      ]);
      discovery.failure = StateError('offline');
      expect(data(discovery)['observedOnlineDeviceCount'], isNull);
      discovery.failure = null;
      discovery.observing = false;
      expect(data(discovery)['observedOnlineDeviceCount'], isNull);
      discovery.observing = true;
      discovery.data = _snapshot(now, [
        _presence(now, 'remote', 'remote-runtime'),
      ]);
      expect(data(discovery)['observedOnlineDeviceCount'], isNull);
      expect(
        jsonDecode(
          companionDeviceContext('self').split('\n').last,
        )['knownLocalDeviceCount'],
        1,
      );
    },
  );

  test(
    'private persona requests carry fresh count, public requests omit account context',
    () {
      final discovery = appServices.put<AccountRuntimeDiscoveryService>(
        _Discovery(
          _snapshot(now, [
            _presence(now, 'local', 'local-runtime'),
            _presence(now, 'mobile', 'mobile-runtime'),
          ]),
        ),
      );
      String prompt(bool private) => PersonaChatLoop.buildMessages(
        userText: 'How many devices are online?',
        turnPlan: const AgentTurnPlan(
          route: AgentTurnRoute.chitchat,
          mood: 'attentive',
          confidence: 1,
        ),
        profile: AgentProfile(
          nickname: 'Maaso',
          avatar: '',
          bio: '',
          personalityTraits: [],
          catchphrase: '',
        ),
        locale: AppLocale.en,
        conversationStyle: ConversationStyleSnapshot(isPrivate: private),
      ).first.content;
      expect(prompt(true), contains('"observedOnlineDeviceCount":2'));
      expect(prompt(false), isNot(contains('observedOnlineDeviceCount')));
      (discovery as _Discovery).data = _snapshot(now, [
        _presence(now, 'local', 'local-runtime'),
      ]);
      expect(prompt(true), contains('"observedOnlineDeviceCount":1'));
    },
  );
}

AccountDevicePresenceListResult _snapshot(
  DateTime now,
  List<AccountDevicePresenceView> presences, {
  bool truncated = false,
}) => AccountDevicePresenceListResult(
  presences: presences,
  snapshotAt: now,
  eventSequence: 1,
  truncated: truncated,
);

AccountDevicePresenceView _presence(
  DateTime now,
  String installation,
  String runtime, {
  bool expired = false,
}) => AccountDevicePresenceView(
  agentId: 'self',
  installationId: installation,
  runtimeInstanceId: runtime,
  presenceSessionId: '$runtime-presence',
  deviceLabel: 'private-device-label',
  platform: installation == 'local' ? 'macos' : 'ios',
  appVersion: '1',
  openedAt: now.subtract(const Duration(minutes: 1)),
  lastSeenAt: now,
  expiresAt: now.add(Duration(seconds: expired ? -1 : 60)),
  isCurrentHolder: false,
);

class _Discovery extends AccountRuntimeDiscoveryService {
  _Discovery(this.data)
    : super(
        gateway: _Gateway(),
        identity: const AccountDeviceIdentity(
          installationId: 'local',
          runtimeInstanceId: 'local-runtime',
        ),
      );
  AccountDevicePresenceListResult data;
  bool observing = true;
  Object? failure;
  @override
  AccountDevicePresenceListResult get snapshot => data;
  @override
  List<AccountDevicePresenceView> get presences => data.presences;
  @override
  bool get isObserving => observing;
  @override
  Object? get lastError => failure;
}

class _Gateway implements AccountRuntimeDiscoveryGateway {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

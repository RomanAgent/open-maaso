import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/account_device_lease.dart';
import 'package:maaso/src/core/prompts/bundles/skill_prompts_en.dart';
import 'package:maaso/src/core/prompts/bundles/skill_prompts_zh.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/skills/device_handoff_skill.dart';

import 'support/device_handoff_skill_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HandoffSkillFixture fixture;
  setUp(() async => fixture = await HandoffSkillFixture.create());
  tearDown(() => fixture.dispose());

  test(
    'catalog exposes native exact arguments without an unconfirmed local manifest',
    () {
      final spec = SkillCatalog.byId('device_handoff')!;
      expect(spec.factory!('self'), isA<DeviceHandoffSkill>());
      expect(spec.localManifest, isNull);
      expect(spec.hostRouting, isNotNull);
      expect(
        fixture.skill.nativeToolSchemas.keys,
        unorderedEquals(['listDevices']),
      );
    },
  );

  test(
    'directory only returns public device labels and current-account ids',
    () async {
      expect(await call(fixture.skill, 'listDevices', {}), {
        'ok': true,
        'deviceCount': 2,
        'truncated': false,
        'targets': [
          {'id': 'presence-phone', 'label': 'Phone', 'platform': 'ios'},
          {
            'id': handoffTestTarget,
            'label': 'My computer',
            'platform': 'macos',
          },
        ],
      });
      expect(fixture.gateway.requestedAccounts, ['account-owner']);
      expect(fixture.gateway.commands, isEmpty);
    },
  );

  test(
    'retired handoff operations are absent from every exposed method map',
    () {
      expect(fixture.skill.methods.keys, ['listDevices']);
      expect(fixture.skill.nativeMethodDescriptions.keys, ['listDevices']);
      expect(fixture.skill.nativeToolSchemas.keys, ['listDevices']);
      expect(SkillCatalog.byId('device_handoff')!.hostRouting!.methods, [
        'listDevices',
      ]);
      expect(fixture.gateway.commands, isEmpty);
      expect(fixture.bridge.calls, isEmpty);
    },
  );

  test(
    'account retirement during directory lookup rejects the stale snapshot',
    () async {
      fixture.gateway.listGate = Completer<void>();
      final pending = call(fixture.skill, 'listDevices', {});
      await Future<void>.delayed(Duration.zero);
      fixture.context = null;
      fixture.gateway.listGate!.complete();
      expect((await pending)['ok'], isFalse);
      expect(fixture.gateway.commands, isEmpty);
    },
  );

  test(
    'device discovery admits only self with an empty argument object',
    () async {
      final other = DeviceHandoffSkill(
        agentId: 'other',
        directory: fixture.directory,
      );
      expect(
        (await call(other, 'listDevices', {}))['error'],
        'handoff_self_only',
      );
      for (final args in [
        {'force': true},
        {'targetPresenceSessionId': handoffTestTarget},
      ]) {
        expect(
          (await call(fixture.skill, 'listDevices', args))['error'],
          'invalid_arguments',
        );
      }
      expect(fixture.gateway.commands, isEmpty);
    },
  );

  test('device discovery requires the current account directory', () async {
    expect(
      (await call(DeviceHandoffSkill(), 'listDevices', {}))['error'],
      'handoff_unavailable',
    );
  });

  test(
    'presence count deduplicates installations and ignores expired sessions',
    () async {
      fixture.gateway.extraPresences.addAll([
        _device('second-desktop-session', installation: 'installation-desktop'),
        _device(
          'expired-browser',
          installation: 'browser-installation',
          expired: true,
        ),
        _device(
          'current-browser',
          installation: 'browser-installation',
          platform: 'web',
        ),
      ]);
      fixture.gateway.snapshotTruncated = true;
      final result = await call(fixture.skill, 'listDevices', {});
      expect(result['deviceCount'], 3);
      expect(result['truncated'], isTrue);
      final rows = result['targets'] as List;
      expect(rows, hasLength(3));
      expect(rows.where((row) => row['platform'] == 'web'), hasLength(1));
      expect(fixture.gateway.commands, isEmpty);
    },
  );

  test('English and Chinese prompts describe simultaneous device display', () {
    for (final prompts in [skillPromptsEn, skillPromptsZh]) {
      final description = prompts['skill.DeviceHandoff.description']!;
      expect(description, contains('deviceCount'));
      expect(description, isNot(contains('no_handoff_needed')));
      expect(prompts, isNot(contains('skill.DeviceHandoff.method.request')));
      expect(prompts, isNot(contains('skill.DeviceHandoff.method.cancel')));
      expect(description, contains('truncated'));
      expect(description, isNot(contains('started')));
    }
    expect(
      skillPromptsEn['skill.DeviceHandoff.description'],
      contains('every device at once'),
    );
    expect(
      skillPromptsZh['skill.DeviceHandoff.description'],
      contains('同时出现在所有设备'),
    );
  });
}

AccountDevicePresenceView _device(
  String id, {
  required String installation,
  String platform = 'macos',
  bool expired = false,
}) => AccountDevicePresenceView(
  agentId: 'self',
  installationId: installation,
  runtimeInstanceId: 'runtime-$id',
  presenceSessionId: id,
  deviceLabel: 'Device',
  platform: platform,
  appVersion: '1',
  openedAt: handoffTestNow,
  lastSeenAt: handoffTestNow,
  expiresAt: handoffTestNow.add(Duration(minutes: expired ? -1 : 1)),
  isCurrentHolder: false,
);

Future<Map<String, dynamic>> call(
  DeviceHandoffSkill skill,
  String method,
  Map<String, dynamic> args,
) async =>
    jsonDecode(await skill.methods[method]!([jsonEncode(args)]))
        as Map<String, dynamic>;

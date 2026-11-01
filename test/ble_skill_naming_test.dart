import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';

import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/skills/ble_yoturetoys_skill.dart';
import 'package:maaso/src/features/agent/application/skills/bluetooth_skill.dart';
import 'package:maaso/src/features/agent/application/skills/show_card_skill.dart';
import 'package:maaso/src/features/agent/application/skills/web_search_skill.dart';

void main() {
  final skills = <AgentSkill>[
    BluetoothSkill(),
    BleYoturetoysSkill(),
    WebSearchSkill(),
  ];

  final defaultSkills = SkillCatalog.all
      .where((s) => SkillCatalog.defaultEnabled.contains(s.id))
      .where((s) => s.factory != null)
      .map((s) => s.factory!('self'))
      .toList();

  test('native tool schemas only advertise real method keys', () {
    for (final skill in skills) {
      final advertised = skill.nativeToolSchemas?.keys.toSet() ?? const {};
      expect(advertised, isNotEmpty, reason: skill.skillName);
      for (final name in advertised) {
        expect(
          skill.methods.keys,
          contains(name),
          reason: '${skill.skillName} advertises "$name" but has no method key',
        );
      }
    }
  });

  test('method keys are globally unique across Bluetooth projector skills', () {
    final bt = BluetoothSkill().methods.keys.toSet();
    final yt = BleYoturetoysSkill().methods.keys.toSet();
    final collide = bt.intersection(yt);
    expect(
      collide,
      isEmpty,
      reason: 'these keys collide in the structured tool namespace: $collide',
    );
  });

  test('default skill method collisions are explicitly scoped', () {
    final owners = <String, List<String>>{};
    for (final skill in defaultSkills) {
      for (final key in skill.methods.keys) {
        owners.putIfAbsent(key, () => <String>[]).add(skill.skillName);
      }
    }

    final collisions = Map.fromEntries(
      owners.entries.where((e) => e.value.length > 1),
    );

    expect(collisions, isEmpty);
    expect(owners['execute'], ['AppControl']);
    expect(
      defaultSkills.map((skill) => skill.skillName),
      isNot(contains('WorldControl')),
    );
  });

  test('setup card skill only exposes the setup-card method', () {
    final skill = ShowCardSkill();

    expect(skill.methods.keys, contains('showSetupCard'));
    expect(skill.methods.keys, isNot(contains('showCard')));
    expect(skill.nativeToolSchemas?.keys, contains('showSetupCard'));
    expect(skill.nativeToolSchemas?.keys, isNot(contains('showCard')));
  });

  test(
    'ble_yoturetoys_projector localManifest.method is a real method key',
    () {
      final manifest = SkillCatalog.byId(
        'ble_yoturetoys_projector',
      )!.localManifest!;
      final keys = BleYoturetoysSkill().methods.keys.toSet();
      expect(
        keys,
        contains(manifest.method),
        reason:
            'localManifest.method "${manifest.method}" is not in '
            '${keys.toList()} — the local path invokes skill.methods[method]',
      );
    },
  );

  test('projector docs steer connect through auto-scan connect method', () {
    final bluetooth = BluetoothSkill().nativeMethodDescriptions;
    final projector = BleYoturetoysSkill().description;

    expect(bluetooth['bluetoothConnect'], contains('scan and auto-connect'));
    expect(projector, contains('first call bluetoothConnect'));
    expect(projector, isNot(contains('bluetoothScan then bluetoothConnect')));
  });
}

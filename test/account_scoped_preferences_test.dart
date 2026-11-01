import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/agent_token_service.dart';
import 'package:maaso/src/core/services/avatar_config_service.dart';
import 'package:maaso/src/core/services/avatar_voice_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/services/sherpa_neural_tts.dart';
import 'package:maaso/src/core/utils/sp_utils.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/data/context/user_profile_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AccountStorageScope accountA;
  late AccountStorageScope accountB;
  const rawAgentId = 'raw-agent/alpha@example.com';

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    accountA = AccountStorageScope(
      environmentKey: 'prod',
      accountUuid: 'raw-account-A@example.com',
    );
    accountB = AccountStorageScope(
      environmentKey: 'prod',
      accountUuid: 'raw-account-B@example.com',
    );
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await SpUtils.init();
  });

  tearDown(() async {
    for (final prefix in <String>{
      accountA.storageNamespace,
      accountB.storageNamespace,
      accountA.agent(rawAgentId).storageNamespace,
      accountB.agent(rawAgentId).storageNamespace,
      '',
    }) {
      UserProfileManager().deactivate(storageKeyPrefix: prefix);
    }
    await appServices.reset();
  });

  test(
    'profile survives A to B to A without consuming retired affinity data',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'agent_intimacy_level': 99,
        'agent_long_term_facts': <String>['legacy-secret'],
        'agent_user_profile': jsonEncode(<String, String>{
          'owner': 'legacy-owner',
        }),
      });
      await SpUtils.init();
      final prefixA = accountA.agent(rawAgentId).storageNamespace;
      final prefixB = accountB.agent(rawAgentId).storageNamespace;
      final profile = UserProfileManager();

      await profile.init(storageKeyPrefix: prefixA);
      expect(profile.traits, isEmpty);

      await profile.updateTraits(<String, String>{'owner': 'account-a'});

      await AgentRuntimeRegistry(storageKeyPrefix: prefixA).shutdown();
      expect(profile.traits, isEmpty);
      await expectLater(
        profile.updateTraits(<String, String>{'owner': 'stale'}),
        throwsStateError,
      );

      await profile.init(storageKeyPrefix: prefixB);
      expect(profile.traits, isEmpty);
      await profile.updateTraits(<String, String>{'owner': 'account-b'});
      await AgentRuntimeRegistry(storageKeyPrefix: prefixB).shutdown();

      await profile.init(storageKeyPrefix: prefixA);
      expect(profile.traits, <String, String>{'owner': 'account-a'});
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('agent_intimacy_level'), 99);
      expect(prefs.getInt('$prefixA.preferences.agent_intimacy_level'), isNull);
      expect(prefs.getInt('$prefixB.preferences.agent_intimacy_level'), isNull);
    },
  );

  test('deactivate fences an init completion that arrives late', () async {
    final prefix = accountA.agent(rawAgentId).storageNamespace;
    final profile = UserProfileManager();

    final profileInit = profile.init(storageKeyPrefix: prefix);
    profile.deactivate(storageKeyPrefix: prefix);

    await expectLater(profileInit, throwsStateError);
    expect(profile.traits, isEmpty);
    await expectLater(
      profile.updateTraits(<String, String>{'owner': 'late'}),
      throwsStateError,
    );
  });

  test(
    'registry isolates enabled skills and hashes scoped agent keys',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'enabledSkills.$rawAgentId': <String>[],
      });
      final prefixA = accountA.agent(rawAgentId).storageNamespace;
      final prefixB = accountB.agent(rawAgentId).storageNamespace;
      final optionalSkill = SkillCatalog.all.firstWhere(
        (skill) => !skill.isCore && !skill.isComingSoon,
      );

      final registryA = AgentRuntimeRegistry(storageKeyPrefix: prefixA);
      await registryA.setEnabledSkills(rawAgentId, <String>{});
      expect(
        await registryA.readEnabledSkills(rawAgentId),
        isNot(contains(optionalSkill.id)),
      );

      final registryB = AgentRuntimeRegistry(storageKeyPrefix: prefixB);
      expect(
        await registryB.readEnabledSkills(rawAgentId),
        contains(optionalSkill.id),
      );
      await registryB.setEnabledSkills(rawAgentId, <String>{optionalSkill.id});

      final restoredA = AgentRuntimeRegistry(storageKeyPrefix: prefixA);
      expect(
        await restoredA.readEnabledSkills(rawAgentId),
        isNot(contains(optionalSkill.id)),
      );

      final prefs = await SharedPreferences.getInstance();
      final scopedKeys = prefs
          .getKeys()
          .where((key) => key.contains('.preferences.enabledSkills.'))
          .toList();
      expect(scopedKeys, hasLength(2));
      expect(scopedKeys, everyElement(isNot(contains(rawAgentId))));
      expect(scopedKeys, everyElement(isNot(contains(accountA.accountUuid))));
      expect(scopedKeys, everyElement(isNot(contains(accountB.accountUuid))));
    },
  );

  test('scoped avatar selection and voice never read legacy keys', () async {
    final prefixA = accountA.agent(rawAgentId).storageNamespace;
    final prefixB = accountB.agent(rawAgentId).storageNamespace;
    SharedPreferences.setMockInitialValues(<String, Object>{
      'avatar.selected_id': 'alternate',
      AvatarVoiceService.followAvatarPrefsKey: false,
      AvatarVoiceService.voiceSidPrefsKey: 9,
      '$prefixB.preferences.avatar.selected_id': 'alternate',
      '$prefixB.preferences.${AvatarVoiceService.followAvatarPrefsKey}': true,
      '$prefixB.preferences.${AvatarVoiceService.voiceSidPrefsKey}': 6,
    });
    await SpUtils.init();
    final sherpa = appServices.put(SherpaNeuralTts());
    const catalog = <AvatarOption>[
      AvatarOption(
        id: 'agent',
        name: 'Agent',
        backend: AvatarBackendKind.unity,
        modelUrl: 'unity://agent',
        isDefault: true,
      ),
      AvatarOption(
        id: 'alternate',
        name: 'Alternate',
        backend: AvatarBackendKind.unity,
        modelUrl: 'unity://alternate',
      ),
    ];

    final avatarA = AvatarConfigService(
      storageKeyPrefix: prefixA,
      initialCatalog: catalog,
    ).init();
    expect(avatarA.selectedId.value, 'agent');
    expect(avatarA.voicePreferences.followsAvatar.value, isTrue);
    expect(
      avatarA.voicePreferences.voiceSid.value,
      AvatarVoiceService.defaultFemaleSid,
    );
    await avatarA.voicePreferences.selectManualSid(7);
    expect(sherpa.voiceSid.value, 7);
    expect(SpUtils.getInt(AvatarVoiceService.voiceSidPrefsKey), 9);

    final avatarB = AvatarConfigService(
      storageKeyPrefix: prefixB,
      initialCatalog: catalog,
    ).init();
    expect(avatarB.selectedId.value, 'alternate');
    expect(avatarB.voicePreferences.followsAvatar.value, isTrue);
    expect(avatarB.voicePreferences.voiceSid.value, 6);

    final restoredA = AvatarConfigService(
      storageKeyPrefix: prefixA,
      initialCatalog: catalog,
    ).init();
    expect(restoredA.selectedId.value, 'agent');
    expect(restoredA.voicePreferences.followsAvatar.value, isFalse);
    expect(restoredA.voicePreferences.voiceSid.value, 7);
  });

  test(
    'AgentToken scoped keys contain digests, never raw account ids',
    () async {
      final storage = _RecordingSecureStorageService(<String, String>{
        'agent_token': 'legacy-token',
      });
      appServices.put<SecureStorageService>(storage);
      final tokens = AgentTokenService();

      await tokens.init(scope: accountA);
      final tokenA = tokens.agentToken.value;
      await tokens.init(scope: accountB);
      final tokenB = tokens.agentToken.value;
      await tokens.init(scope: accountA);

      expect(tokenA, isNotEmpty);
      expect(tokenB, isNotEmpty);
      expect(tokenB, isNot(tokenA));
      expect(tokens.agentToken.value, tokenA);
      expect(storage.readKeys, isNot(contains('agent_token')));
      expect(
        storage.usedKeys,
        everyElement(isNot(contains(accountA.accountUuid))),
      );
      expect(
        storage.usedKeys,
        everyElement(isNot(contains(accountB.accountUuid))),
      );
      expect(
        storage.usedKeys,
        everyElement(
          matches(
            RegExp(r'^maaso\.account\.v1\.[0-9a-f]{64}\.secure\.agent_token$'),
          ),
        ),
      );
    },
  );
}

final class _RecordingSecureStorageService extends SecureStorageService {
  _RecordingSecureStorageService(Map<String, String> initialValues)
    : _values = Map<String, String>.of(initialValues);

  final Map<String, String> _values;
  final List<String> readKeys = <String>[];
  final List<String> writeKeys = <String>[];

  Iterable<String> get usedKeys => <String>[...readKeys, ...writeKeys];

  @override
  Future<String?> read(String key) async {
    readKeys.add(key);
    return _values[key];
  }

  @override
  Future<bool> write(String key, String? value) async {
    writeKeys.add(key);
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
    return true;
  }
}

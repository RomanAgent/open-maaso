import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/soul_service.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';
import 'package:maaso/src/features/agent/application/persona/agent_persona_spec.dart';
import 'package:maaso/src/features/agent/application/skills/set_soul_skill.dart';
import 'package:sembast/sembast_memory.dart';

class _MemorySoulService extends SoulService {
  @override
  Future<void> update({
    String? name,
    int? age,
    String? gender,
    String? notesAppend,
    String? notesReplace,
  }) async {
    if (name != null && name.trim().isNotEmpty) this.name.value = name.trim();
    if (age != null) this.age.value = age;
    if (gender != null && gender.trim().isNotEmpty) {
      this.gender.value = gender.trim();
    }
    if (notesReplace != null) {
      notes.value = notesReplace.trim();
    } else if (notesAppend != null && notesAppend.trim().isNotEmpty) {
      final extra = notesAppend.trim();
      notes.value = notes.value.isEmpty ? extra : '${notes.value}\n$extra';
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    appServices.testMode = true;
    appServices.reset();
  });
  tearDown(appServices.reset);

  test('localized model prompt exposes explicit profession payload keys', () {
    for (final locale in <AppLocale>[AppLocale.en, AppLocale.zh]) {
      final description = AgentPromptCatalog.text(
        'skill.SetSoul.description',
        locale: locale,
      );
      expect(description, contains('professionTitle'));
      expect(description, contains('specialties'));
    }
  });

  test(
    'setSoul explicitly updates profession while preserving every profile field',
    () async {
      final core = await _putCore();
      appServices.put<SoulService>(_MemorySoulService());
      final original = AgentProfile(
        nickname: 'Old name',
        avatar: 'avatar.glb',
        bio: 'Bio',
        personalityTraits: <String>['Warm'],
        catchphrase: 'Hello',
        wakeUpHour: 6,
        sleepHour: 21,
        longTermMemory: 'private',
        agentToken: 'token',
        gender: 'female',
        voiceId: 'voice',
        birthDate: DateTime.utc(2026, 2, 3),
        uiStyle: 'adventure_world',
        themeBrightness: 'dark',
        themeMode: 'system',
        themeAccent: 'rose',
        persona: const AgentPersonaSpec(interests: <String>['旅行']),
      );
      await core.updateProfile(original);

      final result = await _setSoul(<String, Object?>{
        'name': 'Momo',
        'professionTitle': '摄影师',
        'specialties': <String>['人像', '灯光', '人像'],
      });
      final updated = core.profile.value!;

      expect(updated.nickname, 'Momo');
      expect(updated.avatar, original.avatar);
      expect(updated.bio, original.bio);
      expect(updated.personalityTraits, original.personalityTraits);
      expect(updated.catchphrase, original.catchphrase);
      expect(updated.wakeUpHour, original.wakeUpHour);
      expect(updated.sleepHour, original.sleepHour);
      expect(updated.longTermMemory, original.longTermMemory);
      expect(updated.agentToken, original.agentToken);
      expect(updated.gender, original.gender);
      expect(updated.voiceId, original.voiceId);
      expect(updated.birthDate, original.birthDate);
      expect(updated.uiStyle, original.uiStyle);
      expect(updated.themeBrightness, original.themeBrightness);
      expect(updated.themeMode, original.themeMode);
      expect(updated.themeAccent, original.themeAccent);
      expect(updated.persona.professionTitle, '摄影师');
      expect(updated.persona.specialties, <String>['人像', '灯光']);
      expect(updated.persona.interests, <String>['旅行']);
      expect(
        (result['persona'] as Map<String, dynamic>)['professionTitle'],
        '摄影师',
      );
    },
  );

  test(
    'profession changes require explicit fields and can be explicitly cleared',
    () async {
      final core = await _putCore();
      appServices.put<SoulService>(_MemorySoulService());
      await core.updateProfile(
        AgentProfile(
          nickname: 'Momo',
          avatar: '',
          bio: '',
          personalityTraits: const <String>['Warm'],
          catchphrase: '',
          persona: const AgentPersonaSpec(
            professionTitle: '作家',
            specialties: <String>['科幻'],
          ),
        ),
      );

      await _setSoul(<String, Object?>{'notesAppend': '今天想拍照'});
      expect(core.profile.value!.persona.professionTitle, '作家');
      expect(core.profile.value!.persona.specialties, <String>['科幻']);

      await _setSoul(<String, Object?>{
        'professionTitle': '',
        'specialties': <String>[],
      });
      expect(core.profile.value!.persona.professionTitle, isNull);
      expect(core.profile.value!.persona.specialties, isEmpty);
    },
  );
}

Future<AgentCoreController> _putCore() async {
  final db = await DBService().init(
    factory: databaseFactoryMemory,
    path: 'set_soul_persona_test.db',
  );
  appServices.put<DBService>(db);
  final core = appServices.put(AgentCoreController());
  await core.loadProfile();
  return core;
}

Future<Map<String, dynamic>> _setSoul(Map<String, Object?> payload) async {
  final method = SetSoulSkill().methods['setSoul']!;
  final raw = await method(<dynamic>[jsonEncode(payload)]);
  return jsonDecode(raw as String) as Map<String, dynamic>;
}

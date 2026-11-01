import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/features/agent/application/persona/agent_persona_spec.dart';

void main() {
  test('legacy profile JSON decodes with an optional neutral persona', () {
    final profile = AgentProfile.fromJson(<String, Object?>{
      'userId': 'self',
      'nickname': 'Momo',
      'avatar': 'avatar.glb',
      'bio': 'Warm friend',
      'personalityTraits': <String>['Warm'],
      'catchphrase': 'Hi',
    });

    expect(profile.persona.isNeutral, isTrue);
    expect(profile.toJson(), isNot(contains('persona')));
  });

  test('public persona survives profile JSON round trip', () {
    final original = _profile(
      persona: const AgentPersonaSpec(
        professionTitle: '摄影师',
        specialties: <String>['人像', '灯光'],
        interests: <String>['短视频'],
        socialStyle: AgentSocialStyle(humor: 0.7),
        avoidTopics: <String>['未核实指控'],
      ),
    );

    final decoded = AgentProfile.fromJson(original.toJson());

    expect(decoded.persona.professionTitle, '摄影师');
    expect(decoded.persona.specialties, <String>['人像', '灯光']);
    expect(decoded.persona.interests, <String>['短视频']);
    expect(decoded.persona.socialStyle.humor, 0.7);
    expect(decoded.persona.avoidTopics, <String>['未核实指控']);
  });

  test('malformed persona payload fails closed without losing the profile', () {
    final json = _profile().toJson()
      ..['persona'] = <Object?, Object?>{1: 'bad key', 'schemaVersion': 999};

    final decoded = AgentProfile.fromJson(json);

    expect(decoded.nickname, 'Original');
    expect(decoded.persona.isNeutral, isTrue);
  });

  test('complete copyWith preserves fields and can clear nullable values', () {
    final original = _profile(
      persona: const AgentPersonaSpec(
        professionTitle: '作家',
        specialties: <String>['科幻'],
      ),
    );

    final renamed = original.copyWith(nickname: 'Renamed');

    expect(renamed.userId, original.userId);
    expect(renamed.nickname, 'Renamed');
    expect(renamed.avatar, original.avatar);
    expect(renamed.bio, original.bio);
    expect(renamed.personalityTraits, original.personalityTraits);
    expect(
      identical(renamed.personalityTraits, original.personalityTraits),
      isFalse,
    );
    expect(renamed.catchphrase, original.catchphrase);
    expect(renamed.wakeUpHour, original.wakeUpHour);
    expect(renamed.sleepHour, original.sleepHour);
    expect(renamed.longTermMemory, original.longTermMemory);
    expect(renamed.agentToken, original.agentToken);
    expect(renamed.gender, original.gender);
    expect(renamed.voiceId, original.voiceId);
    expect(renamed.birthDate, original.birthDate);
    expect(renamed.uiStyle, original.uiStyle);
    expect(renamed.themeBrightness, original.themeBrightness);
    expect(renamed.themeMode, original.themeMode);
    expect(renamed.themeAccent, original.themeAccent);
    expect(renamed.persona.professionTitle, '作家');

    final cleared = renamed.copyWith(
      longTermMemory: null,
      birthDate: null,
      themeMode: null,
    );
    expect(cleared.longTermMemory, isNull);
    expect(cleared.birthDate, isNull);
    expect(cleared.themeMode, isNull);
  });
}

AgentProfile _profile({AgentPersonaSpec persona = AgentPersonaSpec.empty}) {
  return AgentProfile(
    userId: 'self',
    nickname: 'Original',
    avatar: 'avatar.glb',
    bio: 'Bio',
    personalityTraits: <String>['Warm', 'Curious'],
    catchphrase: 'Hello',
    wakeUpHour: 7,
    sleepHour: 22,
    longTermMemory: 'private memory',
    agentToken: 'token',
    gender: 'female',
    voiceId: 'voice',
    birthDate: DateTime.utc(2026, 1, 2),
    uiStyle: 'adventure_world',
    themeBrightness: 'dark',
    themeMode: 'system',
    themeAccent: 'rose',
    persona: persona,
  );
}

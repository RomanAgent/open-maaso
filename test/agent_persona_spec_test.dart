import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/persona/agent_persona_spec.dart';

void main() {
  test('old profiles decode to a neutral optional persona', () {
    final persona = AgentPersonaSpec.fromJson(null);

    expect(persona.professionTitle, isNull);
    expect(persona.specialties, isEmpty);
    expect(persona.routingPriorTerms, isEmpty);
  });

  test('profession is a routing prior and never a capability allowlist', () {
    const persona = AgentPersonaSpec(
      professionTitle: '摄影师',
      specialties: <String>['人像摄影', '灯光', '人像摄影'],
      interests: <String>['短视频'],
    );

    expect(persona.routingPriorTerms, <String>{'摄影师', '人像摄影', '灯光'});
    expect(persona.toJson()['specialties'], <String>['人像摄影', '灯光']);
  });

  test('social style clamps untrusted persisted values', () {
    final style = AgentSocialStyle.fromJson(<String, Object?>{
      'initiative': 2,
      'humor': -1,
      'slangIntensity': '0.7',
      'commentFrequency': null,
    });

    expect(style.initiative, 1);
    expect(style.humor, 0);
    expect(style.slangIntensity, 0.7);
    expect(style.commentFrequency, 0.15);
  });

  test('persona capsule is bounded and excludes private runtime context', () {
    const persona = AgentPersonaSpec(
      professionTitle: '科技记者',
      specialties: <String>['AI', '芯片', '产品分析'],
      interests: <String>['新闻', '短视频'],
      socialStyle: AgentSocialStyle(slangIntensity: 0.35),
      avoidTopics: <String>['未核实指控'],
    );

    final capsule = persona.toCapsule(maxCharacters: 128);

    expect(capsule.length, lessThanOrEqualTo(128));
    expect(capsule, contains('profession=科技记者'));
    expect(capsule, isNot(contains('relationship')));
    expect(capsule, isNot(contains('memory')));
    expect(capsule, isNot(contains('account')));
  });
}

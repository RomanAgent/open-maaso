import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:maaso/src/features/agent/data/skills/face_skill.dart';
import 'package:maaso/src/features/agent/data/skills/memory_skill.dart';
import 'package:maaso/src/features/agent/data/skills/skill_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    SharedPreferences.setMockInitialValues({
      'agent_intimacy_level': 63,
      'owner.preferences.agent_intimacy_level': 21,
    });
  });
  tearDown(appServices.reset);

  test(
    'retired methods cannot bind or execute and keep old data untouched',
    () async {
      final manager = SkillManager()
        ..registerSkill(MemorySkill())
        ..registerSkill(FaceSkill(agentId: 'self'));

      for (final tool in const [
        'skill_memorycontrol_changeintimacy',
        'skill_facecontrol_setface',
      ]) {
        expect(manager.skillOwnerForTool(tool), isNull);
        expect(manager.methodNameForTool(tool), isNull);
        await expectLater(
          manager.invokeTool(tool, const {'delta': 20}),
          throwsStateError,
        );
      }

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('agent_intimacy_level'), 63);
      expect(prefs.getInt('owner.preferences.agent_intimacy_level'), 21);
      expect(
        manager.skillOwnerForTool('skill_memorycontrol_remember'),
        isA<MemorySkill>(),
      );
    },
  );

  test(
    'semantic face skill still emits its account-addressed emotion',
    () async {
      final face = FaceSkill(agentId: 'agent-alpha');
      final manager = SkillManager()..registerSkill(face);
      expect(face.methods.keys, ['setEmotion']);
      expect(
        manager.skillOwnerForTool('skill_facecontrol_setemotion'),
        same(face),
      );
      final next = EventBus().on<EmotionStateEvent>().first;
      final output = face.methods['setEmotion']!([
        jsonEncode({'emotion': 'happy', 'intensity': 0.65}),
      ]);
      final event = await next;
      expect(jsonDecode(output as String), {'status': 'success'});
      expect(event.agentId, 'agent-alpha');
      expect(event.semanticLabel, 'happy');
      expect(event.params.intensity, 0.65);
      expect(event.params.mouthCurve, greaterThan(0));
    },
  );

  test('retired motion reference management has no host or local entry', () {
    expect(SkillCatalog.byId('avatar_motion_learning'), isNull);
    expect(
      SkillCatalog.all.any(
        (spec) =>
            spec.hostRouting?.skillName == 'AvatarMotionLearning' ||
            spec.localManifest?.skillName == 'AvatarMotionLearning',
      ),
      isFalse,
    );
  });
}

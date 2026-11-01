import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    appServices.testMode = true;
  });
  tearDown(appServices.reset);

  test(
    'startup profile projection exposes one awaitable mount barrier',
    () async {
      final database = _GatedProfileDatabase();
      appServices.put<DBService>(database);
      final core = appServices.put(AgentCoreController());

      final first = core.ensureLoaded();
      final second = core.ensureLoaded();
      expect(second, same(first));
      expect(database.reads, 1);
      expect(core.isInitialized.value, isFalse);

      database.profile.complete(
        AgentProfile(
          userId: 'self',
          nickname: 'Account A',
          avatar: '',
          bio: '',
          personalityTraits: const <String>['warm'],
          catchphrase: '',
          agentToken: 'agent-token-a',
          gender: 'female',
          voiceId: 'voice-a',
          birthDate: DateTime.utc(2026, 1, 1),
        ),
      );

      await first;
      expect(core.profile.value?.nickname, 'Account A');
      expect(core.isInitialized.value, isTrue);
      expect(database.reads, 1);
    },
  );
}

final class _GatedProfileDatabase extends DBService {
  final profile = Completer<AgentProfile?>();
  int reads = 0;

  @override
  Future<AgentProfile?> getSelfProfile() {
    reads++;
    return profile.future;
  }

  @override
  Future<void> saveAgentProfile(AgentProfile profile) async {}
}

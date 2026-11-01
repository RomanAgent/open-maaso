import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/services/llm_request_dispatch_scope.dart';
import 'package:maaso/src/core/services/metered_llm_http_client.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/services/skill_usage_service.dart';
import 'package:maaso/src/features/agent/application/skill_routing/prompt_skill_snapshot.dart';
import 'package:maaso/src/features/agent/application/skill_routing/prompt_skill_usage_turn.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_descriptor.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_route_decision.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database database;
  late SkillUsageService service;
  late MeteredLlmHttpClient client;
  var current = true;
  var snapshotCurrent = true;
  var dispatches = 0;
  var databaseSerial = 0;
  final selected = _entry('marketplace:selected', 'PRIVATE_SELECTED_FRAGMENT');
  final learned = _entry('learned:learned', 'PRIVATE_LEARNED_FRAGMENT');
  final unselected = _entry('marketplace:other', 'PRIVATE_UNSELECTED_FRAGMENT');
  final snapshot = PromptSkillSnapshot.fromEntries([
    selected,
    learned,
    unselected,
  ]);

  setUp(() async {
    current = true;
    snapshotCurrent = true;
    dispatches = 0;
    database = await databaseFactoryMemory.openDatabase(
      'prompt-usage-test-${++databaseSerial}',
    );
    service = await SkillUsageService(
      database: database,
      accountScopeDigest: AccountStorageScope(
        environmentKey: 'test',
        accountUuid: 'prompt-owner',
      ).accountDigest,
      isCurrent: () => current,
    ).init(observeLifecycle: false);
    client = MeteredLlmHttpClient(
      inner: MockClient((request) async {
        dispatches++;
        return http.Response('{"reply":"ok","actions":[]}', 200);
      }),
      record:
          ({
            required requestId,
            required dispatchedAt,
            required usage,
          }) async {},
      canDispatch: () => current,
    );
  });

  tearDown(() async {
    client.close();
    await service.shutdown();
    await database.close();
  });

  PromptSkillUsageTurn turn({Iterable<PromptSkillEntry>? entries}) {
    final usage = PromptSkillUsageTurn(
      service: service,
      isCurrent: () => current,
    );
    usage.select(
      snapshot: snapshot,
      grant: TurnSkillGrant.bounded(
        rankedDescriptors: (entries ?? [selected, learned]).map(
          (e) => e.descriptor,
        ),
        maxSkills: 2,
        promptBudget: 4096,
        snapshotToken: snapshot,
      ),
      snapshotIsCurrent: () => snapshotCurrent,
    );
    return usage;
  }

  Future<void> dispatch(PromptSkillUsageTurn usage, Object payload) async {
    await LlmRequestDispatchScope.run(
      () => client.post(
        Uri.parse('https://model.example/chat'),
        body: jsonEncode(payload),
      ),
      onDispatch: usage.onDispatch,
    );
    await service.whenSettled;
  }

  Map<String, Object?> system(String text) => {
    'messages': [
      {'role': 'system', 'content': text},
      {'role': 'user', 'content': 'a natural user request'},
    ],
  };

  test(
    'only selected complete fragments in a dispatched system prompt count',
    () async {
      await dispatch(
        turn(),
        system('${selected.promptFragment}\n${unselected.promptFragment}'),
      );
      expect(dispatches, 1);
      expect(
        service.forSkill(promptSkillUsageKey(selected.descriptor.id)!).started,
        1,
      );
      expect(
        service.forSkill(promptSkillUsageKey(learned.descriptor.id)!).started,
        0,
      );
      expect(
        service
            .forSkill(promptSkillUsageKey(unselected.descriptor.id)!)
            .started,
        0,
      );
    },
  );

  test(
    'selection without dispatch and dispatch without selection are not uses',
    () async {
      final selectedTurn = turn();
      await service.whenSettled;
      expect(service.entries.value, isEmpty);
      await dispatch(
        PromptSkillUsageTurn(service: service, isCurrent: () => current),
        system(selected.promptFragment),
      );
      expect(service.entries.value, isEmpty);
      expect(dispatches, 1);
      await dispatch(selectedTurn, system(selected.promptFragment));
      expect(service.entries.value.single.started, 1);
    },
  );

  test(
    'user text, titles, and shortened fragments cannot claim prompt use',
    () async {
      final usage = turn();
      await dispatch(usage, {
        'messages': [
          {'role': 'system', 'content': 'PRIVATE_SELECTED'},
          {'role': 'user', 'content': selected.promptFragment},
        ],
      });
      expect(service.entries.value, isEmpty);
      await dispatch(usage, system(selected.promptFragment));
      expect(service.entries.value.single.started, 1);
    },
  );

  test(
    'retries and continuations count once per prompt Skill per natural turn',
    () async {
      final usage = turn();
      final payload = system(
        '${selected.promptFragment}\n${learned.promptFragment}',
      );
      for (var i = 0; i < 4; i++) {
        await dispatch(usage, payload);
      }
      expect(dispatches, 4);
      expect(service.entries.value, hasLength(2));
      for (final entry in service.entries.value) {
        expect([entry.started, entry.succeeded, entry.failed], [1, 1, 0]);
      }
      await dispatch(turn(), payload);
      expect(dispatches, 5);
      for (final entry in service.entries.value) {
        expect(entry.started, 2);
      }
    },
  );

  test('an invalidated snapshot or account cannot add a use', () async {
    final usage = turn();
    snapshotCurrent = false;
    await dispatch(usage, system(selected.promptFragment));
    expect(service.entries.value, isEmpty);
    current = false;
    await expectLater(
      dispatch(usage, system(selected.promptFragment)),
      throwsStateError,
    );
    expect(dispatches, 1);
    expect(service.entries.value, isEmpty);
  });

  test(
    'Gemini systemInstruction is accepted; arbitrary payloads are ignored',
    () async {
      final usage = turn();
      await dispatch(usage, {
        'contents': [
          {'text': selected.promptFragment},
        ],
      });
      expect(service.entries.value, isEmpty);
      await dispatch(usage, {
        'systemInstruction': {
          'parts': [
            {'text': learned.promptFragment},
          ],
        },
      });
      expect(
        service.entries.value.single.skillName,
        promptSkillUsageKey(learned.descriptor.id),
      );
      expect(service.entries.value.single.started, 1);
    },
  );

  test(
    'ordinary HTTP has no observer and observer failures cannot fail a request',
    () async {
      await client.post(
        Uri.parse('https://model.example/chat'),
        body: 'not JSON',
      );
      await LlmRequestDispatchScope.run(
        () => client.post(Uri.parse('https://model.example/chat'), body: '{}'),
        onDispatch: (_) => throw StateError('telemetry failure'),
      );
      expect(dispatches, 2);
      expect(service.entries.value, isEmpty);
    },
  );

  test('stored usage contains only hashed identity and metadata', () async {
    await dispatch(
      turn(),
      system('${selected.promptFragment}\n${learned.promptFragment}'),
    );
    final records = await StoreRef<String, Map<String, Object?>>(
      'skill_usage_totals.v1',
    ).find(database);
    final serialized = jsonEncode(records.map((r) => r.value).toList());
    expect(serialized, isNot(contains('PRIVATE_')));
    expect(serialized, isNot(contains(selected.descriptor.id)));
    expect(serialized, isNot(contains(learned.descriptor.id)));
    expect(serialized, isNot(contains('model.example')));
    for (final entry in service.entries.value) {
      expect(
        entry.skillName,
        matches(RegExp(r'^(marketplace|learned):[a-f0-9]{64}$')),
      );
      expect(entry.method, 'applyPrompt');
      expect(entry.channel, SkillUsageChannel.prompt);
    }
    expect(promptSkillUsageKey('AppControl'), isNull);
  });
}

PromptSkillEntry _entry(String id, String fragment) => PromptSkillEntry(
  source: id.startsWith('marketplace:')
      ? PromptSkillSource.marketplace
      : PromptSkillSource.learned,
  descriptor: SkillDescriptor(
    id: id,
    summary: 'A selected prompt instruction.',
  ),
  promptFragment: fragment,
  contentRevision: 'one',
);

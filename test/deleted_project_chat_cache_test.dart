import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';
import 'package:maaso/src/features/agent/application/orchestration/agent_turn_orchestrator.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_persistence.dart';
import 'package:maaso/src/features/agent/presentation/agent_task_chat_card.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/chat/application/u2a_chat_controller.dart';
import 'package:maaso/src/features/home/application/home_controller.dart';
import 'package:maaso/src/features/home/presentation/widgets/home_chat_history.dart';
import 'package:maaso/src/features/project_build/data/project_build_v2_repository.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_contract.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_task_binding.dart';
import 'project_bundle_deletion_test.dart' show deletionProof;
import 'support/project_bundle_v2_fixture.dart';

const _scope = AppletLocalOwnership.deviceLegacyScope;
const _root = 'job_123_1';
ChatMessage _message({bool task = false, String scope = _scope}) => ChatMessage(
  id: task ? 2 : 1,
  sessionId: 'self',
  senderId: 'self',
  receiverId: 'user',
  content: task ? '' : 'Keep ordinary conversation',
  timestamp: DateTime.now(),
  taskReference: task
      ? AgentTaskChatReference(taskId: _root, scopeKey: scope, agentId: 'self')
      : null,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _HistoryDb db;
  late _Markers markers;
  late AgentTaskJobStore jobs;
  late _QuietHome home;
  late ProjectBuildV2DeletionProof proof;
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    db = _HistoryDb();
    markers = _Markers();
    jobs = await AgentTaskJobStore(persistence: markers).init();
    appServices.put<DBService>(db);
    appServices.put(AgentRuntimeRegistry(hostExecutionEnabled: false));
    appServices.put<AgentCoreController>(_QuietCore());
    appServices.put<AgentTaskJobStore>(jobs);
    home = appServices.put<HomeController>(_QuietHome()) as _QuietHome;
    proof = await deletionProof(productionBundleFixture());
  });
  tearDown(() async {
    await jobs.deactivateAndDrain();
    await appServices.reset();
  });
  Future<Set<String>> purge() => jobs.purgeProjectBuildV2(
    proof,
    expectedScopeKey: _scope,
    expectedRepositoryScopeKey: 'test|owner',
  );
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  testWidgets(
    'late history read cannot restore deleted typed cards; ordinary chat remains',
    (tester) async {
      db.messages = [_message(), _message(task: true)];
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: appProviderContainer,
          child: const MaterialApp(
            home: Scaffold(
              body: HomeChatHistory(
                contentPadding: EdgeInsets.all(16),
                latestButtonBottom: 0,
                topFadeHeight: 0,
              ),
            ),
          ),
        ),
      );
      await settle(tester);
      // A missing job alone is not a deletion. Its typed card is still rendered.
      expect(find.byType(AgentTaskChatCard), findsOneWidget);
      final stale = Completer<List<ChatMessage>>();
      db.nextMessages = stale;
      home.conversationRevision.value++;
      await tester.pump();
      final roots = (await tester.runAsync(purge))!;
      home.purgeDeletedProjectTaskCards(
        proof,
        roots,
        expectedAppletScopeKey: _scope,
        expectedProjectBuildScopeKey: 'test|owner',
      );
      await tester.pump();
      expect(find.byType(AgentTaskChatCard), findsNothing);
      stale.complete([_message(), _message(task: true)]);
      await settle(tester);
      expect(find.byType(AgentTaskChatCard), findsNothing);
      expect(find.text('Keep ordinary conversation'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'positive deletion fence prevents job merge while durable purge is pending',
    (tester) async {
      final fixture =
          jsonDecode(
                File(
                  'tool/fixtures/project_build_wire_v2.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final snapshot = ProjectBuildV2Snapshot.fromJson(fixture['snapshot']);
      expect(snapshot.projectId, proof.projectId);
      final job = AgentTaskJob(
        id: _root,
        agentId: 'self',
        taskKind: AgentTaskKind.surfaceGeneration,
        userText: 'Synthetic saved project',
        status: AgentTaskJobStatus.completed,
        createdAt: DateTime.now(),
        appletScopeKey: _scope,
        projectBuildV2: ProjectBuildV2TaskBinding(
          scopeKey: 'test|owner',
          createRequestId: fixture['createRequest']['requestId'] as String,
          taskId: snapshot.taskId,
          snapshot: snapshot,
        ),
      );
      jobs.jobs.add(job);
      db.messages = [_message(), _message(task: true)];
      final chat = _QuietChat()..messages.assignAll(db.messages);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: appProviderContainer,
          child: const MaterialApp(
            home: Scaffold(
              body: HomeChatHistory(
                contentPadding: EdgeInsets.all(16),
                latestButtonBottom: 0,
                topFadeHeight: 0,
              ),
            ),
          ),
        ),
      );
      await settle(tester);
      expect(find.byType(AgentTaskChatCard), findsOneWidget);
      expect(
        chat.todayMessages.where((m) => m.taskReference != null),
        hasLength(1),
      );
      final gate = markers.purgeGate = Completer<void>();
      late Future<Set<String>> purging;
      await tester.runAsync(() async {
        purging = purge();
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();
      expect(jobs.isTaskDeleted(_root, expectedScopeKey: _scope), isTrue);
      expect(jobs.jobs, contains(job));
      home.conversationRevision.value++;
      await settle(tester);
      expect(find.byType(AgentTaskChatCard), findsNothing);
      expect(chat.todayMessages.where((m) => m.taskReference != null), isEmpty);
      expect(find.text('Keep ordinary conversation'), findsOneWidget);
      gate.complete();
      await tester.runAsync(() => purging);
      expect(jobs.jobs, isEmpty);
      chat.onClose();
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'reopened tombstones filter U2A cached cards but retain another scope and ordinary messages',
    () async {
      final chat = _QuietChat();
      chat.messages.assignAll([
        _message(),
        _message(task: true),
        _message(task: true, scope: 'foreign|owner'),
      ]);
      expect(chat.todayMessages, hasLength(3));
      await purge();
      expect(chat.todayMessages, hasLength(2));
      await jobs.deactivateAndDrain();
      jobs = await AgentTaskJobStore(persistence: markers).init();
      appServices.put<AgentTaskJobStore>(jobs, overrideAbstract: true);
      expect(chat.todayMessages, hasLength(2));
      expect(
        chat.todayMessages.any(
          (m) => m.content == 'Keep ordinary conversation',
        ),
        isTrue,
      );
      expect(
        chat.todayMessages.any(
          (m) => m.taskReference?.scopeKey == 'foreign|owner',
        ),
        isTrue,
      );
      chat.onClose();
    },
  );

  test(
    'a late dock read is fenced and a foreign proof cannot clear caches',
    () async {
      final widget = AgentWidget(
        id: 7,
        agentId: 'self',
        title: 'Owned',
        kind: 'surface',
        createdAt: DateTime.now(),
        spec: {'rendering': 'projectBundle', 'surfaceId': proof.projectId},
      );
      AppletLocalOwnership.stamp(widget, scopeKey: _scope);
      home.dockWidgets.add(widget);
      final stale = Completer<List<AgentWidget>>();
      db.nextWidgets = stale;
      final loading = home.loadDock();
      await Future<void>.delayed(Duration.zero);
      final foreign = await deletionProof(
        productionBundleFixture(),
        scope: 'test|foreign',
      );
      expect(
        () => home.purgeDeletedProjectTaskCards(
          foreign,
          {},
          expectedAppletScopeKey: _scope,
          expectedProjectBuildScopeKey: 'test|owner',
        ),
        throwsStateError,
      );
      expect(home.dockWidgets, hasLength(1));
      final roots = await purge();
      home.purgeDeletedProjectTaskCards(
        proof,
        roots,
        expectedAppletScopeKey: _scope,
        expectedProjectBuildScopeKey: 'test|owner',
      );
      stale.complete([widget]);
      await loading;
      expect(home.dockWidgets, isEmpty);
    },
  );
}

class _HistoryDb extends DBService {
  List<ChatMessage> messages = [];
  Completer<List<ChatMessage>>? nextMessages;
  Completer<List<AgentWidget>>? nextWidgets;
  @override
  Future<List<ChatMessage>> getMessagesInRange(
    String sessionId, {
    required DateTime from,
    required DateTime before,
  }) {
    final next = nextMessages;
    nextMessages = null;
    return next?.future ?? Future.value(List.of(messages));
  }

  @override
  Future<List<AgentWidget>> getAllWidgets() {
    final next = nextWidgets;
    nextWidgets = null;
    return next?.future ?? Future.value([]);
  }
}

class _Markers
    implements AgentTaskPersistence, AgentTaskProjectDeletionPersistence {
  bool deleted = false;
  Completer<void>? purgeGate;
  @override
  Future<List<Map<String, Object?>>> readJobs() async => [];
  @override
  Future<void> writeJob(Map<String, Object?> job, ChatMessage card) async {}
  @override
  Future<Map<String, Set<String>>> readDeletedLocalTaskIds() async => deleted
      ? {
          _scope: Set.unmodifiable({_root}),
        }
      : {};
  @override
  Future<Set<String>> purgeProjectBuildV2(
    ProjectBuildV2DeletionProof proof, {
    required String expectedScopeKey,
    required String expectedRepositoryScopeKey,
  }) async {
    await purgeGate?.future;
    deleted = true;
    return {_root};
  }
}

class _QuietHome extends HomeController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

class _QuietCore extends AgentCoreController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

class _QuietChat extends U2aChatController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

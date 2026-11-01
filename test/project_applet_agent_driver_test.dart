import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/project_build/application/project_applet_agent_coordinator.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/privacy_guarded_llm_client.dart';
import 'package:maaso/src/features/privacy/domain/privacy_models.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/project_build/application/project_applet_agent_driver.dart';
import 'package:maaso/src/features/project_build/application/project_applet_control_service.dart';
import 'package:maaso/src/features/project_build/data/project_applet_action_journal.dart';
import 'package:maaso/src/features/surface_play/data/surface_companion_call_ledger.dart';
import 'package:sembast/sembast_memory.dart';
import 'project_applet_control_test.dart' show AppletTestHost;

class _Model implements LLMClient {
  final prompts = <List<Message>>[];
  final answers = <Completer<String>>[];
  @override
  Duration get defaultTimeout => const Duration(seconds: 1);
  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) {
    prompts.add(messages);
    final response = Completer<String>();
    answers.add(response);
    return response.future;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

const finish = '{"operation":"finish","actionId":null,"args":{}}';
String action(int value) => jsonEncode({
  'operation': 'act',
  'actionId': 'app.set',
  'args': {'value': value},
});
Future<void> until(bool Function() predicate) async {
  for (var i = 0; i < 300; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('Condition not reached');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          (_) async => 1,
        );
    for (final name in [
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers',
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
  });
  late DBService db;
  late ProjectAppletControlService control;
  late AppletTestHost host;
  late SurfaceCompanionCallLedger ledger;
  late _Model model;
  late ProjectAppletGrant grant;
  late ProjectAppletAgentDriver driver;
  var current = true, canRun = true, index = 0;
  setUp(() async {
    current = canRun = true;
    db = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'applet-driver-${index++}.db',
    );
    ledger = SurfaceCompanionCallLedger(
      database: db,
      scopeKey: 'owner',
      isCurrent: () => current,
    );
    control = ProjectAppletControlService(
      scopeKey: 'storage-one',
      appletScopeKey: 'owner',
      journal: ProjectAppletActionJournal(
        database: db.raw,
        scopeKey: 'storage-one',
        repositoryScopeKey: 'owner',
        processId: 'test',
        isCurrent: () => current,
      ),
      isCurrent: () => current,
      isForeground: () => true,
      commandTimeout: const Duration(milliseconds: 25),
    );
    host = AppletTestHost();
    control.registerHost(host);
    grant = await control.grantFromNative(
      host,
      purpose: 'Set one then set two',
    );
    model = _Model();
    driver = ProjectAppletAgentDriver(
      control: control,
      grant: grant,
      calls: ledger,
      client: model,
      runInLane: (generate) => generate(),
      canRun: () => canRun,
      canDispatch: () => canRun,
    );
  });
  tearDown(() async {
    for (final answer in model.answers) {
      if (!answer.isCompleted) answer.complete(finish);
    }
    await driver.close();
    await control.deactivateAndDrain();
    await db.close();
  });
  Future<void> acknowledge(int value) async {
    await until(() => host.dispatched != null);
    final command = host.dispatched!;
    host.visible = {'value': value};
    await control.acceptRuntimeResult(host, host.callback!, {
      'requestId': command['requestId'],
      'actionId': command['actionId'],
      'status': 'applied',
      'stateVersion': 2,
      'result': {'value': value},
    });
    host.dispatched = null;
  }

  test(
    'multi-step loop observes results and uses only native declared actions',
    () async {
      driver.start();
      await until(() => model.answers.length == 1);
      model.answers[0].complete(action(1));
      await acknowledge(1);
      await until(() => model.answers.length == 2);
      final second = jsonDecode(model.prompts[1].last.content) as Map;
      expect(second['observation']['visibleState']['value'], 1);
      expect(second['previousReceipt']['status'], 'applied');
      expect(second['goal'], 'Set one then set two');
      model.answers[1].complete(action(2));
      await acknowledge(2);
      await until(() => model.answers.length == 3);
      model.answers[2].complete(finish);
      await until(() => driver.status == 'finished');
      expect(host.dispatchCount, 2);
      expect(host.inspectCount, 3);
      final calls = await stringMapStoreFactory
          .store('surface_companion_calls.v1')
          .find(db.raw);
      expect(calls, hasLength(3));
    },
  );
  test(
    'lost action acknowledgment queries receipt without a second command or model call',
    () async {
      driver.start();
      await until(() => model.answers.isNotEmpty);
      model.answers.single.complete(action(1));
      await until(() => !grant.isCurrent);
      expect(host.fenceCount, 1);
      expect(host.dispatchCount, 1);
      expect(model.answers, hasLength(1));
      final command = host.dispatched!;
      expect(
        await control.acceptRuntimeResult(host, host.callback!, {
          'requestId': command['requestId'],
          'actionId': command['actionId'],
          'status': 'applied',
          'stateVersion': 2,
        }),
        isFalse,
      );
      final receipt = await control.receipt(
        grant,
        command['requestId']! as String,
      );
      expect(receipt['status'], 'interrupted');
      expect(receipt['mayHaveApplied'], isTrue);
      driver.notifyAvailabilityChanged();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(host.dispatchCount, 1);
    },
  );
  test(
    'user priority during pending command fences writes and stops further decisions',
    () async {
      driver.start();
      await until(() => model.answers.isNotEmpty);
      model.answers.single.complete(action(1));
      await until(() => host.dispatchCount == 1);
      canRun = false;
      driver.notifyAvailabilityChanged();
      await until(() => !grant.isCurrent);
      expect(host.fenceCount, 1);
      expect(model.answers, hasLength(1));
      final receipt = await control.receipt(
        grant,
        host.dispatched!['requestId']! as String,
      );
      expect(receipt['status'], 'interrupted');
    },
  );
  test('a late model result cannot act after native takeover', () async {
    driver.start();
    await until(() => model.answers.isNotEmpty);
    await control.takeOverFromNative(host);
    model.answers.single.complete(action(1));
    await driver.close();
    expect(host.dispatchCount, 0);
    expect(model.answers, hasLength(1));
  });
  test(
    'model-invented action cannot dispatch or access another skill',
    () async {
      driver.start();
      await until(() => model.answers.isNotEmpty);
      model.answers.single.complete(
        '{"operation":"act","actionId":"email.send","args":{}}',
      );
      await until(() => driver.status == 'stopped');
      expect(host.dispatchCount, 0);
    },
  );
  test(
    'coordinator serializes replacement grants on the real runtime lane',
    () async {
      await appServices.reset();
      appServices.testMode = true;
      appServices.put(db);
      final runtime = AgentRuntime(
        agentId: 'self',
        profile: AgentProfile(
          nickname: 'Maaso',
          avatar: '',
          bio: '',
          personalityTraits: const [],
          catchphrase: '',
        ),
        llmClient: model,
        prepareTtsForNewTurn: (_) async {},
      );
      await runtime.init();
      final coordinator = ProjectAppletAgentCoordinator(
        control: control,
        calls: ledger,
        runtimeForAgent: (_) => runtime,
        isCurrent: () => current,
      );
      addTearDown(() async {
        for (final answer in model.answers) {
          if (!answer.isCompleted) answer.complete(finish);
        }
        await coordinator.deactivateAndDrain();
        await runtime.retireAndDrain();
        runtime.dispose();
        await appServices.reset();
      });
      await control.takeOverFromNative(host);
      host.controlIsReady = true;
      coordinator.start();
      await control.grantFromNative(host, purpose: 'first goal');
      await until(() => model.answers.length == 1);
      expect(runtime.isSurfacePlayDecisionActive, isTrue);
      await control.takeOverFromNative(host);
      host.controlIsReady = true;
      await control.grantFromNative(host, purpose: 'replacement goal');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        model.answers,
        hasLength(1),
        reason: 'Replacement must drain the first provider request',
      );
      model.answers[0].complete(action(1));
      await until(() => model.answers.length == 2);
      expect(host.dispatchCount, 0);
      expect(
        jsonDecode(model.prompts[1].last.content)['goal'],
        'replacement goal',
      );
      model.answers[1].complete(finish);
      await until(() => coordinator.status.value == 'finished');
      expect(host.dispatchCount, 0);
      final rows = await stringMapStoreFactory
          .store('surface_companion_calls.v1')
          .find(db.raw);
      expect(
        rows.map((r) => r.value['outcome']),
        everyElement('completed'),
        reason:
            'Successful provider replies still count, but must not become permanent unknown holds just because a user preempted delivery',
      );
    },
  );
  Future<void> useClient(LLMClient client) async {
    await driver.close();
    driver = ProjectAppletAgentDriver(
      control: control,
      grant: grant,
      calls: ledger,
      client: client,
      runInLane: (generate) => generate(),
      canRun: () => canRun,
      canDispatch: () => canRun,
    );
  }

  Future<String> recordedOutcome() async {
    final rows = await stringMapStoreFactory
        .store('surface_companion_calls.v1')
        .find(db.raw);
    return rows.single.value['outcome']! as String;
  }

  test(
    'privacy denial before inner client is not a permanent unknown hold',
    () async {
      await useClient(
        privacyGuardedLLMClient(
          model,
          () async => throw const PrivacyException('PRIVACY_CONSENT_REQUIRED'),
        ),
      );
      driver.start();
      await until(() => driver.status == 'stopped');
      expect(model.prompts, isEmpty);
      expect(await recordedOutcome(), 'notDispatched');
    },
  );
  test(
    'cancellation during permission wait blocks late model dispatch',
    () async {
      final entered = Completer<void>(), permission = Completer<void>();
      await useClient(
        privacyGuardedLLMClient(model, () {
          entered.complete();
          return permission.future;
        }),
      );
      driver.start();
      await entered.future;
      canRun = false;
      driver.notifyAvailabilityChanged();
      permission.complete();
      await until(() => driver.status == 'stopped');
      expect(model.prompts, isEmpty);
      expect(await recordedOutcome(), 'notDispatched');
    },
  );
  test(
    'a provider error named PrivacyException after admission remains unknown',
    () async {
      await useClient(privacyGuardedLLMClient(model, () async {}));
      driver.start();
      await until(() => model.answers.isNotEmpty);
      model.answers.single.completeError(
        const PrivacyException('PRIVACY_CONSENT_REQUIRED'),
      );
      await until(() => driver.status == 'stopped');
      expect(model.prompts, hasLength(1));
      expect(await recordedOutcome(), 'unknown');
    },
  );
}

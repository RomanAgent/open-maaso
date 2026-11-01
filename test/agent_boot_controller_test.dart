import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/agent_pipeline_runtime_service.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_boot_controller.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_card_controller.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/local_llm_service.dart';
import 'package:maaso/src/core/services/soul_service.dart';
import 'package:maaso/src/core/services/tts_warmup_service.dart';
import 'package:sembast/sembast_memory.dart';

class _PresentationReady extends ValueNotifier<bool> {
  _PresentationReady() : super(false);

  bool get isObserved => hasListeners;
}

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

var _databaseGeneration = 0;

Future<AgentCoreController> _putLoadedCore() async {
  final db = await DBService().init(
    factory: databaseFactoryMemory,
    path: 'agent_boot_test_${_databaseGeneration++}.db',
  );
  appServices.put<DBService>(db);
  final core = appServices.put(AgentCoreController());
  await core.loadProfile();
  expect(core.profile.value?.nickname, isEmpty);
  return core;
}

void _mockFlutterTts() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('flutter_tts'), (_) async {
        return 1;
      });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    appServices.testMode = true;
    _mockFlutterTts();
  });

  tearDown(() {
    appServices.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), null);
  });

  test('automatic opening waits for entry and resumes exactly once', () async {
    await _putLoadedCore();
    appServices.put(AgentPipelineRuntimeService()).proxyTtsReady.value = true;
    final ready = _PresentationReady();
    final spoken = <String>[];
    final boot = appServices.put(
      AgentBootController(
        fallbackStop: () async {},
        presentationReady: () => ready.value,
        presentationChanges: ready,
      )..say = spoken.add,
    );
    boot.boot();
    expect(boot.voiceReady.value, isTrue);
    expect(boot.awaitingName.value, isFalse);
    expect(spoken, isEmpty);

    ready.value = true;
    expect(boot.awaitingName.value, isTrue);
    expect(spoken, hasLength(1));
    ready.value = false;
    ready.value = true;
    boot.boot();
    expect(spoken, hasLength(1));

    await boot.deactivateAndDrain();
    expect(ready.isObserved, isFalse);
    ready.dispose();
  });

  for (final close in <bool>[false, true]) {
    test(
      '${close ? 'close' : 'deactivate'} retires pending opening listener',
      () async {
        await _putLoadedCore();
        appServices.put(AgentPipelineRuntimeService()).proxyTtsReady.value =
            true;
        final ready = _PresentationReady();
        final oldSpoken = <String>[];
        final old = AgentBootController(
          fallbackStop: () async {},
          presentationReady: () => ready.value,
          presentationChanges: ready,
        )..say = oldSpoken.add;
        old.onInit();
        expect(ready.isObserved, isTrue);
        if (close) old.onClose();
        await old.deactivateAndDrain();
        expect(ready.isObserved, isFalse);

        final nextSpoken = <String>[];
        final next = AgentBootController(
          fallbackStop: () async {},
          presentationReady: () => ready.value,
          presentationChanges: ready,
        )..say = nextSpoken.add;
        next.onInit();
        ready.value = true;
        old.boot();
        expect(oldSpoken, isEmpty);
        expect(old.awaitingName.value, isFalse);
        expect(nextSpoken, hasLength(1));

        await next.deactivateAndDrain();
        next.onClose();
        if (!close) old.onClose();
        expect(ready.isObserved, isFalse);
        ready.dispose();
      },
    );
  }

  test('presentation gate leaves explicit loading replies available', () async {
    final spoken = <String>[];
    final boot = AgentBootController(
      fallbackStop: () async {},
      presentationReady: () => false,
    )..say = spoken.add;
    boot.voiceLoading.value = true;
    expect(boot.tryInterceptUserMessage('Hello'), isTrue);
    expect(spoken, hasLength(1));
    await boot.deactivateAndDrain();
    boot.onClose();
  });

  test(
    'does not ask for a name until a local or cloud brain is callable',
    () async {
      await _putLoadedCore();
      final tts = appServices.put(TtsWarmupService());
      tts.isReady.value = true;
      final llm = appServices.put(LocalLLMService());
      llm.isAvailable.value = false;

      final boot = appServices.put(AgentBootController());
      boot.say = (_) {};
      boot.boot();
      await Future<void>.delayed(Duration.zero);

      expect(boot.awaitingName.value, isFalse);

      llm.isAvailable.value = true;
      await Future<void>.delayed(Duration.zero);

      expect(boot.awaitingName.value, isTrue);
    },
  );

  test(
    'confirming the boot name syncs profile nickname and soul name',
    () async {
      final core = await _putLoadedCore();
      final soul = appServices.put<SoulService>(_MemorySoulService());
      appServices.put(AgentCardController());
      final tts = appServices.put(TtsWarmupService());
      tts.isReady.value = true;
      final llm = appServices.put(LocalLLMService());
      llm.isAvailable.value = true;

      final boot = appServices.put(AgentBootController());
      boot.say = (_) {};
      boot.boot();
      await Future<void>.delayed(Duration.zero);
      expect(boot.awaitingName.value, isTrue);

      expect(boot.tryInterceptUserMessage('Momo'), isTrue);
      final card = appServices.find<AgentCardController>().current;
      expect(card?.type, 'confirm_name');

      card!.actions.onNext!();
      await Future<void>.delayed(Duration.zero);

      expect(core.profile.value?.nickname, 'Momo');
      expect(soul.name.value, 'Momo');
      expect(boot.awaitingName.value, isFalse);
    },
  );

  test(
    'default proxy asks once after cloud TTS and the chat surface are ready',
    () async {
      await _putLoadedCore();
      final pipeline = appServices.put(AgentPipelineRuntimeService());
      pipeline.proxyTtsReady.value = true;

      final boot = appServices.put(AgentBootController());
      await Future<void>.delayed(Duration.zero);

      // The runtime can become ready before HomeController binds its bubble.
      // That must not latch and lose the first visible onboarding line.
      expect(boot.awaitingName.value, isFalse);

      final spoken = <String>[];
      boot.say = spoken.add;
      boot.boot();
      await Future<void>.delayed(Duration.zero);

      expect(boot.voiceReady.value, isTrue);
      expect(boot.awaitingName.value, isTrue);
      expect(spoken, hasLength(1));

      pipeline.proxyTtsReady.value = false;
      pipeline.proxyTtsReady.value = true;
      boot.boot();
      await Future<void>.delayed(Duration.zero);

      expect(spoken, hasLength(1));
    },
  );
}

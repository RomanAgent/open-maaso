import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_utterance.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';

import 'conversation_entry_controllers_test.dart' show ConversationEntryHarness;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ConversationEntryHarness harness;
  late _LocalAccount lifecycle;

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    lifecycle = _LocalAccount();
    appServices.put<AccountSessionLifecycleService>(lifecycle);
    harness = await ConversationEntryHarness.create();
  });

  tearDown(() => harness.close());

  test(
    'Home executes the local dialogue while another device holds shared execution',
    () async {
      harness.home.inputController.text = '直接在这里聊';
      await harness.home.send();

      expect(lifecycle.canExecuteAgent, isFalse);
      expect(lifecycle.canChatLocally, isTrue);
      expect(harness.runtime.submissions, 1);
      final messages = await harness.database.getMessages('self');
      expect(messages.first.content, '直接在这里聊');
      expect(messages.map((message) => message.content), [
        '直接在这里聊',
        'A',
        'B',
        'C',
      ]);
      expect(harness.home.isThinking.value, isFalse);
    },
  );

  test('shared execution changes do not cancel a local Home turn', () async {
    final entered = Completer<void>();
    final finish = Completer<void>();
    harness.runtime.runChat = (context, history) async {
      entered.complete();
      await finish.future;
      await context.deliver([ConversationUtteranceDraft(text: '本机继续回应')]);
      return ExecutionResult.success('already delivered');
    };
    addTearDown(() {
      if (!finish.isCompleted) finish.complete();
    });
    harness.home.inputController.text = '执行权变化也继续聊';
    final sending = harness.home.send();
    await entered.future.timeout(const Duration(seconds: 3));
    lifecycle.publish(sharedExecution: true);
    lifecycle.publish(sharedExecution: false);
    finish.complete();
    await sending.timeout(const Duration(seconds: 3));

    expect(harness.runtime.submissions, 1);
    expect(lifecycle.canExecuteAgent, isFalse);
    expect(
      (await harness.database.getMessages(
        'self',
      )).map((message) => message.content),
      ['执行权变化也继续聊', '本机继续回应'],
    );
  });

  test('account retirement fences a local Home reply', () async {
    final entered = Completer<void>();
    final finish = Completer<void>();
    harness.runtime.runChat = (context, history) async {
      entered.complete();
      await finish.future;
      await context.deliver([
        ConversationUtteranceDraft(text: 'retired reply'),
      ]);
      return ExecutionResult.success('already delivered');
    };
    addTearDown(() {
      if (!finish.isCompleted) finish.complete();
    });
    harness.home.inputController.text = 'before retirement';
    final sending = harness.home.send();
    await entered.future.timeout(const Duration(seconds: 3));
    lifecycle.publish(mounted: false);
    finish.complete();
    await sending.timeout(const Duration(seconds: 3));

    expect(lifecycle.canChatLocally, isFalse);
    expect(
      (await harness.database.getMessages(
        'self',
      )).where((message) => !message.isUserMessage),
      isEmpty,
    );
  });
}

class _LocalAccount extends AppService
    implements AccountSessionLifecycleService {
  final _listeners = <VoidCallback>[];
  bool _mounted = true;
  bool _sharedExecution = false;

  @override
  bool get isMounted => _mounted;
  @override
  bool get canChatLocally => _mounted;
  @override
  bool get canExecuteAgent => _sharedExecution;

  void publish({bool? mounted, bool? sharedExecution}) {
    _mounted = mounted ?? _mounted;
    _sharedExecution = sharedExecution ?? _sharedExecution;
    for (final listener in List<VoidCallback>.of(_listeners)) {
      listener();
    }
  }

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);
  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

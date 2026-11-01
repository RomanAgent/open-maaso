import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';

import 'conversation_entry_controllers_test.dart' show ConversationEntryHarness;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ConversationEntryHarness harness;
  late _LocalChatAccount account;
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    harness = await ConversationEntryHarness.create();
    account =
        appServices.put<AccountSessionLifecycleService>(_LocalChatAccount())
            as _LocalChatAccount;
  });
  tearDown(() async => harness.close());

  for (final entry in ['chat', 'companion']) {
    test(
      '$entry uses the local runtime without an exclusive execution lease',
      () async {
        harness.runtime.runChat = (_, _) async =>
            ExecutionResult.success('本机回复');
        harness.input(entry).text = '这里继续聊天';
        await harness.send(entry).timeout(const Duration(seconds: 5));
        expect(account.canExecuteAgent, isFalse);
        expect(account.canChatLocally, isTrue);
        expect(harness.runtime.submissions, 1);
        expect(harness.input(entry).text, isEmpty);
        expect(
          (await harness.database.getMessages(
            'self',
          )).map((row) => row.content),
          ['这里继续聊天', '本机回复'],
        );
      },
    );

    test(
      '$entry preserves its draft when the local account is unmounted',
      () async {
        account.mounted = false;
        harness.input(entry).text = '保留待发送内容';
        await harness.send(entry);
        expect(harness.runtime.submissions, 0);
        expect(harness.input(entry).text, '保留待发送内容');
        expect(await harness.database.getMessages('self'), isEmpty);
      },
    );
  }
}

class _LocalChatAccount extends AppService
    implements AccountSessionLifecycleService {
  bool mounted = true;
  @override
  bool get isMounted => mounted;
  @override
  bool get canChatLocally => mounted;
  @override
  bool get canExecuteAgent => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

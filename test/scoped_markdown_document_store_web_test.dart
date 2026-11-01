import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/services/persistence/markdown_document_store_base.dart';
import 'package:maaso/src/core/services/persistence/markdown_document_store_web.dart'
    as web;

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test(
    'account document stores are isolated by account and environment',
    () async {
      final accountA = AccountStorageScope(
        environmentKey: 'prod',
        accountUuid: 'account-A-sensitive',
      );
      final accountB = AccountStorageScope(
        environmentKey: 'prod',
        accountUuid: 'account-B-sensitive',
      );
      final testAccountA = AccountStorageScope(
        environmentKey: 'test',
        accountUuid: 'account-A-sensitive',
      );
      final storeA = await web.openAccountMarkdownDocumentStore(
        accountA,
        AccountMarkdownDocumentKind.master,
      );
      final storeB = await web.openAccountMarkdownDocumentStore(
        accountB,
        AccountMarkdownDocumentKind.master,
      );
      final testStoreA = await web.openAccountMarkdownDocumentStore(
        testAccountA,
        AccountMarkdownDocumentKind.master,
      );

      await storeA.write('owner A');

      expect(await storeA.read(), 'owner A');
      expect(await storeB.read(), isNull);
      expect(await testStoreA.read(), isNull);

      final preferences = await SharedPreferences.getInstance();
      expect(preferences.containsKey('maaso.markdown.master.md'), isFalse);
      for (final key in preferences.getKeys()) {
        expect(key, isNot(contains('account-A-sensitive')));
        expect(key, startsWith(accountA.webKeyPrefix));
      }
    },
  );

  test(
    'agent document stores are isolated by agent and document kind',
    () async {
      final account = AccountStorageScope(
        environmentKey: 'prod',
        accountUuid: 'account-1',
      );
      final firstAgent = account.agent('agent-1');
      final secondAgent = account.agent('agent-2');
      final firstSoul = await web.openAgentMarkdownDocumentStore(
        firstAgent,
        AgentMarkdownDocumentKind.soul,
      );
      final firstWorld = await web.openAgentMarkdownDocumentStore(
        firstAgent,
        AgentMarkdownDocumentKind.world,
      );
      final secondSoul = await web.openAgentMarkdownDocumentStore(
        secondAgent,
        AgentMarkdownDocumentKind.soul,
      );

      await firstSoul.write('first soul');

      expect(await firstSoul.read(), 'first soul');
      expect(await firstWorld.read(), isNull);
      expect(await secondSoul.read(), isNull);
    },
  );

  test('scoped Markdown APIs expose only fixed document names', () {
    expect(
      AccountMarkdownDocumentKind.values.map((value) => value.fileName),
      <String>['master.md'],
    );
    expect(
      AgentMarkdownDocumentKind.values.map((value) => value.fileName),
      <String>['soul.md', 'world.md'],
    );
  });
}

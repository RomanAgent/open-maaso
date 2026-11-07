import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:maaso/src/offline/offline_skills.dart';
import 'package:maaso/src/offline/offline_store.dart';

void main() {
  late OfflineStore store;
  var counter = 0;
  setUp(() async {
    store = await OfflineStore.open(
      factory: databaseFactoryMemory,
      path: 'skill-page-${counter++}.db',
      seedSamples: false,
    );
  });
  tearDown(() => store.close());

  testWidgets('create and edit a skill through the local page', (tester) async {
    var changes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: OfflineSkillsPage(store: store, onChanged: () => changes++),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('还没有本地技能'), findsOneWidget);
    await tester.tap(find.byTooltip('添加技能'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), '我的写作助手');
    await tester.enterText(find.byType(TextFormField).at(1), '先列出三个要点，再给出解释。');
    await tester.tap(find.text('保存到本机'));
    await tester.pumpAndSettle();
    final initial = (await tester.runAsync(store.listSkills))!;
    expect(initial, hasLength(1));
    expect(initial.single.name, '我的写作助手');
    expect(initial.single.enabled, isTrue);
    expect(changes, 1);
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(1), '用一个例子说明。');
    await tester.tap(find.text('保存到本机'));
    await tester.pumpAndSettle();
    final changed = (await tester.runAsync(store.listSkills))!;
    expect(changed.single.id, initial.single.id);
    expect(changed.single.instructions, '用一个例子说明。');
    expect(changes, 2);
  });

  testWidgets(
    'toggle persists and deletion requires an explicit confirmation',
    (tester) async {
      await tester.runAsync(
        () => store.saveSkill(
          const OfflineSkill(id: 'one', name: '本地偏好', instructions: '保持简洁。'),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(home: OfflineSkillsPage(store: store)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(
        ((await tester.runAsync(store.listSkills))!).single.enabled,
        isFalse,
      );
      await tester.tap(find.byTooltip('删除本地偏好'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect((await tester.runAsync(store.listSkills))!, hasLength(1));
      await tester.tap(find.byTooltip('删除本地偏好'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();
      expect((await tester.runAsync(store.listSkills))!, isEmpty);
      expect(find.text('还没有本地技能'), findsOneWidget);
    },
  );

  testWidgets(
    'blank form never creates a record; compact page has no overflow',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
            child: OfflineSkillsPage(store: store),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('添加技能'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存到本机'));
      await tester.pumpAndSettle();
      expect(find.text('请输入技能名称'), findsOneWidget);
      expect(find.text('请输入提示内容'), findsOneWidget);
      expect((await tester.runAsync(store.listSkills))!, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'skills participate in full local backup without executable fields',
    () async {
      await store.saveSkill(
        const OfflineSkill(
          id: 'saved',
          name: '备份偏好',
          instructions: '尽量给出例子。',
          enabled: false,
        ),
      );
      final backup = await store.exportJson();
      final parsed = jsonDecode(backup) as Map;
      expect(parsed['skills'], hasLength(1));
      final restored = await OfflineStore.open(
        factory: databaseFactoryMemory,
        path: 'skill-restored-${counter++}.db',
        seedSamples: false,
      );
      try {
        await restored.importJson(backup, replace: true);
        final entries = await restored.listSkills();
        expect(entries.single.name, '备份偏好');
        expect(entries.single.enabled, isFalse);
        expect(
          entries.single.toJson().keys,
          unorderedEquals(['id', 'name', 'instructions', 'enabled']),
        );
      } finally {
        await restored.close();
      }
    },
  );
}

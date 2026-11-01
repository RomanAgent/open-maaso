import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/conversation_policy.dart';
import 'package:maaso/src/core/models/conversation_preference.dart';
import 'package:maaso/src/core/services/conversation_preference_service.dart';
import 'package:maaso/src/features/relationship/presentation/conversation_preference_controls.dart';

const _scope =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

void main() {
  late ConversationPreferenceService service;
  late _Store store;
  setUp(() async {
    await appServices.reset();
    store = _Store();
    service = await ConversationPreferenceService(
      store: store,
      accountScopeDigest: _scope,
    ).init();
    appServices.put(service);
  });
  tearDown(() => appServices.reset());

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(375, 812),
    double scale = 1,
    Brightness brightness = Brightness.light,
    Locale locale = const Locale('zh'),
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        supportedLocales: const [Locale('zh'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: ThemeData(brightness: brightness),
        home: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(scale),
            disableAnimations: true,
          ),
          child: const Scaffold(
            body: SingleChildScrollView(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: ConversationPreferenceControls(),
              ),
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
  }

  testWidgets('humor defaults and light banter never silently grant topics', (
    tester,
  ) async {
    await mount(tester);
    expect(find.text('偶尔逗我'), findsOneWidget);
    await tester.tap(find.text('开玩笑的方式'));
    await _settle(tester);
    await tester.tap(find.text('适度互损'));
    await _settle(tester);
    expect(
      service.effectiveSnapshot.humorStyle,
      ConversationHumorStyle.lightBanter,
    );
    expect(service.effectiveSnapshot.banterBoundaries, isEmpty);
    await tester.tap(find.text('允许轻轻吐槽的话题'));
    await _settle(tester);
    expect(find.widgetWithText(CheckboxListTile, '健康'), findsNothing);
    await tester.tap(find.widgetWithText(CheckboxListTile, '游戏'));
    await tester.tap(find.text('保存'));
    await _settle(tester);
    expect(service.effectiveSnapshot.banterBoundaries, {
      'gaming': BanterDisposition.accepted,
    });
  });

  testWidgets('preferred names are editable and empty save clears them', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.text('怎么称呼我'));
    await _settle(tester);
    await tester.enterText(find.byType(TextField), '小林');
    await tester.tap(find.text('保存'));
    await _settle(tester);
    expect(find.text('小林'), findsOneWidget);
    await tester.tap(find.text('怎么称呼我'));
    await _settle(tester);
    await tester.enterText(find.byType(TextField), '');
    await tester.tap(find.text('保存'));
    await _settle(tester);
    expect(service.effectiveSnapshot.preferredAddress, isNull);
  });

  testWidgets('unsupported names stay in the form with inline validation', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.text('怎么称呼我'));
    await _settle(tester);
    await tester.enterText(find.byType(TextField), 'Alex!');
    await tester.tap(find.text('保存'));
    await _settle(tester);
    expect(service.effectiveSnapshot.preferredAddress, isNull);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('最多16个称呼'), findsOneWidget);
  });

  testWidgets('topic save failure retains checked choices for retry', (
    tester,
  ) async {
    await mount(tester);
    await tester.ensureVisible(find.text('不想被调侃的话题'));
    await tester.tap(find.text('不想被调侃的话题'));
    await _settle(tester);
    await tester.tap(find.widgetWithText(CheckboxListTile, '游戏'));
    store.fail = true;
    await tester.tap(find.text('保存'));
    await _settle(tester);
    expect(find.textContaining('未保存。'), findsOneWidget);
    expect(
      tester
          .widget<CheckboxListTile>(find.widgetWithText(CheckboxListTile, '游戏'))
          .value,
      isTrue,
    );
    store.fail = false;
    await tester.tap(find.text('保存'));
    await _settle(tester);
    expect(service.effectiveSnapshot.banterBoundaries, {
      'gaming': BanterDisposition.forbidden,
    });
  });

  testWidgets(
    'a failed address save retains the draft and explains the failure',
    (tester) async {
      await mount(tester);
      store.fail = true;
      await tester.tap(find.text('怎么称呼我'));
      await _settle(tester);
      await tester.enterText(find.byType(TextField), '小林');
      await tester.tap(find.text('保存'));
      await _settle(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '小林',
      );
      expect(find.textContaining('未保存。'), findsOneWidget);
      expect(service.effectiveSnapshot.preferredAddress, isNull);
      store.fail = false;
      await tester.tap(find.text('保存'));
      await _settle(tester);
      expect(service.effectiveSnapshot.preferredAddress, '小林');
    },
  );

  testWidgets(
    'the clear control removes choices while keeping learned habits separate',
    (tester) async {
      await tester.runAsync(() => service.setPreferredAddress('小林'));
      await mount(tester);
      expect(find.text('记住的交流习惯'), findsNothing);
      await tester.ensureVisible(find.text('清空这些聊天设置'));
      await tester.tap(find.text('清空这些聊天设置'));
      await _settle(tester);
      expect(service.effectiveSnapshot.preferredAddress, isNull);
      expect(service.revision, 2);
    },
  );

  for (final layout in [
    (const Size(375, 812), Brightness.dark),
    (const Size(812, 375), Brightness.light),
  ]) {
    testWidgets('large text fits ${layout.$1} ${layout.$2}', (tester) async {
      await mount(
        tester,
        size: layout.$1,
        scale: 2,
        brightness: layout.$2,
        locale: const Locale('en'),
      );
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Call me'));
      await tester.tap(find.text('Call me'));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('Save'), findsOneWidget);
    });
  }
}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  });
  await tester.pumpAndSettle();
}

class _Store implements ConversationPreferenceStore {
  Map<String, Object?>? row;
  bool fail = false;
  @override
  Future<Map<String, Object?>?> read() async => row;
  @override
  Future<void> write(ConversationPreferenceSnapshot value) async {
    if (fail) throw StateError('storage failed');
    row = value.toStorageJson();
  }
}

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/widgets/theme.dart';
import 'package:maaso/src/core/widgets/ui/app_palette.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_native_frost_group.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_frost_tokens.dart';
import 'package:maaso/src/features/chat/presentation/widgets/chat_window_visibility.dart';
import 'package:maaso/src/features/chat/presentation/widgets/message_bubble.dart';

const _menu = ValueKey('message-action-menu');

Widget _reply(String text, int id) => MessageBubble(
  message: ChatMessage(
    id: id,
    sessionId: 'self',
    senderId: 'self',
    receiverId: 'user',
    content: text,
    timestamp: DateTime(2026, 9, 15, 14, 8),
    deliveryStatus: 'published',
  ),
);

Widget _host({
  ValueNotifier<bool>? visible,
  bool highContrast = false,
  bool disableAnimations = false,
  String? fontFamily,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: AppTheme.build(AppPalette.of(Brightness.light, AppAccent.blue))
      .copyWith(
        textTheme: AppTheme.build(
          AppPalette.of(Brightness.light, AppAccent.blue),
        ).textTheme.apply(fontFamily: fontFamily),
      ),
  home: MediaQuery(
    data: MediaQueryData(
      highContrast: highContrast,
      disableAnimations: disableAnimations,
    ),
    child: Scaffold(
      body: Center(
        child: SizedBox(
          width: 340,
          height: 300,
          child: AppNativeFrostGroup(
            child: ValueListenableBuilder<bool>(
              valueListenable: visible ?? _alwaysVisible,
              builder: (_, value, child) =>
                  ChatWindowVisibilityScope(visible: value, child: child!),
              child: ListView(
                padding: const EdgeInsets.only(left: 90, top: 40),
                children: [
                  _reply('First reply', 1),
                  const SizedBox(height: 60),
                  _reply('Second reply', 2),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  ),
);

final _alwaysVisible = ValueNotifier(true);

double _foregroundOpacity(WidgetTester tester) => tester
    .widgetList<Opacity>(
      find.descendant(of: find.byKey(_menu), matching: find.byType(Opacity)),
    )
    .first
    .opacity;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final created = <int>[];
  final disposed = <int>[];
  final payloads = <int, List<Map<Object?, Object?>>>{};
  Future<void> Function(int)? delayCreate;
  Future<void> Function(int)? delayRegions;

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    created.clear();
    disposed.clear();
    payloads.clear();
    delayCreate = null;
    delayRegions = null;
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform_views, (call) async {
          final args = call.arguments;
          final id = args is Map ? args['id'] as int : args as int;
          if (call.method == 'create') {
            created.add(id);
            payloads[id] = [];
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(
                  MethodChannel('maaso/frosted_input/$id'),
                  (call) async {
                    if (call.method == 'regions') {
                      payloads[id]!.add(
                        Map<Object?, Object?>.from(call.arguments as Map),
                      );
                      await delayRegions?.call(id);
                    }
                    return null;
                  },
                );
            await delayCreate?.call(id);
          } else if (call.method == 'dispose') {
            disposed.add(id);
          }
          return null;
        });
  });

  testWidgets('slow native setup stays invisible then starts the stagger', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();
    final create = Completer<void>();
    final ack = Completer<void>();
    delayCreate = (_) => create.future;
    delayRegions = (_) => ack.future;
    await tester.tap(find.text('First reply'));
    await tester.pumpAndSettle();
    final menuId = created.last;
    expect(created, hasLength(2));
    expect(payloads[menuId], isEmpty);
    expect(_foregroundOpacity(tester), 0);
    expect(
      find.byKey(const ValueKey('message-copy-action')).hitTestable(),
      findsNothing,
    );
    await tester.pump(const Duration(seconds: 1));
    expect(_foregroundOpacity(tester), 0);
    create.complete();
    await tester.pumpAndSettle();
    expect(payloads[menuId]!.single['opacity'], 0);
    expect(_foregroundOpacity(tester), 0);
    ack.complete();
    // Layout/ack/readiness are frame boundaries, independent of elapsed time.
    for (var frame = 0; frame < 4; frame++) {
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 60));
    expect(_foregroundOpacity(tester), allOf(greaterThan(0), lessThan(1)));
    final first = tester
        .widget<Opacity>(find.byKey(const ValueKey('message-action-opacity-0')))
        .opacity;
    final last = tester
        .widget<Opacity>(find.byKey(const ValueKey('message-action-opacity-3')))
        .opacity;
    expect(first, greaterThan(last));
    await tester.pumpAndSettle();
    expect(_foregroundOpacity(tester), 1);
    expect(payloads[menuId]!.last['opacity'], 1);
    final sent = payloads[menuId]!.length;
    await tester.pump(const Duration(seconds: 2));
    expect(
      payloads[menuId],
      hasLength(sent),
      reason: 'readiness does not restart a settled animation',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'closing before creation and same-frame reopening cannot strand actions',
    (tester) async {
      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();
      final create = Completer<void>();
      delayCreate = (_) => create.future;
      await tester.tap(find.text('First reply'));
      await tester.pumpAndSettle();
      final oldId = created.last;
      await tester.tap(find.text('First reply'));
      await tester.tap(find.text('First reply'));
      delayCreate = null;
      await tester.pumpAndSettle();
      expect(created, hasLength(3));
      expect(_foregroundOpacity(tester), 1);
      create.complete();
      await tester.pumpAndSettle();
      expect(disposed, contains(oldId));
      expect(find.byType(UiKitView), findsNWidgets(2));
      expect(_foregroundOpacity(tester), 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'reduced motion waits for native ack and same-frame reopening stays usable',
    (tester) async {
      await tester.pumpWidget(_host(disableAnimations: true));
      await tester.pumpAndSettle();
      final ack = Completer<void>();
      delayRegions = (_) => ack.future;
      await tester.tap(find.text('First reply'));
      await tester.pumpAndSettle();
      expect(_foregroundOpacity(tester), 0);
      expect(payloads[created.last]!.single['opacity'], 0);
      ack.complete();
      await tester.pumpAndSettle();
      expect(_foregroundOpacity(tester), 1);
      for (var index = 0; index < 4; index++) {
        expect(
          tester
              .widget<Opacity>(
                find.byKey(ValueKey('message-action-opacity-$index')),
              )
              .opacity,
          1,
        );
      }
      final oldId = created.last;
      await tester.tap(find.text('First reply'));
      await tester.tap(find.text('First reply'));
      await tester.pumpAndSettle();
      expect(created, hasLength(3));
      expect(disposed, contains(oldId));
      expect(_foregroundOpacity(tester), 1);
      expect(
        find.byKey(const ValueKey('message-copy-action')).hitTestable(),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'failed nested native material uses its own readable fallback and can retry',
    (tester) async {
      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();
      final conversationId = created.single;
      delayRegions = (id) async {
        if (id != conversationId) throw PlatformException(code: 'unavailable');
      };
      await tester.tap(find.text('First reply'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(_menu),
          matching: find.byType(UiKitView),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byKey(_menu),
          matching: find.byType(AppNativeFrostRegion),
        ),
        findsNothing,
      );
      expect(_foregroundOpacity(tester), 1);
      expect(
        find.byKey(const ValueKey('message-copy-action')).hitTestable(),
        findsOneWidget,
      );
      expect(
        find.byType(UiKitView),
        findsOneWidget,
        reason: 'the conversation retains its own healthy sampler',
      );
      await tester.tap(find.text('First reply'));
      await tester.pumpAndSettle();
      delayRegions = null;
      await tester.tap(find.text('First reply'));
      await tester.pumpAndSettle();
      expect(find.byType(UiKitView), findsNWidgets(2));
      expect(_foregroundOpacity(tester), 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'high contrast replaces pending material without an old ack reviving it',
    (tester) async {
      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();
      final ack = Completer<void>();
      delayRegions = (_) => ack.future;
      await tester.tap(find.text('First reply'));
      await tester.pumpAndSettle();
      expect(_foregroundOpacity(tester), 0);
      await tester.pumpWidget(_host(highContrast: true));
      await tester.pumpAndSettle();
      // Reparenting the conversation can close its portal; either way a fresh
      // activation must expose usable non-native controls immediately.
      if (find.byKey(_menu).evaluate().isEmpty) {
        await tester.tap(find.text('First reply'));
        await tester.pumpAndSettle();
      }
      expect(find.byType(UiKitView), findsNothing);
      expect(_foregroundOpacity(tester), 1);
      expect(
        find.byKey(const ValueKey('message-copy-action')).hitTestable(),
        findsOneWidget,
      );
      ack.complete();
      await tester.pumpAndSettle();
      expect(find.byType(UiKitView), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    },
  );

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    for (final id in created) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            MethodChannel('maaso/frosted_input/$id'),
            null,
          );
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform_views, null);
    await appServices.reset();
  });

  testWidgets('a menu in a scrollable allocates one independent native sampler', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();
    expect(created, hasLength(1));
    final conversationPayload = payloads[created.first]!.last;
    await tester.tap(find.text('First reply'));
    await tester.pumpAndSettle();
    expect(created, hasLength(2));
    expect(find.byType(UiKitView), findsNWidgets(2));
    final menuView = find.descendant(
      of: find.byKey(_menu),
      matching: find.byType(UiKitView),
    );
    expect(menuView, findsOneWidget);
    // OverlayPortal preserves inherited widgets from the conversation but
    // paints in the overlay. Check actual render ancestry, not Element ancestry.
    RenderObject? ancestor = tester.renderObject(menuView).parent;
    while (ancestor != null) {
      expect(ancestor, isNot(isA<RenderOpacity>()));
      expect(ancestor, isNot(isA<RenderShaderMask>()));
      ancestor = ancestor.parent;
    }
    final bounds = tester.getRect(menuView);
    expect(bounds.width, closeTo(24.5, .1));
    expect(bounds.height, closeTo(87.15, .1));
    final menuPayload = payloads[created.last]!.last;
    expect(menuPayload['regions'], hasLength(1));
    expect(menuPayload['topFade'], 0);
    expect(menuPayload['bottomFade'], 0);
    final region = (menuPayload['regions'] as List).single as Map;
    expect(region['radius'], MaasoFrostTokens.messageRadius);
    expect(region['userTint'], false);
    expect(region['width'], closeTo(bounds.width, .1));
    expect(payloads[created.first]!.last, conversationPayload);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
    expect(disposed, containsAll(created));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'normal close animates but suppression releases the view immediately',
    (tester) async {
      final visible = ValueNotifier(true);
      addTearDown(visible.dispose);
      await tester.pumpWidget(_host(visible: visible));
      await tester.pumpAndSettle();
      await tester.tap(find.text('First reply'));
      await tester.pumpAndSettle();
      final menuId = created.last;
      await tester.tap(find.text('First reply'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.byType(UiKitView), findsNWidgets(2));
      expect(disposed, isNot(contains(menuId)));
      visible.value = false;
      await tester.pump();
      await tester.pump();
      expect(find.byKey(_menu), findsNothing);
      expect(find.byType(UiKitView), findsOneWidget);
      expect(disposed, contains(menuId));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('switching messages never retains two menu samplers', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();
    await tester.tap(find.text('First reply'));
    await tester.pumpAndSettle();
    final firstMenuId = created.last;
    await tester.tap(find.text('Second reply'));
    await tester.pumpAndSettle();
    expect(find.byKey(_menu), findsOneWidget);
    expect(find.byType(UiKitView), findsNWidgets(2));
    expect(created, hasLength(3));
    expect(disposed, contains(firstMenuId));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'route changes remove the sampler without waiting for the close animation',
    (tester) async {
      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();
      await tester.tap(find.text('First reply'));
      await tester.pumpAndSettle();
      final menuId = created.last;
      final context = tester.element(find.text('First reply'));
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Next page')),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byKey(_menu), findsNothing);
      expect(disposed, contains(menuId));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('high contrast uses readable opaque Flutter material', (
    tester,
  ) async {
    await tester.pumpWidget(_host(highContrast: true));
    await tester.pumpAndSettle();
    await tester.tap(find.text('First reply'));
    await tester.pumpAndSettle();
    expect(find.byKey(_menu), findsOneWidget);
    expect(find.byType(UiKitView), findsNothing);
    expect(created, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('exports an actual Flutter layout preview when requested', (
    tester,
  ) async {
    const previewDirectory = String.fromEnvironment(
      'MAASO_MESSAGE_MENU_PREVIEW_DIR',
    );
    if (previewDirectory.isEmpty) {
      debugDefaultTargetPlatformOverride = null;
      return;
    }
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(390, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await ui.loadFontFromList(
        await File('assets/fonts/NunitoSans-Variable.ttf').readAsBytes(),
        fontFamily: 'PreviewSans',
      );
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    });
    final repaint = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: repaint,
        child: _host(fontFamily: 'PreviewSans'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('First reply'));
    await tester.pumpAndSettle();
    final boundary =
        repaint.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(previewDirectory).create(recursive: true);
      await File(
        '$previewDirectory/compact-message-menu-flutter.png',
      ).writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
  });
}

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/widgets/theme.dart';
import 'package:maaso/src/core/widgets/ui/app_palette.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_native_frost_group.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_frost_tokens.dart';
import 'package:maaso/src/features/chat/presentation/widgets/chat_history_edge.dart';
import 'package:maaso/src/features/chat/presentation/widgets/message_bubble.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final payloads = <Map<Object?, Object?>>[];
  final created = <int>[];
  final disposed = <int>[];
  final payloadViews = <int>[];
  Future<void> Function(int id)? delayCreate;
  Future<void> Function(int id)? delayRegions;

  setUp(() {
    payloads.clear();
    created.clear();
    disposed.clear();
    payloadViews.clear();
    delayCreate = null;
    delayRegions = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform_views, (call) async {
          final args = call.arguments;
          final id = args is Map ? args['id'] as int : args as int;
          if (call.method == 'create') {
            created.add(id);
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(
                  MethodChannel('maaso/frosted_input/$id'),
                  (call) async {
                    if (call.method == 'regions') {
                      payloadViews.add(id);
                      payloads.add(
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

  testWidgets('user bubble keeps readable text in both appearances', (
    tester,
  ) async {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      await tester.pumpWidget(
        _host(brightness: brightness, child: _pairedMessages()),
      );
      await tester.pumpAndSettle();
      final userText = tester.widget<Text>(find.text(_message(1).content));
      expect(
        userText.style?.color,
        brightness == Brightness.dark
            ? MaasoFrostTokens.darkOnUserMessage
            : MaasoFrostTokens.lightOnUserMessage,
      );
    }
  });

  testWidgets(
    'fills remain readable through delayed create and first region ack',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final create = Completer<void>();
      final regions = Completer<void>();
      delayCreate = (_) => create.future;
      delayRegions = (_) => regions.future;
      await tester.pumpWidget(_host(child: _pairedMessages()));
      await tester.pumpAndSettle();
      expect(created, hasLength(1));
      expect(payloads, isEmpty);
      expect(_fallbackFills(tester), [
        MaasoFrostTokens.lightSurface.withValues(
          alpha: MaasoFrostTokens.messageFillAlpha,
        ),
        MaasoFrostTokens.lightUserMessage.withValues(
          alpha: MaasoFrostTokens.messageUserFillAlpha,
        ),
      ]);
      final before = _regionRects(tester);
      create.complete();
      await tester.pumpAndSettle();
      expect(payloads.last['regions'], hasLength(2));
      expect(_fallbackFills(tester).every((fill) => fill != null), isTrue);
      expect(_regionRects(tester), before);
      regions.complete();
      await tester.pumpAndSettle();
      expect(_fallbackFills(tester), [null, null]);
      expect(_regionRects(tester), before);
      expect(find.byType(BackdropFilter), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
      expect(disposed, orderedEquals(created));
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'theme replacement restores fills until the new view acknowledges regions',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await tester.pumpWidget(_host(child: _pairedMessages()));
      await tester.pumpAndSettle();
      expect(_fallbackFills(tester), [null, null]);
      final oldView = created.single;
      final before = _regionRects(tester);
      final create = Completer<void>();
      final regions = Completer<void>();
      delayCreate = (_) => create.future;
      delayRegions = (_) => regions.future;
      await tester.pumpWidget(
        _host(brightness: Brightness.dark, child: _pairedMessages()),
      );
      await tester.pumpAndSettle();
      expect(created, hasLength(2));
      expect(disposed, contains(oldView));
      expect(_fallbackFills(tester), [
        MaasoFrostTokens.darkSurface.withValues(
          alpha: MaasoFrostTokens.messageFillAlpha,
        ),
        MaasoFrostTokens.darkUserMessage.withValues(
          alpha: MaasoFrostTokens.messageUserFillAlpha,
        ),
      ]);
      expect(_regionRects(tester), before);
      create.complete();
      await tester.pumpAndSettle();
      expect(payloadViews.last, created.last);
      expect(_fallbackFills(tester).every((fill) => fill != null), isTrue);
      regions.complete();
      await tester.pumpAndSettle();
      expect(_fallbackFills(tester), [null, null]);
      expect(_regionRects(tester), before);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
      expect(disposed, orderedEquals(created));
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'an opacity update does not postpone acknowledged geometry readiness',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final firstAck = Completer<void>();
      final opacityAck = Completer<void>();
      delayRegions = (_) =>
          payloads.length == 1 ? firstAck.future : opacityAck.future;
      await tester.pumpWidget(_host(opacity: .2, child: _pairedMessages()));
      await tester.pumpAndSettle();
      await tester.pumpWidget(_host(opacity: .6, child: _pairedMessages()));
      await tester.pumpAndSettle();
      expect(_fallbackFills(tester).every((fill) => fill != null), isTrue);
      firstAck.complete();
      await tester.pumpAndSettle();
      expect(payloads, hasLength(2));
      expect(payloads.first['regions'], payloads.last['regions']);
      expect(payloads.last['opacity'], .6);
      expect(
        _fallbackFills(tester),
        [null, null],
        reason: 'the pending visibility update has the same accepted geometry',
      );
      opacityAck.complete();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('an old view ack cannot enable or block its theme replacement', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final oldAck = Completer<void>();
    final newAck = Completer<void>();
    delayRegions = (id) => id == created.first ? oldAck.future : newAck.future;
    await tester.pumpWidget(_host(child: _pairedMessages()));
    await tester.pumpAndSettle();
    final oldView = created.single;
    expect(payloadViews, contains(oldView));
    await tester.pumpWidget(
      _host(brightness: Brightness.dark, child: _pairedMessages()),
    );
    await tester.pumpAndSettle();
    final newView = created.last;
    expect(newView, isNot(oldView));
    // The old in-flight call must not prevent the new view receiving geometry.
    expect(payloadViews, contains(newView));
    oldAck.complete();
    await tester.pumpAndSettle();
    expect(_fallbackFills(tester).every((fill) => fill != null), isTrue);
    newAck.complete();
    await tester.pumpAndSettle();
    expect(_fallbackFills(tester), [null, null]);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
    expect(disposed, orderedEquals(created));
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'a layout change before the first ack keeps fills until current geometry is accepted',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final initialAck = Completer<void>();
      final resizedAck = Completer<void>();
      delayRegions = (_) =>
          payloads.length == 1 ? initialAck.future : resizedAck.future;
      await tester.pumpWidget(_host(child: _pairedMessages()));
      await tester.pumpAndSettle();
      final initialRegions = payloads.single['regions'];
      await tester.pumpWidget(_host(width: 320, child: _pairedMessages()));
      await tester.pumpAndSettle();
      expect(payloads, hasLength(1));
      initialAck.complete();
      await tester.pumpAndSettle();
      expect(payloads, hasLength(2));
      expect(payloads.last['regions'], isNot(equals(initialRegions)));
      expect(_fallbackFills(tester).every((fill) => fill != null), isTrue);
      final beforeReady = _regionRects(tester);
      resizedAck.complete();
      await tester.pumpAndSettle();
      expect(_fallbackFills(tester), [null, null]);
      expect(_regionRects(tester), beforeReady);
      expect(created, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    },
  );

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
    for (final id in created) {
      messenger.setMockMethodCallHandler(
        MethodChannel('maaso/frosted_input/$id'),
        null,
      );
    }
  });

  testWidgets('visible bubbles share one native view, outside text masks', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(_host(scroll: scroll));
    await tester.pumpAndSettle();
    expect(find.byType(UiKitView), findsOneWidget);
    expect(
      find.ancestor(
        of: find.byType(UiKitView),
        matching: find.byType(ShaderMask),
      ),
      findsNothing,
    );
    expect(
      find.ancestor(of: find.byType(UiKitView), matching: find.byType(Opacity)),
      findsNothing,
    );
    expect(find.byKey(AppGlassSurface.frostedLayerKey), findsNothing);
    final first = payloads.last;
    final initialRegions = first['regions'] as List;
    expect(initialRegions.length, inInclusiveRange(1, 8));
    expect(
      initialRegions.any((region) => (region as Map)['userTint'] == true),
      isTrue,
    );
    expect(
      initialRegions.any((region) => (region as Map)['userTint'] == false),
      isTrue,
    );
    expect(first['topFade'], 44);
    expect(first['bottomFade'], 24);
    final before = initialRegions.first;
    await tester.drag(find.byType(ListView), const Offset(0, -115));
    await tester.pumpAndSettle();
    expect(payloads.last['regions'], isNot(equals(initialRegions)));
    expect((payloads.last['regions'] as List).first, isNot(equals(before)));
    expect(created, hasLength(1));
    final sent = payloads.length;
    await tester.pump(const Duration(seconds: 2));
    expect(
      payloads,
      hasLength(sent),
      reason: 'stationary native regions do not poll',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
    expect(disposed, orderedEquals(created));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'conversation fade leaves the independent menu sampler and actions usable',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      String? copied;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      Widget page(double opacity) => _host(
        opacity: opacity,
        child: Center(child: MessageBubble(message: _message(0))),
      );
      await tester.pumpWidget(page(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text(_message(0).content));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('message-copy-action')));
      await tester.pump();
      expect(copied, _message(0).content);
      await tester.pumpWidget(page(.4));
      await tester.pumpAndSettle();
      expect(payloads.last['opacity'], .4);
      expect(created, hasLength(2));
      await tester.pumpWidget(page(0));
      await tester.pumpAndSettle();
      expect(payloads.last['opacity'], 0);
      await tester.pumpWidget(page(1));
      await tester.pumpAndSettle();
      expect(payloads.last['opacity'], 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'high contrast and non-iOS keep readable non-native message surfaces',
    (tester) async {
      for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
        debugDefaultTargetPlatformOverride = platform;
        await tester.pumpWidget(
          _host(highContrast: true, child: MessageBubble(message: _message(0))),
        );
        await tester.pumpAndSettle();
        expect(find.byType(UiKitView), findsNothing);
        final box = tester.widget<DecoratedBox>(
          find.byKey(AppGlassSurface.frostedLayerKey),
        );
        expect((box.decoration as BoxDecoration).color!.a, 1);
        expect(find.byType(BackdropFilter), findsNothing);
      }
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'rows entering the bottom fade band soften and become sharp inside',
    (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 260,
                height: 200,
                child: ChatHistoryEdge(
                  extent: 40,
                  bottomExtent: 40,
                  child: ListView(
                    controller: scroll,
                    addRepaintBoundaries: false,
                    children: const [
                      ChatHistoryEdgeItem(
                        extent: 40,
                        bottomExtent: 40,
                        child: SizedBox(height: 180, child: Text('first')),
                      ),
                      ChatHistoryEdgeItem(
                        extent: 40,
                        bottomExtent: 40,
                        child: SizedBox(height: 80, child: Text('next')),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.layers.whereType<ImageFilterLayer>(), hasLength(1));
      scroll.jumpTo(60);
      await tester.pump();
      expect(tester.layers.whereType<ImageFilterLayer>(), isEmpty);
      expect(find.byType(BackdropFilter), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

ChatMessage _message(int index) => ChatMessage(
  sessionId: 'self',
  senderId: index.isOdd ? 'user' : 'self',
  receiverId: 'user',
  isUserMessage: index.isOdd,
  content: 'Message $index with enough words to make a readable bubble.',
  timestamp: DateTime(2026, 9, 15, 10, index),
);

Widget _host({
  ScrollController? scroll,
  Widget? child,
  double opacity = 1,
  bool highContrast = false,
  Brightness brightness = Brightness.light,
  double width = 260,
}) => MaterialApp(
  theme: AppTheme.build(AppPalette.of(brightness, AppAccent.blue)),
  home: MediaQuery(
    data: MediaQueryData(highContrast: highContrast),
    child: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          height: 280,
          child: AppNativeFrostGroup(
            opacity: opacity,
            child:
                child ??
                ChatHistoryEdge(
                  extent: 44,
                  child: ListView.builder(
                    controller: scroll,
                    itemCount: 30,
                    scrollCacheExtent: const ScrollCacheExtent.pixels(0),
                    padding: const EdgeInsets.symmetric(vertical: 28),
                    itemBuilder: (_, index) =>
                        MessageBubble(message: _message(index)),
                  ),
                ),
          ),
        ),
      ),
    ),
  ),
);

Widget _pairedMessages() => SingleChildScrollView(
  child: Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      MessageBubble(message: _message(0)),
      MessageBubble(message: _message(1)),
    ],
  ),
);

List<Color?> _fallbackFills(WidgetTester tester) => tester
    .widgetList<DecoratedBox>(
      find.byKey(const ValueKey('native-message-fallback')),
    )
    .map((box) => (box.decoration as BoxDecoration).color)
    .toList();

List<Rect> _regionRects(WidgetTester tester) => find
    .byType(AppNativeFrostRegion)
    .evaluate()
    .map((element) => tester.getRect(find.byWidget(element.widget)))
    .toList();

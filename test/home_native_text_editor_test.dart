import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/widgets/ui/app_palette.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_glass_theme.dart';
import 'package:maaso/src/features/home/application/home_native_text_editing_bridge.dart';
import 'package:maaso/src/features/home/presentation/widgets/home_native_text_editor.dart';

Map<String, Object?> _nativeReply(MethodCall call) {
  final args = call.arguments as Map;
  final sequence = args['expectedSequence'] as int? ?? 0;
  return {
    'accepted': true,
    'sequence': sequence,
    if (call.method == 'sync') ...{
      'value': {
        'owner': args['owner'],
        'sequence': sequence,
        'kind': 'edit',
        'text': args['text'],
        'selectionBase': args['selectionBase'],
        'selectionExtent': args['selectionExtent'],
        'composingStart': args['composingStart'],
        'composingEnd': args['composingEnd'],
      },
      'focused': false,
    },
  };
}

void main() {
  testWidgets(
    'unsupported platform does not create a native or second Flutter editor',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        final controller = TextEditingController(text: 'preserve');
        final bridge = HomeNativeTextEditingBridge(
          owner: 'scope/1',
          controller: controller,
        );
        addTearDown(() {
          bridge.dispose();
          controller.dispose();
        });
        await tester.pumpWidget(
          MaterialApp(
            home: SizedBox(
              height: 180,
              child: HomeNativeTextEditor(bridge: bridge),
            ),
          ),
        );
        expect(find.byType(UiKitView), findsNothing);
        expect(find.byType(AndroidView), findsNothing);
        expect(find.byType(EditableText), findsNothing);
        expect(controller.text, 'preserve');
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets('iOS probe creates a scoped genuine-text view and disposes it', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      final calls = <MethodCall>[];
      final channels = <MethodChannel>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform_views,
        (call) async {
          calls.add(call);
          if (call.method == 'create') {
            final id = (call.arguments as Map)['id'];
            final channel = MethodChannel(
              '${HomeNativeTextEditingBridge.viewType}/$id',
            );
            channels.add(channel);
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
              channel,
              (call) async => _nativeReply(call),
            );
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform_views,
          null,
        ),
      );
      addTearDown(() {
        for (final channel in channels) {
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          );
        }
      });
      final controller = TextEditingController(text: '中文\n\ufffc');
      final bridge = HomeNativeTextEditingBridge(
        owner: 'scope/1',
        controller: controller,
        attachmentSnapshot: HomeNativeAttachmentSnapshot(
          token: 3,
          ids: ['photo-a'],
        ),
      );
      addTearDown(() {
        bridge.dispose();
        controller.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            height: 180,
            child: HomeNativeTextEditor(bridge: bridge),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final native = tester.widget<UiKitView>(find.byType(UiKitView));
      expect(native.viewType, HomeNativeTextEditingBridge.viewType);
      expect((native.creationParams as Map)['text'], controller.text);
      expect((native.creationParams as Map)['owner'], 'scope/1');
      expect((native.creationParams as Map)['attachments'], {
        'token': 3,
        'ids': ['photo-a'],
        'selectedId': null,
        'enabled': true,
      });
      expect(
        (native.creationParams as Map).containsKey('attachmentAvailable'),
        isFalse,
      );
      expect(bridge.synchronized, isTrue);
      expect(find.byType(EditableText), findsNothing);
      expect(find.byType(BackdropFilter), findsNothing);
      expect(calls.where((call) => call.method == 'create'), hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(calls.where((call) => call.method == 'dispose'), hasLength(1));
      expect(bridge.attached, isFalse);
      expect(controller.text, '中文\n\ufffc');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
    'theme and font updates retain the native view and canonical draft',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final controller = TextEditingController(text: '保留 draft 👩🏽‍💻');
      final bridge = HomeNativeTextEditingBridge(
        owner: 'scope/style',
        controller: controller,
      );
      final calls = <MethodCall>[];
      final nativeCalls = <MethodCall>[];
      final channels = <MethodChannel>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform_views,
        (call) async {
          calls.add(call);
          if (call.method == 'create') {
            final id = (call.arguments as Map)['id'];
            final channel = MethodChannel(
              '${HomeNativeTextEditingBridge.viewType}/$id',
            );
            channels.add(channel);
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
              channel,
              (nativeCall) async {
                nativeCalls.add(nativeCall);
                return _nativeReply(nativeCall);
              },
            );
          }
          return null;
        },
      );
      final lightGlass =
          MaasoGlassTheme.fromPalette(
            AppPalette.of(Brightness.light, AppAccent.blue),
          ).copyWith(
            foregroundPrimary: const Color(0xff193a40),
            accent: const Color(0xff156677),
          );
      final darkGlass =
          MaasoGlassTheme.fromPalette(
            AppPalette.of(Brightness.dark, AppAccent.blue),
          ).copyWith(
            foregroundPrimary: const Color(0xffe0eeee),
            accent: const Color(0xff225588),
          );
      Widget host({
        required bool dark,
        required double font,
        double scale = 1,
      }) => MaterialApp(
        theme: ThemeData(
          brightness: dark ? Brightness.dark : Brightness.light,
          extensions: [dark ? darkGlass : lightGlass],
        ),
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: SizedBox(
              height: 180,
              child: HomeNativeTextEditor(bridge: bridge, fontSize: font),
            ),
          ),
        ),
      );
      try {
        await tester.pumpWidget(host(dark: false, font: 16));
        await tester.pumpAndSettle();
        final nativeState = tester.state(find.byType(UiKitView));
        final initialParams =
            tester.widget<UiKitView>(find.byType(UiKitView)).creationParams
                as Map;
        expect(
          initialParams['textColorArgb'],
          lightGlass.foregroundPrimary.toARGB32(),
        );
        expect(initialParams['cursorColorArgb'], lightGlass.action.toARGB32());
        expect(
          initialParams['selectionColorArgb'],
          lightGlass.action.withValues(alpha: .28).toARGB32(),
        );
        final value = controller.value;
        await tester.pumpWidget(host(dark: true, font: 20, scale: 1.25));
        await tester.pumpAndSettle();
        expect(tester.state(find.byType(UiKitView)), same(nativeState));
        expect(calls.where((call) => call.method == 'create'), hasLength(1));
        final latestSync =
            nativeCalls.lastWhere((call) => call.method == 'sync').arguments
                as Map;
        expect(latestSync['dark'], isTrue);
        expect(latestSync['fontSize'], 25.0);
        expect(
          latestSync['textColorArgb'],
          darkGlass.foregroundPrimary.toARGB32(),
        );
        expect(latestSync['cursorColorArgb'], darkGlass.action.toARGB32());
        expect(
          latestSync['selectionColorArgb'],
          darkGlass.action.withValues(alpha: .28).toARGB32(),
        );
        expect(controller.value, value);
        expect(bridge.synchronized, isTrue);
      } finally {
        try {
          await tester.pumpWidget(const SizedBox.shrink());
        } finally {
          debugDefaultTargetPlatformOverride = null;
          bridge.dispose();
          controller.dispose();
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform_views,
            null,
          );
          for (final channel in channels) {
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
              channel,
              null,
            );
          }
        }
      }
    },
  );
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/voice_input_retirement.dart';
import 'package:maaso/src/core/widgets/chat_input_bar.dart';
import 'package:maaso/src/features/agent/application/companion/companion_browsing_context_service.dart';
import 'package:maaso/src/features/widgets_hub/application/game_voice_companion.dart';
import 'package:maaso/src/features/widgets_hub/presentation/game_voice_host.dart';
import 'package:maaso/src/features/widgets_hub/presentation/game_voice_observation_adapter.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';
import 'package:webview_flutter/webview_flutter.dart';
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

class _Controller extends Fake implements PlatformWebViewController {
  final callbacks = <JavaScriptChannelParams>[];
  int removes = 0;
  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams value) async {
    callbacks.add(value);
  }

  @override
  Future<void> removeJavaScriptChannel(String name) async {
    removes++;
  }

  @override
  Future<void> runJavaScript(String source) async {}
}

String _message(int revision, int score, {bool event = false}) => jsonEncode({
  'kind': event ? 'game.event' : 'game.state',
  'revision': revision,
  'state': {'score': score},
  if (event) 'event': {'type': 'round_end', 'summary': 'Game ended'},
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late GameVoiceCompanionService service;
  late CompanionBrowsingContextService context;
  var comments = 0;
  setUp(() async {
    await appServices.reset();
    voiceInputRetirementCoordinator.clearVoiceSessionIntent();
    comments = 0;
    context = appServices.put(CompanionBrowsingContextService());
    service = appServices.put(
      GameVoiceCompanionService(
        browsingContext: context,
        commentary:
            (observation, {required isCurrent, required onRevoked}) async {
              comments++;
              return true;
            },
        soundEnabled: () => true,
        commentInterval: Duration.zero,
      ),
    );
  });
  tearDown(() async {
    voiceInputRetirementCoordinator.clearVoiceSessionIntent();
    await appServices.reset();
  });

  Widget player(
    WebViewController controller,
    int generation,
    String id, {
    String? observation,
    VoidCallback? onTap,
    SurfaceRuntime? runtime,
  }) => MaterialApp(
    home: Scaffold(
      body: GameVoiceHost(
        key: const ValueKey('voice-host'),
        playerId: id,
        scopeKey: 'device-legacy',
        documentGeneration: generation,
        title: id,
        summary: 'Local game',
        ready: true,
        controller: controller,
        runtime: runtime,
        observation: observation,
        child: GestureDetector(
          key: const ValueKey('playable-game'),
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: const ColoredBox(color: Colors.white),
        ),
      ),
    ),
  );

  testWidgets('voice host adds no button and preserves game hit testing', (
    tester,
  ) async {
    final platform = _Controller();
    final controller = WebViewController.fromPlatform(platform);
    var taps = 0;
    await tester.pumpWidget(player(controller, 1, 'A', onTap: () => taps++));
    await tester.pumpAndSettle();
    expect(service.currentSession, isNotNull);
    expect(find.byType(ChatInputBar, skipOffstage: false), findsNothing);
    expect(find.byType(IconButton), findsNothing);
    await tester.tap(find.byKey(const ValueKey('playable-game')));
    expect(taps, 1);
    expect(comments, 0);
  });

  testWidgets(
    'controller A late message cannot change controller B or call a model',
    (tester) async {
      final a = _Controller(), b = _Controller();
      final first = WebViewController.fromPlatform(a);
      final next = WebViewController.fromPlatform(b);
      await tester.pumpWidget(player(first, 1, 'A'));
      await tester.pumpAndSettle();
      final old = a.callbacks.last;
      old.onMessageReceived(JavaScriptMessage(message: _message(1, 10)));
      expect(service.currentSession!.latest!.revision, 1);
      await tester.pumpWidget(player(next, 2, 'B'));
      await tester.pumpAndSettle();
      b.callbacks.last.onMessageReceived(
        JavaScriptMessage(message: _message(1, 20)),
      );
      old.onMessageReceived(
        JavaScriptMessage(message: _message(99, 999, event: true)),
      );
      expect(context.current!.title, 'B');
      expect(service.currentSession!.latest!.publicState['state'], {
        'score': 20,
      });
      expect(service.currentSession!.latest!.revision, 1);
      expect(comments, 0);
      expect(a.removes, greaterThanOrEqualTo(2));
    },
  );

  testWidgets('same controller reload fences the previous document callback', (
    tester,
  ) async {
    final native = _Controller();
    final controller = WebViewController.fromPlatform(native);
    await tester.pumpWidget(player(controller, 1, 'A'));
    await tester.pumpAndSettle();
    final old = native.callbacks.last;
    await tester.pumpWidget(player(controller, 2, 'A'));
    await tester.pumpAndSettle();
    final current = native.callbacks.last;
    current.onMessageReceived(JavaScriptMessage(message: _message(1, 30)));
    old.onMessageReceived(
      JavaScriptMessage(message: _message(100, 100, event: true)),
    );
    expect(service.currentSession!.latest!.publicState['state'], {'score': 30});
    expect(comments, 0);
    expect(native.callbacks, hasLength(2));
  });

  testWidgets(
    'background cancels the old binding and resume restores facts without commentary replay',
    (tester) async {
      final native = _Controller();
      final controller = WebViewController.fromPlatform(native);
      await tester.pumpWidget(
        player(controller, 1, 'A', observation: _message(1, 10, event: true)),
      );
      await tester.pumpAndSettle();
      final first = service.currentSession!;
      final old = native.callbacks.last;
      old.onMessageReceived(JavaScriptMessage(message: _message(2, 40)));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(first.isCurrent, isFalse);
      expect(context.current, isNull);
      old.onMessageReceived(
        JavaScriptMessage(message: _message(99, 99, event: true)),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(service.currentSession!.generation, greaterThan(first.generation));
      expect(service.currentSession!.latest!.publicState['state'], {
        'score': 40,
      });
      expect(service.currentSession!.latest!.eventKind, 'state');
      expect(comments, 0);
    },
  );
  testWidgets(
    'voice choice survives background and resets for a new document',
    (tester) async {
      final native = _Controller();
      final controller = WebViewController.fromPlatform(native);
      await tester.pumpWidget(player(controller, 1, 'A'));
      await tester.pumpAndSettle();
      expect(service.currentSession!.spokenRepliesEnabled, isTrue);
      service.setSpokenRepliesEnabled(false);
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(service.currentSession, isNull);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(service.currentSession!.spokenRepliesEnabled, isFalse);
      await tester.pumpWidget(player(controller, 2, 'A'));
      await tester.pumpAndSettle();
      expect(service.currentSession!.spokenRepliesEnabled, isTrue);
    },
  );
  for (final boundary in ['background', 'modal']) {
    testWidgets(
      'local DOM counter restarts after $boundary without retaining the old sequence',
      (tester) async {
        await tester.runAsync(GameVoiceObservationAdapter.loadObserverSource);
        final native = _Controller();
        final controller = WebViewController.fromPlatform(native);
        final runtime = SurfaceRuntime();
        addTearDown(runtime.closeLifecycle);
        await tester.pumpWidget(
          player(controller, 1, 'local', runtime: runtime),
        );
        await tester.pumpAndSettle();
        String snapshot(int revision, String text) => jsonEncode({
          'kind': 'companion.snapshot',
          'revision': revision,
          'state': {'version': 1, 'visibleText': text},
        });
        final old = native.callbacks.last;
        old.onMessageReceived(
          JavaScriptMessage(message: snapshot(40, 'Old visible state')),
        );
        final first = service.currentSession!;
        expect(first.replayEnvelopes.last['revision'], 40);
        final navigator = Navigator.of(
          tester.element(find.byType(GameVoiceHost)),
        );
        if (boundary == 'background') {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
        } else {
          unawaited(
            showModalBottomSheet<void>(
              context: tester.element(find.byType(GameVoiceHost)),
              builder: (_) => const SizedBox(height: 100),
            ),
          );
        }
        await tester.pumpAndSettle();
        expect(first.isCurrent, isFalse);
        if (boundary == 'background') {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        } else {
          navigator.pop();
        }
        await tester.pumpAndSettle();
        // Asset loading runs outside the fake clock; drain the serialized
        // detach/attach tail before simulating the new producer's message.
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pumpAndSettle();
        final reopened = service.currentSession!;
        expect(reopened.generation, greaterThan(first.generation));
        expect(native.callbacks, hasLength(2));
        expect(reopened.isCurrent, isTrue);
        native.callbacks.last.onMessageReceived(
          JavaScriptMessage(message: snapshot(1, 'New visible state')),
        );
        old.onMessageReceived(
          JavaScriptMessage(message: snapshot(100, 'Stale former producer')),
        );
        final current = reopened.replayEnvelopes.last;
        expect(current['revision'], 1);
        expect((current['state'] as Map)['visibleText'], 'New visible state');
      },
    );
  }
}

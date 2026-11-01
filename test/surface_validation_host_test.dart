import 'dart:convert';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/widgets/surface_web_view.dart';
import 'package:maaso/src/core/widgets/surface_worker_validation_host.dart';
import 'package:maaso/src/features/agent/application/surface/surface_manifest.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime_diagnostic.dart';
import 'package:maaso/src/features/agent/application/surface/surface_web_app_host.dart';
import 'package:maaso/src/features/agent/application/surface/surface_worker_health_gate.dart';
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

final List<String> _loadedDocuments = <String>[];
final List<String?> _loadedBaseUrls = <String?>[];
final Map<String, JavaScriptChannelParams> _channels =
    <String, JavaScriptChannelParams>{};
NavigationRequestCallback? _navigationRequest;
PageEventCallback? _pageStarted;
WebResourceErrorCallback? _webResourceError;
const String _lifecycleNonce = '00112233445566778899aabbccddeeff';
const String _forgedLifecycleNonce = 'ffeeddccbbaa99887766554433221100';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _loadedDocuments.clear();
    _loadedBaseUrls.clear();
    _channels.clear();
    _navigationRequest = null;
    _pageStarted = null;
    _webResourceError = null;
    WebViewPlatform.instance = _FakeWebViewPlatform();
    appServices.reset();
  });

  tearDown(appServices.reset);

  testWidgets(
    'webApp first frame uses an authenticated validation-only channel',
    (tester) async {
      final gate = appServices.put(SurfaceWorkerHealthGate());
      final runtime = appServices.put(SurfaceRuntime());
      gate.beginPresentation(runtime: runtime);
      await runtime.show(_webAppProject());
      final session = runtime.activeSession;
      final completion = gate.waitForFirstFrame(
        session: session,
        document: runtime.document.value!,
        timeout: const Duration(seconds: 5),
      );
      addTearDown(gate.cancelPresentation);

      await tester.pumpWidget(
        const MaterialApp(
          home: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              SurfaceWorkerValidationHost(),
              ColoredBox(color: Colors.white),
            ],
          ),
        ),
      );
      await tester.pump();

      expect(_channels.keys, <String>['SurfaceValidationLifecycle']);
      expect(_loadedDocuments, hasLength(1));
      expect(_loadedDocuments.single, contains('<button>Play</button>'));
      expect(_navigationRequest, isNotNull);
      final lifecycleChannel = _channels['SurfaceValidationLifecycle']!;

      lifecycleChannel.onMessageReceived(
        JavaScriptMessage(
          message: _readyMessage(session, _forgedLifecycleNonce),
        ),
      );
      await tester.pump();
      expect(gate.hasValidationClaim, isTrue);

      lifecycleChannel.onMessageReceived(
        JavaScriptMessage(message: _bootstrapMessage(session, _lifecycleNonce)),
      );
      lifecycleChannel.onMessageReceived(
        JavaScriptMessage(
          message: _readyMessage(session, _forgedLifecycleNonce),
        ),
      );
      await tester.pump();
      expect(gate.hasValidationClaim, isTrue);

      lifecycleChannel.onMessageReceived(
        JavaScriptMessage(message: _readyMessage(session, _lifecycleNonce)),
      );
      await tester.pump();
      await completion.timeout(const Duration(seconds: 1));

      expect(gate.hasValidationClaim, isFalse);
      expect(_loadedDocuments.last, contains('<body></body>'));
    },
  );

  testWidgets(
    'webApp startup fatal rejects the authenticated preflight claim',
    (tester) async {
      final gate = appServices.put(SurfaceWorkerHealthGate());
      final runtime = appServices.put(SurfaceRuntime());
      gate.beginPresentation(runtime: runtime);
      await runtime.show(_webAppProject());
      final session = runtime.activeSession;
      final completion = gate.waitForFirstFrame(
        session: session,
        document: runtime.document.value!,
        timeout: const Duration(seconds: 5),
      );
      final rejected = expectLater(
        completion,
        throwsA(
          isA<SurfaceWorkerFirstFrameException>().having(
            (error) => error.reason,
            'reason',
            SurfaceWorkerFatalReason.runtimeFailed,
          ),
        ),
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              SurfaceWorkerValidationHost(),
              ColoredBox(color: Colors.white),
            ],
          ),
        ),
      );
      await tester.pump();
      final channel = _channels['SurfaceValidationLifecycle']!;
      channel.onMessageReceived(
        JavaScriptMessage(message: _bootstrapMessage(session, _lifecycleNonce)),
      );
      channel.onMessageReceived(
        JavaScriptMessage(
          message: _fatalMessage(session, _forgedLifecycleNonce),
        ),
      );
      channel.onMessageReceived(
        JavaScriptMessage(message: _fatalMessage(session + 1, _lifecycleNonce)),
      );
      await tester.pump();
      expect(gate.hasValidationClaim, isTrue);
      channel.onMessageReceived(
        JavaScriptMessage(message: _fatalMessage(session, _lifecycleNonce)),
      );
      channel.onMessageReceived(
        JavaScriptMessage(message: _readyMessage(session, _lifecycleNonce)),
      );
      await tester.pump();
      await rejected;
      expect(gate.hasValidationClaim, isFalse);
      expect(_loadedDocuments.last, contains('<body></body>'));
    },
  );

  for (final mountedSource in [false, true]) {
    testWidgets(
      'runtime source metadata requires current session, nonce and hash (mounted: $mountedSource)',
      (tester) async {
        const source = 'missingContract();';
        final project = SurfaceProject.fromJson({
          ..._webAppProject().toJson(),
          'js': mountedSource ? '' : source,
          if (mountedSource)
            'html':
                '<button>Play</button><script src="data:text/javascript;charset=utf-8;base64,${base64Encode(utf8.encode(source))}"></script>',
        });
        final runtime = appServices.put(SurfaceRuntime());
        final gate = appServices.put(SurfaceWorkerHealthGate());
        gate.beginPresentation(runtime: runtime);
        await runtime.show(project);
        final session = runtime.activeSession;
        final completion = gate.waitForFirstFrame(
          session: session,
          document: runtime.document.value!,
          timeout: const Duration(seconds: 5),
        );
        final assertion = expectLater(
          completion,
          throwsA(
            isA<SurfaceWorkerFirstFrameException>().having(
              (failure) => failure.diagnostic?.sourceHash,
              'current source',
              SurfaceRuntimeDiagnostic.hashSource(source),
            ),
          ),
        );
        await tester.pumpWidget(
          const MaterialApp(
            home: Stack(
              fit: StackFit.expand,
              children: [
                SurfaceWorkerValidationHost(),
                ColoredBox(color: Colors.white),
              ],
            ),
          ),
        );
        await tester.pump();
        final channel = _channels['SurfaceValidationLifecycle']!;
        channel.onMessageReceived(
          JavaScriptMessage(
            message: _bootstrapMessage(session, _lifecycleNonce),
          ),
        );
        final diagnostic = SurfaceRuntimeDiagnostic(
          category: 'reference_error',
          sourceHash: SurfaceRuntimeDiagnostic.hashSource(source),
          line: 1,
          column: 1,
        ).toJson();
        Map<String, dynamic> payload(
          int reported,
          String nonce,
          Object facts,
        ) => {
          'version': 1,
          'session': reported,
          'kind': 'lifecycle',
          'status': 'fatal',
          'reason': 'runtime_failed',
          'nonce': nonce,
          'diagnostic': facts,
        };
        for (final rejected in [
          payload(session, _forgedLifecycleNonce, diagnostic),
          payload(session + 1, _lifecycleNonce, diagnostic),
          payload(session, _lifecycleNonce, {
            ...diagnostic,
            'sourceHash': '0' * 64,
          }),
          payload(session, _lifecycleNonce, {
            ...diagnostic,
            'message': 'private',
          }),
        ]) {
          channel.onMessageReceived(
            JavaScriptMessage(message: jsonEncode(rejected)),
          );
          await tester.pump();
          expect(gate.hasValidationClaim, isTrue);
        }
        channel.onMessageReceived(
          JavaScriptMessage(
            message: jsonEncode(payload(session, _lifecycleNonce, diagnostic)),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 6));
        await assertion;
        expect(gate.hasValidationClaim, isFalse);
      },
    );
  }

  for (final afterReady in <bool>[false, true]) {
    testWidgets(
      'visible webApp rejects current fatal (after ready: $afterReady)',
      (tester) async {
        final runtime = SurfaceRuntime()..initializeLifecycle();
        addTearDown(runtime.closeLifecycle);
        await runtime.show(_webAppProject());
        final reasons = <SurfaceWorkerFatalReason>[];
        var captures = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: SurfaceWebView(
              runtime: runtime,
              onWorkerFatal: reasons.add,
              onFirstFrameReady: (_) => captures++,
            ),
          ),
        );
        await tester.pump();
        final session = runtime.activeSession;
        final channel = _channels['SurfaceValidationLifecycle']!;
        channel.onMessageReceived(
          JavaScriptMessage(
            message: _bootstrapMessage(session, _lifecycleNonce),
          ),
        );
        channel.onMessageReceived(
          JavaScriptMessage(
            message: _fatalMessage(session, _forgedLifecycleNonce),
          ),
        );
        channel.onMessageReceived(
          JavaScriptMessage(
            message: _fatalMessage(session + 1, _lifecycleNonce),
          ),
        );
        expect(reasons, isEmpty);
        if (afterReady) {
          channel.onMessageReceived(
            JavaScriptMessage(message: _readyMessage(session, _lifecycleNonce)),
          );
        }
        channel.onMessageReceived(
          JavaScriptMessage(message: _fatalMessage(session, _lifecycleNonce)),
        );
        channel.onMessageReceived(
          JavaScriptMessage(message: _readyMessage(session, _lifecycleNonce)),
        );
        await tester.pump();
        expect(captures, 0);
        expect(reasons, <SurfaceWorkerFatalReason>[
          SurfaceWorkerFatalReason.runtimeFailed,
        ]);
        expect(runtime.isVisible.value, isFalse);
        expect(runtime.document.value, isNull);
        expect(_loadedDocuments.last, contains('<body></body>'));

        await runtime.show(_webAppProject());
        await tester.pump();
        final next = runtime.activeSession;
        expect(next, isNot(session));
        final nextChannel = _channels['SurfaceValidationLifecycle']!;
        nextChannel.onMessageReceived(
          JavaScriptMessage(message: _bootstrapMessage(next, _lifecycleNonce)),
        );
        nextChannel.onMessageReceived(
          JavaScriptMessage(message: _fatalMessage(session, _lifecycleNonce)),
        );
        nextChannel.onMessageReceived(
          JavaScriptMessage(message: _readyMessage(next, _lifecycleNonce)),
        );
        await tester.pump();
        expect(captures, 1);
        expect(reasons, hasLength(1));
        expect(
          find.byKey(SurfaceWebView.webAppFirstFrameCoverKey),
          findsNothing,
        );
      },
    );
  }

  testWidgets(
    'fatal callback replacement is not closed by the failed session',
    (tester) async {
      final runtime = SurfaceRuntime()..initializeLifecycle();
      addTearDown(runtime.closeLifecycle);
      await runtime.show(_webAppProject());
      final failedSession = runtime.activeSession;
      Future<void>? replacement;
      await tester.pumpWidget(
        MaterialApp(
          home: SurfaceWebView(
            runtime: runtime,
            onWorkerFatal: (_) => replacement = runtime.show(_webAppProject()),
          ),
        ),
      );
      await tester.pump();
      final channel = _channels['SurfaceValidationLifecycle']!;
      channel.onMessageReceived(
        JavaScriptMessage(
          message: _bootstrapMessage(failedSession, _lifecycleNonce),
        ),
      );
      channel.onMessageReceived(
        JavaScriptMessage(
          message: _fatalMessage(failedSession, _lifecycleNonce),
        ),
      );
      expect(replacement, isNotNull);
      await replacement;
      await tester.pump();
      final next = runtime.activeSession;
      expect(next, isNot(failedSession));
      expect(runtime.isVisible.value, isTrue);
      expect(runtime.document.value, contains('<button>Play</button>'));
      final nextChannel = _channels['SurfaceValidationLifecycle']!;
      nextChannel.onMessageReceived(
        JavaScriptMessage(message: _bootstrapMessage(next, _lifecycleNonce)),
      );
      nextChannel.onMessageReceived(
        JavaScriptMessage(
          message: _fatalMessage(failedSession, _lifecycleNonce),
        ),
      );
      nextChannel.onMessageReceived(
        JavaScriptMessage(message: _readyMessage(next, _lifecycleNonce)),
      );
      await tester.pump();
      expect(runtime.isVisible.value, isTrue);
      expect(find.byKey(SurfaceWebView.webAppFirstFrameCoverKey), findsNothing);
    },
  );

  testWidgets('webApp rejects a second bootstrap nonce without timing out', (
    tester,
  ) async {
    final gate = appServices.put(SurfaceWorkerHealthGate());
    final runtime = appServices.put(SurfaceRuntime());
    gate.beginPresentation(runtime: runtime);
    await runtime.show(_webAppProject());
    final session = runtime.activeSession;
    final completion = gate.waitForFirstFrame(
      session: session,
      document: runtime.document.value!,
      timeout: const Duration(seconds: 5),
    );
    final expectedFailure = expectLater(
      completion,
      throwsA(
        isA<SurfaceWorkerFirstFrameException>().having(
          (error) => error.reason,
          'reason',
          SurfaceWorkerFatalReason.securityBoundaryFailed,
        ),
      ),
    );
    addTearDown(gate.cancelPresentation);

    await tester.pumpWidget(
      const MaterialApp(
        home: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            SurfaceWorkerValidationHost(),
            ColoredBox(color: Colors.white),
          ],
        ),
      ),
    );
    await tester.pump();

    final lifecycleChannel = _channels['SurfaceValidationLifecycle']!;
    lifecycleChannel.onMessageReceived(
      JavaScriptMessage(message: _bootstrapMessage(session, _lifecycleNonce)),
    );
    lifecycleChannel.onMessageReceived(
      JavaScriptMessage(
        message: _bootstrapMessage(session, _forgedLifecycleNonce),
      ),
    );
    await tester.pump();

    await expectedFailure;
    expect(gate.hasValidationClaim, isFalse);
    expect(_loadedDocuments.last, contains('<body></body>'));
  });

  testWidgets('webApp rejects main-frame replacement without timing out', (
    tester,
  ) async {
    final gate = appServices.put(SurfaceWorkerHealthGate());
    final runtime = appServices.put(SurfaceRuntime());
    gate.beginPresentation(runtime: runtime);
    await runtime.show(_webAppProject());
    final session = runtime.activeSession;
    final completion = gate.waitForFirstFrame(
      session: session,
      document: runtime.document.value!,
      timeout: const Duration(seconds: 5),
    );
    final expectedFailure = expectLater(
      completion,
      throwsA(
        isA<SurfaceWorkerFirstFrameException>().having(
          (error) => error.reason,
          'reason',
          SurfaceWorkerFatalReason.securityBoundaryFailed,
        ),
      ),
    );
    addTearDown(gate.cancelPresentation);

    await tester.pumpWidget(
      const MaterialApp(
        home: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            SurfaceWorkerValidationHost(),
            ColoredBox(color: Colors.white),
          ],
        ),
      ),
    );
    await tester.pump();

    _channels['SurfaceValidationLifecycle']!.onMessageReceived(
      JavaScriptMessage(message: _bootstrapMessage(session, _lifecycleNonce)),
    );
    expect(
      await Future<NavigationDecision>.value(
        _navigationRequest!(
          const NavigationRequest(
            url: 'data:text/html,reload',
            isMainFrame: true,
          ),
        ),
      ),
      NavigationDecision.prevent,
    );
    await tester.pump();
    await expectedFailure;
    expect(gate.hasValidationClaim, isFalse);
  });

  testWidgets('webApp rejects a main-frame start that bypasses navigation', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final gate = appServices.put(SurfaceWorkerHealthGate());
    final runtime = appServices.put(SurfaceRuntime());
    gate.beginPresentation(runtime: runtime);
    await runtime.show(_webAppProject());
    final session = runtime.activeSession;
    final completion = gate.waitForFirstFrame(
      session: session,
      document: runtime.document.value!,
      timeout: const Duration(seconds: 5),
    );
    final expectedFailure = expectLater(
      completion,
      throwsA(
        isA<SurfaceWorkerFirstFrameException>().having(
          (error) => error.reason,
          'reason',
          SurfaceWorkerFatalReason.securityBoundaryFailed,
        ),
      ),
    );
    addTearDown(gate.cancelPresentation);

    await tester.pumpWidget(
      const MaterialApp(
        home: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            SurfaceWorkerValidationHost(),
            ColoredBox(color: Colors.white),
          ],
        ),
      ),
    );
    await tester.pump();

    _pageStarted!(_loadedBaseUrls.single!);
    _channels['SurfaceValidationLifecycle']!.onMessageReceived(
      JavaScriptMessage(message: _bootstrapMessage(session, _lifecycleNonce)),
    );
    // Models this Android path: a POST navigation can reach onPageStarted
    // without ever reaching shouldOverrideUrlLoading/onNavigationRequest.
    _pageStarted!('https://example.com/post-target');
    await tester.pump();

    await expectedFailure;
    expect(gate.hasValidationClaim, isFalse);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('visible game capture waits for an authenticated first frame', (
    tester,
  ) async {
    final runtime = SurfaceRuntime()..initializeLifecycle();
    addTearDown(runtime.closeLifecycle);
    await runtime.show(_webAppProject());
    var captures = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: SurfaceWebView(
          runtime: runtime,
          onFirstFrameReady: (_) => captures++,
        ),
      ),
    );
    await tester.pump();
    final channel = _channels['SurfaceValidationLifecycle']!;
    channel.onMessageReceived(
      JavaScriptMessage(
        message: _readyMessage(runtime.activeSession, _forgedLifecycleNonce),
      ),
    );
    await tester.pump();
    expect(captures, 0);
    channel.onMessageReceived(
      JavaScriptMessage(
        message: _bootstrapMessage(runtime.activeSession, _lifecycleNonce),
      ),
    );
    channel.onMessageReceived(
      JavaScriptMessage(
        message: _readyMessage(runtime.activeSession, _lifecycleNonce),
      ),
    );
    expect(
      captures,
      0,
      reason: 'The first visible frame must be painted first.',
    );
    await tester.pump();
    expect(captures, 1);
    channel.onMessageReceived(
      JavaScriptMessage(
        message: _readyMessage(runtime.activeSession, _lifecycleNonce),
      ),
    );
    await tester.pump();
    expect(captures, 1);
  });

  testWidgets('closed game does not capture a delayed ready notification', (
    tester,
  ) async {
    final runtime = SurfaceRuntime()..initializeLifecycle();
    addTearDown(runtime.closeLifecycle);
    await runtime.show(_workerProject());
    var captures = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: SurfaceWebView(
          runtime: runtime,
          onFirstFrameReady: (_) => captures++,
        ),
      ),
    );
    await tester.pump();
    final session = runtime.activeSession;
    _channels['SurfaceLifecycle']!.onMessageReceived(
      JavaScriptMessage(
        message:
            '{"version":1,"session":$session,"status":"ready","reason":"first_frame_ready"}',
      ),
    );
    await runtime.closeIfSession(session);
    await tester.pump();
    expect(captures, 0);
  });

  testWidgets('workerCanvas keeps its typed native lifecycle channel', (
    tester,
  ) async {
    final gate = appServices.put(SurfaceWorkerHealthGate());
    final runtime = appServices.put(SurfaceRuntime());
    gate.beginPresentation(runtime: runtime);
    await runtime.show(_workerProject());
    final session = runtime.activeSession;
    final completion = gate.waitForFirstFrame(
      session: session,
      document: runtime.document.value!,
      timeout: const Duration(seconds: 5),
    );
    addTearDown(gate.cancelPresentation);

    await tester.pumpWidget(
      const MaterialApp(
        home: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            SurfaceWorkerValidationHost(),
            ColoredBox(color: Colors.white),
          ],
        ),
      ),
    );
    await tester.pump();

    expect(_channels.keys, contains('SurfaceLifecycle'));
    _channels['SurfaceLifecycle']!.onMessageReceived(
      JavaScriptMessage(
        message:
            '{"version":1,"session":$session,"status":"ready",'
            '"reason":"first_frame_ready"}',
      ),
    );
    await tester.pump();
    await completion.timeout(const Duration(seconds: 1));

    expect(gate.hasValidationClaim, isFalse);
  });

  testWidgets(
    'visible webApp mirrors the inert validation facade and forwards events',
    (tester) async {
      final runtime = SurfaceRuntime()..initializeLifecycle();
      final fatalReasons = <SurfaceWorkerFatalReason>[];
      addTearDown(runtime.closeLifecycle);
      await runtime.show(_domProject());

      await tester.pumpWidget(
        MaterialApp(
          home: SurfaceWebView(
            runtime: runtime,
            onWorkerFatal: fatalReasons.add,
          ),
        ),
      );
      await tester.pump();

      expect(_channels.keys, contains('SurfaceEvent'));
      await runtime.show(_webAppProject());
      await tester.pump();

      expect(_channels.keys, <String>['SurfaceValidationLifecycle']);
      expect(
        find.byKey(SurfaceWebView.webAppFirstFrameCoverKey),
        findsOneWidget,
      );
      _channels['SurfaceValidationLifecycle']!.onMessageReceived(
        JavaScriptMessage(
          message: _readyMessage(runtime.activeSession, _forgedLifecycleNonce),
        ),
      );
      await tester.pump();
      expect(runtime.isVisible.value, isTrue);
      expect(
        find.byKey(SurfaceWebView.webAppFirstFrameCoverKey),
        findsOneWidget,
      );
      _channels['SurfaceValidationLifecycle']!.onMessageReceived(
        JavaScriptMessage(
          message: _bootstrapMessage(runtime.activeSession, _lifecycleNonce),
        ),
      );
      _channels['SurfaceValidationLifecycle']!.onMessageReceived(
        JavaScriptMessage(
          message: _readyMessage(runtime.activeSession, _lifecycleNonce),
        ),
      );
      await tester.pump();
      expect(find.byKey(SurfaceWebView.webAppFirstFrameCoverKey), findsNothing);
      expect(_loadedDocuments.last, contains('<button>Play</button>'));
      expect(_navigationRequest, isNotNull);
      final events = <dynamic>[];
      final eventSubscription = runtime.onEvent.listen(events.add);
      addTearDown(eventSubscription.cancel);

      final subframeEventDecision = await Future<NavigationDecision>.value(
        _navigationRequest!(
          NavigationRequest(
            url: _eventUrl(runtime.activeSession),
            isMainFrame: false,
          ),
        ),
      );
      expect(subframeEventDecision, NavigationDecision.prevent);
      await tester.pump();
      expect(events, isEmpty);

      final mainFrameEventDecision = await Future<NavigationDecision>.value(
        _navigationRequest!(
          NavigationRequest(
            url: _eventUrl(runtime.activeSession),
            isMainFrame: true,
          ),
        ),
      );
      expect(mainFrameEventDecision, NavigationDecision.prevent);
      await tester.pump();
      final event = events.single;
      expect(event.event, 'game.started');
      expect(event.data, <String, Object?>{'level': 1});

      expect(
        await Future<NavigationDecision>.value(
          _navigationRequest!(
            const NavigationRequest(
              url: 'https://example.com/library.js',
              isMainFrame: false,
            ),
          ),
        ),
        NavigationDecision.navigate,
      );
      expect(
        await Future<NavigationDecision>.value(
          _navigationRequest!(
            const NavigationRequest(
              url: 'https://example.com/replacement',
              isMainFrame: true,
            ),
          ),
        ),
        NavigationDecision.prevent,
      );
      expect(
        await Future<NavigationDecision>.value(
          _navigationRequest!(
            const NavigationRequest(
              url: 'data:text/html,reload',
              isMainFrame: true,
            ),
          ),
        ),
        NavigationDecision.prevent,
      );
      expect(
        await Future<NavigationDecision>.value(
          _navigationRequest!(
            const NavigationRequest(
              url: 'https://example.com/library.js',
              isMainFrame: false,
            ),
          ),
        ),
        NavigationDecision.prevent,
      );
      await tester.pump();
      expect(runtime.isVisible.value, isFalse);
      expect(runtime.document.value, isNull);
      expect(_loadedDocuments.last, contains('<body></body>'));
      expect(fatalReasons, <SurfaceWorkerFatalReason>[
        SurfaceWorkerFatalReason.securityBoundaryFailed,
      ]);
    },
  );

  testWidgets(
    'initial game state is buffered once until authenticated readiness',
    (tester) async {
      final runtime = SurfaceRuntime()..initializeLifecycle();
      addTearDown(runtime.closeLifecycle);
      await runtime.show(_webAppProject(declaresGameState: true));
      final events = <dynamic>[];
      final subscription = runtime.onEvent.listen(events.add);
      addTearDown(subscription.cancel);
      await tester.pumpWidget(
        MaterialApp(home: SurfaceWebView(runtime: runtime)),
      );
      await tester.pump();
      final session = runtime.activeSession;
      final channel = _channels['SurfaceValidationLifecycle']!;
      Future<void> emit(Map<String, Object?> data) async {
        expect(
          await Future<NavigationDecision>.value(
            _navigationRequest!(
              NavigationRequest(
                url: _eventUrl(session, event: 'game.state', data: data),
                isMainFrame: true,
              ),
            ),
          ),
          NavigationDecision.prevent,
        );
      }

      // The lifecycle bootstrap must belong to this actual document first.
      await emit({
        'revision': 0,
        'state': {'score': 0},
      });
      channel.onMessageReceived(
        JavaScriptMessage(message: _bootstrapMessage(session, _lifecycleNonce)),
      );
      for (final invalid in <Map<String, Object?>>[
        {
          'revision': -1,
          'state': {'score': 0},
        },
        {
          'revision': 0.5,
          'state': {'score': 0},
        },
        {'revision': 0, 'state': {}},
        {
          'revision': 0,
          'state': {'label': 'x' * 513},
        },
        {
          'revision': 0,
          'state': {'score': 0},
          'kind': 'game.state',
        },
      ]) {
        await emit(invalid);
      }
      await emit({
        'revision': 1,
        'state': {'phase': 'playing', 'score': 0},
      });
      await emit({
        'revision': 2,
        'state': {'phase': 'playing', 'score': 1},
      });
      await emit({
        'revision': 1,
        'state': {'score': -99},
      });
      channel.onMessageReceived(
        JavaScriptMessage(
          message: _readyMessage(session, _forgedLifecycleNonce),
        ),
      );
      await tester.pump();
      expect(events, isEmpty);
      channel.onMessageReceived(
        JavaScriptMessage(message: _readyMessage(session, _lifecycleNonce)),
      );
      await tester.pump();
      await tester.pump();
      expect(events, hasLength(1));
      expect(events.single.event, 'game.state');
      expect(events.single.data, {
        'revision': 2,
        'state': {'phase': 'playing', 'score': 1},
      });
      channel.onMessageReceived(
        JavaScriptMessage(message: _readyMessage(session, _lifecycleNonce)),
      );
      await tester.pump();
      expect(events, hasLength(1));
    },
  );

  for (final termination in ['fatal', 'close', 'supersede']) {
    testWidgets('initial game snapshot cannot leak after $termination', (
      tester,
    ) async {
      final runtime = SurfaceRuntime()..initializeLifecycle();
      addTearDown(runtime.closeLifecycle);
      await runtime.show(_webAppProject(declaresGameState: true));
      final events = <dynamic>[];
      final subscription = runtime.onEvent.listen(events.add);
      addTearDown(subscription.cancel);
      await tester.pumpWidget(
        MaterialApp(home: SurfaceWebView(runtime: runtime)),
      );
      await tester.pump();
      final first = runtime.activeSession;
      final channel = _channels['SurfaceValidationLifecycle']!;
      channel.onMessageReceived(
        JavaScriptMessage(message: _bootstrapMessage(first, _lifecycleNonce)),
      );
      await Future<NavigationDecision>.value(
        _navigationRequest!(
          NavigationRequest(
            url: _eventUrl(
              first,
              event: 'game.state',
              data: {
                'revision': 1,
                'state': {'owner': 'A'},
              },
            ),
            isMainFrame: true,
          ),
        ),
      );
      // Also reject a captured post-frame delivery after a valid ready receipt.
      channel.onMessageReceived(
        JavaScriptMessage(message: _readyMessage(first, _lifecycleNonce)),
      );
      if (termination == 'fatal') {
        channel.onMessageReceived(
          JavaScriptMessage(message: _fatalMessage(first, _lifecycleNonce)),
        );
      } else if (termination == 'close') {
        await runtime.close();
      } else {
        await runtime.show(_webAppProject(declaresGameState: true));
      }
      await tester.pump();
      expect(events, isEmpty);
      if (termination != 'supersede') {
        await runtime.show(_webAppProject(declaresGameState: true));
        await tester.pump();
      }
      final next = runtime.activeSession;
      expect(next, isNot(first));
      final nextChannel = _channels['SurfaceValidationLifecycle']!;
      nextChannel.onMessageReceived(
        JavaScriptMessage(message: _bootstrapMessage(next, _lifecycleNonce)),
      );
      await Future<NavigationDecision>.value(
        _navigationRequest!(
          NavigationRequest(
            url: _eventUrl(
              first,
              event: 'game.state',
              data: {
                'revision': 99,
                'state': {'owner': 'A'},
              },
            ),
            isMainFrame: true,
          ),
        ),
      );
      nextChannel.onMessageReceived(
        JavaScriptMessage(message: _readyMessage(next, _lifecycleNonce)),
      );
      await tester.pump();
      expect(events, isEmpty);
      await Future<NavigationDecision>.value(
        _navigationRequest!(
          NavigationRequest(
            url: _eventUrl(
              next,
              event: 'game.state',
              data: {
                'revision': 0,
                'state': {'owner': 'B'},
              },
            ),
            isMainFrame: true,
          ),
        ),
      );
      await tester.pump();
      expect(events, hasLength(1));
      expect(events.single.data['state'], {'owner': 'B'});
    });
  }

  testWidgets('visible webApp closes its session when first frame times out', (
    tester,
  ) async {
    final runtime = SurfaceRuntime()..initializeLifecycle();
    final fatalReasons = <SurfaceWorkerFatalReason>[];
    addTearDown(runtime.closeLifecycle);
    await runtime.show(_webAppProject());

    await tester.pumpWidget(
      MaterialApp(
        home: SurfaceWebView(runtime: runtime, onWorkerFatal: fatalReasons.add),
      ),
    );
    await tester.pump();

    expect(find.byKey(SurfaceWebView.webAppFirstFrameCoverKey), findsOneWidget);
    await tester.pump(const Duration(seconds: 16));
    await tester.pump();
    expect(runtime.isVisible.value, isFalse);
    expect(runtime.document.value, isNull);
    expect(_loadedDocuments.last, contains('<body></body>'));
    expect(fatalReasons, <SurfaceWorkerFatalReason>[
      SurfaceWorkerFatalReason.watchdogTimeout,
    ]);
  });

  testWidgets('visible webApp rejects a main-frame POST start after ready', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final runtime = SurfaceRuntime()..initializeLifecycle();
    final fatalReasons = <SurfaceWorkerFatalReason>[];
    addTearDown(runtime.closeLifecycle);
    await runtime.show(_webAppProject());

    await tester.pumpWidget(
      MaterialApp(
        home: SurfaceWebView(runtime: runtime, onWorkerFatal: fatalReasons.add),
      ),
    );
    await tester.pump();

    _pageStarted!(_loadedBaseUrls.single!);
    _channels['SurfaceValidationLifecycle']!.onMessageReceived(
      JavaScriptMessage(
        message: _bootstrapMessage(runtime.activeSession, _lifecycleNonce),
      ),
    );
    _channels['SurfaceValidationLifecycle']!.onMessageReceived(
      JavaScriptMessage(
        message: _readyMessage(runtime.activeSession, _lifecycleNonce),
      ),
    );
    await tester.pump();
    expect(find.byKey(SurfaceWebView.webAppFirstFrameCoverKey), findsNothing);

    _pageStarted!('https://example.com/post-target');
    await tester.pump();

    expect(runtime.isVisible.value, isFalse);
    expect(runtime.document.value, isNull);
    expect(_loadedDocuments.last, contains('<body></body>'));
    expect(fatalReasons, <SurfaceWorkerFatalReason>[
      SurfaceWorkerFatalReason.securityBoundaryFailed,
    ]);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('WK relabeled page starts do not poison the next webApp', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final runtime = SurfaceRuntime()..initializeLifecycle();
    final fatalReasons = <SurfaceWorkerFatalReason>[];
    addTearDown(runtime.closeLifecycle);
    await runtime.show(_webAppProject());

    await tester.pumpWidget(
      MaterialApp(
        home: SurfaceWebView(runtime: runtime, onWorkerFatal: fatalReasons.add),
      ),
    );
    await tester.pump();
    final firstDocumentUrl = _loadedBaseUrls.single!;
    await runtime.show(_webAppProject());
    await tester.pump();
    final secondDocumentUrl = _loadedBaseUrls.last!;
    expect(secondDocumentUrl, isNot(firstDocumentUrl));
    // webview_flutter_wkwebview reads webView.url after an async hop, so both
    // A and B didStart callbacks can carry B's URL. iOS relies on its complete
    // navigation-action delegate instead of treating these callbacks as IDs.
    _pageStarted!(secondDocumentUrl);
    _pageStarted!(secondDocumentUrl);
    _webResourceError!(
      WebResourceError(
        errorCode: -999,
        description: 'cancelled',
        isForMainFrame: true,
        url: firstDocumentUrl,
      ),
    );
    _channels['SurfaceValidationLifecycle']!.onMessageReceived(
      JavaScriptMessage(
        message: _bootstrapMessage(runtime.activeSession, _lifecycleNonce),
      ),
    );
    _channels['SurfaceValidationLifecycle']!.onMessageReceived(
      JavaScriptMessage(
        message: _readyMessage(runtime.activeSession, _lifecycleNonce),
      ),
    );
    await tester.pump();

    expect(fatalReasons, isEmpty);
    expect(find.byKey(SurfaceWebView.webAppFirstFrameCoverKey), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a known stale load error does not poison started webApp B', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final runtime = SurfaceRuntime()..initializeLifecycle();
    final fatalReasons = <SurfaceWorkerFatalReason>[];
    addTearDown(runtime.closeLifecycle);
    await runtime.show(_webAppProject());

    await tester.pumpWidget(
      MaterialApp(
        home: SurfaceWebView(runtime: runtime, onWorkerFatal: fatalReasons.add),
      ),
    );
    await tester.pump();
    final firstDocumentUrl = _loadedBaseUrls.single!;
    await runtime.show(_webAppProject());
    await tester.pump();
    final secondDocumentUrl = _loadedBaseUrls.last!;
    _pageStarted!(secondDocumentUrl);
    _webResourceError!(
      WebResourceError(
        errorCode: -1003,
        description: 'host not found',
        isForMainFrame: true,
        url: firstDocumentUrl,
      ),
    );
    _channels['SurfaceValidationLifecycle']!.onMessageReceived(
      JavaScriptMessage(
        message: _bootstrapMessage(runtime.activeSession, _lifecycleNonce),
      ),
    );
    _channels['SurfaceValidationLifecycle']!.onMessageReceived(
      JavaScriptMessage(
        message: _readyMessage(runtime.activeSession, _lifecycleNonce),
      ),
    );
    await tester.pump();

    expect(fatalReasons, isEmpty);
    expect(find.byKey(SurfaceWebView.webAppFirstFrameCoverKey), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('WK process termination fails a ready visible webApp', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final runtime = SurfaceRuntime()..initializeLifecycle();
    final fatalReasons = <SurfaceWorkerFatalReason>[];
    addTearDown(runtime.closeLifecycle);
    await runtime.show(_webAppProject());

    await tester.pumpWidget(
      MaterialApp(
        home: SurfaceWebView(runtime: runtime, onWorkerFatal: fatalReasons.add),
      ),
    );
    await tester.pump();
    _channels['SurfaceValidationLifecycle']!.onMessageReceived(
      JavaScriptMessage(
        message: _bootstrapMessage(runtime.activeSession, _lifecycleNonce),
      ),
    );
    _channels['SurfaceValidationLifecycle']!.onMessageReceived(
      JavaScriptMessage(
        message: _readyMessage(runtime.activeSession, _lifecycleNonce),
      ),
    );
    await tester.pump();
    expect(find.byKey(SurfaceWebView.webAppFirstFrameCoverKey), findsNothing);

    _webResourceError!(
      WebResourceError(
        errorCode: 2,
        description: 'web content process terminated',
        errorType: WebResourceErrorType.webContentProcessTerminated,
        isForMainFrame: true,
      ),
    );
    await tester.pump();

    expect(runtime.isVisible.value, isFalse);
    expect(runtime.document.value, isNull);
    expect(_loadedDocuments.last, contains('<body></body>'));
    expect(fatalReasons, <SurfaceWorkerFatalReason>[
      SurfaceWorkerFatalReason.webViewLoadFailed,
    ]);
    debugDefaultTargetPlatformOverride = null;
  });
}

SurfaceProject _webAppProject({bool declaresGameState = false}) =>
    SurfaceProject(
      id: 'surface_web_app_validation',
      title: 'Web App',
      kind: SurfaceKind.fullscreen,
      rendering: SurfaceRendering.webApp,
      html: '<main><button>Play</button></main>',
      css: '',
      js: '',
      transparent: false,
      placement: const SurfacePlacement(x: 0, y: 0, width: 1, height: 1),
      manifest: SurfaceManifest(
        events: <SurfaceEntry>[
          const SurfaceEntry('game.started', <String, String>{
            'level': 'number',
          }),
          if (declaresGameState)
            const SurfaceEntry('game.state', {
              'revision': 'number',
              'state': 'object',
            }),
        ],
      ),
      backend: const <String, Object?>{},
      revisions: const <SurfaceRevision>[],
      experienceType: SurfaceExperienceType.game,
    );

SurfaceProject _domProject() => SurfaceProject(
  id: 'surface_dom_before_web_app',
  title: 'DOM Utility',
  kind: SurfaceKind.card,
  rendering: SurfaceRendering.dom,
  html: '<main>Utility</main>',
  css: '',
  js: '',
  transparent: false,
  placement: const SurfacePlacement(x: 0, y: 0, width: 1, height: 1),
  manifest: const SurfaceManifest(),
  backend: const <String, Object?>{},
  revisions: const <SurfaceRevision>[],
);

SurfaceProject _workerProject() => SurfaceProject(
  id: 'surface_worker_validation',
  title: 'Worker Game',
  kind: SurfaceKind.fullscreen,
  rendering: SurfaceRendering.workerCanvas,
  html: '',
  css: '',
  js: '''
Game.define({
  init(){return {};},
  update(state){return state;},
  draw(){return [{type:'clear',color:'#000'}];},
  input(state){return state;}
});
''',
  transparent: false,
  placement: const SurfacePlacement(x: 0, y: 0, width: 1, height: 1),
  manifest: const SurfaceManifest(),
  backend: const <String, Object?>{},
  revisions: const <SurfaceRevision>[],
  experienceType: SurfaceExperienceType.game,
);

String _bootstrapMessage(int session, String nonce) =>
    jsonEncode(<String, Object?>{
      'version': 1,
      'session': session,
      'kind': 'bootstrap',
      'nonce': nonce,
    });

String _readyMessage(int session, String nonce) => jsonEncode(<String, Object?>{
  'version': 1,
  'session': session,
  'kind': 'lifecycle',
  'status': 'ready',
  'reason': 'first_frame_ready',
  'nonce': nonce,
});

String _fatalMessage(int session, String nonce) => jsonEncode(<String, Object?>{
  'version': 1,
  'session': session,
  'kind': 'lifecycle',
  'status': 'fatal',
  'reason': 'runtime_failed',
  'nonce': nonce,
});

String _eventUrl(
  int session, {
  String event = 'game.started',
  Map<String, Object?> data = const {'level': 1},
}) {
  final payload = base64UrlEncode(
    utf8.encode(
      jsonEncode(<String, Object?>{
        'version': 1,
        'session': session,
        'event': event,
        'data': data,
      }),
    ),
  ).replaceAll('=', '');
  return '${SurfaceWebAppNavigationMessage.navigationScheme}://event'
      '?payload=$payload';
}

class _FakeWebViewPlatform extends WebViewPlatform {
  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) => _FakePlatformWebViewController(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _FakePlatformWebViewWidget(params);

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => _FakePlatformNavigationDelegate(params);
}

class _FakePlatformWebViewController extends PlatformWebViewController {
  _FakePlatformWebViewController(super.params) : super.implementation();

  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams params) async {
    _channels[params.name] = params;
  }

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async {
    _loadedDocuments.add(html);
    _loadedBaseUrls.add(baseUrl);
  }

  @override
  Future<void> removeJavaScriptChannel(String javaScriptChannelName) async {
    _channels.remove(javaScriptChannelName);
  }

  @override
  Future<void> runJavaScript(String javaScript) async {}

  @override
  Future<void> setBackgroundColor(Color color) async {}

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> setOnConsoleMessage(
    void Function(JavaScriptConsoleMessage consoleMessage) onConsoleMessage,
  ) async {}

  @override
  Future<void> setPlatformNavigationDelegate(
    covariant PlatformNavigationDelegate handler,
  ) async {}
}

class _FakePlatformNavigationDelegate extends PlatformNavigationDelegate {
  _FakePlatformNavigationDelegate(super.params) : super.implementation();

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) async {
    _navigationRequest = onNavigationRequest;
  }

  @override
  Future<void> setOnPageStarted(PageEventCallback onPageStarted) async {
    _pageStarted = onPageStarted;
  }

  @override
  Future<void> setOnWebResourceError(
    WebResourceErrorCallback onWebResourceError,
  ) async {
    _webResourceError = onWebResourceError;
  }
}

class _FakePlatformWebViewWidget extends PlatformWebViewWidget {
  _FakePlatformWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

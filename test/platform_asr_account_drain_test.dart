import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/platform_asr_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('maaso/native_asr');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('account drain fences and waits for an admitted native start', () async {
    final startEntered = Completer<void>();
    final releaseStart = Completer<void>();
    var startCalls = 0;
    var cancelCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'start':
              startCalls++;
              if (!startEntered.isCompleted) startEntered.complete();
              await releaseStart.future;
              return true;
            case 'cancel':
              cancelCalls++;
              return null;
          }
          return null;
        });

    final service = await PlatformAsrService().init();
    addTearDown(service.onClose);
    final start = service.start();
    await startEntered.future;

    var drainCompleted = false;
    final drain = service.deactivateAccountAndDrain().whenComplete(
      () => drainCompleted = true,
    );
    await _flushAsyncWork();

    expect(drainCompleted, isFalse);
    expect(await service.start(), isFalse);
    expect(startCalls, 1);

    releaseStart.complete();
    expect(await start, isFalse, reason: 'the admitted A start became stale');
    await drain;

    expect(drainCompleted, isTrue);
    expect(
      cancelCalls,
      2,
      reason: 'pending starts require a pre-cancel and a final compensation',
    );
    expect(service.isListening.value, isFalse);
  });

  test(
    'failed strict cancel blocks activation, retries, and drops A callbacks in B',
    () async {
      final requestIds = <int>[];
      var cancelAttempts = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
              case 'start':
                final arguments = call.arguments as Map<Object?, Object?>;
                requestIds.add(arguments['requestId']! as int);
                return true;
              case 'cancel':
                cancelAttempts++;
                if (cancelAttempts == 1) {
                  throw PlatformException(code: 'cancel_failed');
                }
                return null;
            }
            return null;
          });

      final service = await PlatformAsrService().init();
      addTearDown(service.onClose);
      final results = <String>[];
      final resultsSub = service.finalResults.listen(results.add);
      addTearDown(resultsSub.cancel);

      expect(await service.start(), isTrue);
      final accountARequestId = requestIds.single;
      await _sendNativeCall(
        channel,
        const MethodCall('onPartial', 'legacy current request'),
      );
      expect(service.partialTranscript.value, 'legacy current request');

      await expectLater(
        service.deactivateAccountAndDrain(),
        throwsA(isA<PlatformException>()),
      );
      expect(service.activateAccount, throwsStateError);

      await service.deactivateAccountAndDrain();
      service.activateAccount();
      expect(await service.start(), isTrue);
      final accountBRequestId = requestIds.last;
      expect(accountBRequestId, isNot(accountARequestId));

      await _sendNativeCall(
        channel,
        MethodCall('onPartial', <String, Object>{
          'requestId': accountARequestId,
          'text': 'A partial secret',
        }),
      );
      await _sendNativeCall(
        channel,
        MethodCall('onFinal', <String, Object>{
          'requestId': accountARequestId,
          'text': 'A final secret',
        }),
      );
      await _sendNativeCall(
        channel,
        MethodCall('onError', <String, Object>{
          'requestId': accountARequestId,
          'error': 'A stale error',
        }),
      );
      await _sendNativeCall(
        channel,
        const MethodCall('onFinal', 'legacy A final secret'),
      );
      await _flushAsyncWork();

      expect(results, isEmpty);
      expect(service.partialTranscript.value, isNot(contains('A')));
      expect(service.error.value, isNot('A stale error'));

      await _sendNativeCall(
        channel,
        MethodCall('onPartial', <String, Object>{
          'requestId': accountBRequestId,
          'text': 'B partial',
        }),
      );
      await _sendNativeCall(
        channel,
        MethodCall('onFinal', <String, Object>{
          'requestId': accountBRequestId,
          'text': 'B final',
        }),
      );
      await _flushAsyncWork();

      expect(service.partialTranscript.value, 'B final');
      expect(results, <String>['B final']);
      expect(cancelAttempts, 2);
    },
  );

  test('drain waits for append tail and stale A PCM never reaches B', () async {
    final firstAppendEntered = Completer<void>();
    final releaseFirstAppend = Completer<void>();
    final bAppendObserved = Completer<void>();
    final appended = <List<int>>[];
    var stopCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'startExternal':
              return true;
            case 'appendPcm16':
              final bytes = List<int>.from(call.arguments as Uint8List);
              appended.add(bytes);
              if (bytes.single == 1) {
                if (!firstAppendEntered.isCompleted) {
                  firstAppendEntered.complete();
                }
                await releaseFirstAppend.future;
              }
              if (bytes.single == 4 && !bAppendObserved.isCompleted) {
                bAppendObserved.complete();
              }
              return null;
            case 'cancel':
              return null;
            case 'stop':
              stopCalls++;
              return null;
          }
          return null;
        });

    final service = await PlatformAsrService(
      supportsExternalAudioInputOverride: true,
    ).init();
    addTearDown(service.onClose);
    final accountA = StreamController<Uint8List>();
    final accountB = StreamController<Uint8List>();
    addTearDown(accountB.close);

    expect(
      await service.start(
        audioStream: accountA.stream,
        finishExternalAudioOnDone: true,
      ),
      isTrue,
    );
    accountA.add(Uint8List.fromList(const [1]));
    await firstAppendEntered.future;
    accountA.add(Uint8List.fromList(const [2]));
    await _flushAsyncWork();
    await accountA.close();
    await _flushAsyncWork();

    final drain = service.deactivateAccountAndDrain();
    await _flushAsyncWork();
    releaseFirstAppend.complete();
    await drain;

    service.activateAccount();
    expect(await service.start(audioStream: accountB.stream), isTrue);
    accountB.add(Uint8List.fromList(const [4]));
    await bAppendObserved.future;

    expect(appended, <List<int>>[
      <int>[1],
      <int>[4],
    ]);
    expect(stopCalls, 0, reason: 'A onDone must not stop B recognition');
    await service.cancel();
  });

  test(
    'an older false start completion cannot retire the latest request',
    () async {
      final starts = <int, Completer<bool>>{};
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) {
            if (call.method != 'start') return Future<Object?>.value();
            final arguments = call.arguments as Map<Object?, Object?>;
            final requestId = arguments['requestId']! as int;
            final completion = Completer<bool>();
            starts[requestId] = completion;
            return completion.future;
          });

      final service = await PlatformAsrService().init();
      addTearDown(service.onClose);
      final finalResults = <String>[];
      final resultsSub = service.finalResults.listen(finalResults.add);
      addTearDown(resultsSub.cancel);

      final olderStart = service.start();
      await _flushAsyncWork();
      final olderRequestId = starts.keys.single;
      final latestStart = service.start();
      await _flushAsyncWork();
      final latestRequestId = starts.keys.last;

      starts[latestRequestId]!.complete(true);
      expect(await latestStart, isTrue);
      expect(service.isListening.value, isTrue);

      starts[olderRequestId]!.complete(false);
      expect(await olderStart, isFalse);
      expect(
        service.isListening.value,
        isTrue,
        reason: 'a stale completion must not retire the latest native request',
      );

      await _sendNativeCall(
        channel,
        MethodCall('onFinal', <String, Object>{
          'requestId': latestRequestId,
          'text': 'latest result',
        }),
      );
      await _flushAsyncWork();

      expect(finalResults, <String>['latest result']);
    },
  );

  test('an older start exception cannot retire the latest request', () async {
    final starts = <int, Completer<bool>>{};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) {
          if (call.method != 'start') return Future<Object?>.value();
          final arguments = call.arguments as Map<Object?, Object?>;
          final requestId = arguments['requestId']! as int;
          final completion = Completer<bool>();
          starts[requestId] = completion;
          return completion.future;
        });

    final service = await PlatformAsrService().init();
    addTearDown(service.onClose);

    final olderStart = service.start();
    await _flushAsyncWork();
    final olderRequestId = starts.keys.single;
    final latestStart = service.start();
    await _flushAsyncWork();
    final latestRequestId = starts.keys.last;

    starts[latestRequestId]!.complete(true);
    expect(await latestStart, isTrue);

    starts[olderRequestId]!.completeError(
      PlatformException(code: 'stale_transport_failure'),
    );
    expect(await olderStart, isFalse);
    expect(service.isListening.value, isTrue);
    expect(service.error.value, isNull);

    await _sendNativeCall(
      channel,
      MethodCall('onPartial', <String, Object>{
        'requestId': latestRequestId,
        'text': 'latest partial',
      }),
    );
    expect(service.partialTranscript.value, 'latest partial');
  });

  test(
    'strict cancel brackets a pending start before replacement admission',
    () async {
      final firstStartEntered = Completer<void>();
      final releaseFirstStart = Completer<void>();
      final calls = <String>[];
      var startCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
              case 'start':
                final arguments = call.arguments as Map<Object?, Object?>;
                final requestId = arguments['requestId']! as int;
                startCalls++;
                calls.add('start:$requestId');
                if (startCalls == 1) {
                  firstStartEntered.complete();
                  await releaseFirstStart.future;
                }
                return true;
              case 'cancel':
                calls.add('cancel');
                return null;
            }
            return null;
          });

      final service = await PlatformAsrService().init();
      addTearDown(service.onClose);
      final firstStart = service.start();
      await firstStartEntered.future;

      final retirement = service.cancelAndDrain();
      await _flushAsyncWork();
      expect(calls, <String>['start:1', 'cancel']);

      final replacementStart = service.start();
      await _flushAsyncWork();
      expect(startCalls, 1, reason: 'replacement must wait for final cancel');

      releaseFirstStart.complete();
      expect(await firstStart, isFalse);
      await retirement;
      expect(calls, <String>['start:1', 'cancel', 'cancel']);

      expect(await replacementStart, isTrue);
      expect(calls, <String>['start:1', 'cancel', 'cancel', 'start:2']);
      await service.cancelAndDrain();
    },
  );

  test(
    'failed strict UI cancel fences starts until a successful retry',
    () async {
      var startCalls = 0;
      var cancelCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
              case 'start':
                startCalls++;
                return true;
              case 'cancel':
                cancelCalls++;
                if (cancelCalls == 1) {
                  throw PlatformException(code: 'transient_cancel_failure');
                }
                return null;
            }
            return null;
          });

      final service = await PlatformAsrService().init();
      addTearDown(service.onClose);
      expect(await service.start(), isTrue);

      await expectLater(
        service.cancelAndDrain(),
        throwsA(isA<PlatformException>()),
      );
      expect(await service.start(), isFalse);
      expect(startCalls, 1, reason: 'failed retirement must fail closed');

      await service.cancelAndDrain();
      expect(await service.start(), isTrue);
      expect(startCalls, 2);
      await service.cancelAndDrain();
    },
  );

  test('start failure cannot skip the final compensating cancel', () async {
    final stream = _RetryCancelStream();
    final lateStartEntered = Completer<void>();
    final releaseLateStart = Completer<void>();
    final calls = <String>[];
    var nativeStartCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'startExternal':
              nativeStartCalls++;
              calls.add('start:$nativeStartCalls');
              if (nativeStartCalls == 2) {
                lateStartEntered.complete();
                await releaseLateStart.future;
              }
              return true;
            case 'cancel':
              calls.add('cancel');
              return null;
          }
          return null;
        });

    final service = await PlatformAsrService(
      supportsExternalAudioInputOverride: true,
    ).init();
    addTearDown(service.onClose);
    expect(await service.start(audioStream: stream), isTrue);

    final failingStart = service.start();
    await stream.subscription.firstCancelEntered.future;
    final failingStartFailure = expectLater(
      failingStart,
      throwsA(same(stream.subscription.firstFailure)),
    );
    final lateStart = service.start(
      audioStream: const Stream<Uint8List>.empty(),
    );
    await lateStartEntered.future;

    final retirement = service.cancelAndDrain();
    await _flushAsyncWork();
    expect(calls.last, 'cancel');
    stream.subscription.releaseFirstCancel.complete();
    releaseLateStart.complete();

    await failingStartFailure;
    expect(await lateStart, isFalse);
    await expectLater(
      retirement,
      throwsA(same(stream.subscription.firstFailure)),
    );
    expect(
      calls.where((call) => call == 'cancel').length,
      2,
      reason: 'an admitted-start error must not skip the final cancel',
    );

    await service.cancelAndDrain();
    expect(
      await service.start(audioStream: const Stream<Uint8List>.empty()),
      isTrue,
    );
    await service.cancelAndDrain();
  });

  test('failed final compensation remains forced on retry', () async {
    final startEntered = Completer<void>();
    final releaseStart = Completer<void>();
    var startCalls = 0;
    var cancelCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'start':
              startCalls++;
              if (startCalls == 1) {
                startEntered.complete();
                await releaseStart.future;
              }
              return true;
            case 'cancel':
              cancelCalls++;
              if (cancelCalls == 2) {
                throw PlatformException(code: 'final_cancel_failed');
              }
              return null;
          }
          return null;
        });

    final service = await PlatformAsrService().init();
    addTearDown(service.onClose);
    final pendingStart = service.start();
    await startEntered.future;

    final retirement = service.cancelAndDrain();
    await _flushAsyncWork();
    expect(cancelCalls, 1);
    releaseStart.complete();
    expect(await pendingStart, isFalse);
    await expectLater(retirement, throwsA(isA<PlatformException>()));
    expect(cancelCalls, 2);
    expect(await service.start(), isFalse);
    expect(startCalls, 1);

    await service.cancelAndDrain();
    expect(cancelCalls, 3, reason: 'failed final cancel must remain retryable');
    expect(await service.start(), isTrue);
    await service.cancelAndDrain();
  });

  test('main and native hosts enforce the tagged account drain contract', () {
    final mainSource = File('lib/main.dart').readAsStringSync();
    final dartSource = File(
      'lib/src/core/services/platform_asr_service.dart',
    ).readAsStringSync();
    final androidSource = File(
      'android/app/src/main/kotlin/com/futurpals/maaso/MainActivity.kt',
    ).readAsStringSync();
    final iosSource = File('ios/Runner/AppDelegate.swift').readAsStringSync();

    expect(mainSource, contains("'native_asr'"));
    expect(mainSource, contains('?.deactivateAccountAndDrain()'));
    expect(mainSource, contains('PlatformAsrService>().activateAccount()'));
    expect(dartSource, contains("'requestId': requestId"));
    expect(dartSource, contains('callbackRequestId == _activeRequestId'));
    expect(dartSource, contains('_allowLegacyCallbacks = false'));
    expect(androidSource, contains('activeNativeAsrRequestId'));
    expect(androidSource, contains('pendingStartResult?.success(false)'));
    final androidCancelStart = androidSource.indexOf('"cancel" -> {');
    final androidCancelEnd = androidSource.indexOf(
      'else -> result.notImplemented()',
      androidCancelStart,
    );
    final androidCancel = androidSource.substring(
      androidCancelStart,
      androidCancelEnd,
    );
    expect(androidCancel, contains('pendingStartResult?.success(false)'));
    expect(androidCancel, contains('pendingStartResult = null'));
    expect(androidCancel, contains('pendingStartLocale = null'));
    expect(androidCancel, contains('pendingStartRequestId = null'));
    expect(
      androidCancel.indexOf('pendingStartResult?.success(false)'),
      lessThan(androidCancel.indexOf('speechRecognizer?.cancel()')),
    );
    expect(
      androidSource,
      contains('mapOf("requestId" to requestId, valueKey to value)'),
    );
    expect(iosSource, contains('activeRequestId: Int64?'));
    expect(iosSource, contains('latestStartRequestId: Int64?'));
    expect(
      iosSource,
      contains('guard self.latestStartRequestId == requestId else'),
    );
    expect(
      iosSource,
      contains('guard self.activeRequestId == requestId else { return }'),
    );
    expect(
      iosSource,
      contains('arguments: ["requestId": requestId, valueKey: value]'),
    );
  });
}

Future<void> _sendNativeCall(MethodChannel channel, MethodCall call) async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final data = channel.codec.encodeMethodCall(call);
  await messenger.handlePlatformMessage(channel.name, data, (_) {});
}

Future<void> _flushAsyncWork() => Future<void>.delayed(Duration.zero);

final class _RetryCancelStream extends Stream<Uint8List> {
  final _RetryCancelSubscription subscription = _RetryCancelSubscription();

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => subscription;
}

final class _RetryCancelSubscription implements StreamSubscription<Uint8List> {
  final Object firstFailure = StateError('external subscription cancel failed');
  final Completer<void> firstCancelEntered = Completer<void>();
  final Completer<void> releaseFirstCancel = Completer<void>();
  int cancelCalls = 0;

  @override
  Future<void> cancel() async {
    cancelCalls++;
    if (cancelCalls == 1) {
      firstCancelEntered.complete();
      await releaseFirstCancel.future;
      throw firstFailure;
    }
  }

  @override
  bool get isPaused => false;

  @override
  void onData(void Function(Uint8List data)? handleData) {}

  @override
  void onDone(void Function()? handleDone) {}

  @override
  void onError(Function? handleError) {}

  @override
  void pause([Future<void>? resumeSignal]) {}

  @override
  void resume() {}

  @override
  Future<E> asFuture<E>([E? futureValue]) => Future<E>.value(futureValue);
}

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_reply_coordinator.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_utterance.dart';
import 'package:maaso/src/features/agent/application/speech/speech_utterance_handle.dart';

ConversationUtteranceDraft _unit(
  String text, [
  ConversationAfter after = ConversationAfter.finish,
]) => ConversationUtteranceDraft(text: text, after: after);

void main() {
  testWidgets('each semantic bubble owns one complete speech handle', (
    tester,
  ) async {
    const texts = ['嗯', '今天先休息。明天再看也来得及。你不用现在决定。', '嘿嘿'];
    final spoken = <String>[];
    final shown = <String>[];
    final handles = <_ControlledSpeechHandle>[];
    final coordinator = ConversationReplyCoordinator(
      turnId: 'semantic-bubbles',
      publish: (_, mayPublish) async => mayPublish(),
      seal: () async {},
      onPublished: (unit) => shown.add(unit.text),
      speak: (unit) {
        spoken.add(unit.text);
        final handle = _ControlledSpeechHandle(unit.turnId, unit.utteranceId);
        handles.add(handle);
        return handle;
      },
      briefPause: Duration.zero,
      now: tester.binding.clock.now,
    );
    final delivery = coordinator.run([
      _unit(texts[0], ConversationAfter.continueReply),
      _unit(texts[1], ConversationAfter.continueReply),
      _unit(texts[2]),
    ]);
    for (var index = 0; index < texts.length; index++) {
      await tester.pump();
      expect(handles, hasLength(index + 1));
      expect(spoken.last, texts[index]);
      handles[index].start.complete(true);
      await tester.pump(const Duration(seconds: 2));
      expect(
        handles,
        hasLength(index + 1),
        reason:
            'Punctuation and elapsed time cannot create a second handle within this bubble.',
      );
      handles[index].end.complete(SpeechTerminal.completed);
    }
    await tester.pump();
    await delivery;
    expect(shown, texts);
    expect(spoken, texts);
    expect(handles.map((handle) => handle.utteranceId).toSet(), hasLength(3));
  });

  testWidgets(
    'yield waits for its complete audio and never starts a following bubble',
    (tester) async {
      final spoken = <String>[];
      final handle = _ControlledSpeechHandle('yield-bubble', 'yield-bubble:0');
      final coordinator = ConversationReplyCoordinator(
        turnId: 'yield-bubble',
        publish: (_, mayPublish) async => mayPublish(),
        seal: () async {},
        speak: (unit) {
          spoken.add(unit.text);
          return handle;
        },
        briefPause: Duration.zero,
        now: tester.binding.clock.now,
      );
      final delivery = coordinator.run([
        _unit('慢慢想。你想先聊哪一件？', ConversationAfter.yieldToUser),
        _unit('不应发布或播报的后续内容'),
      ]);
      await tester.pump();
      handle.start.complete(true);
      await tester.pump(const Duration(seconds: 10));
      expect(coordinator.state, ConversationDeliveryState.awaitingAudio);
      expect(spoken, ['慢慢想。你想先聊哪一件？']);
      handle.end.complete(SpeechTerminal.completed);
      await tester.pump();
      await delivery;
      expect(coordinator.delivered, hasLength(1));
      expect(spoken, ['慢慢想。你想先聊哪一件？']);
      expect(coordinator.state, ConversationDeliveryState.completed);
    },
  );

  testWidgets('publishes three independent units without an aggregate fourth', (
    tester,
  ) async {
    final persisted = <ConversationUtterance>[];
    final shown = <String>[];
    var seals = 0;
    final coordinator = ConversationReplyCoordinator(
      turnId: 'turn-a',
      publish: (unit, mayPublish) async {
        if (!mayPublish()) return false;
        persisted.add(unit);
        return true;
      },
      seal: () async => seals++,
      onPublished: (unit) => shown.add(unit.text),
      now: tester.binding.clock.now,
      readingTimePerCharacter: Duration.zero,
    );
    final delivery = coordinator.run([
      _unit('今天呀，嗯，我想想', ConversationAfter.continueReply),
      _unit('猪脚饭？', ConversationAfter.optional),
      _unit('或者看你想吃啥，我都行'),
    ]);
    await tester.pump();
    expect(shown, ['今天呀，嗯，我想想']);
    expect(coordinator.state, ConversationDeliveryState.briefGap);
    await tester.pump(const Duration(milliseconds: 400));
    expect(shown, ['今天呀，嗯，我想想', '猪脚饭？']);
    expect(coordinator.state, ConversationDeliveryState.optionalWindow);
    await tester.pump(const Duration(milliseconds: 1800));
    await delivery;
    expect(persisted.map((unit) => unit.sequence), [0, 1, 2]);
    expect(persisted.map((unit) => unit.utteranceId).toSet().length, 3);
    expect(persisted.every((unit) => unit.turnId == 'turn-a'), isTrue);
    expect(shown, ['今天呀，嗯，我想想', '猪脚饭？', '或者看你想吃啥，我都行']);
    expect(coordinator.deliveredText, shown.join('\n'));
    expect(coordinator.state, ConversationDeliveryState.completed);
    expect(seals, 1);
  });

  testWidgets('submit in the invitation gap cancels the unsent supplement', (
    tester,
  ) async {
    final shown = <String>[];
    final spoken = <String>[];
    final speech = _ControlledSpeechHandle('old-turn', 'old-turn:0');
    var stops = 0;
    var seals = 0;
    final coordinator = ConversationReplyCoordinator(
      turnId: 'old-turn',
      publish: (_, mayPublish) async => mayPublish(),
      seal: () async => seals++,
      cancelOutput: () async => stops++,
      onPublished: (unit) => shown.add(unit.text),
      speak: (unit) {
        spoken.add(unit.text);
        return speech;
      },
      now: tester.binding.clock.now,
      readingTimePerCharacter: Duration.zero,
    );
    final delivery = coordinator.run([
      _unit('猪脚饭？', ConversationAfter.optional),
      _unit('或者看你想吃啥，我都行'),
    ]);
    await tester.pump();
    speech.start.complete(true);
    speech.end.complete(SpeechTerminal.completed);
    await tester.pump();
    expect(coordinator.state, ConversationDeliveryState.optionalWindow);
    final cancellation = coordinator.cancel();
    expect(coordinator.mayPublish, isFalse);
    expect(stops, 1);
    await tester.pump();
    await cancellation;
    await delivery;
    await coordinator.cancel();
    await tester.pump(const Duration(seconds: 10));
    expect(shown, ['猪脚饭？']);
    expect(spoken, ['猪脚饭？']);
    expect(coordinator.deliveredText, '猪脚饭？');
    expect(coordinator.state, ConversationDeliveryState.cancelled);
    expect(seals, 1);
    expect(stops, 1);
  });

  testWidgets(
    'editing holds the optional unit, clearing within window releases',
    (tester) async {
      final shown = <String>[];
      final coordinator = ConversationReplyCoordinator(
        turnId: 'editing',
        publish: (_, mayPublish) async => mayPublish(),
        seal: () async {},
        onPublished: (unit) => shown.add(unit.text),
        now: tester.binding.clock.now,
        readingTimePerCharacter: Duration.zero,
      );
      final delivery = coordinator.run([
        _unit('猪脚饭？', ConversationAfter.optional),
        _unit('也可以吃点别的'),
      ]);
      await tester.pump();
      coordinator.updateDraft('昨天');
      await tester.pump(const Duration(seconds: 3));
      expect(shown, ['猪脚饭？']);
      coordinator.updateDraft('');
      await tester.pump();
      await delivery;
      expect(shown, ['猪脚饭？', '也可以吃点别的']);
    },
  );

  testWidgets('expired optional unit never returns when the draft is deleted', (
    tester,
  ) async {
    final shown = <String>[];
    final coordinator = ConversationReplyCoordinator(
      turnId: 'expired',
      publish: (_, mayPublish) async => mayPublish(),
      seal: () async {},
      onPublished: (unit) => shown.add(unit.text),
      now: tester.binding.clock.now,
      readingTimePerCharacter: Duration.zero,
    );
    final delivery = coordinator.run([
      _unit('猪脚饭？', ConversationAfter.optional),
      _unit('可选补充'),
    ]);
    await tester.pump();
    coordinator.updateDraft('昨天吃过');
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    await delivery;
    coordinator.updateDraft('');
    await tester.pump(const Duration(seconds: 6));
    expect(shown, ['猪脚饭？']);
    expect(coordinator.deliveredText, '猪脚饭？');
    expect(coordinator.state, ConversationDeliveryState.completed);
  });

  testWidgets(
    'seals after an in-flight transaction has observed cancellation',
    (tester) async {
      final releaseWrite = Completer<void>();
      final order = <String>[];
      final coordinator = ConversationReplyCoordinator(
        turnId: 'writing',
        publish: (_, mayPublish) async {
          order.add('write-start');
          await releaseWrite.future;
          order.add(mayPublish() ? 'write-commit' : 'write-rollback');
          return mayPublish();
        },
        seal: () async => order.add('seal'),
        onPublished: (_) => order.add('shown'),
        now: tester.binding.clock.now,
      );
      final delivery = coordinator.run([_unit('旧回答')]);
      await tester.pump();
      final cancellation = coordinator.cancel();
      await tester.pump();
      expect(order, ['write-start']);
      releaseWrite.complete();
      await tester.pump();
      await cancellation;
      await delivery;
      order.add('new-user');
      expect(order, ['write-start', 'write-rollback', 'seal', 'new-user']);
      expect(coordinator.delivered, isEmpty);
    },
  );

  testWidgets(
    'a committed unit survives takeover but its late UI event does not',
    (tester) async {
      final finishWrite = Completer<bool>();
      final shown = <String>[];
      final coordinator = ConversationReplyCoordinator(
        turnId: 'committed',
        publish: (_, _) => finishWrite.future,
        seal: () async {},
        onPublished: (unit) => shown.add(unit.text),
        now: tester.binding.clock.now,
      );
      final delivery = coordinator.run([_unit('已提交数据库的完整句子')]);
      final cancellation = coordinator.cancel();
      finishWrite.complete(true);
      await tester.pump();
      await cancellation;
      await delivery;
      expect(shown, isEmpty);
      expect(coordinator.deliveredText, '已提交数据库的完整句子');
    },
  );

  testWidgets('ownership invalidation rejects a late unit', (tester) async {
    var ownsTurn = true;
    final shown = <String>[];
    final coordinator = ConversationReplyCoordinator(
      turnId: 'ownership',
      publish: (_, mayPublish) async => mayPublish(),
      seal: () async {},
      isCurrent: () => ownsTurn,
      onPublished: (unit) => shown.add(unit.text),
      now: tester.binding.clock.now,
      readingTimePerCharacter: Duration.zero,
    );
    final delivery = coordinator.run([
      _unit('第一句', ConversationAfter.continueReply),
      _unit('第二句'),
    ]);
    await tester.pump();
    ownsTurn = false;
    await tester.pump(const Duration(seconds: 1));
    await delivery;
    expect(shown, ['第一句']);
    expect(coordinator.state, ConversationDeliveryState.cancelled);
  });

  testWidgets('yield ends output without generating a silent follow-up', (
    tester,
  ) async {
    final shown = <String>[];
    final coordinator = ConversationReplyCoordinator(
      turnId: 'yield',
      publish: (_, mayPublish) async => mayPublish(),
      seal: () async {},
      onPublished: (unit) => shown.add(unit.text),
      now: tester.binding.clock.now,
    );
    await coordinator.run([_unit('你觉得呢？', ConversationAfter.yieldToUser)]);
    await tester.pump(const Duration(seconds: 20));
    expect(shown, ['你觉得呢？']);
    expect(coordinator.state, ConversationDeliveryState.completed);
  });

  testWidgets('identical text in distinct units is not deduplicated', (
    tester,
  ) async {
    final shown = <ConversationUtterance>[];
    final coordinator = ConversationReplyCoordinator(
      turnId: 'same-text',
      publish: (_, mayPublish) async => mayPublish(),
      seal: () async {},
      onPublished: shown.add,
      now: tester.binding.clock.now,
      readingTimePerCharacter: Duration.zero,
    );
    final delivery = coordinator.run([
      _unit('嗯', ConversationAfter.continueReply),
      _unit('嗯'),
    ]);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await delivery;
    expect(shown.map((unit) => unit.text), ['嗯', '嗯']);
    expect(shown.map((unit) => unit.utteranceId).toSet().length, 2);
  });

  testWidgets('database failure stops later units and still seals the turn', (
    tester,
  ) async {
    var attempts = 0;
    var seals = 0;
    final coordinator = ConversationReplyCoordinator(
      turnId: 'failed',
      publish: (_, _) async {
        attempts++;
        throw StateError('disk-unavailable');
      },
      seal: () async => seals++,
      now: tester.binding.clock.now,
    );
    await expectLater(
      coordinator.run([
        _unit('第一句', ConversationAfter.continueReply),
        _unit('第二句'),
      ]),
      throwsStateError,
    );
    expect(attempts, 1);
    expect(seals, 1);
    expect(coordinator.state, ConversationDeliveryState.failed);
    expect(coordinator.delivered, isEmpty);
  });

  testWidgets('a denied publication cancels delivery without a visible unit', (
    tester,
  ) async {
    final shown = <String>[];
    final coordinator = ConversationReplyCoordinator(
      turnId: 'already-sealed',
      publish: (_, _) async => false,
      seal: () async {},
      onPublished: (unit) => shown.add(unit.text),
      now: tester.binding.clock.now,
    );
    await coordinator.run([_unit('迟到的句子')]);
    expect(shown, isEmpty);
    expect(coordinator.state, ConversationDeliveryState.cancelled);
  });

  testWidgets('a completed coordinator cannot stop a later turn audio', (
    tester,
  ) async {
    var stops = 0;
    final coordinator = ConversationReplyCoordinator(
      turnId: 'finished',
      publish: (_, mayPublish) async => mayPublish(),
      seal: () async {},
      cancelOutput: () async => stops++,
      now: tester.binding.clock.now,
    );
    await coordinator.run([_unit('这一轮已经说完')]);
    expect(coordinator.mayPublish, isFalse);
    await coordinator.cancel();
    expect(stops, 0);
    expect(coordinator.state, ConversationDeliveryState.completed);
  });

  testWidgets('synchronous cancellation inside publish still seals after it', (
    tester,
  ) async {
    final finishWrite = Completer<void>();
    final order = <String>[];
    late final ConversationReplyCoordinator coordinator;
    Future<void>? cancellation;
    coordinator = ConversationReplyCoordinator(
      turnId: 'reentrant',
      publish: (_, mayPublish) async {
        order.add('write-start');
        cancellation = coordinator.cancel();
        await finishWrite.future;
        order.add('write-return');
        return mayPublish();
      },
      seal: () async => order.add('seal'),
      now: tester.binding.clock.now,
    );
    final delivery = coordinator.run([_unit('被取消的句子')]);
    await tester.pump();
    final orderBeforeWriteFinished = List<String>.of(order);
    finishWrite.complete();
    await tester.pump();
    await delivery;
    await cancellation;
    expect(orderBeforeWriteFinished, ['write-start']);
    expect(order, ['write-start', 'write-return', 'seal']);
  });

  testWidgets('caller mutation cannot replace or append pending drafts', (
    tester,
  ) async {
    final shown = <String>[];
    final drafts = [
      _unit('第一句', ConversationAfter.continueReply),
      _unit('原本的第二句'),
    ];
    final coordinator = ConversationReplyCoordinator(
      turnId: 'snapshot',
      publish: (_, mayPublish) async => mayPublish(),
      seal: () async {},
      onPublished: (unit) => shown.add(unit.text),
      now: tester.binding.clock.now,
      readingTimePerCharacter: Duration.zero,
    );
    final delivery = coordinator.run(drafts);
    await tester.pump();
    drafts[1] = _unit('外部追加', ConversationAfter.continueReply);
    drafts.add(_unit('第三句'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await delivery;
    expect(shown, ['第一句', '原本的第二句']);
  });

  testWidgets('only playback terminal opens the gap, including the last unit', (
    tester,
  ) async {
    final order = <String>[];
    final handles = <_ControlledSpeechHandle>[];
    var seals = 0;
    final coordinator = ConversationReplyCoordinator(
      turnId: 'spoken',
      publish: (unit, mayPublish) async {
        order.add('commit:${unit.sequence}');
        return mayPublish();
      },
      onPublished: (unit) => order.add('show:${unit.sequence}'),
      speak: (unit) {
        order.add('speak:${unit.sequence}');
        final handle = _ControlledSpeechHandle(unit.turnId, unit.utteranceId);
        handles.add(handle);
        return handle;
      },
      onSpeechStarted: (unit) => order.add('started:${unit.sequence}'),
      onSpeechFinished: (unit, terminal) =>
          order.add('${terminal.name}:${unit.sequence}'),
      onTextDelivery: (_) => fail('completed speech must not use text clock'),
      seal: () async => seals++,
      now: tester.binding.clock.now,
      readingTimePerCharacter: const Duration(milliseconds: 100),
    );
    final delivery = coordinator.run([
      _unit('AAAA', ConversationAfter.continueReply),
      _unit('BBBB'),
    ]);
    await tester.pump();
    expect(order, ['commit:0', 'show:0', 'speak:0']);
    expect(coordinator.state, ConversationDeliveryState.awaitingAudio);
    handles.first.start.complete(true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(handles, hasLength(1));
    expect(seals, 0);

    handles.first.end.complete(SpeechTerminal.completed);
    await tester.pump();
    expect(coordinator.state, ConversationDeliveryState.briefGap);
    await tester.pump(const Duration(milliseconds: 399));
    expect(handles, hasLength(1));
    await tester.pump(const Duration(milliseconds: 1));
    expect(handles, hasLength(2));
    expect(seals, 0);
    handles.last.start.complete(true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(seals, 0);
    expect(coordinator.state, ConversationDeliveryState.awaitingAudio);
    handles.last.end.complete(SpeechTerminal.completed);
    await tester.pump();
    await delivery;
    expect(order, [
      'commit:0',
      'show:0',
      'speak:0',
      'started:0',
      'completed:0',
      'commit:1',
      'show:1',
      'speak:1',
      'started:1',
      'completed:1',
    ]);
    expect(seals, 1);
    expect(coordinator.state, ConversationDeliveryState.completed);
  });

  for (final terminal in [SpeechTerminal.failed, SpeechTerminal.timedOut]) {
    testWidgets('$terminal degrades the remaining audio chain to reading', (
      tester,
    ) async {
      final shown = <String>[];
      final textCues = <String>[];
      final ended = <SpeechTerminal>[];
      var speechCalls = 0;
      final handle = _ControlledSpeechHandle('fallback', 'fallback:0');
      final coordinator = ConversationReplyCoordinator(
        turnId: 'fallback',
        publish: (_, mayPublish) async => mayPublish(),
        seal: () async {},
        speak: (_) {
          speechCalls++;
          return handle;
        },
        onPublished: (unit) => shown.add(unit.text),
        onTextDelivery: (unit) => textCues.add(unit.text),
        onSpeechFinished: (_, value) => ended.add(value),
        now: tester.binding.clock.now,
        readingTimePerCharacter: const Duration(milliseconds: 100),
      );
      final delivery = coordinator.run([
        _unit('AAAA', ConversationAfter.continueReply),
        _unit('B', ConversationAfter.optional),
        _unit('C'),
      ]);
      await tester.pump();
      handle.start.complete(true);
      await tester.pump();
      handle.end.complete(terminal);
      await tester.pump();
      expect(textCues, ['AAAA']);
      expect(ended, [terminal]);
      await tester.pump(const Duration(milliseconds: 799));
      expect(shown, ['AAAA']);
      await tester.pump(const Duration(milliseconds: 1));
      expect(shown, ['AAAA', 'B']);
      expect(speechCalls, 1);
      await tester.pump(const Duration(milliseconds: 1899));
      expect(shown, hasLength(2));
      await tester.pump(const Duration(milliseconds: 1));
      await delivery;
      expect(shown, ['AAAA', 'B', 'C']);
      expect(textCues, shown);
      expect(speechCalls, 1);
      expect(coordinator.state, ConversationDeliveryState.completed);
    });
  }

  testWidgets('a cancelled audio terminal cancels rather than reading ahead', (
    tester,
  ) async {
    final shown = <String>[];
    final textCues = <String>[];
    final handle = _ControlledSpeechHandle(
      'cancelled-audio',
      'cancelled-audio:0',
    );
    final coordinator = ConversationReplyCoordinator(
      turnId: handle.turnId,
      publish: (_, mayPublish) async => mayPublish(),
      seal: () async {},
      speak: (_) => handle,
      onPublished: (unit) => shown.add(unit.text),
      onTextDelivery: (unit) => textCues.add(unit.text),
      now: tester.binding.clock.now,
    );
    final delivery = coordinator.run([
      _unit('first', ConversationAfter.continueReply),
      _unit('must not appear'),
    ]);
    await tester.pump();
    handle.end.complete(SpeechTerminal.cancelled);
    await tester.pump();
    await delivery;
    await tester.pump(const Duration(seconds: 10));
    expect(shown, ['first']);
    expect(textCues, isEmpty);
    expect(coordinator.state, ConversationDeliveryState.cancelled);
  });

  testWidgets('cancellation does not wait for a stuck audio terminal', (
    tester,
  ) async {
    final handle = _ControlledSpeechHandle('stuck-audio', 'stuck-audio:0');
    final newerHandle = _ControlledSpeechHandle('new-turn', 'new-turn:0');
    final starts = <String>[];
    final terminals = <SpeechTerminal>[];
    var outputStops = 0;
    var seals = 0;
    final coordinator = ConversationReplyCoordinator(
      turnId: handle.turnId,
      publish: (_, mayPublish) async => mayPublish(),
      seal: () async => seals++,
      speak: (_) => handle,
      cancelOutput: () async => outputStops++,
      onSpeechStarted: (unit) => starts.add(unit.utteranceId),
      onSpeechFinished: (_, terminal) => terminals.add(terminal),
      now: tester.binding.clock.now,
    );
    final delivery = coordinator.run([_unit('first')]);
    await tester.pump();
    final cancellation = coordinator.cancel();
    expect(handle.cancellations, 1);
    expect(outputStops, 1);
    await tester.pump();
    await cancellation;
    await delivery;
    expect(handle.end.isCompleted, isFalse);
    expect(seals, 1);
    expect(terminals, [SpeechTerminal.cancelled]);
    handle.start.complete(true);
    handle.end.complete(SpeechTerminal.completed);
    await tester.pump();
    await coordinator.cancel();
    expect(starts, isEmpty);
    expect(terminals, [SpeechTerminal.cancelled]);
    expect(handle.cancellations, 1);
    expect(newerHandle.cancellations, 0);
    expect(coordinator.state, ConversationDeliveryState.cancelled);
  });

  testWidgets('reentrant cancellation while speak returns stops that handle', (
    tester,
  ) async {
    final handle = _ControlledSpeechHandle(
      'reentrant-speech',
      'reentrant-speech:0',
    );
    late ConversationReplyCoordinator coordinator;
    Future<void>? cancellation;
    coordinator = ConversationReplyCoordinator(
      turnId: handle.turnId,
      publish: (_, mayPublish) async => mayPublish(),
      seal: () async {},
      speak: (_) {
        cancellation = coordinator.cancel();
        return handle;
      },
      onSpeechStarted: (_) => fail('cancelled speech cannot start a cue'),
      onTextDelivery: (_) => fail('cancelled speech cannot fall back to text'),
      now: tester.binding.clock.now,
    );
    final delivery = coordinator.run([_unit('first')]);
    await tester.pump();
    await cancellation;
    await delivery;
    expect(handle.cancellations, 1);
    expect(coordinator.state, ConversationDeliveryState.cancelled);
  });

  testWidgets('an invitation window starts after audio, not publication', (
    tester,
  ) async {
    final handles = <_ControlledSpeechHandle>[];
    final shown = <String>[];
    final coordinator = ConversationReplyCoordinator(
      turnId: 'audio-invite',
      publish: (_, mayPublish) async => mayPublish(),
      seal: () async {},
      onPublished: (unit) => shown.add(unit.text),
      speak: (unit) {
        final handle = _ControlledSpeechHandle(unit.turnId, unit.utteranceId);
        handles.add(handle);
        return handle;
      },
      now: tester.binding.clock.now,
    );
    final delivery = coordinator.run([
      _unit('question?', ConversationAfter.optional),
      _unit('supplement'),
    ]);
    await tester.pump();
    coordinator.updateDraft('my draft');
    await tester.pump(const Duration(seconds: 10));
    expect(shown, ['question?']);
    handles.first.end.complete(SpeechTerminal.completed);
    await tester.pump();
    expect(coordinator.state, ConversationDeliveryState.optionalWindow);
    await tester.pump(const Duration(milliseconds: 5999));
    expect(shown, ['question?']);
    coordinator.updateDraft('');
    await tester.pump();
    expect(shown, ['question?', 'supplement']);
    handles.last.end.complete(SpeechTerminal.completed);
    await tester.pump();
    await delivery;
  });

  testWidgets('a start arriving after terminal cannot reactivate a cue', (
    tester,
  ) async {
    final handle = _ControlledSpeechHandle('late-start', 'late-start:0');
    var starts = 0;
    final coordinator = ConversationReplyCoordinator(
      turnId: handle.turnId,
      publish: (_, mayPublish) async => mayPublish(),
      seal: () async {},
      speak: (_) => handle,
      onSpeechStarted: (_) => starts++,
      now: tester.binding.clock.now,
    );
    final delivery = coordinator.run([_unit('finished')]);
    await tester.pump();
    handle.end.complete(SpeechTerminal.completed);
    await tester.pump();
    await delivery;
    handle.start.complete(true);
    await tester.pump();
    expect(starts, 0);
  });

  testWidgets('wrong-owner speech is neither observed nor cancelled', (
    tester,
  ) async {
    final foreign = _ControlledSpeechHandle('other-turn', 'other-turn:0');
    final textCues = <String>[];
    final coordinator = ConversationReplyCoordinator(
      turnId: 'owned-turn',
      publish: (_, mayPublish) async => mayPublish(),
      seal: () async {},
      speak: (_) => foreign,
      onSpeechStarted: (_) => fail('foreign speech cannot drive this unit'),
      onTextDelivery: (unit) => textCues.add(unit.text),
      now: tester.binding.clock.now,
    );
    await coordinator.run([_unit('text only')]);
    foreign.start.complete(true);
    await tester.pump();
    expect(foreign.cancellations, 0);
    expect(textCues, ['text only']);
  });

  testWidgets('a denied DB publication cannot start speech or a text cue', (
    tester,
  ) async {
    final coordinator = ConversationReplyCoordinator(
      turnId: 'not-published',
      publish: (_, _) async => false,
      seal: () async {},
      speak: (_) => throw StateError('must not be called'),
      onTextDelivery: (_) => fail('not published'),
      now: tester.binding.clock.now,
    );
    await coordinator.run([_unit('not delivered')]);
    expect(coordinator.state, ConversationDeliveryState.cancelled);
  });

  test('stream publishes one unit while waiting for generation', () async {
    final drafts = StreamController<ConversationUtteranceDraft>(sync: true);
    final shown = <String>[];
    final coordinator = ConversationReplyCoordinator(
      turnId: 'incremental',
      publish: (_, mayPublish) async => mayPublish(),
      seal: () async {},
      onPublished: (unit) => shown.add(unit.text),
      briefPause: Duration.zero,
      readingTimePerCharacter: Duration.zero,
    );
    var completed = false;
    final delivery = coordinator.runStream(drafts.stream)
      ..then((_) => completed = true);

    drafts.add(_unit('第一句', ConversationAfter.continueReply));
    await Future<void>.delayed(Duration.zero);
    expect(shown, ['第一句']);
    expect(completed, isFalse);

    drafts.add(_unit('第二句'));
    await Future<void>.delayed(Duration.zero);
    await delivery;
    expect(shown, ['第一句', '第二句']);
    expect(coordinator.state, ConversationDeliveryState.completed);
    await drafts.close();
  });

  test('stream optional expiry suppresses its buffered terminal', () async {
    final drafts = StreamController<ConversationUtteranceDraft>(sync: true);
    final shown = <String>[];
    final coordinator = ConversationReplyCoordinator(
      turnId: 'incremental-optional',
      publish: (_, mayPublish) async => mayPublish(),
      seal: () async {},
      onPublished: (unit) => shown.add(unit.text),
      invitationPause: const Duration(milliseconds: 1),
      optionalWindowLimit: const Duration(milliseconds: 5),
      readingTimePerCharacter: Duration.zero,
    );
    final delivery = coordinator.runStream(drafts.stream);
    coordinator.updateDraft('用户正在输入');
    drafts.add(_unit('要不吃面？', ConversationAfter.optional));
    drafts.add(_unit('我还知道一家店。'));
    await Future<void>.delayed(Duration.zero);
    expect(shown, ['要不吃面？']);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await delivery;

    expect(shown, ['要不吃面？']);
    expect(coordinator.state, ConversationDeliveryState.completed);
    await drafts.close();
  });

  test('stream cancellation fences a late unit while model stalls', () async {
    final drafts = StreamController<ConversationUtteranceDraft>(sync: true);
    final shown = <String>[];
    final coordinator = ConversationReplyCoordinator(
      turnId: 'incremental-cancel',
      publish: (_, mayPublish) async => mayPublish(),
      seal: () async {},
      onPublished: (unit) => shown.add(unit.text),
      briefPause: Duration.zero,
      readingTimePerCharacter: Duration.zero,
    );
    final delivery = coordinator.runStream(drafts.stream);
    drafts.add(_unit('已经提交', ConversationAfter.continueReply));
    await Future<void>.delayed(Duration.zero);
    await coordinator.cancel();
    await delivery;
    drafts.add(_unit('迟到的句子'));
    await Future<void>.delayed(Duration.zero);

    expect(shown, ['已经提交']);
    expect(coordinator.state, ConversationDeliveryState.cancelled);
    await drafts.close();
  });

  test('stream error retains its published safe prefix', () async {
    final drafts = StreamController<ConversationUtteranceDraft>(sync: true);
    final shown = <String>[];
    final coordinator = ConversationReplyCoordinator(
      turnId: 'incremental-error',
      publish: (_, mayPublish) async => mayPublish(),
      seal: () async {},
      onPublished: (unit) => shown.add(unit.text),
      briefPause: Duration.zero,
      readingTimePerCharacter: Duration.zero,
    );
    final delivery = coordinator.runStream(drafts.stream);
    drafts.add(_unit('安全前缀', ConversationAfter.continueReply));
    await Future<void>.delayed(Duration.zero);
    final expectation = expectLater(delivery, throwsStateError);
    drafts.addError(StateError('bad suffix'));
    await Future<void>.delayed(Duration.zero);
    await expectation;

    expect(shown, ['安全前缀']);
    expect(coordinator.state, ConversationDeliveryState.failed);
    await drafts.close();
  });
}

class _ControlledSpeechHandle implements SpeechUtteranceHandle {
  _ControlledSpeechHandle(this.turnId, this.utteranceId);
  @override
  final String turnId;
  @override
  final String utteranceId;
  final start = Completer<bool>();
  final end = Completer<SpeechTerminal>();
  int cancellations = 0;
  @override
  Future<bool> get started => start.future;
  @override
  Future<SpeechTerminal> get terminal => end.future;
  @override
  Future<void> cancel([String reason = 'cancelled']) async {
    cancellations++;
  }

  @override
  Future<void> get drained async {}
}

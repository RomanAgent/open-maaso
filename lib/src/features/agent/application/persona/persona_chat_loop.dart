import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'companion_interest_context.dart';
import 'companion_device_context.dart';
import 'conversation_style_context.dart';
import 'conversation_style_prompt.dart';
import 'conversation_delivery_policy.dart';

import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/features/agent/application/body/avatar_body_intent_policy.dart';
import 'package:maaso/src/features/agent/application/maaso_tts_plugin.dart';
import 'package:maaso/src/features/agent/application/orchestration/agent_turn_orchestrator.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/agent/data/bridge/tts_engine.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/hosted_llm_failure.dart';
import 'package:maaso/src/core/services/lip_sync_viseme_analyzer.dart';
import 'package:maaso/src/core/services/streaming_audio_sink.dart';
import 'package:maaso/src/core/services/turn_trace.dart';
import 'package:maaso/src/core/utils/text_filters.dart';

typedef PersonaProfileProvider = AgentProfile Function();
typedef PersonaLocaleProvider = AppLocale Function();
typedef PersonaSpeechSessionOpener = Future<PersonaSpeechSession?> Function();
typedef PersonaFallbackSpeak = void Function(String text);
typedef PersonaControlEventHandler =
    FutureOr<void> Function(LLMStreamEvent event);
typedef PersonaReplyDeltaHandler = void Function(String delta);
typedef PersonaTaskHandoffHandler = void Function(PersonaTaskHandoff handoff);

class PersonaTaskHandoff {
  const PersonaTaskHandoff({
    required this.kind,
    required this.query,
    this.confidence = 0.0,
  });

  final String kind;
  final String query;
  final double confidence;

  static PersonaTaskHandoff? tryParse(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final kind = decoded['kind'];
      final query = decoded['query'];
      if (kind is! String || kind.trim().isEmpty) return null;
      if (query is! String || query.trim().isEmpty) return null;
      final confidenceValue = decoded['confidence'];
      final confidence = switch (confidenceValue) {
        num value => value.toDouble(),
        String value => double.tryParse(value) ?? 0.0,
        _ => 0.0,
      };
      return PersonaTaskHandoff(
        kind: kind.trim(),
        query: query.trim(),
        confidence: confidence.clamp(0.0, 1.0).toDouble(),
      );
    } catch (_) {
      return null;
    }
  }
}

abstract class PersonaSpeechSession {
  Future<void> sendText(String text, {required bool flush});
  Future<void> finish();
  Future<void> cancel(String reason);
}

/// Optional retirement boundary for transports whose cancellation has a fast
/// local stop and slower network/resource cleanup.
abstract interface class PersonaSpeechSessionDrain {
  Future<void> get drained;
}

class PersonaChatLoop {
  PersonaChatLoop({
    required this.agentId,
    required this.llmClient,
    required this.profileProvider,
    required this.localeProvider,
    required this.openSpeechSession,
    required this.fallbackSpeak,
    this.onControlEvent,
    this.onReplyDelta,
    this.onTaskHandoff,
    this.requireSpeechSession = false,
  });

  final String agentId;
  final LLMClient llmClient;
  final PersonaProfileProvider profileProvider;
  final PersonaLocaleProvider localeProvider;
  final PersonaSpeechSessionOpener openSpeechSession;
  final PersonaFallbackSpeak fallbackSpeak;
  final PersonaControlEventHandler? onControlEvent;
  final PersonaReplyDeltaHandler? onReplyDelta;
  final PersonaTaskHandoffHandler? onTaskHandoff;
  final bool requireSpeechSession;

  final Completer<void> _cancelledSignal = Completer<void>();
  final Completer<void> _runDone = Completer<void>();
  _PersonaSpeechOutbox? _speechOutbox;
  _PersonaBodyIntentGate? _bodyIntents;
  StreamIterator<LLMStreamEvent>? _events;
  Future<void>? _streamCancellation;
  Future<void>? _cancelFuture;
  Future<void>? _controlWork;
  bool _hasRun = false;

  bool get isCancelled => _cancelledSignal.isCompleted;

  /// Fences this turn immediately, even when the model has stopped sending.
  /// A late speech opener is cancelled when it resolves, without holding up
  /// the next user turn. Account retirement can additionally await [drained].
  Future<void> cancel([String reason = 'cancelled']) {
    if (_cancelFuture != null) return _cancelFuture!;
    if (_runDone.isCompleted) return Future<void>.value();
    if (!_cancelledSignal.isCompleted) _cancelledSignal.complete();
    _bodyIntents?.close();
    _requestStreamCancellation();
    return _cancelFuture =
        _speechOutbox?.cancel(reason) ?? Future<void>.value();
  }

  Future<void> get drained async {
    if (_hasRun) await _runDone.future;
    await Future.wait<void>([
      ?_streamCancellation,
      if (_speechOutbox != null) _speechOutbox!.drained,
      ?_controlWork,
      if (_bodyIntents != null) _bodyIntents!._tail,
    ]);
  }

  void _requestStreamCancellation() {
    final events = _events;
    if (events == null || _streamCancellation != null) return;
    final cancellation = _streamCancellation = Future<void>.sync(events.cancel);
    unawaited(
      cancellation.catchError((Object error) {
        TurnTrace.event(
          'mode3.persona_stream.cancel_failed',
          details: 'agent=$agentId error=$error',
        );
      }),
    );
  }

  Future<bool> _waitUnlessCancelled(Future<void> work) => Future.any<bool>([
    work.then((_) => true),
    _cancelledSignal.future.then((_) => false),
  ]);

  static const recentHistoryMaxMessages = 8;
  static const recentHistoryMessageMaxCharacters = 1200;
  static const recentHistoryMaxCharacters = 6000;

  Future<ExecutionResult?> run({
    required String userText,
    String? currentUserText,
    List<Message> history = const [],
    required AgentTurnPlan turnPlan,
    ConversationStyleSnapshot? conversationStyle,
    bool Function()? shouldCancel,
  }) async {
    if (_hasRun) throw StateError('persona_loop_already_started');
    _hasRun = true;
    final locale = localeProvider();
    bool isCancelled() =>
        _cancelledSignal.isCompleted ||
        conversationStyle?.isCurrent == false ||
        shouldCancel?.call() == true;
    ExecutionResult cancelledResult() => ExecutionResult.success(
      AgentPromptCatalog.text('runtime.cancelled', locale: locale),
    );
    if (isCancelled()) {
      _runDone.complete();
      return ExecutionResult.success(
        AgentPromptCatalog.text('runtime.cancelled', locale: locale),
      );
    }

    TurnTrace.event('agent.path', details: 'mode3.persona_chat_loop');
    final sw = TurnTrace.stopwatch(
      'mode3.persona_chat_loop',
      details: 'agent=$agentId chars=${userText.length}',
    );
    final openedSpeechSession = Future<PersonaSpeechSession?>.sync(
      openSpeechSession,
    );
    final speechOutbox = _speechOutbox = _PersonaSpeechOutbox(
      agentId: agentId,
      sessionFuture: openedSpeechSession,
      fallbackSpeak: fallbackSpeak,
    );
    final reply = StringBuffer();
    final textGate = ConversationTextGate(conversationStyle);
    final segments = conversationStyle?.isPrivate == true
        ? ConversationSegmentBuffer(textGate)
        : null;
    final bodyIntents = _bodyIntents = _PersonaBodyIntentGate(
      onControlEvent: onControlEvent,
      shouldCancel: isCancelled,
    );
    final sidebandStripper = _PersonaSidebandStripper(
      onHandoff: (handoff) {
        if (!isCancelled()) onTaskHandoff?.call(handoff);
      },
      onControlEvent: bodyIntents.add,
    );
    final speech = PersonaSpeechBuffer(
      onFlush: (chunk, {required first}) {
        if (isCancelled() || !textGate.allows(chunk)) return;
        TurnTrace.event(
          first ? 'tts.stream.flush_first' : 'tts.stream.flush_next',
          details: 'agent=$agentId chars=${chunk.length}',
        );
        speechOutbox.send(chunk, first: first);
      },
    );

    try {
      if (requireSpeechSession) {
        final requiredSession = await Future.any<PersonaSpeechSession?>([
          openedSpeechSession,
          _cancelledSignal.future.then((_) => null),
        ]);
        if (isCancelled()) {
          await cancel();
          return cancelledResult();
        }
        if (requiredSession == null) {
          TurnTrace.done(
            'mode3.persona_chat_loop',
            sw,
            details: 'streaming_speech_unavailable=true',
          );
          return null;
        }
      }
      if (isCancelled()) {
        await cancel();
        return cancelledResult();
      }
      final events = _events = StreamIterator(
        llmClient.streamChatEvents(
          buildMessages(
            userText: userText,
            turnPlan: turnPlan,
            profile: profileProvider(),
            locale: locale,
            currentUserText: currentUserText,
            history: history,
            conversationStyle: conversationStyle,
          ),
          timeout: llmClient.defaultTimeout,
        ),
      );
      while (!isCancelled() &&
          await Future.any<bool>([
            events.moveNext(),
            _cancelledSignal.future.then((_) => false),
          ])) {
        if (isCancelled()) {
          bodyIntents.close();
          TurnTrace.done(
            'mode3.persona_chat_loop',
            sw,
            details: 'cancelled=true',
          );
          await cancel();
          return cancelledResult();
        }
        final event = events.current;
        if (event.event == 'error') {
          throw StateError(event.data);
        }
        if (!event.isReplyDelta) {
          TurnTrace.event(
            'mode3.persona_sse_event',
            details: 'agent=$agentId event=${event.event}',
          );
          if (event.event == 'task.handoff') {
            final payload = event.jsonPayload;
            if (payload != null) {
              final handoff = PersonaTaskHandoff.tryParse(jsonEncode(payload));
              if (handoff != null) {
                TurnTrace.event(
                  'mode3.persona_task_handoff',
                  details:
                      'agent=$agentId kind=${handoff.kind} confidence=${handoff.confidence.toStringAsFixed(2)}',
                );
                onTaskHandoff?.call(handoff);
              }
            }
          }
          if (event.event == 'body.intent') {
            bodyIntents.add(event);
          } else {
            final controlWork = _controlWork = Future<void>.sync(
              () => onControlEvent?.call(event),
            );
            await _waitUnlessCancelled(controlWork);
          }
          continue;
        }
        final chunk = stripEmojiFromDelta(
          sidebandStripper.add(event.deltaText),
        );
        if (isCancelled()) {
          bodyIntents.close();
          await cancel();
          return cancelledResult();
        }
        if (chunk.isEmpty) continue;
        for (final unit in segments?.add(chunk) ?? [chunk]) {
          if (isCancelled()) break;
          reply.write(unit);
          onReplyDelta?.call(unit);
          speech.add(unit);
        }
        if (segments?.blocked == true) break;
      }
      sidebandStripper.finish();
      for (final unit in segments?.finish() ?? const <String>[]) {
        if (isCancelled()) break;
        reply.write(unit);
        onReplyDelta?.call(unit);
        speech.add(unit);
      }
      if (isCancelled()) {
        bodyIntents.close();
        await cancel();
        return cancelledResult();
      }
      speech.finish();
      await _waitUnlessCancelled(speechOutbox.finish());
      if (!isCancelled()) await _waitUnlessCancelled(bodyIntents.finish());
      if (isCancelled()) {
        await cancel();
        return cancelledResult();
      }
      final text = stripEmoji(reply.toString()).trim();
      TurnTrace.done(
        'mode3.persona_chat_loop',
        sw,
        details: 'reply_chars=${text.length}',
      );
      if (text.isEmpty) return null;
      return ExecutionResult.success(text);
    } catch (e) {
      bodyIntents.close();
      await speechOutbox.cancel('error');
      if (isCancelled()) return cancelledResult();
      TurnTrace.event('mode3.persona_chat_loop.error', details: 'error=$e');
      if (e is HostedLLMFailure) {
        TurnTrace.done('mode3.persona_chat_loop', sw, details: e.runtimeReason);
        // Admission rejection will also reject a structured fallback. Keep
        // the failure so the caller can report it without another dispatch.
        return ExecutionResult.error(e.runtimeReason);
      }
      TurnTrace.done('mode3.persona_chat_loop', sw, details: 'fallback=error');
      return null;
    } finally {
      bodyIntents.close();
      sidebandStripper.finish();
      _requestStreamCancellation();
      if (!_runDone.isCompleted) _runDone.complete();
    }
  }

  static List<Message> buildMessages({
    required String userText,
    String? currentUserText,
    List<Message> history = const [],
    required AgentTurnPlan turnPlan,
    required AgentProfile profile,
    required AppLocale locale,
    ConversationStyleSnapshot? conversationStyle,
  }) {
    final currentText = (currentUserText ?? userText).trim();
    final languageCode = languageCodeForText(currentText, locale);
    final languageRule = languageCode == 'zh'
        ? AgentPromptCatalog.text('runtime.persona.language.zh', locale: locale)
        : AgentPromptCatalog.text(
            'runtime.persona.language.en',
            locale: locale,
          );
    final traits = profile.personalityTraits.join(', ');
    final baseSystemPrompt = AgentPromptCatalog.text(
      'runtime.persona.system',
      locale: locale,
      params: {
        'nickname': profile.nickname,
        'language_rule': languageRule,
        'route': turnPlan.route.name,
        'mood': turnPlan.mood,
        'task': turnPlan.taskKind.name,
        'traits': traits,
      },
    );
    final capsule = profile.persona.toCapsule();
    final capsuleLine = capsule.isEmpty
        ? ''
        : AgentPromptCatalog.text(
            'runtime.persona.capsule_line',
            locale: locale,
            params: <String, Object?>{'capsule': capsule},
          );
    final stylePrompt = ConversationStylePrompt.render(
      conversationStyle ?? ConversationStyleSnapshot(isPrivate: false),
      locale: locale,
    );
    final systemPrompt = [
      baseSystemPrompt,
      if (capsuleLine.isNotEmpty) capsuleLine,
      stylePrompt,
    ].join('\n');
    final recentConversation = _boundedRecentConversation(history, currentText);
    final interests = conversationStyle?.isPrivate == true
        ? companionInterestContext(profile.userId)
        : '';
    final devices = conversationStyle?.isPrivate == true
        ? companionDeviceContext(profile.userId)
        : '';
    return [
      Message.system(
        devices.isEmpty ? systemPrompt : '$systemPrompt\n$devices',
      ),
      if (interests.isNotEmpty) Message.user(interests),
      if (recentConversation != null)
        Message.user(
          AgentPromptCatalog.text(
            'runtime.persona.recent_context',
            locale: locale,
            params: {'history': recentConversation},
          ),
        ),
      if (currentText.isNotEmpty && currentText != userText.trim())
        Message.user(_personaUserMessage(userText, currentText, locale)),
      Message.user(currentText.isEmpty ? userText : currentText),
    ];
  }

  static String? _boundedRecentConversation(
    List<Message> history,
    String currentText,
  ) {
    final conversation = history
        .where(
          (message) =>
              (message.role == 'user' || message.role == 'assistant') &&
              (message.toolCalls?.isEmpty ?? true) &&
              message.content.trim().isNotEmpty,
        )
        .toList();
    // Home persists the current user message before calling the runtime.
    if (conversation.isNotEmpty &&
        conversation.last.role == 'user' &&
        conversation.last.content.trim() == currentText) {
      conversation.removeLast();
    }
    final recent = <Map<String, String>>[];
    var encodedCharacters = 2;
    for (final message in conversation.reversed.take(
      recentHistoryMaxMessages,
    )) {
      var content = message.content.trim();
      if (content.length > recentHistoryMessageMaxCharacters) {
        content = content.substring(0, recentHistoryMessageMaxCharacters);
      }
      final item = {'role': message.role, 'content': content};
      // Bound the serialized context, including escaped control text.
      var encoded = _encodeConversation(item);
      final remaining = recentHistoryMaxCharacters - encodedCharacters - 1;
      if (remaining < 80) break;
      while (encoded.length > remaining && content.isNotEmpty) {
        final excess = encoded.length - remaining;
        content = content.substring(0, math.max(0, content.length - excess));
        item['content'] = content;
        encoded = _encodeConversation(item);
      }
      if (content.isEmpty) break;
      recent.insert(0, item);
      encodedCharacters += encoded.length + 1;
    }
    return recent.isEmpty ? null : _encodeConversation(recent);
  }

  static String _encodeConversation(Object value) =>
      jsonEncode(value).replaceAll('<', r'\u003c').replaceAll('>', r'\u003e');

  static String languageCodeForText(String text, AppLocale fallback) {
    final trimmed = text.trim();
    if (RegExp(r'[\u4e00-\u9fff]').hasMatch(trimmed)) return 'zh';
    if (RegExp(r'[A-Za-z]').hasMatch(trimmed)) return 'en';
    return fallback == AppLocale.zh ? 'zh' : 'en';
  }

  static String _personaUserMessage(
    String userText,
    String currentText,
    AppLocale locale,
  ) {
    if (currentText.isEmpty || currentText == userText.trim()) {
      return userText;
    }
    return AgentPromptCatalog.text(
      'runtime.persona.user_context',
      locale: locale,
      params: {'current': currentText, 'context': userText},
    ).trim();
  }

  static Future<PersonaSpeechSession?> openDefaultSpeechSession(
    String agentId, {
    String? language,
    StreamingAudioSink? sink,
    bool Function()? shouldCancel,
    void Function(Future<void>)? trackCleanup,
  }) async {
    if (!MaasoTtsPlugin.soundEnabled.value || shouldCancel?.call() == true) {
      return null;
    }
    final engine = TTSEngineRegistry.current;
    if (engine is! FullDuplexTTSEngine) return null;
    var abandoned = false;
    TtsSession? resolvedSession;
    Future<void>? sessionCleanup;
    void observeCleanup(Future<void> cleanup) {
      trackCleanup?.call(cleanup);
      unawaited(
        cleanup.catchError((Object error) {
          TurnTrace.event(
            'tts.session.open_cleanup_failed',
            details: 'agent=$agentId error=$error',
          );
        }),
      );
    }

    Future<void> retireSession(TtsSession session) {
      if (sessionCleanup != null) return sessionCleanup!;
      final cleanup = sessionCleanup = Future<void>.sync(
        () => session.cancel('opener_cancelled'),
      );
      observeCleanup(cleanup);
      return cleanup;
    }

    final unregisterSoundStopper = MaasoTtsPlugin.registerSoundStopper(() {
      abandoned = true;
      final session = resolvedSession;
      return session == null ? Future<void>.value() : retireSession(session);
    });
    try {
      final turnId =
          'mode3_${DateTime.now().microsecondsSinceEpoch}_${math.Random().nextInt(999999)}';
      TurnTrace.event('tts.session.open', details: 'agent=$agentId');
      final opening = Future<TtsSession>.sync(
        () => engine.openSession(turnId: turnId, language: language),
      );
      // Future.timeout does not cancel its source. Retain this tail for account
      // retirement, so a session returned after the deadline cannot leak/start.
      final lateCleanup = opening.then<void>((session) async {
        resolvedSession = session;
        if (abandoned ||
            !MaasoTtsPlugin.soundEnabled.value ||
            shouldCancel?.call() == true) {
          await retireSession(session);
        }
      }, onError: (Object _, StackTrace _) {});
      observeCleanup(lateCleanup);
      final session = await opening.timeout(const Duration(milliseconds: 1200));
      if (abandoned ||
          !MaasoTtsPlugin.soundEnabled.value ||
          shouldCancel?.call() == true) {
        unawaited(retireSession(session));
        return null;
      }
      final speech = Mode3FullDuplexSpeech(
        agentId: agentId,
        session: session,
        sink: sink ?? MethodChannelStreamingAudioSink(),
      );
      speech.start();
      return speech;
    } catch (e) {
      abandoned = true;
      final lateSession = resolvedSession;
      if (lateSession != null) unawaited(retireSession(lateSession));
      TurnTrace.event(
        'tts.session.open_failed',
        details: 'agent=$agentId error=$e',
      );
      return null;
    } finally {
      unregisterSoundStopper();
    }
  }
}

/// One budget for native SSE and inline markers, scoped to this run only.
class _PersonaBodyIntentGate {
  _PersonaBodyIntentGate({required this.onControlEvent, this.shouldCancel});

  final PersonaControlEventHandler? onControlEvent;
  final bool Function()? shouldCancel;
  final Set<String> _seen = {};
  bool _closed = false;
  Future<void> _tail = Future<void>.value();

  void add(LLMStreamEvent event) {
    if (_closed || shouldCancel?.call() == true) return;
    final payload = AvatarBodyIntentPolicy.normalize(event.jsonPayload);
    if (payload == null) return;
    final signature = AvatarBodyIntentPolicy.signature(payload);
    if (_seen.contains(signature) || _seen.length >= 2) return;
    _seen.add(signature);
    _tail = _tail
        .then((_) async {
          if (_closed || shouldCancel?.call() == true) return;
          await onControlEvent?.call(
            LLMStreamEvent(event: 'body.intent', data: jsonEncode(payload)),
          );
        })
        .catchError((Object error) {
          TurnTrace.event(
            'persona.body_intent.failed',
            details: 'handler_failed=true',
          );
        });
  }

  Future<void> finish() async {
    try {
      await _tail.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      close();
      TurnTrace.event(
        'persona.body_intent.timeout',
        details: 'drain_limit_ms=2000',
      );
    }
  }

  void close() => _closed = true;
}

class _PersonaSidebandStripper {
  _PersonaSidebandStripper({
    required this.onHandoff,
    required this.onControlEvent,
  });

  static const _taskHandoff = _PersonaSidebandMarker(
    start: '<task_handoff>',
    end: '</task_handoff>',
    type: _PersonaSidebandType.taskHandoff,
  );
  static const _bodyIntent = _PersonaSidebandMarker(
    start: '<body_intent>',
    end: '</body_intent>',
    type: _PersonaSidebandType.bodyIntent,
  );
  static const _markers = [_taskHandoff, _bodyIntent];

  final PersonaTaskHandoffHandler? onHandoff;
  final PersonaControlEventHandler? onControlEvent;
  String _pending = '';
  _PersonaSidebandMarker? _discarding;

  String add(String input) {
    if (input.isEmpty) return '';
    var buffer = _pending + input;
    _pending = '';
    final out = StringBuffer();

    final discarding = _discarding;
    if (discarding != null) {
      final end = buffer.indexOf(discarding.end);
      if (end < 0) {
        _pending = buffer.substring(
          math.max(0, buffer.length - discarding.end.length),
        );
        return '';
      }
      buffer = buffer.substring(end + discarding.end.length);
      _discarding = null;
    }

    while (buffer.isNotEmpty) {
      final match = _nextMarker(buffer);
      if (match != null) {
        final marker = match.marker;
        final start = match.index;
        out.write(buffer.substring(0, start));
        if (match.isClosing) {
          buffer = buffer.substring(start + marker.end.length);
          continue;
        }
        final validOpening = buffer.startsWith(marker.start, start);
        final payloadStart = math.min(
          start + marker.start.length,
          buffer.length,
        );
        final end = buffer.indexOf(marker.end, payloadStart);
        if (end < 0) {
          if (buffer.length - start > 8192) {
            _discarding = marker;
            _pending = buffer.substring(buffer.length - marker.end.length);
          } else {
            _pending = buffer.substring(start);
          }
          break;
        }
        if (validOpening) _emit(marker, buffer.substring(payloadStart, end));
        buffer = buffer.substring(end + marker.end.length);
        continue;
      }

      final keep = _partialStartSuffixLength(buffer);
      if (keep > 0) {
        out.write(buffer.substring(0, buffer.length - keep));
        _pending = buffer.substring(buffer.length - keep);
      } else {
        out.write(buffer);
      }
      break;
    }

    return out.toString();
  }

  void finish() {
    _pending = '';
  }

  void _emit(_PersonaSidebandMarker marker, String raw) {
    final payload = raw.trim();
    if (payload.isEmpty) return;
    switch (marker.type) {
      case _PersonaSidebandType.taskHandoff:
        final handoff = PersonaTaskHandoff.tryParse(payload);
        if (handoff == null) return;
        onHandoff?.call(handoff);
      case _PersonaSidebandType.bodyIntent:
        try {
          final decoded = jsonDecode(payload);
          if (decoded is! Map) return;
          onControlEvent?.call(
            LLMStreamEvent(
              event: 'body.intent',
              data: jsonEncode(Map<String, dynamic>.from(decoded)),
            ),
          );
        } catch (_) {
          return;
        }
    }
  }

  _PersonaSidebandMatch? _nextMarker(String value) {
    _PersonaSidebandMatch? best;
    for (final marker in _markers) {
      // Recognize the reserved opening name even if its trailing syntax is
      // malformed, so attributes or a missing '>' cannot leak to speech.
      for (final isClosing in [false, true]) {
        final token = isClosing
            ? marker.end
            : marker.start.substring(0, marker.start.length - 1);
        final index = value.indexOf(token);
        if (index < 0) continue;
        if (best == null || index < best.index) {
          best = _PersonaSidebandMatch(
            marker: marker,
            index: index,
            isClosing: isClosing,
          );
        }
      }
    }
    return best;
  }

  int _partialStartSuffixLength(String value) {
    var best = 0;
    for (final marker in _markers) {
      for (final token in [marker.start, marker.end]) {
        final max = math.min(token.length - 1, value.length);
        for (var len = max; len > best; len--) {
          if (token.startsWith(value.substring(value.length - len))) {
            best = len;
            break;
          }
        }
      }
    }
    return best;
  }
}

enum _PersonaSidebandType { taskHandoff, bodyIntent }

class _PersonaSidebandMarker {
  const _PersonaSidebandMarker({
    required this.start,
    required this.end,
    required this.type,
  });

  final String start;
  final String end;
  final _PersonaSidebandType type;
}

class _PersonaSidebandMatch {
  const _PersonaSidebandMatch({
    required this.marker,
    required this.index,
    this.isClosing = false,
  });

  final _PersonaSidebandMarker marker;
  final int index;
  final bool isClosing;
}

class _PersonaSpeechOutbox {
  _PersonaSpeechOutbox({
    required this.agentId,
    required Future<PersonaSpeechSession?> sessionFuture,
    required this.fallbackSpeak,
  }) : _sessionFuture = sessionFuture {
    // Observe the opener immediately, including when no speech has yet flushed.
    unawaited(_resolveSession());
  }

  final String agentId;
  final Future<PersonaSpeechSession?> _sessionFuture;
  final PersonaFallbackSpeak fallbackSpeak;

  PersonaSpeechSession? _session;
  Future<PersonaSpeechSession?>? _resolution;
  bool _cancelled = false;
  String _cancelReason = 'cancelled';
  Future<void>? _sessionCancellation;
  Future<void> _tail = Future<void>.value();

  Future<void> get drained async {
    final session = await _resolveSession();
    if (_cancelled) await _cancelSession();
    await _tail;
    await _sessionCancellation;
    if (session is PersonaSpeechSessionDrain) {
      await (session as PersonaSpeechSessionDrain).drained;
    }
  }

  void send(String text, {required bool first}) {
    if (text.trim().isEmpty || _cancelled) return;
    _tail = _tail
        .then((_) async {
          if (_cancelled) return;
          final session = await _resolveSession();
          if (_cancelled) return;
          if (session != null) {
            await session.sendText(text, flush: !first);
          } else {
            fallbackSpeak(text);
          }
        })
        .catchError((Object e) {
          TurnTrace.event(
            'tts.stream.send_failed',
            details: 'agent=$agentId error=$e',
          );
        });
    unawaited(_tail);
  }

  Future<void> finish() async {
    try {
      await _tail;
      if (_cancelled) return;
      final session = await _resolveSession();
      if (_cancelled) return;
      await session?.finish();
    } catch (e) {
      TurnTrace.event(
        'tts.stream.finish_failed',
        details: 'agent=$agentId error=$e',
      );
    }
  }

  Future<void> cancel(String reason) {
    _cancelled = true;
    _cancelReason = reason;
    // Never wait for a network opener to release a user turn. Its resolution
    // handler below owns cancellation of a session which arrives later.
    return _session == null ? Future<void>.value() : _cancelSession();
  }

  Future<void> _cancelSession() {
    final cancellation = _sessionCancellation ??= Future<void>.sync(
      () => _session?.cancel(_cancelReason),
    );
    return cancellation.catchError((Object e) {
      TurnTrace.event(
        'tts.stream.cancel_failed',
        details: 'agent=$agentId reason=$_cancelReason error=$e',
      );
    });
  }

  Future<PersonaSpeechSession?> _resolveSession() => _resolution ??= () async {
    try {
      _session = await _sessionFuture;
      if (_cancelled) unawaited(_cancelSession());
      return _session;
    } catch (e) {
      TurnTrace.event(
        'tts.session.resolve_failed',
        details: 'agent=$agentId error=$e',
      );
      return null;
    }
  }();
}

class PersonaSpeechBuffer {
  PersonaSpeechBuffer({required this.onFlush});

  static const firstChunkMinChars = 24;
  static const laterChunkMinChars = 72;

  final void Function(String text, {required bool first}) onFlush;
  final StringBuffer _pending = StringBuffer();
  bool _flushed = false;

  void add(String delta) {
    if (delta.isEmpty) return;
    _pending.write(delta);
    _drain(force: false);
  }

  void finish() {
    _drain(force: true);
  }

  void _drain({required bool force}) {
    while (true) {
      final text = _pending.toString();
      if (text.trim().isEmpty) {
        if (force) _pending.clear();
        return;
      }
      final index = _flushIndex(text, first: !_flushed, force: force);
      if (index == null) return;

      final chunk = text.substring(0, index).trim();
      final rest = text.substring(index);
      _pending
        ..clear()
        ..write(rest);
      if (chunk.isNotEmpty) {
        final first = !_flushed;
        _flushed = true;
        onFlush(chunk, first: first);
      }
      if (!force) return;
    }
  }

  int? _flushIndex(String text, {required bool first, required bool force}) {
    final minChars = first ? firstChunkMinChars : laterChunkMinChars;
    final softMinChars = math.max(8, (minChars * 0.45).round());
    var visible = 0;
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (ch.trim().isNotEmpty) visible++;
      if (visible >= softMinChars && _isSentenceBoundary(ch)) {
        return i + 1;
      }
    }
    if (visible >= minChars) return text.length;
    if (force) return text.length;
    return null;
  }

  bool _isSentenceBoundary(String ch) {
    return ch == '。' ||
        ch == '！' ||
        ch == '？' ||
        ch == '，' ||
        ch == '；' ||
        ch == '.' ||
        ch == '!' ||
        ch == '?' ||
        ch == ',' ||
        ch == ';';
  }
}

class Mode3FullDuplexSpeech
    implements PersonaSpeechSession, PersonaSpeechSessionDrain {
  Mode3FullDuplexSpeech({
    required this.agentId,
    required this.session,
    required this.sink,
  });

  final String agentId;
  final TtsSession session;
  final StreamingAudioSink sink;
  final Completer<void> _done = Completer<void>();
  StreamSubscription<TtsAudioFrame>? _sub;
  Future<void> _writeTail = Future.value();
  final List<Timer> _lipTimers = <Timer>[];
  DateTime? _playbackStartedAt;
  Duration _scheduledAudioDuration = Duration.zero;
  bool _sinkStarted = false;
  bool _firstAudio = true;
  bool _firstWrite = true;
  bool _closed = false;
  bool _cancelled = false;
  bool _sinkFailed = false;
  bool _stopped = false;
  bool _localStopFailed = false;
  final Completer<void> _cancelledSignal = Completer<void>();
  Future<void>? _cancelFuture;
  Future<void>? _transportCancellation;
  void Function()? _unregisterSoundStopper;
  static const _lipFrameDuration = Duration(milliseconds: 33);

  @override
  Future<void> get drained async {
    await _done.future;
    await Future.wait<void>([
      _writeTail,
      ?_cancelFuture,
      ?_transportCancellation,
    ]);
  }

  void start() {
    if (_closed || _sub != null) return;
    _unregisterSoundStopper ??= MaasoTtsPlugin.registerSoundStopper(
      () => cancel('sound_disabled'),
    );
    if (!MaasoTtsPlugin.soundEnabled.value) {
      unawaited(cancel('sound_disabled'));
      return;
    }
    EventBus().fire(SpeakingStatusEvent(true, agentId: agentId));
    _sub = session.audioFrames.listen(
      _onFrame,
      onError: (Object error) {
        TurnTrace.event(
          'tts.session.error',
          details: 'agent=$agentId error=$error',
        );
        _complete(drain: false);
      },
      onDone: () => _complete(drain: true),
      cancelOnError: true,
    );
  }

  @override
  Future<void> sendText(String text, {required bool flush}) async {
    if (_closed) return;
    TurnTrace.event(
      'tts.session.text_sent',
      details: 'agent=$agentId chars=${text.length} flush=$flush',
    );
    await session.sendText(text, flush: flush);
  }

  @override
  Future<void> finish() async {
    try {
      if (!_closed) {
        await Future.any<void>([session.finish(), _cancelledSignal.future]);
      }
      await _done.future.timeout(const Duration(seconds: 15));
    } catch (_) {
      await cancel('finish_timeout');
    }
  }

  @override
  Future<void> cancel(String reason) {
    if (_cancelFuture != null && !_localStopFailed) return _cancelFuture!;
    if (_stopped && !_cancelled) return Future<void>.value();
    final stopped = Completer<void>();
    _cancelFuture = stopped.future;
    _localStopFailed = false;
    _cancelled = true;
    _closed = true;
    if (!_cancelledSignal.isCompleted) _cancelledSignal.complete();
    TurnTrace.event(
      'tts.session.cancel',
      details: 'agent=$agentId reason=$reason',
    );
    _cancelLipTimers();
    _emitStopped(retainSoundStopper: true);
    // Stop the local device before waiting on any network/stream cleanup.
    final localStop = Future<void>.sync(() => sink.stop(drain: false));
    final transportCancellation = _transportCancellation ??= Future.wait<void>([
      Future<void>.sync(() => session.cancel(reason)),
      Future<void>.sync(() => _sub?.cancel()),
    ]).then<void>((_) {});
    unawaited(
      transportCancellation.catchError((Object error) {
        TurnTrace.event(
          'tts.session.cancel_error',
          details: 'agent=$agentId error=$error',
        );
      }),
    );
    localStop.then(
      (_) {
        _releaseSoundStopper();
        stopped.complete();
      },
      onError: (Object error, StackTrace stack) {
        _localStopFailed = true;
        stopped.completeError(error, stack);
      },
    );
    return stopped.future;
  }

  void _onFrame(TtsAudioFrame frame) {
    if (_closed || frame.bytes.isEmpty) return;
    _writeTail = _writeTail.then((_) => _writeFrame(frame));
  }

  void _complete({required bool drain}) {
    if (_closed) return;
    _closed = true;
    _writeTail = _writeTail.then((_) => _completeAfterWrites(drain));
  }

  Future<void> _writeFrame(TtsAudioFrame frame) async {
    // Server EOF closes input, but already accepted frames still need playback.
    if (_cancelled || _sinkFailed) return;
    try {
      if (_firstAudio) {
        _firstAudio = false;
        TurnTrace.event(
          'tts.session.first_audio_frame',
          details:
              'agent=$agentId bytes=${frame.bytes.length} sampleRate=${frame.sampleRate}',
        );
      }
      if (!_sinkStarted) {
        await sink.start(
          sampleRate: frame.sampleRate,
          channels: frame.channels,
        );
        if (_cancelled || _sinkFailed) {
          // A native start can finish after the immediate mute stop. Retire
          // that late generation without accepting any PCM or mouth cues.
          await sink.stop(drain: false);
          return;
        }
        _sinkStarted = true;
        TurnTrace.event('tts.audio.sink.start', details: 'agent=$agentId');
      }
      if (_cancelled || _sinkFailed) return;
      _scheduleLipSyncForFrame(frame);
      await sink.write(frame.bytes);
      if (_cancelled || _sinkFailed) return;
      TurnTrace.event(
        _firstWrite ? 'tts.audio.sink.write_first' : 'tts.audio.sink.write',
        details:
            'agent=$agentId seq=${frame.sequence} bytes=${frame.bytes.length}',
      );
      _firstWrite = false;
    } catch (error) {
      await _handleSinkFailure(error);
    }
  }

  Future<void> _completeAfterWrites(bool drain) async {
    if (_sinkFailed || _cancelled) return;
    try {
      var nativeDrainVerified = false;
      if (_sinkStarted) {
        if (sink case final VerifiedStreamingAudioSink verifiedSink) {
          final receipt = await verifiedSink.stopWithReceipt(drain: drain);
          if (_cancelled) return;
          nativeDrainVerified = drain;
          if (drain &&
              receipt.terminal != StreamingAudioPlaybackTerminal.completed) {
            throw StateError(
              'Native PCM playback ended before drain completed.',
            );
          }
        } else {
          await sink.stop(drain: drain);
        }
      }
      if (_cancelled) return;
      if (drain && !nativeDrainVerified) {
        final remaining = _remainingPlaybackDelay();
        if (remaining > Duration.zero) {
          TurnTrace.event(
            'tts.audio.playback_drain_wait',
            details: 'agent=$agentId ms=${remaining.inMilliseconds}',
          );
          final elapsed = Completer<void>();
          final timer = Timer(remaining, elapsed.complete);
          try {
            await Future.any<void>([elapsed.future, _cancelledSignal.future]);
          } finally {
            timer.cancel();
          }
        }
      } else {
        _cancelLipTimers();
      }
      _cancelLipTimers();
      if (_cancelled) return;
      _emitStopped();
      TurnTrace.event(
        'tts.session.done',
        details: 'agent=$agentId drain=$drain',
      );
    } catch (error) {
      await _handleSinkFailure(error);
    }
  }

  Future<void> _handleSinkFailure(Object error) async {
    if (_sinkFailed || _cancelled) return;
    _sinkFailed = true;
    _closed = true;
    TurnTrace.event(
      'tts.audio.sink.error',
      details: 'agent=$agentId error=$error',
    );
    try {
      await cancel('sink_failure');
    } catch (stopError) {
      TurnTrace.event(
        'tts.audio.sink.stop_error',
        details: 'agent=$agentId error=$stopError',
      );
    }
    _emitStopped();
  }

  void _emitStopped({bool retainSoundStopper = false}) {
    if (_stopped) return;
    _stopped = true;
    if (!retainSoundStopper) _releaseSoundStopper();
    EventBus().fire(LipSyncAmplitudeEvent(0, agentId: agentId));
    EventBus().fire(SpeakingStatusEvent(false, agentId: agentId));
    if (!_done.isCompleted) _done.complete();
  }

  void _releaseSoundStopper() {
    _unregisterSoundStopper?.call();
    _unregisterSoundStopper = null;
  }

  void _scheduleLipSyncForFrame(TtsAudioFrame frame) {
    final duration = _pcmDuration(frame);
    if (frame.encoding.toLowerCase() != 'pcm_s16le') {
      _scheduleLegacyLipSyncForFrame(frame, duration);
      return;
    }

    final track = LipSyncVisemeAnalyzer.analyzePcmS16le(
      frame.bytes,
      sampleRate: frame.sampleRate,
      channels: frame.channels,
      // Network packet boundaries are not pauses in speech. The drain/stop
      // path closes the mouth after the queued audio actually finishes.
      closeAtEnd: false,
    );
    final peak = track.envelope.fold<double>(
      0,
      (value, amplitude) => math.max(value, amplitude),
    );

    void emitTrack() {
      if (_cancelled || _stopped) return;
      // Keep one scalar tick for legacy observers, then immediately replace
      // it with the whole-envelope and five-vowel renderer tracks.
      EventBus().fire(LipSyncAmplitudeEvent(peak, agentId: agentId));
      EventBus().fire(
        LipSyncEnvelopeEvent(
          track.envelope,
          frameRate: track.frameRate,
          agentId: agentId,
        ),
      );
      EventBus().fire(LipSyncVisemeTrackEvent(track, agentId: agentId));
    }

    if (duration <= Duration.zero) {
      emitTrack();
      return;
    }

    _playbackStartedAt ??= DateTime.now();
    final frameStart = _scheduledAudioDuration;
    _scheduledAudioDuration += duration;
    final timer = Timer(_delayUntilPlaybackOffset(frameStart), emitTrack);
    _lipTimers.add(timer);
  }

  void _scheduleLegacyLipSyncForFrame(TtsAudioFrame frame, Duration duration) {
    if (_cancelled || _stopped) return;
    final amplitude = _pcmS16leAmplitude(frame.bytes);
    if (duration <= Duration.zero) {
      EventBus().fire(LipSyncAmplitudeEvent(amplitude, agentId: agentId));
      return;
    }

    _playbackStartedAt ??= DateTime.now();
    final frameStart = _scheduledAudioDuration;
    _scheduledAudioDuration += duration;
    final tickCount = math.max(
      1,
      (duration.inMicroseconds / _lipFrameDuration.inMicroseconds).ceil(),
    );
    for (var i = 0; i < tickCount; i++) {
      final offset = frameStart + _lipFrameDuration * i;
      final timer = Timer(_delayUntilPlaybackOffset(offset), () {
        if (_cancelled || _stopped) return;
        EventBus().fire(LipSyncAmplitudeEvent(amplitude, agentId: agentId));
      });
      _lipTimers.add(timer);
    }
  }

  Duration _pcmDuration(TtsAudioFrame frame) {
    if (frame.sampleRate <= 0 || frame.channels <= 0) return Duration.zero;
    final bytesPerFrame = 2 * frame.channels;
    if (bytesPerFrame <= 0) return Duration.zero;
    final sampleFrames = frame.bytes.length ~/ bytesPerFrame;
    if (sampleFrames <= 0) return Duration.zero;
    final micros =
        (sampleFrames * Duration.microsecondsPerSecond) ~/ frame.sampleRate;
    return Duration(microseconds: micros);
  }

  Duration _remainingPlaybackDelay() {
    final start = _playbackStartedAt;
    if (start == null) return Duration.zero;
    final remaining =
        _scheduledAudioDuration - DateTime.now().difference(start);
    return remaining.isNegative ? Duration.zero : remaining;
  }

  Duration _delayUntilPlaybackOffset(Duration offset) {
    final start = _playbackStartedAt;
    if (start == null) return Duration.zero;
    final remaining = offset - DateTime.now().difference(start);
    return remaining.isNegative ? Duration.zero : remaining;
  }

  void _cancelLipTimers() {
    for (final timer in _lipTimers) {
      timer.cancel();
    }
    _lipTimers.clear();
  }

  double _pcmS16leAmplitude(List<int> bytes) {
    if (bytes.length < 2) return 0;
    var sum = 0.0;
    var count = 0;
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      var sample = bytes[i] | (bytes[i + 1] << 8);
      if (sample & 0x8000 != 0) sample -= 0x10000;
      sum += sample.abs() / 32768.0;
      count++;
    }
    if (count == 0) return 0;
    return (sum / count).clamp(0.0, 1.0);
  }
}

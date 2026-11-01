import 'dart:async';
import 'dart:math';

import '../speech/speech_utterance_handle.dart';
import 'conversation_utterance.dart';

enum ConversationDeliveryState {
  generating,
  delivering,
  awaitingAudio,
  briefGap,
  optionalWindow,
  completed,
  cancelled,
  failed,
}

/// A validated unit with identities assigned by the host, never by the model.
class ConversationUtterance {
  const ConversationUtterance({
    required this.turnId,
    required this.utteranceId,
    required this.sequence,
    required this.draft,
  });

  final String turnId;
  final String utteranceId;
  final int sequence;
  final ConversationUtteranceDraft draft;

  String get text => draft.text;
}

typedef PublishConversationUtterance =
    Future<bool> Function(
      ConversationUtterance utterance,
      bool Function() mayPublish,
    );

/// One runtime-owned delivery. It never calls the model or starts another turn.
///
/// [publish] is the persistence boundary. It must check [mayPublish] inside its
/// transaction and return true only after a committed write. Cancellation seals
/// after any outstanding publication, so a new user message can be written
/// after [cancel] without allowing an old supplement to appear below it.
class ConversationReplyCoordinator {
  ConversationReplyCoordinator({
    required this.turnId,
    required PublishConversationUtterance publish,
    required Future<void> Function() seal,
    bool Function()? isCurrent,
    Future<void> Function()? cancelOutput,
    void Function(ConversationUtterance)? onPublished,
    SpeechUtteranceHandle Function(ConversationUtterance)? speak,
    void Function(ConversationUtterance)? onSpeechStarted,
    void Function(ConversationUtterance, SpeechTerminal)? onSpeechFinished,
    void Function(ConversationUtterance)? onTextDelivery,
    void Function(ConversationDeliveryState)? onStateChanged,
    DateTime Function()? now,
    this.briefPause = const Duration(milliseconds: 400),
    this.invitationPause = const Duration(milliseconds: 1800),
    this.optionalWindowLimit = const Duration(seconds: 6),
    this.readingTimePerCharacter = const Duration(milliseconds: 20),
  }) : _publish = publish,
       _seal = seal,
       _isCurrent = isCurrent ?? (() => true),
       _cancelOutput = cancelOutput,
       _onPublished = onPublished,
       _speak = speak,
       _onSpeechStarted = onSpeechStarted,
       _onSpeechFinished = onSpeechFinished,
       _onTextDelivery = onTextDelivery,
       _onStateChanged = onStateChanged,
       _now = now ?? DateTime.now;

  final String turnId;
  final PublishConversationUtterance _publish;
  final Future<void> Function() _seal;
  final bool Function() _isCurrent;
  final Future<void> Function()? _cancelOutput;
  final void Function(ConversationUtterance)? _onPublished;
  // terminal must describe actual playback. Failed/timedOut handles must fence
  // late output and stop their owned player before settling, never after it.
  final SpeechUtteranceHandle Function(ConversationUtterance)? _speak;
  final void Function(ConversationUtterance)? _onSpeechStarted;
  final void Function(ConversationUtterance, SpeechTerminal)? _onSpeechFinished;
  final void Function(ConversationUtterance)? _onTextDelivery;
  final void Function(ConversationDeliveryState)? _onStateChanged;
  final DateTime Function() _now;
  final Duration briefPause;
  final Duration invitationPause;
  final Duration optionalWindowLimit;
  final Duration readingTimePerCharacter;

  final Completer<void> _cancelled = Completer<void>();
  final List<ConversationUtterance> _delivered = [];
  ConversationDeliveryState _state = ConversationDeliveryState.generating;
  Future<bool>? _publication;
  Future<void>? _sealFuture;
  Future<void>? _cancelFuture;
  Completer<void>? _draftChanged;
  bool _hasDraft = false;
  bool _started = false;
  bool _audioDegraded = false;
  SpeechUtteranceHandle? _activeSpeech;

  ConversationDeliveryState get state => _state;
  bool get mayPublish =>
      !_cancelled.isCompleted &&
      _state != ConversationDeliveryState.completed &&
      _state != ConversationDeliveryState.failed &&
      _isCurrent();
  List<ConversationUtterance> get delivered => List.unmodifiable(_delivered);
  String get deliveredText => _delivered.map((item) => item.text).join('\n');

  /// Call only on actual text edits. Focus and pointer changes are irrelevant.
  void updateDraft(String text) {
    _hasDraft = text.trim().isNotEmpty;
    final changed = _draftChanged;
    if (changed != null && !changed.isCompleted) changed.complete();
  }

  Future<void> run(List<ConversationUtteranceDraft> drafts) async {
    if (_started) throw StateError('conversation_delivery_already_started');
    _started = true;
    final pending = List<ConversationUtteranceDraft>.of(drafts);
    try {
      if (pending.isEmpty || pending.length > 3) {
        throw ArgumentError.value(
          pending.length,
          'drafts',
          'Expected 1–3 units',
        );
      }
      for (var sequence = 0; sequence < pending.length; sequence++) {
        if (!mayPublish) break;
        final draft = pending[sequence];
        final utterance = ConversationUtterance(
          turnId: turnId,
          utteranceId: '$turnId:$sequence',
          sequence: sequence,
          draft: draft,
        );
        _setState(ConversationDeliveryState.delivering);
        final publication = Completer<bool>();
        _publication = publication.future;
        unawaited(
          Future<bool>.sync(
            () => _publish(utterance, () => mayPublish),
          ).then(publication.complete, onError: publication.completeError),
        );
        final committed = await publication.future;
        if (committed) _delivered.add(utterance);
        if (!committed) {
          if (!_cancelled.isCompleted) _cancelled.complete();
          break;
        }
        if (!mayPublish) break;
        _onPublished?.call(utterance);
        if (!mayPublish) break;
        var spoken = false;
        if (_speak != null && !_audioDegraded) {
          _setState(ConversationDeliveryState.awaitingAudio);
          final terminal = await _deliverSpeech(utterance);
          if (terminal == SpeechTerminal.cancelled) {
            if (!_cancelled.isCompleted) _cancelled.complete();
            break;
          }
          if (!mayPublish) break;
          spoken = terminal == SpeechTerminal.completed;
          if (!spoken) _audioDegraded = true;
        }
        if (!mayPublish) break;
        if (!spoken) _onTextDelivery?.call(utterance);
        if (!mayPublish) break;
        // Even the last/finish/yield unit owns playback until its terminal.
        if (draft.after == ConversationAfter.finish ||
            draft.after == ConversationAfter.yieldToUser ||
            sequence == pending.length - 1) {
          break;
        }
        if (draft.after == ConversationAfter.optional) {
          if (!await _waitForOptional(draft, includeReading: !spoken)) break;
        } else {
          _setState(ConversationDeliveryState.briefGap);
          final pause = draft.pause == ConversationPause.invite
              ? invitationPause
              : briefPause;
          await _wait(spoken ? pause : _readingPause(draft, pause));
        }
      }
      if (mayPublish) {
        _setState(ConversationDeliveryState.completed);
      } else {
        _setState(ConversationDeliveryState.cancelled);
      }
    } catch (_) {
      if (mayPublish) _setState(ConversationDeliveryState.failed);
      rethrow;
    } finally {
      await _sealOnce();
    }
  }

  /// Consumes already-validated presentation units as generation admits them.
  ///
  /// The stream is bounded to three units and must end with `yield` or
  /// `finish`. Cancellation races the next stream item so a stalled model never
  /// keeps the delivery owner alive after takeover.
  Future<void> runStream(Stream<ConversationUtteranceDraft> drafts) =>
      _runStream(drafts);

  Future<void> _runStream(Stream<ConversationUtteranceDraft> drafts) async {
    if (_started) throw StateError('conversation_delivery_already_started');
    _started = true;
    final iterator = StreamIterator<ConversationUtteranceDraft>(drafts);
    try {
      var sequence = 0;
      var sawTerminal = false;
      var suppressedOptionalTail = false;
      while (mayPublish) {
        final next = await Future.any<int>([
          iterator.moveNext().then((hasNext) => hasNext ? 1 : 0),
          _cancelled.future.then((_) => -1),
        ]);
        if (next <= 0 || !mayPublish) break;
        if (sequence >= 3) {
          throw ArgumentError.value(
            sequence + 1,
            'drafts',
            'Expected 1–3 units',
          );
        }
        final draft = iterator.current;
        final utterance = ConversationUtterance(
          turnId: turnId,
          utteranceId: '$turnId:$sequence',
          sequence: sequence,
          draft: draft,
        );
        _setState(ConversationDeliveryState.delivering);
        final publication = Completer<bool>();
        _publication = publication.future;
        unawaited(
          Future<bool>.sync(
            () => _publish(utterance, () => mayPublish),
          ).then(publication.complete, onError: publication.completeError),
        );
        final committed = await publication.future;
        if (committed) _delivered.add(utterance);
        if (!committed) {
          if (!_cancelled.isCompleted) _cancelled.complete();
          break;
        }
        if (!mayPublish) break;
        _onPublished?.call(utterance);
        if (!mayPublish) break;
        var spoken = false;
        if (_speak != null && !_audioDegraded) {
          _setState(ConversationDeliveryState.awaitingAudio);
          final terminal = await _deliverSpeech(utterance);
          if (terminal == SpeechTerminal.cancelled) {
            if (!_cancelled.isCompleted) _cancelled.complete();
            break;
          }
          if (!mayPublish) break;
          spoken = terminal == SpeechTerminal.completed;
          if (!spoken) _audioDegraded = true;
        }
        if (!mayPublish) break;
        if (!spoken) _onTextDelivery?.call(utterance);
        if (!mayPublish) break;
        // Even the last/finish/yield unit owns playback until its terminal.
        if (draft.after == ConversationAfter.finish ||
            draft.after == ConversationAfter.yieldToUser) {
          sawTerminal = true;
          break;
        }
        if (draft.after == ConversationAfter.optional) {
          if (!await _waitForOptional(draft, includeReading: !spoken)) {
            suppressedOptionalTail = mayPublish;
            break;
          }
        } else {
          _setState(ConversationDeliveryState.briefGap);
          final pause = draft.pause == ConversationPause.invite
              ? invitationPause
              : briefPause;
          await _wait(spoken ? pause : _readingPause(draft, pause));
        }
        sequence++;
      }
      if (mayPublish) {
        if (sequence == 0 && _delivered.isEmpty) {
          throw ArgumentError.value(0, 'drafts', 'Expected 1–3 units');
        }
        if (!sawTerminal && !suppressedOptionalTail) {
          throw StateError('conversation_stream_missing_terminal');
        }
        _setState(ConversationDeliveryState.completed);
      } else {
        _setState(ConversationDeliveryState.cancelled);
      }
    } catch (_) {
      if (mayPublish) _setState(ConversationDeliveryState.failed);
      rethrow;
    } finally {
      try {
        await iterator.cancel();
      } catch (_) {
        // The producing runtime owns and tracks transport cleanup separately.
      }
      await _sealOnce();
    }
  }

  Future<SpeechTerminal> _deliverSpeech(ConversationUtterance utterance) async {
    SpeechUtteranceHandle? handle;
    var terminalSettled = false;
    late SpeechTerminal terminal;
    try {
      final candidate = _speak!(utterance);
      // Never control or observe a handle belonging to a different owner.
      if (candidate.turnId != utterance.turnId ||
          candidate.utteranceId != utterance.utteranceId) {
        terminal = SpeechTerminal.failed;
      } else {
        handle = candidate;
        _activeSpeech = candidate;
        if (!mayPublish) {
          await candidate.cancel('stale_conversation_utterance');
          terminal = SpeechTerminal.cancelled;
        } else {
          unawaited(
            candidate.started
                .then<void>((started) {
                  if (started &&
                      !terminalSettled &&
                      mayPublish &&
                      identical(_activeSpeech, candidate)) {
                    _onSpeechStarted?.call(utterance);
                  }
                })
                .catchError((Object _, StackTrace _) {}),
          );
          terminal = await Future.any<SpeechTerminal>([
            candidate.terminal,
            _cancelled.future.then((_) => SpeechTerminal.cancelled),
          ]);
        }
      }
    } catch (_) {
      // A throwing adapter is also a speech failure. Stop only its captured
      // handle before allowing a text fallback to proceed.
      await handle?.cancel('conversation_speech_failed');
      terminal = SpeechTerminal.failed;
    } finally {
      terminalSettled = true;
      if (identical(_activeSpeech, handle)) _activeSpeech = null;
    }
    _onSpeechFinished?.call(utterance, terminal);
    return terminal;
  }

  /// Invalidates publication synchronously, including while the model stalls.
  /// The returned future covers this turn's output stop and durable seal only.
  Future<void> cancel() {
    if (_cancelFuture != null) return _cancelFuture!;
    if (_state == ConversationDeliveryState.completed ||
        _state == ConversationDeliveryState.failed) {
      return _sealOnce();
    }
    final cancellation = Completer<void>();
    _cancelFuture = cancellation.future;
    final speech = _activeSpeech;
    if (!_cancelled.isCompleted) _cancelled.complete();
    _setState(ConversationDeliveryState.cancelled);
    final output = Future<void>.sync(() => _cancelOutput?.call());
    final speechStopped = Future<void>.sync(
      () => speech?.cancel('conversation_cancelled'),
    );
    unawaited(
      Future.wait<void>([output, speechStopped, _sealOnce()]).then(
        (_) => cancellation.complete(),
        onError: cancellation.completeError,
      ),
    );
    return cancellation.future;
  }

  Future<void> _sealOnce() => _sealFuture ??= () async {
    try {
      await _publication;
    } catch (_) {
      // Sealing is still required after a failed publication. The original
      // error remains owned by run(), rather than being replaced here.
    }
    await _seal();
  }();

  Duration _readingPause(ConversationUtteranceDraft draft, Duration base) {
    final readingMilliseconds =
        draft.text.runes.length * readingTimePerCharacter.inMilliseconds;
    return base + Duration(milliseconds: min(readingMilliseconds, 1200));
  }

  Future<bool> _waitForOptional(
    ConversationUtteranceDraft draft, {
    required bool includeReading,
  }) async {
    _setState(ConversationDeliveryState.optionalWindow);
    final openedAt = _now();
    final earliest = openedAt.add(
      includeReading ? _readingPause(draft, invitationPause) : invitationPause,
    );
    final expiresAt = openedAt.add(optionalWindowLimit);
    while (mayPublish) {
      final now = _now();
      if (!now.isBefore(expiresAt)) return false;
      if (!now.isBefore(earliest) && !_hasDraft) return true;
      final wakeAt = now.isBefore(earliest) && earliest.isBefore(expiresAt)
          ? earliest
          : expiresAt;
      final draftChanged = Completer<void>();
      _draftChanged = draftChanged;
      await _wait(wakeAt.difference(now), draftChanged: draftChanged.future);
      if (identical(_draftChanged, draftChanged)) _draftChanged = null;
    }
    return false;
  }

  Future<void> _wait(Duration duration, {Future<void>? draftChanged}) async {
    if (!mayPublish || duration <= Duration.zero) return;
    final elapsed = Completer<void>();
    final timer = Timer(duration, elapsed.complete);
    try {
      await Future.any<void>([
        elapsed.future,
        _cancelled.future,
        ?draftChanged,
      ]);
    } finally {
      timer.cancel();
    }
  }

  void _setState(ConversationDeliveryState state) {
    if (_state == state) return;
    _state = state;
    _onStateChanged?.call(state);
  }
}

/// RFC 4122 version 4 identity, independent of runtime restarts and timestamps.
String newConversationTurnId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

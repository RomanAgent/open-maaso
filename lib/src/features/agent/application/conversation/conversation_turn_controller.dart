import 'dart:async';
import '../app_invocation/app_invocation_result_store.dart';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/models/app_invocation_chat_reference.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/memory_write_coordinator.dart';
import 'package:maaso/src/core/services/turn_trace.dart';
import 'package:maaso/src/features/agent/data/models/execution_result.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';

import '../turn_router_gateway.dart';
import '../speech/speech_utterance_handle.dart';
import 'conversation_reply_coordinator.dart';
import 'conversation_response_trace.dart';
import 'conversation_utterance.dart';

enum ConversationDeliveryMode { legacy, text, speech }

/// Immutable delivery authority captured at user-turn admission.
///
/// [isCurrent] is evaluated again at every visible, audible, and durable
/// boundary. This keeps an old turn fenced when an account rollout changes
/// without changing its coarse delivery mode (for example enforce rev1 ->
/// enforce rev2).
final class ConversationDeliveryAdmission {
  const ConversationDeliveryAdmission({
    required this.mode,
    required bool Function() isCurrent,
  }) : _isCurrent = isCurrent;

  final ConversationDeliveryMode mode;
  final bool Function() _isCurrent;

  bool get isCurrent {
    try {
      return _isCurrent();
    } catch (_) {
      return false;
    }
  }
}

/// Native builds use semantic speech units by default. Explicit legacy/text
/// builds remain available; rollout admission still enforces platform/account
/// restrictions before a turn can use this delivery mode.
const defaultConversationDeliveryMode =
    String.fromEnvironment(
          'MAASO_CONVERSATION_DELIVERY',
          defaultValue: 'speech',
        ) ==
        'speech'
    ? ConversationDeliveryMode.speech
    : String.fromEnvironment('MAASO_CONVERSATION_DELIVERY') == 'text'
    ? ConversationDeliveryMode.text
    : ConversationDeliveryMode.legacy;

class ConversationTurnResult {
  ConversationTurnResult({
    required this.turnId,
    required this.execution,
    required this.cancelled,
    required this.userMessage,
    List<ChatMessage> userMessages = const [],
    required List<ChatMessage> publishedMessages,
  }) : userMessages = List.unmodifiable(userMessages),
       publishedMessages = List.unmodifiable(publishedMessages);

  final String turnId;
  final ExecutionResult execution;
  final bool cancelled;
  final ChatMessage? userMessage;
  final List<ChatMessage> userMessages;
  final List<ChatMessage> publishedMessages;
}

class ConversationTurnHandle {
  ConversationTurnHandle._(this._context);

  final ConversationTurnContext _context;
  String get turnId => _context.turnId;
  bool get isCancelled => _context.isCancelled;
  bool get isCurrent =>
      identical(_context._ownerHandle, this) && _context.isCurrent;
  Future<ConversationTurnResult> get done => _context._result.future;
  Future<void> cancel() => identical(_context._ownerHandle, this)
      ? _context.cancel()
      : Future<void>.value();
  void updateDraft(String text) {
    if (isCurrent) _context.updateDraft(text);
  }
}

typedef RunConversationChat =
    Future<ExecutionResult> Function(
      ConversationTurnContext context,
      List<Message> history,
    );

/// Runtime-owned admission and durable publication for all three chat entries.
/// Only admission/sealing is serialized; an abandoned model request cannot hold
/// the next user's input hostage. AgentRuntime still tracks its resource tail.
class ConversationTurnController {
  ConversationTurnController({
    required this.agentId,
    required RunConversationChat runChat,
    required Future<void> Function() stopOutput,
    required bool Function() isAvailable,
    ConversationDeliveryAdmission Function()? deliveryAdmission,
    ConversationDeliveryMode Function()? deliveryMode,
    void Function(ChatMessage)? onMessage,
    void Function(ConversationTurnContext)? onClosed,
    this.briefPause = const Duration(milliseconds: 400),
    this.invitationPause = const Duration(milliseconds: 1800),
    this.inputMergeWindow = const Duration(milliseconds: 250),
    this.typingQuietWindow = const Duration(milliseconds: 750),
    this.maximumInputWait = const Duration(milliseconds: 1500),
  }) : _runChat = runChat,
       _stopOutput = stopOutput,
       _isAvailable = isAvailable,
       _deliveryAdmission =
           deliveryAdmission ??
           (() {
             final reader = deliveryMode;
             final mode = _readDeliveryMode(reader);
             return ConversationDeliveryAdmission(
               mode: mode,
               isCurrent: reader == null
                   ? _alwaysCurrent
                   : () => _readDeliveryMode(reader) == mode,
             );
           }),
       _requiresEnabledMode = deliveryAdmission != null || deliveryMode != null,
       _onMessage = onMessage,
       _onClosed = onClosed;

  final String agentId;
  final RunConversationChat _runChat;
  final Future<void> Function() _stopOutput;
  final bool Function() _isAvailable;
  final ConversationDeliveryAdmission Function() _deliveryAdmission;
  final bool _requiresEnabledMode;
  final void Function(ChatMessage)? _onMessage;
  final void Function(ConversationTurnContext)? _onClosed;
  final Duration briefPause;
  final Duration invitationPause;
  final Duration inputMergeWindow;
  final Duration typingQuietWindow;
  final Duration maximumInputWait;
  final _messages = StreamController<ChatMessage>.broadcast();
  final Set<Future<void>> _operations = {};
  final Map<String, ConversationTurnHandle> _submissions = {};
  Future<void> _admissionTail = Future<void>.value();
  Future<void>? _retirement;
  ConversationTurnContext? _active;
  bool _retired = false;

  Stream<ChatMessage> get messages => _messages.stream;
  bool get hasActiveTurn => _active?.isCurrent == true;

  ConversationTurnHandle submit(
    String text, {
    required DBService database,
    String? sessionId,
    TurnOrigin origin = TurnOrigin.user,
    String? submissionToken,
    String? expectedAppletScopeKey,
    List<Message> extraContext = const [],
    List<ChatAttachment> attachments = const [],
    String? visualContext,
    void Function(ChatMessage)? onMessage,
    AppLocale? locale,
    bool respondImmediately = false,
    bool allowInputMerge = true,
  }) {
    final normalized = text.trim();
    if (normalized.isEmpty) throw ArgumentError('conversation_input_empty');
    if (!origin.isHumanAuthored) throw ArgumentError('conversation_origin');
    if (_retired || !_isAvailable()) throw StateError('agent_runtime_retired');
    final turnLocale = locale == null || locale == AppLocale.system
        ? AgentPromptCatalog.currentLocale
        : locale;
    final deliveryAdmission = _snapshotDeliveryAdmission();
    final deliveryMode = deliveryAdmission.mode;
    if (_requiresEnabledMode &&
        (deliveryMode == ConversationDeliveryMode.legacy ||
            !deliveryAdmission.isCurrent)) {
      throw StateError('conversation_mode_disabled');
    }
    final previousSubmission = submissionToken == null
        ? null
        : _submissions[submissionToken];
    if (previousSubmission != null) return previousSubmission;

    final previous = _active;
    final canMerge =
        allowInputMerge &&
        previous != null &&
        previous._allowInputMerge &&
        previous._acceptingInput &&
        previous.isCurrent &&
        identical(previous.database, database) &&
        previous.sessionId == (sessionId ?? agentId) &&
        previous.origin == origin &&
        previous.locale == turnLocale &&
        previous.expectedAppletScopeKey == expectedAppletScopeKey &&
        previous.deliveryMode == deliveryMode &&
        previous._textOnly &&
        attachments.isEmpty &&
        visualContext == null &&
        _sameExtraContext(previous._extraContext, extraContext);
    // Revoke before assigning the successor: stopping the captured old audio
    // begins synchronously and cannot accidentally target the new turn.
    final stopped = canMerge
        ? Future<void>.value()
        : previous == null
        ? Future<void>.sync(_stopOutput)
        : previous.cancel();
    final context = canMerge
        ? previous
        : ConversationTurnContext._(
            controller: this,
            database: database,
            turnId: newConversationTurnId(),
            sessionId: sessionId ?? agentId,
            origin: origin,
            locale: turnLocale,
            deliveryAdmission: deliveryAdmission,
            expectedAppletScopeKey: expectedAppletScopeKey,
            onMessage: onMessage,
            textOnly: attachments.isEmpty && visualContext == null,
            allowInputMerge: allowInputMerge,
            extraContext: List.unmodifiable(extraContext),
          );
    context._onMessage = onMessage;
    context._inputCount++;
    final handle = ConversationTurnHandle._(context);
    context._ownerHandle = handle;
    _active = context;
    if (submissionToken != null) {
      _submissions[submissionToken] = handle;
      if (_submissions.length > 64) {
        _submissions.remove(_submissions.keys.first);
      }
    }
    final priorAdmission = _admissionTail;
    final admission = () async {
      try {
        await priorAdmission;
        await stopped;
        // Fetch enough rows to retain complete logical turns before applying
        // the character budget, including space for synthetic event records.
        if (context._history == null) {
          final recent = await database.getRecentMessages(
            context.sessionId,
            limit: 128,
          );
          context._history = [
            ...context._extraContext,
            ...conversationHistory(recent, turnLimit: 8),
          ];
        }
        final user = ChatMessage(
          sessionId: context.sessionId,
          senderId: 'user',
          receiverId: agentId,
          content: normalized,
          attachments: List.unmodifiable(attachments),
          visualContext: visualContext,
          timestamp: DateTime.now().toUtc(),
          isUserMessage: true,
          turnOrigin: origin.name,
          turnId: context.turnId,
          deliveryStatus: 'published',
        );
        await database.saveChatMessage(user);
        // Observers receive their own mutable ChatMessage; they cannot change
        // the raw source records frozen for generation.
        context._userMessages.add(_copyMessage(user));
        _notifyMessage(user, onMessage);
        TurnTrace.event(
          'conversation.admitted',
          details: 'turn=${context.turnId}',
        );
      } catch (_) {
        context._admissionFailed = true;
      }
    }();
    _admissionTail = admission;
    context._admissionTail = admission;
    context._draft = '';
    context._scheduleInput(respondImmediately: respondImmediately);
    if (canMerge) {
      TurnTrace.event(
        'conversation.input_merged',
        details: 'turn=${context.turnId} count=${context._inputCount}',
      );
    }
    if (!canMerge) {
      final operation = _run(context);
      _operations.add(operation);
      unawaited(operation.whenComplete(() => _operations.remove(operation)));
    }
    return handle;
  }

  Future<void> _run(ConversationTurnContext context) async {
    var execution = ExecutionResult.success('');
    try {
      await context._inputReady.future;
      await context._admissionTail;
      context._freezeInputs();
      if (context._admissionFailed) {
        throw StateError('conversation_input_persistence_failed');
      }
      final history = context._history ?? const <Message>[];
      if (context.isCurrent && context.userMessage != null) {
        Future<ExecutionResult> generate() => _runChat(context, history);
        final memoryWriter = appServices.maybeFind<MemoryWriteCoordinator>();
        final generation = memoryWriter == null
            ? generate()
            : memoryWriter.runWithPersistedChatSource(
                messageRecordId: context.userMessage!.id!,
                sessionId: context.sessionId,
                agentId: agentId,
                operation: generate,
              );
        execution = await Future.any<ExecutionResult>([
          generation,
          context.cancelled.then((_) => ExecutionResult.success('')),
        ]);
        if (context.isCurrent && !context.hasDelivery && execution.isSuccess) {
          final text = execution.stdout.trim();
          if (text.isNotEmpty) {
            await context.deliver([ConversationUtteranceDraft(text: text)]);
          }
        }
      }
    } catch (error) {
      TurnTrace.event('conversation.failed', details: 'turn=${context.turnId}');
      execution = ExecutionResult.error('conversation_delivery_failed');
    } finally {
      try {
        await context.seal();
      } catch (_) {
        execution = ExecutionResult.error('conversation_persistence_failed');
      }
      if (identical(_active, context)) _active = null;
      context._finished = true;
      context._responseTrace.finish(
        context.isCancelled
            ? ConversationResponseOutcome.cancelled
            : execution.isSuccess
            ? ConversationResponseOutcome.completed
            : ConversationResponseOutcome.failed,
      );
      context._result.complete(
        ConversationTurnResult(
          turnId: context.turnId,
          execution: execution.isSuccess
              ? ExecutionResult.success(context.deliveredText)
              : execution,
          cancelled: context.isCancelled,
          userMessage: context.userMessage,
          userMessages: context.userMessages,
          publishedMessages: context.publishedMessages,
        ),
      );
    }
  }

  void _notify(ConversationTurnContext context, ChatMessage message) {
    _notifyMessage(message, context._onMessage);
  }

  void _notifyMessage(
    ChatMessage message,
    void Function(ChatMessage)? onMessage,
  ) {
    if (!_messages.isClosed) _messages.add(message);
    // UI callbacks cannot turn a committed record into an apparent DB failure.
    for (final callback in [_onMessage, onMessage]) {
      try {
        callback?.call(message);
      } catch (_) {
        TurnTrace.event('conversation.observer_failed');
      }
    }
  }

  void updateDraft(String text) => _active?.updateDraft(text);

  /// A deliberate answer-now action can bypass the remaining quiet window.
  void flushPendingInput() => _active?._finishInput();

  static bool _sameExtraContext(List<Message> a, List<Message> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].role != b[i].role ||
          a[i].content != b[i].content ||
          a[i].toolCallId != null ||
          b[i].toolCallId != null ||
          a[i].toolCalls != null ||
          b[i].toolCalls != null) {
        return false;
      }
    }
    return true;
  }

  static ChatMessage _copyMessage(ChatMessage message) =>
      ChatMessage.fromJson(message.toJson(), id: message.id);

  Future<void> cancelCurrent() => _active?.cancel() ?? Future<void>.value();

  ConversationDeliveryAdmission _snapshotDeliveryAdmission() {
    try {
      return _deliveryAdmission();
    } catch (_) {
      return ConversationDeliveryAdmission(
        mode: ConversationDeliveryMode.legacy,
        isCurrent: _neverCurrent,
      );
    }
  }

  static ConversationDeliveryMode _readDeliveryMode(
    ConversationDeliveryMode Function()? reader,
  ) {
    if (reader == null) return defaultConversationDeliveryMode;
    try {
      return reader();
    } catch (_) {
      return ConversationDeliveryMode.legacy;
    }
  }

  static bool _alwaysCurrent() => true;
  static bool _neverCurrent() => false;

  Future<void> retireAndDrain() {
    final current = _retirement;
    if (current != null) return current;
    final completion = Completer<void>();
    _retirement = completion.future;
    _retired = true;
    unawaited(() async {
      try {
        await cancelCurrent();
        await _admissionTail;
        while (_operations.isNotEmpty) {
          await Future.wait(_operations.toList());
        }
        await _messages.close();
        completion.complete();
      } catch (error, stackTrace) {
        completion.completeError(error, stackTrace);
      }
    }());
    return completion.future;
  }
}

/// The same object travels through the runtime's Zone and all async callbacks.
class ConversationTurnContext {
  ConversationTurnContext._({
    required ConversationTurnController controller,
    required this.database,
    required this.turnId,
    required this.sessionId,
    required this.origin,
    required this.locale,
    required ConversationDeliveryAdmission deliveryAdmission,
    required this.expectedAppletScopeKey,
    required void Function(ChatMessage)? onMessage,
    required bool textOnly,
    required bool allowInputMerge,
    required List<Message> extraContext,
  }) : _controller = controller,
       _responseTrace = ConversationResponseTrace(turnId: turnId),
       _deliveryAdmission = deliveryAdmission,
       _onMessage = onMessage,
       _textOnly = textOnly,
       _allowInputMerge = allowInputMerge,
       _extraContext = extraContext;

  final ConversationTurnController _controller;
  final ConversationResponseTrace _responseTrace;
  final DBService database;
  final String turnId;
  final String sessionId;

  /// One prompt input, composed only from independently persisted user rows.
  String get text => inputTexts.join('\n');
  final TurnOrigin origin;
  final AppLocale locale;
  final ConversationDeliveryAdmission _deliveryAdmission;
  ConversationDeliveryMode get deliveryMode => _deliveryAdmission.mode;
  final String? expectedAppletScopeKey;
  void Function(ChatMessage)? _onMessage;
  final bool _textOnly;
  // A non-mergeable submission also prevents later input from joining it.
  final bool _allowInputMerge;
  final List<Message> _extraContext;
  final _cancelled = Completer<void>();
  final _inputReady = Completer<void>();
  final _result = Completer<ConversationTurnResult>();
  final List<ChatMessage> _published = [];
  final List<ChatMessage> _userMessages = [];
  ConversationTurnHandle? _ownerHandle;
  List<String>? _inputTexts;
  List<Message>? _history;
  Future<void> _admissionTail = Future<void>.value();
  bool _admissionFailed = false;
  bool _acceptingInput = true;
  int _inputCount = 0;
  Timer? _inputTimer;
  final Stopwatch _inputClock = Stopwatch()..start();
  bool Function()? _deliveryGuard;
  bool Function()? _invocationOwnership;
  ConversationReplyCoordinator? _delivery;
  PreparedInvocationResult? _invocationPublication;
  ({String text, AppInvocationChatReference reference})? _invocationNotice;
  bool _preparingInvocationDelivery = false;
  Future<void>? _seal;
  Future<void>? _cancellation;
  bool _finished = false;
  String _draft = '';

  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get cancelled => _cancelled.future;
  bool get isCurrent =>
      !isCancelled &&
      !_finished &&
      !_controller._retired &&
      _controller._isAvailable() &&
      _deliveryAdmission.isCurrent &&
      _deliveryGuardCurrent &&
      _invocationOwnershipCurrent &&
      identical(_controller._active, this);
  bool get hasDelivery => _delivery != null;
  List<ChatMessage> get publishedMessages => List.unmodifiable(_published);
  String get deliveredText => _published.map((m) => m.content).join('\n');

  /// Stable membership and text once runChat starts. Copies keep mutable UI
  /// model objects from modifying another consumer's trusted source snapshot.
  List<ChatMessage> get userMessages => List.unmodifiable(
    _userMessages.map(ConversationTurnController._copyMessage),
  );
  ChatMessage? get userMessage => _userMessages.isEmpty
      ? null
      : ConversationTurnController._copyMessage(_userMessages.last);
  List<String> get inputTexts =>
      _inputTexts ??
      List.unmodifiable(_userMessages.map((message) => message.content));

  /// Runtime binds its policy version after preparing the turn. Publication,
  /// speech and DB commits all reuse isCurrent, so a revoked version fails shut.
  void bindDeliveryGuard(bool Function() isCurrent) {
    if (_deliveryGuard != null) throw StateError('conversation_guard_bound');
    _deliveryGuard = isCurrent;
  }

  /// One native invocation/recovery owner, independent of the style policy.
  /// Revocation participates in the very same DB and speech publication checks.
  void bindInvocationOwnership(bool Function() isCurrent) {
    if (_invocationOwnership != null)
      throw StateError('invocation_ownership_bound');
    _invocationOwnership = isCurrent;
  }

  bool get _invocationOwnershipCurrent {
    try {
      return _invocationOwnership?.call() ?? true;
    } catch (_) {
      return false;
    }
  }

  bool get _deliveryGuardCurrent {
    try {
      return _deliveryGuard?.call() ?? true;
    } catch (_) {
      return false;
    }
  }

  void _scheduleInput({bool respondImmediately = false}) {
    if (!_acceptingInput) return;
    _inputTimer?.cancel();
    final remaining = _controller.maximumInputWait - _inputClock.elapsed;
    if (respondImmediately ||
        _inputCount >= 8 ||
        _controller.inputMergeWindow <= Duration.zero ||
        remaining <= Duration.zero) {
      _finishInput();
      return;
    }
    final quiet = _draft.trim().isEmpty
        ? _controller.inputMergeWindow
        : _controller.typingQuietWindow;
    _inputTimer = Timer(quiet < remaining ? quiet : remaining, _finishInput);
  }

  void _finishInput() {
    _acceptingInput = false;
    _inputTimer?.cancel();
    _inputClock.stop();
    if (!_inputReady.isCompleted) _inputReady.complete();
  }

  void _freezeInputs() {
    _inputTexts ??= List.unmodifiable(
      _userMessages.map((message) => message.content),
    );
  }

  void updateDraft(String text) {
    if (!isCurrent) return;
    _draft = text;
    _scheduleInput();
    _delivery?.updateDraft(text);
  }

  /// Binds one verified result to this turn's existing speech/publication queue.
  /// A recovered result may return its original message; it never reopens that
  /// message's sealed turn or re-executes an action.
  Future<void> deliverInvocationResult(
    PreparedInvocationResult result, {
    Future<void> Function(Stream<ConversationUtteranceDraft>)? deliverUsing,
  }) async {
    if (!isCurrent || !result.isCurrent) return;
    if (_delivery != null ||
        _invocationPublication != null ||
        _invocationNotice != null)
      throw StateError('conversation_already_delivered');
    if (!result.usesDatabase(database.raw) ||
        result.invocationReference.sessionId != sessionId ||
        (expectedAppletScopeKey != null &&
            expectedAppletScopeKey != result.scopeKey)) {
      throw StateError('invocation_result_conversation_scope');
    }
    _invocationPublication = result;
    try {
      final stream = Stream.value(
        ConversationUtteranceDraft(text: result.summary),
      );
      if (deliverUsing != null) {
        await deliverUsing(stream);
      } else {
        await deliverStream(stream);
      }
      if (isCurrent && _delivery == null)
        throw StateError('invocation_result_not_delivered');
    } finally {
      _invocationPublication = null;
    }
  }

  /// A truthful final status from the native invocation runner, through the
  /// same delivery queue. Metadata is display-only, never an execution grant.
  Future<void> deliverInvocationNotice({
    required String text,
    required AppInvocationChatReference reference,
    Future<void> Function(Stream<ConversationUtteranceDraft>)? deliverUsing,
  }) async {
    if (!isCurrent) return;
    if (_delivery != null ||
        _invocationPublication != null ||
        _invocationNotice != null) {
      throw StateError('conversation_already_delivered');
    }
    if (text.trim().isEmpty ||
        text.length > 8192 ||
        reference.sessionId != sessionId ||
        (expectedAppletScopeKey != null &&
            reference.scopeKey != expectedAppletScopeKey) ||
        reference.status == AppInvocationChatStatus.working ||
        reference.status == AppInvocationChatStatus.completed) {
      throw StateError('invocation_notice_invalid');
    }
    _invocationNotice = (text: text, reference: reference);
    try {
      final stream = Stream.value(ConversationUtteranceDraft(text: text));
      if (deliverUsing == null) {
        await deliverStream(stream);
      } else {
        await deliverUsing(stream);
      }
      if (isCurrent && _delivery == null)
        throw StateError('invocation_notice_not_delivered');
    } finally {
      _invocationNotice = null;
    }
  }

  Future<void> deliver(
    List<ConversationUtteranceDraft> drafts, {
    SpeechUtteranceHandle Function(ConversationUtterance)? speak,
    void Function(ConversationUtterance)? onPublished,
    void Function(ConversationUtterance)? onSpeechStarted,
    void Function(ConversationUtterance, SpeechTerminal)? onSpeechFinished,
    void Function(ConversationUtterance)? onTextDelivery,
  }) => _deliver(
    drafts: drafts,
    speak: speak,
    onPublished: onPublished,
    onSpeechStarted: onSpeechStarted,
    onSpeechFinished: onSpeechFinished,
    onTextDelivery: onTextDelivery,
  );

  Future<void> deliverStream(
    Stream<ConversationUtteranceDraft> drafts, {
    SpeechUtteranceHandle Function(ConversationUtterance)? speak,
    void Function(ConversationUtterance)? onPublished,
    void Function(ConversationUtterance)? onSpeechStarted,
    void Function(ConversationUtterance, SpeechTerminal)? onSpeechFinished,
    void Function(ConversationUtterance)? onTextDelivery,
  }) => _deliver(
    draftStream: drafts,
    speak: speak,
    onPublished: onPublished,
    onSpeechStarted: onSpeechStarted,
    onSpeechFinished: onSpeechFinished,
    onTextDelivery: onTextDelivery,
  );

  Future<void> _deliver({
    List<ConversationUtteranceDraft>? drafts,
    Stream<ConversationUtteranceDraft>? draftStream,
    SpeechUtteranceHandle Function(ConversationUtterance)? speak,
    void Function(ConversationUtterance)? onPublished,
    void Function(ConversationUtterance)? onSpeechStarted,
    void Function(ConversationUtterance, SpeechTerminal)? onSpeechFinished,
    void Function(ConversationUtterance)? onTextDelivery,
  }) async {
    if (!isCurrent) return;
    if (_delivery != null || _preparingInvocationDelivery) {
      throw StateError('conversation_already_delivered');
    }
    if ((drafts == null) == (draftStream == null)) {
      throw ArgumentError('conversation_delivery_source');
    }
    final invocationResult = _invocationPublication;
    final invocationNotice = _invocationNotice;
    final invocationText = invocationResult?.summary ?? invocationNotice?.text;
    if (invocationText != null) {
      _preparingInvocationDelivery = true;
      try {
        final source = drafts == null
            ? draftStream!
            : Stream.fromIterable(drafts);
        final checked = <ConversationUtteranceDraft>[];
        await for (final draft in source) {
          if (!isCurrent) return;
          if (checked.isNotEmpty ||
              draft.text != invocationText ||
              draft.after != ConversationAfter.finish) {
            throw StateError('invocation_result_delivery_changed');
          }
          checked.add(draft);
        }
        if (checked.length != 1)
          throw StateError('invocation_result_delivery_missing');
        drafts = checked;
        draftStream = null;
      } finally {
        _preparingInvocationDelivery = false;
      }
    }
    late final ConversationReplyCoordinator delivery;
    delivery = ConversationReplyCoordinator(
      turnId: turnId,
      isCurrent: () => isCurrent && (invocationResult?.isCurrent ?? true),
      briefPause: _controller.briefPause,
      invitationPause: _controller.invitationPause,
      publish: (unit, mayPublish) async {
        final message = await database.publishConversationUtterance(
          ChatMessage(
            sessionId: sessionId,
            senderId: _controller.agentId,
            receiverId: 'user',
            content: unit.text,
            timestamp: DateTime.now().toUtc(),
            turnOrigin: origin.name,
            turnId: turnId,
            utteranceId: invocationResult?.utteranceId ?? unit.utteranceId,
            sequence: unit.sequence,
            deliveryStatus: 'published',
            attachments: invocationResult?.attachments ?? const [],
            appletReference: invocationResult?.appletReference,
            invocationReference:
                invocationResult?.invocationReference ??
                invocationNotice?.reference,
            idempotencyKey: invocationResult?.idempotencyKey,
          ),
          shouldContinue: () =>
              mayPublish() && (invocationResult?.isCurrent ?? true),
          publication: invocationResult,
        );
        if (message == null) return false;
        _published.add(message);
        return true;
      },
      onPublished: (unit) {
        if (!isCurrent) return;
        _responseTrace.recordPublished();
        _controller._notify(this, _published.last);
        if (isCurrent) onPublished?.call(unit);
      },
      speak: invocationResult?.summary.trim().isEmpty == true ? null : speak,
      onSpeechStarted: (unit) {
        _responseTrace.recordAudioStarted();
        onSpeechStarted?.call(unit);
      },
      onSpeechFinished: onSpeechFinished,
      onTextDelivery: onTextDelivery,
      seal: () async {
        // A native/player cancellation is a cancelled logical turn too, even
        // when the user did not press our Stop button. Mark it before observers
        // receive the sealed result; do not recursively await delivery.cancel.
        if (delivery.state == ConversationDeliveryState.cancelled &&
            !_cancelled.isCompleted) {
          _cancelled.complete();
          if (identical(_controller._active, this)) {
            await Future<void>.sync(_controller._stopOutput);
          }
        }
        await seal();
      },
      onStateChanged: (state) => TurnTrace.event(
        'conversation.delivery',
        details: 'turn=$turnId state=${state.name}',
      ),
    );
    _delivery = delivery;
    delivery.updateDraft(_draft);
    if (drafts != null) {
      await delivery.run(drafts);
    } else {
      await delivery.runStream(draftStream!);
    }
  }

  Future<void> cancel() {
    if (_cancellation != null) return _cancellation!;
    if (_finished) return Future<void>.value();
    // Publish before invoking an output hook that might request Stop again.
    final completion = Completer<void>();
    _cancellation = completion.future;
    final ownedOutput = identical(_controller._active, this);
    if (!_cancelled.isCompleted) _cancelled.complete();
    _finishInput();
    // Stop the captured output before giving the successor permission to run.
    final output = ownedOutput
        ? Future<void>.sync(_controller._stopOutput)
        : Future<void>.value();
    final publication = _delivery?.cancel() ?? seal();
    unawaited(
      Future.wait<void>([output, publication]).then(
        (_) => completion.complete(),
        onError: (Object error, StackTrace stackTrace) =>
            completion.completeError(error, stackTrace),
      ),
    );
    return completion.future;
  }

  Future<void> seal() => _seal ??= () async {
    _finishInput();
    await _admissionTail;
    _freezeInputs();
    if (userMessage != null) {
      await database.sealConversationTurn(sessionId: sessionId, turnId: turnId);
    }
    _controller._onClosed?.call(this);
  }();
}

/// Select whole logical turns, then spend a bounded prompt budget on them.
/// A row-limited query may begin in the middle of an older turn; drop that
/// incomplete first group rather than presenting its suffix as a full turn.
List<Message> conversationHistory(
  List<ChatMessage> messages, {
  int turnLimit = 8,
  int characterBudget = 6000,
}) {
  var candidates = messages;
  if (messages.isNotEmpty &&
      !messages.first.isUserMessage &&
      messages.first.turnId != null) {
    final firstTurn = messages.first.turnId;
    candidates = messages.skipWhile((m) => m.turnId == firstTurn).toList();
  }
  final selected = modelContextTail(candidates, limit: turnLimit);
  final groups = <List<ChatMessage>>[];
  for (final message in selected) {
    if (groups.isEmpty ||
        message.turnId == null ||
        groups.last.last.turnId != message.turnId ||
        groups.last.last.sessionId != message.sessionId) {
      groups.add([]);
    }
    groups.last.add(message);
  }
  final retained = <ChatMessage>[];
  var remaining = characterBudget;
  for (final group in groups.reversed) {
    final cost = group.fold<int>(0, (n, m) => n + m.modelContextText.length);
    if (cost > remaining) break;
    retained.insertAll(0, group);
    remaining -= cost;
  }
  return retained
      .map(
        (m) => m.isUserMessage
            ? Message.user(m.modelContextText)
            : Message.assistant(m.content),
      )
      .toList(growable: false);
}

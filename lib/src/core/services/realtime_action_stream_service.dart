import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/account_device_lease_coordinator.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/realtime_action_cursor_store.dart';
import 'package:maaso/src/core/services/realtime_session_client.dart';
import 'package:maaso/src/features/agent/application/action/action_contract_legacy_adapter.dart';
import 'package:maaso/src/features/agent/application/action/action_contract_v2_service.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_envelope.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_executor.dart';
import 'package:maaso/src/features/agent/application/action/production_action_definition_catalog.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';

typedef RealtimeEnvelopeExecutor =
    FutureOr<void> Function(AgentActionEnvelope envelope);
typedef RealtimeExecutionErrorHandler =
    FutureOr<void> Function(
      Object error,
      StackTrace stackTrace,
      AgentActionEnvelope envelope,
    );
typedef RealtimeStreamFailureHandler =
    void Function(Object error, StackTrace stackTrace);
typedef RealtimeReconnectDelay = Duration Function(int attempt);

final class RealtimeSseFrame {
  const RealtimeSseFrame({this.id, this.event, required this.data});

  final String? id;
  final String? event;
  final String data;
}

class RealtimeActionSseParser {
  RealtimeActionSseParser({
    this.maximumBufferCharacters = 256 * 1024,
    this.maximumEventCharacters = 64 * 1024,
  }) {
    if (maximumBufferCharacters < 1024 ||
        maximumEventCharacters < 1024 ||
        maximumEventCharacters > maximumBufferCharacters) {
      throw ArgumentError('Invalid realtime SSE parser limits');
    }
  }

  final int maximumBufferCharacters;
  final int maximumEventCharacters;
  String _buffer = '';

  List<RealtimeSseFrame> add(String chunk) {
    if (_buffer.length + chunk.length > maximumBufferCharacters) {
      throw const FormatException('realtime SSE buffer is too large');
    }
    _buffer += chunk;
    final frames = <RealtimeSseFrame>[];
    while (true) {
      final boundary = _eventBoundary(_buffer);
      if (boundary == null) break;
      final rawEvent = _buffer.substring(0, boundary.start);
      _buffer = _buffer.substring(boundary.end);
      if (rawEvent.length > maximumEventCharacters) {
        throw const FormatException('realtime SSE event is too large');
      }
      final frame = _parseFrame(rawEvent);
      if (frame != null) frames.add(frame);
    }
    return frames;
  }

  RealtimeSseFrame? _parseFrame(String rawEvent) {
    String? id;
    String? event;
    final dataLines = <String>[];
    for (final line in _splitSseLines(rawEvent)) {
      if (line.isEmpty || line.startsWith(':')) continue;
      final separator = line.indexOf(':');
      final field = separator < 0 ? line : line.substring(0, separator);
      var value = separator < 0 ? '' : line.substring(separator + 1);
      if (value.startsWith(' ')) value = value.substring(1);
      switch (field) {
        case 'id':
          if (id != null || value.contains('\u0000')) {
            throw const FormatException('realtime SSE id is invalid');
          }
          id = value;
        case 'event':
          if (event != null) {
            throw const FormatException(
              'realtime SSE event type is duplicated',
            );
          }
          event = value;
        case 'data':
          dataLines.add(value);
        default:
          // Standard SSE extensions such as retry are not authority-bearing.
          break;
      }
    }
    if (dataLines.isEmpty) return null;
    final data = dataLines.join('\n');
    if (data.length > maximumEventCharacters) {
      throw const FormatException('realtime SSE data is too large');
    }
    return RealtimeSseFrame(id: id, event: event, data: data);
  }

  static ({int start, int end})? _eventBoundary(String value) {
    var cursor = 0;
    while (cursor < value.length) {
      final first = _lineEndingLength(value, cursor);
      if (first == 0) {
        cursor += 1;
        continue;
      }
      final secondStart = cursor + first;
      final second = _lineEndingLength(value, secondStart);
      if (second > 0) {
        return (start: cursor, end: secondStart + second);
      }
      cursor = secondStart;
    }
    return null;
  }

  static int _lineEndingLength(String value, int offset) {
    if (offset >= value.length) return 0;
    final unit = value.codeUnitAt(offset);
    if (unit == 0x0A) return 1;
    if (unit != 0x0D) return 0;
    if (offset + 1 >= value.length) return 0;
    return value.codeUnitAt(offset + 1) == 0x0A ? 2 : 1;
  }

  static List<String> _splitSseLines(String value) =>
      value.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
}

final class RealtimeRuntimeActionEvent {
  const RealtimeRuntimeActionEvent({
    required this.eventId,
    required this.sequence,
    required this.leaseEpoch,
    required this.sessionId,
    required this.rtcGeneration,
    required this.envelope,
  });

  final String eventId;
  final int sequence;
  final int leaseEpoch;
  final String sessionId;
  final int rtcGeneration;
  final AgentActionEnvelope envelope;

  factory RealtimeRuntimeActionEvent.parse(RealtimeSseFrame frame) {
    final id = _positiveSequence(frame.id, 'SSE id');
    if (frame.event != 'realtime.action') {
      throw const FormatException('realtime SSE event type is invalid');
    }
    final decoded = jsonDecode(frame.data);
    if (decoded is! Map) {
      throw const FormatException('realtime action wrapper is not an object');
    }
    final wrapper = Map<String, Object?>.from(decoded);
    _exactKeys(wrapper, const <String>{
      'eventId',
      'sequence',
      'type',
      'leaseEpoch',
      'subjectType',
      'subjectId',
      'payload',
      'createdAt',
    }, 'realtime action wrapper');
    final sequence = _positiveSequence(wrapper['sequence'], 'sequence');
    if (sequence != id || wrapper['type'] != 'realtime.action') {
      throw const FormatException('realtime action identity is inconsistent');
    }
    if (wrapper['subjectType'] != 'realtime_session') {
      throw const FormatException('realtime action subject type is invalid');
    }
    final createdAt = wrapper['createdAt'];
    if (createdAt is! String || DateTime.tryParse(createdAt) == null) {
      throw const FormatException('realtime action createdAt is invalid');
    }
    final rawPayload = wrapper['payload'];
    if (rawPayload is! Map) {
      throw const FormatException('realtime action payload is not an object');
    }
    final payload = Map<String, Object?>.from(rawPayload);
    _exactKeys(payload, const <String>{
      'sessionId',
      'rtcGeneration',
      'envelope',
    }, 'realtime action payload');
    final rawEnvelope = payload['envelope'];
    if (rawEnvelope is! Map) {
      throw const FormatException('realtime action envelope is not an object');
    }
    final sessionId = _opaqueId(payload['sessionId'], 'payload sessionId');
    if (wrapper['subjectId'] != sessionId) {
      throw const FormatException('realtime action subject is inconsistent');
    }
    return RealtimeRuntimeActionEvent(
      eventId: _opaqueId(wrapper['eventId'], 'eventId'),
      sequence: sequence,
      leaseEpoch: _positiveSequence(wrapper['leaseEpoch'], 'leaseEpoch'),
      sessionId: sessionId,
      rtcGeneration: _positiveSequence(
        payload['rtcGeneration'],
        'rtcGeneration',
      ),
      envelope: AgentActionEnvelope.parse(jsonEncode(rawEnvelope)),
    );
  }
}

class RealtimeActionStreamService {
  RealtimeActionStreamService({
    required Uri baseUri,
    http.Client? httpClient,
    RealtimeEnvelopeExecutor? executeEnvelope,
    RealtimeAccessTokenProvider? accessTokenProvider,
    RealtimeActionCursorStore? cursorStore,
    RealtimeExecutionErrorHandler? onExecutionError,
    RealtimeStreamFailureHandler? onTerminalFailure,
    RealtimeReconnectDelay? reconnectDelay,
    ActionContractV2Service? actionContract,
    ProductionActionDefinitionCatalog? productionActionCatalog,
    bool requirePinnedActionContract = false,
    bool useAppServicesActionContractFallback = false,
    Duration requestTimeout = const Duration(seconds: 20),
    int maximumErrorResponseBytes = 64 * 1024,
  }) : _baseUri = requireRealtimeHttpsBaseUri(baseUri),
       _httpClient = httpClient ?? http.Client(),
       _ownsClient = httpClient == null,
       _executeEnvelope = executeEnvelope,
       _accessTokenProvider = accessTokenProvider,
       _cursorStore = cursorStore,
       _onExecutionError = onExecutionError,
       _onTerminalFailure = onTerminalFailure,
       _reconnectDelay = reconnectDelay ?? _defaultReconnectDelay,
       _actionContract = actionContract,
       _productionActionCatalog = productionActionCatalog,
       _requirePinnedActionContract = requirePinnedActionContract,
       _useAppServicesActionContractFallback =
           useAppServicesActionContractFallback,
       _requestTimeout = requestTimeout,
       _maximumErrorResponseBytes = maximumErrorResponseBytes {
    if (requestTimeout <= Duration.zero) {
      throw ArgumentError.value(requestTimeout, 'requestTimeout');
    }
    if (maximumErrorResponseBytes < 1024) {
      throw ArgumentError.value(
        maximumErrorResponseBytes,
        'maximumErrorResponseBytes',
      );
    }
  }

  final Uri _baseUri;
  final http.Client _httpClient;
  final bool _ownsClient;
  final RealtimeEnvelopeExecutor? _executeEnvelope;
  final RealtimeAccessTokenProvider? _accessTokenProvider;
  final RealtimeActionCursorStore? _cursorStore;
  final RealtimeExecutionErrorHandler? _onExecutionError;
  final RealtimeStreamFailureHandler? _onTerminalFailure;
  final RealtimeReconnectDelay _reconnectDelay;
  final ActionContractV2Service? _actionContract;
  final ProductionActionDefinitionCatalog? _productionActionCatalog;
  final bool _requirePinnedActionContract;
  final bool _useAppServicesActionContractFallback;
  final Duration _requestTimeout;
  final int _maximumErrorResponseBytes;

  StreamIterator<String>? _activeIterator;
  Future<void>? _connectionFuture;
  Future<void>? _disconnectFuture;
  Timer? _retryTimer;
  Completer<void>? _retryCompleter;
  Future<void>? _shutdownFuture;
  Object? _terminalFailure;
  int _connectionGeneration = 0;
  bool _retiring = false;
  bool _clientClosed = false;

  Object? get terminalFailure => _terminalFailure;

  Future<void> connect(
    RealtimeSession session, {
    AccountDeviceLeaseRequestAuthority? authority,
    String agentId = 'self',
    AppLocale? locale,
  }) async {
    _requireActive();
    await disconnect();
    _requireActive();
    _validateBinding(session, authority, agentId);

    final requestedLocale = locale ?? AgentPromptCatalog.currentLocale;
    final sessionLocale = AgentPromptCatalog.runWithLocale(
      requestedLocale,
      () => AgentPromptCatalog.currentLocale,
    );
    final generation = ++_connectionGeneration;
    _terminalFailure = null;
    late final _OpenedRealtimeStream opened;
    try {
      opened = await _openInitialStream(generation, session, authority);
    } catch (error, stackTrace) {
      if (error is RealtimeBackendException && error.isAuthorityFailure) {
        _onTerminalFailure?.call(error, stackTrace);
      }
      rethrow;
    }
    _requireConnectionCurrent(generation, authority);
    _connectionFuture = _runConnection(
      generation: generation,
      session: session,
      authority: authority,
      agentId: agentId,
      locale: sessionLocale,
      initial: opened,
    );
  }

  Future<void> disconnect() {
    _connectionGeneration += 1;
    _cancelReconnectDelay();
    final pending = _disconnectFuture;
    if (pending != null) return pending;
    late final Future<void> operation;
    operation = _disconnectOnce().whenComplete(() {
      if (identical(_disconnectFuture, operation)) {
        _disconnectFuture = null;
      }
    });
    _disconnectFuture = operation;
    return operation;
  }

  Future<void> _disconnectOnce() async {
    final iterator = _activeIterator;
    _activeIterator = null;
    await iterator?.cancel();
    final connection = _connectionFuture;
    await connection;
    if (identical(_connectionFuture, connection)) {
      _connectionFuture = null;
    }
  }

  void dispose() {
    unawaited(shutdown());
  }

  Future<void> shutdown() {
    _retiring = true;
    return _shutdownFuture ??= _shutdownOnce();
  }

  Future<void> _shutdownOnce() async {
    var completed = false;
    try {
      await disconnect();
      if (_ownsClient && !_clientClosed) {
        _httpClient.close();
        _clientClosed = true;
      }
      completed = true;
    } finally {
      if (!completed) _shutdownFuture = null;
    }
  }

  Future<_OpenedRealtimeStream> _openInitialStream(
    int generation,
    RealtimeSession session,
    AccountDeviceLeaseRequestAuthority? authority,
  ) async {
    var unauthorizedRetries = 0;
    while (true) {
      try {
        return await _openStream(generation, session, authority);
      } on RealtimeBackendException catch (error) {
        if (error.statusCode != 401 || unauthorizedRetries >= 1) rethrow;
        unauthorizedRetries += 1;
      }
    }
  }

  Future<_OpenedRealtimeStream> _openStream(
    int generation,
    RealtimeSession session,
    AccountDeviceLeaseRequestAuthority? authority,
  ) async {
    _requireConnectionCurrent(generation, authority);
    final expectedPath =
        '/v1/realtime/sessions/${Uri.encodeComponent(session.sessionId)}/actions';
    final destination = requireRealtimeSameOriginEndpoint(
      configuredBaseUri: _baseUri,
      destination: session.actionStreamUri,
      expectedPath: expectedPath,
    );

    var cursor = 0;
    if (session.isFenced) {
      final store = _cursorStore;
      if (store == null) {
        throw StateError('Fenced realtime stream has no cursor store');
      }
      cursor = await store.read(_cursorKey(session));
      _requireConnectionCurrent(generation, authority);
    }
    final token = (await _accessTokenProvider?.call())?.trim();
    _requireConnectionCurrent(generation, authority);

    final request = http.Request('GET', destination)
      ..followRedirects = false
      ..maxRedirects = 0;
    request.headers['accept'] = 'text/event-stream';
    request.headers['cache-control'] = 'no-store';
    if (token != null && token.isNotEmpty) {
      request.headers['authorization'] = 'Bearer $token';
    }
    if (session.isFenced) {
      request.headers['last-event-id'] = cursor.toString();
      // No await may be inserted between this destination-bound proof copy
      // and dispatch.
      authority!.authorizeRealtimeActionStream(
        request.headers,
        destination: destination,
        sessionId: session.sessionId,
      );
    }
    final response = await _httpClient.send(request).timeout(_requestTimeout);
    _requireConnectionCurrent(generation, authority);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final bytes = await readBoundedRealtimeResponse(
        response,
        maximumBytes: _maximumErrorResponseBytes,
        timeout: _requestTimeout,
      );
      _requireConnectionCurrent(generation, authority);
      throw realtimeBackendException(response, bytes);
    }
    final contentType = response.headers['content-type']
        ?.split(';')
        .first
        .trim()
        .toLowerCase();
    if (contentType != 'text/event-stream') {
      throw const FormatException(
        'realtime action stream content type is invalid',
      );
    }
    return _OpenedRealtimeStream(response: response, cursor: cursor);
  }

  Future<void> _runConnection({
    required int generation,
    required RealtimeSession session,
    required AccountDeviceLeaseRequestAuthority? authority,
    required String agentId,
    required AppLocale locale,
    required _OpenedRealtimeStream initial,
  }) async {
    var opened = initial;
    var attempt = 0;
    while (_isConnectionCurrent(generation)) {
      try {
        await _consumeStream(
          generation: generation,
          session: session,
          authority: authority,
          agentId: agentId,
          locale: locale,
          opened: opened,
        );
      } on _InactiveRealtimeConnection {
        return;
      } on _TerminalRealtimeStreamFailure catch (terminal) {
        _recordTerminalFailure(terminal.error, terminal.stackTrace);
        return;
      } catch (error, stackTrace) {
        if (!_isConnectionCurrent(generation)) return;
        if (error is RealtimeBackendException) {
          if (!error.isRetryableStream) {
            _recordTerminalFailure(error, stackTrace);
            return;
          }
        } else if (error is FormatException || error is StateError) {
          _recordTerminalFailure(error, stackTrace);
          return;
        }
      }

      if (!_isConnectionCurrent(generation)) return;
      final delayed = await _waitForReconnect(
        generation,
        _reconnectDelay(attempt),
      );
      if (!delayed) return;
      attempt = min(attempt + 1, 30);
      try {
        opened = await _openInitialStream(generation, session, authority);
      } on _InactiveRealtimeConnection {
        return;
      } catch (error, stackTrace) {
        if (!_isConnectionCurrent(generation)) return;
        if (error is RealtimeBackendException) {
          if (!error.isRetryableStream) {
            _recordTerminalFailure(error, stackTrace);
            return;
          }
        } else if (error is FormatException || error is StateError) {
          _recordTerminalFailure(error, stackTrace);
          return;
        }
        continue;
      }
    }
  }

  Future<void> _consumeStream({
    required int generation,
    required RealtimeSession session,
    required AccountDeviceLeaseRequestAuthority? authority,
    required String agentId,
    required AppLocale locale,
    required _OpenedRealtimeStream opened,
  }) async {
    final parser = RealtimeActionSseParser();
    final iterator = StreamIterator<String>(
      opened.response.stream.transform(utf8.decoder),
    );
    _activeIterator = iterator;
    var cursor = opened.cursor;
    var lastProcessedSequence = cursor;
    String? lastProcessedEventId;
    try {
      while (await iterator.moveNext()) {
        _requireConnectionCurrent(generation, authority);
        for (final frame in parser.add(iterator.current)) {
          _requireConnectionCurrent(generation, authority);
          if (!session.isFenced) {
            if (frame.id != null || frame.event != null) {
              throw const _TerminalRealtimeStreamFailure(
                FormatException(
                  'legacy realtime stream unexpectedly used durable metadata',
                ),
              );
            }
            late final AgentActionEnvelope envelope;
            try {
              envelope = AgentActionEnvelope.parse(frame.data);
            } catch (_, stackTrace) {
              throw _TerminalRealtimeStreamFailure(
                const FormatException('legacy realtime action is invalid'),
                stackTrace,
              );
            }
            await _executeOrStop(
              agentId,
              envelope,
              locale,
              callId: _newLegacyRealtimeCallId(),
              allowEnforcedExecution: false,
            );
            _requireConnectionCurrent(generation, authority);
            continue;
          }

          late final RealtimeRuntimeActionEvent event;
          try {
            event = RealtimeRuntimeActionEvent.parse(frame);
          } catch (_, stackTrace) {
            throw _TerminalRealtimeStreamFailure(
              const FormatException('realtime action event is invalid'),
              stackTrace,
            );
          }
          _validateRuntimeEvent(event, session, authority!);
          if (event.sequence <= cursor) {
            if (event.sequence > opened.cursor &&
                (event.sequence != lastProcessedSequence ||
                    event.eventId != lastProcessedEventId)) {
              throw const _TerminalRealtimeStreamFailure(
                FormatException('realtime action sequence is not increasing'),
              );
            }
            continue;
          }

          authority.requireCurrent();
          var enforced = false;
          await _executeOrStop(
            agentId,
            event.envelope,
            locale,
            callId: 'realtime:${session.sessionId}:${event.sequence}',
            allowEnforcedExecution: true,
            beforeEffect: (isEnforced) async {
              enforced = isEnforced;
              if (!isEnforced) return true;
              final claimed = await _cursorStore!.claim(
                _cursorKey(session),
                event.sequence,
              );
              _requireConnectionCurrent(generation, authority);
              authority.requireCurrent();
              return claimed;
            },
          );
          _requireConnectionCurrent(generation, authority);
          authority.requireCurrent();
          if (!enforced) {
            try {
              await _cursorStore!.commit(_cursorKey(session), event.sequence);
            } catch (error, stackTrace) {
              throw _TerminalRealtimeStreamFailure(error, stackTrace);
            }
            _requireConnectionCurrent(generation, authority);
            authority.requireCurrent();
          }
          cursor = event.sequence;
          lastProcessedSequence = event.sequence;
          lastProcessedEventId = event.eventId;
        }
      }
    } on _InactiveRealtimeConnection {
      rethrow;
    } on _TerminalRealtimeStreamFailure {
      rethrow;
    } on FormatException catch (error, stackTrace) {
      throw _TerminalRealtimeStreamFailure(error, stackTrace);
    } on StateError catch (error, stackTrace) {
      throw _TerminalRealtimeStreamFailure(
        StateError('realtime action execution failed'),
        stackTrace,
      );
    } finally {
      if (identical(_activeIterator, iterator)) _activeIterator = null;
      await iterator.cancel();
    }
  }

  Future<void> _executeOrStop(
    String agentId,
    AgentActionEnvelope envelope,
    AppLocale locale, {
    required String callId,
    required bool allowEnforcedExecution,
    Future<bool> Function(bool isEnforced)? beforeEffect,
  }) async {
    try {
      await _execute(
        agentId,
        envelope,
        locale,
        callId: callId,
        allowEnforcedExecution: allowEnforcedExecution,
        beforeEffect: beforeEffect,
      );
    } catch (error, stackTrace) {
      final handler = _onExecutionError;
      if (handler != null) {
        try {
          await handler(error, stackTrace, envelope);
        } catch (_) {
          // The original fixed failure remains authoritative.
        }
      }
      throw _TerminalRealtimeStreamFailure(error, stackTrace);
    }
  }

  Future<void> _execute(
    String agentId,
    AgentActionEnvelope envelope,
    AppLocale locale, {
    required String callId,
    required bool allowEnforcedExecution,
    Future<bool> Function(bool isEnforced)? beforeEffect,
  }) async {
    final useLegacyGlobalManager =
        _actionContract == null &&
        _productionActionCatalog == null &&
        _useAppServicesActionContractFallback &&
        appServices.isRegistered<SkillManager>();
    final skillManager = useLegacyGlobalManager
        ? appServices.find<SkillManager>()
        : SkillManager(
            actionContract: _actionContract,
            productionCatalog: _productionActionCatalog,
            actionContractAgentId: agentId,
            requirePinnedActionContract: _requirePinnedActionContract,
            useAppServicesActionContractFallback:
                _useAppServicesActionContractFallback,
          );
    final executor = AgentActionExecutor(
      agentId: agentId,
      skillManager: skillManager,
      locale: locale,
      actionContract: _actionContract,
      productionActionCatalog: _productionActionCatalog,
      requirePinnedActionContract: _requirePinnedActionContract,
      useAppServicesActionContractFallback:
          _useAppServicesActionContractFallback,
    );
    final prepared = await executor.prepareActionContract(
      envelope,
      channel: ActionContractChannel.realtime,
      callId: callId,
    );
    if (prepared?.isEnforced == true && !allowEnforcedExecution) {
      await prepared!.abandon(code: 'realtime_unfenced_enforce_unsupported');
      throw StateError('realtime unfenced enforce execution is unsupported');
    }
    late final bool proceed;
    try {
      proceed =
          beforeEffect == null ||
          await beforeEffect(prepared?.isEnforced == true);
    } catch (error, stackTrace) {
      if (prepared != null && !prepared.isClaimed) {
        try {
          await prepared.abandon(code: 'realtime_claim_unavailable');
        } on Object {
          // The original claim/authority failure remains authoritative.
        }
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
    if (!proceed) {
      if (prepared != null && !prepared.isClaimed) {
        await prepared.abandon(code: 'realtime_sequence_already_claimed');
      }
      return;
    }
    final injected = _executeEnvelope;
    if (injected != null) {
      if (prepared == null) {
        await AgentPromptCatalog.runWithLocale(
          locale,
          () => Future.sync(() => injected(envelope)),
        );
        return;
      }
      try {
        final contractResult = await prepared.executeLegacy(
          currentEnvelope: envelope,
          callback: () async {
            await AgentPromptCatalog.runWithLocale(
              locale,
              () => Future.sync(() => injected(envelope)),
            );
            return ActionContractLegacyResult(
              callerOutput: null,
              actionOutputs: List<Object?>.filled(
                prepared.actionOutputCount,
                const <String, Object?>{},
                growable: false,
              ),
            );
          },
        );
        final accepted =
            contractResult.status == ActionContractExecutionStatus.legacy ||
            (contractResult.status == ActionContractExecutionStatus.enforced &&
                contractResult.outcome?.isOk == true);
        if (!accepted) {
          throw StateError('realtime action contract rejected');
        }
        return;
      } finally {
        if (!prepared.isClaimed) {
          try {
            await prepared.abandon();
          } on Object {
            // The fixed realtime execution failure remains authoritative.
          }
        }
      }
    }
    final result = prepared == null
        ? await executor.execute(envelope)
        : await executor.executeAdmitted(envelope, prepared);
    if (!result.ok) {
      throw StateError('realtime action execution failed');
    }
  }

  Future<bool> _waitForReconnect(int generation, Duration delay) {
    if (!_isConnectionCurrent(generation)) return Future<bool>.value(false);
    final bounded = delay.isNegative
        ? Duration.zero
        : delay > const Duration(seconds: 30)
        ? const Duration(seconds: 30)
        : delay;
    final completer = Completer<void>();
    _retryCompleter = completer;
    _retryTimer = Timer(bounded, () {
      if (!completer.isCompleted) completer.complete();
    });
    return completer.future.then((_) => _isConnectionCurrent(generation));
  }

  void _cancelReconnectDelay() {
    _retryTimer?.cancel();
    _retryTimer = null;
    final completer = _retryCompleter;
    _retryCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  void _validateBinding(
    RealtimeSession session,
    AccountDeviceLeaseRequestAuthority? authority,
    String agentId,
  ) {
    final expectedPath =
        '/v1/realtime/sessions/${Uri.encodeComponent(session.sessionId)}/actions';
    requireRealtimeSameOriginEndpoint(
      configuredBaseUri: _baseUri,
      destination: session.actionStreamUri,
      expectedPath: expectedPath,
    );
    if (session.isFenced) {
      if (authority == null ||
          authority.agentId != agentId ||
          authority.leaseEpoch != session.leaseEpoch) {
        throw StateError(
          'Realtime stream authority does not match its session',
        );
      }
      authority.requireCurrent();
      if (_cursorStore == null) {
        throw StateError('Fenced realtime stream has no cursor store');
      }
    } else if (authority != null ||
        session.leaseEpoch != 0 ||
        session.rtcGeneration != 0) {
      throw StateError('Legacy realtime stream has mixed authority metadata');
    }
  }

  static void _validateRuntimeEvent(
    RealtimeRuntimeActionEvent event,
    RealtimeSession session,
    AccountDeviceLeaseRequestAuthority authority,
  ) {
    if (event.sessionId != session.sessionId ||
        event.leaseEpoch != session.leaseEpoch ||
        event.leaseEpoch != authority.leaseEpoch ||
        event.rtcGeneration != session.rtcGeneration) {
      throw const FormatException('realtime action authority binding mismatch');
    }
  }

  RealtimeActionCursorKey _cursorKey(RealtimeSession session) =>
      RealtimeActionCursorKey(
        sessionId: session.sessionId,
        leaseEpoch: session.leaseEpoch,
        rtcGeneration: session.rtcGeneration,
      );

  void _recordTerminalFailure(Object error, StackTrace stackTrace) {
    _terminalFailure = error;
    try {
      _onTerminalFailure?.call(error, stackTrace);
    } catch (_) {
      // A failure observer cannot reactivate this terminal connection.
    }
  }

  bool _isConnectionCurrent(int generation) =>
      !_retiring && !_clientClosed && generation == _connectionGeneration;

  void _requireConnectionCurrent(
    int generation,
    AccountDeviceLeaseRequestAuthority? authority,
  ) {
    if (!_isConnectionCurrent(generation)) {
      throw const _InactiveRealtimeConnection();
    }
    authority?.requireCurrent();
  }

  void _requireActive() {
    if (_retiring || _clientClosed) {
      throw StateError('action stream is retiring');
    }
  }

  static Duration _defaultReconnectDelay(int attempt) {
    final exponent = min(max(attempt, 0), 4);
    final baseMilliseconds = min(250 * (1 << exponent), 4000);
    final jitter = Random.secure().nextInt(101);
    return Duration(milliseconds: baseMilliseconds + jitter);
  }
}

final class _OpenedRealtimeStream {
  const _OpenedRealtimeStream({required this.response, required this.cursor});

  final http.StreamedResponse response;
  final int cursor;
}

final class _InactiveRealtimeConnection implements Exception {
  const _InactiveRealtimeConnection();
}

final class _TerminalRealtimeStreamFailure implements Exception {
  const _TerminalRealtimeStreamFailure(
    this.error, [
    this.stackTrace = StackTrace.empty,
  ]);

  final Object error;
  final StackTrace stackTrace;
}

void _exactKeys(
  Map<String, Object?> value,
  Set<String> expected,
  String label,
) {
  if (value.length != expected.length ||
      !value.keys.toSet().containsAll(expected)) {
    throw FormatException('$label fields are invalid');
  }
}

int _positiveSequence(Object? value, String field) {
  final parsed = value is String ? int.tryParse(value) : value;
  if (parsed is! int || parsed <= 0 || parsed > maxRealtimeJsonInteger) {
    throw FormatException('realtime $field is invalid');
  }
  return parsed;
}

String _opaqueId(Object? value, String field) {
  if (value is! String ||
      value != value.trim() ||
      value.length < 8 ||
      value.length > 64 ||
      !RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(value)) {
    throw FormatException('realtime $field is invalid');
  }
  return value;
}

String _newLegacyRealtimeCallId() {
  final random = Random.secure();
  final nonce = List<int>.generate(
    16,
    (_) => random.nextInt(256),
    growable: false,
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  return 'realtime:legacy:$nonce';
}

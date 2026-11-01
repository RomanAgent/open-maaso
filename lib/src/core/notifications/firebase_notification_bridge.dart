import 'dart:async';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';

import 'app_foreground_service.dart';
import 'firebase_bootstrap_service.dart';
import 'notification_delivery.dart';
import 'notification_models.dart';
import 'notification_preferences_service.dart';

class FirebaseNotificationBridge extends AppService {
  FirebaseNotificationBridge({
    FirebaseMessagingGateway? messaging,
    required NotificationPreferencesService preferences,
    required NotificationDelivery delivery,
    required AppForegroundService foreground,
    AppReactiveValue<MaasoAuthSession?>? session,
    AppReactiveValue<MaasoEnvironment>? environmentSignal,
    AuthSessionService? auth,
    AppEnvironmentService? environment,
    this.initialMessageTimeout = const Duration(seconds: 3),
    bool Function()? interactionConsumerReady,
    this.consumerReadyPollInterval = const Duration(milliseconds: 50),
  }) : _messaging = messaging,
       _preferences = preferences,
       _delivery = delivery,
       _foreground = foreground,
       _session = session ?? auth?.session,
       _environmentSignal = environmentSignal ?? environment?.environment,
       _interactionConsumerReady =
           interactionConsumerReady ?? _defaultInteractionConsumerReady;

  final FirebaseMessagingGateway? _messaging;
  final NotificationPreferencesService _preferences;
  final NotificationDelivery _delivery;
  final AppForegroundService _foreground;
  final Duration initialMessageTimeout;
  final Duration consumerReadyPollInterval;
  final bool Function() _interactionConsumerReady;
  AppReactiveValue<MaasoAuthSession?>? _session;
  AppReactiveValue<MaasoEnvironment>? _environmentSignal;

  final Set<String> _seenMessageIds = <String>{};
  final Set<_ForegroundDeliveryOperation> _foregroundDeliveries =
      <_ForegroundDeliveryOperation>{};
  final List<NotificationInteraction> _pendingInteractions =
      <NotificationInteraction>[];
  StreamSubscription<FirebasePushMessage>? _foregroundSubscription;
  StreamSubscription<FirebasePushMessage>? _openedSubscription;
  StreamSubscription<NotificationInteraction>? _localInteractionSubscription;
  Worker? _lifecycleWorker;
  Worker? _sessionScopeWorker;
  Worker? _environmentScopeWorker;
  Timer? _consumerReadyPoll;
  _NotificationAccountScope? _observedScope;
  _NotificationAccountScope? _deactivatedScope;
  Future<void>? _accountDrain;
  int _accountFence = 0;
  bool _bridgeActive = false;
  bool _closed = false;

  static bool _defaultInteractionConsumerReady() {
    return appServices.maybeFind<AgentRuntimeRegistry>()?.get('self') != null;
  }

  Future<FirebaseNotificationBridge> init() async {
    _session ??= appServices.find<AuthSessionService>().session;
    _environmentSignal ??= appServices
        .find<AppEnvironmentService>()
        .environment;
    _observedScope = _readActiveScope();
    _sessionScopeWorker = _session?.listen((_) => _handleAccountScopeChanged());
    _environmentScopeWorker = _environmentSignal?.listen(
      (_) => _handleAccountScopeChanged(),
    );
    _foregroundSubscription = _messaging?.foregroundMessages.listen(
      (message) => unawaited(_showForegroundMessage(message)),
      onError: (Object _, StackTrace _) {},
    );
    _openedSubscription = _messaging?.openedMessages.listen((message) {
      final interaction = _interactionForMessage(message);
      if (interaction != null) _routeInteraction(interaction);
    }, onError: (Object _, StackTrace _) {});
    _localInteractionSubscription = _delivery.interactions.listen(
      _routeInteraction,
    );
    _lifecycleWorker = _foreground.isForeground.listen((foreground) {
      if (foreground) _flushPending();
    });

    FirebasePushMessage? initialPush;
    try {
      initialPush = await _messaging?.getInitialMessage().timeout(
        initialMessageTimeout,
      );
    } catch (_) {
      initialPush = null;
    }
    if (initialPush != null) {
      final interaction = _interactionForMessage(initialPush);
      if (interaction != null) _pendingInteractions.add(interaction);
    }
    final initialLocal = _delivery.takeInitialInteraction();
    if (initialLocal != null) _pendingInteractions.add(initialLocal);
    return this;
  }

  void activateForegroundBridge() {
    _bridgeActive = true;
    _flushPending();
  }

  /// Fences the currently published account and removes every foreground
  /// delivery admitted by that account before returning.
  ///
  /// The service itself remains device-scoped. Once the auth/environment
  /// signals move away from the fenced scope, a later account can admit its
  /// own notifications with a new fence generation.
  Future<void> deactivateAccountAndDrain() {
    final inFlight = _accountDrain;
    if (inFlight != null) return inFlight;

    final scope = _readActiveScope();
    if (scope != null) _deactivatedScope = scope;
    _accountFence++;
    final admitted = _foregroundDeliveries
        .where(
          (operation) =>
              scope == null ||
              operation.scope == scope ||
              !_operationIsCurrent(operation),
        )
        .toList(growable: false);

    late final Future<void> tracked;
    tracked =
        Future.wait<void>(
          admitted.map(_cancelForegroundDelivery),
          eagerError: false,
        ).whenComplete(() {
          if (identical(_accountDrain, tracked)) _accountDrain = null;
        });
    _accountDrain = tracked;
    return tracked;
  }

  Future<void> _showForegroundMessage(FirebasePushMessage message) async {
    final now = DateTime.now();
    final preferences = _preferences.state.value;
    if (!preferences.canNotify || preferences.isQuietAt(now)) return;
    // Reconcile synchronously as well as through the reactive workers. This
    // closes the small window where a signal value has changed but its worker
    // callback has not yet advanced the fence generation.
    _handleAccountScopeChanged();
    final scope = _readActiveScope();
    if (scope == null ||
        scope == _deactivatedScope ||
        !_scopeClaimsMatchScope(message.data, scope)) {
      return;
    }
    final kind = _allowedRemoteKind(
      message.data['kind'],
      preferences: preferences,
    );
    if (kind == null) return;
    if (!_seenMessageIds.add(message.messageId)) return;
    if (_seenMessageIds.length > 128) {
      _seenMessageIds.remove(_seenMessageIds.first);
    }

    final notification = MaasoNotification(
      deliveryId: 'fcm:${message.messageId}',
      kind: kind,
      title: _safeText(message.title, fallback: 'Maaso'),
      body: _safeText(message.body, fallback: '你的 Agent 有一条新消息。'),
      prompt: _promptFor(kind),
      data: <String, Object?>{
        'messageId': message.messageId,
        'accountUuid': message.data['accountUuid'],
        'environmentKey': message.data['environmentKey'],
      },
    );
    final operation = _ForegroundDeliveryOperation(
      deliveryId: notification.deliveryId,
      scope: scope,
      fence: _accountFence,
    );
    _foregroundDeliveries.add(operation);
    try {
      await _delivery.show(notification);
      operation.showSucceeded = true;
    } catch (_) {
      // Delivery remains best effort; stream callbacks must never surface an
      // unhandled asynchronous exception into the app zone.
    } finally {
      operation.showSettled.complete();
      if (_operationIsCurrent(operation)) {
        if (!operation.showSucceeded) {
          _foregroundDeliveries.remove(operation);
        }
      } else {
        unawaited(
          _cancelForegroundDelivery(operation).catchError((Object _) {}),
        );
      }
    }
  }

  void _handleAccountScopeChanged() {
    final next = _readActiveScope();
    if (next == _observedScope) return;
    _observedScope = next;
    if (_deactivatedScope != null && next != _deactivatedScope) {
      _deactivatedScope = null;
    }
    _accountFence++;
    for (final operation in _foregroundDeliveries.toList(growable: false)) {
      if (_operationIsCurrent(operation)) continue;
      unawaited(_cancelForegroundDelivery(operation).catchError((Object _) {}));
    }
  }

  bool _operationIsCurrent(_ForegroundDeliveryOperation operation) {
    final scope = _readActiveScope();
    return !_closed &&
        operation.fence == _accountFence &&
        operation.scope == scope &&
        operation.scope != _deactivatedScope;
  }

  Future<void> _cancelForegroundDelivery(
    _ForegroundDeliveryOperation operation,
  ) {
    final inFlight = operation.cancellation;
    if (inFlight != null) return inFlight;

    late final Future<void> tracked;
    tracked = _cancelForegroundDeliveryOnce(operation).whenComplete(() {
      if (identical(operation.cancellation, tracked)) {
        operation.cancellation = null;
      }
    });
    operation.cancellation = tracked;
    return tracked;
  }

  Future<void> _cancelForegroundDeliveryOnce(
    _ForegroundDeliveryOperation operation,
  ) async {
    await operation.showSettled.future;
    await _delivery.cancel(operation.deliveryId);
    _foregroundDeliveries.remove(operation);
  }

  NotificationInteraction? _interactionForMessage(FirebasePushMessage message) {
    final preferences = _preferences.state.value;
    if (!preferences.canNotify || !_messageMatchesActiveScope(message)) {
      return null;
    }
    final kind = _allowedRemoteKind(
      message.data['kind'],
      preferences: preferences,
    );
    if (kind == null) return null;
    return NotificationInteraction(
      deliveryId: 'fcm:${message.messageId}',
      kind: kind,
      prompt: _promptFor(kind),
      data: <String, Object?>{
        'messageId': message.messageId,
        'accountUuid': message.data['accountUuid'],
        'environmentKey': message.data['environmentKey'],
      },
    );
  }

  void _routeInteraction(NotificationInteraction interaction) {
    if (!_scopeClaimsMatch(interaction.data)) return;
    if (!_canRouteInteraction) {
      _enqueuePending(interaction);
      return;
    }
    EventBus().fire(
      SystemStatusEvent(
        'notification_opened',
        payload: <String, Object?>{
          ...interaction.data,
          'deliveryId': interaction.deliveryId,
          'kind': interaction.kind.key,
          'prompt': interaction.kind == MaasoNotificationKind.scheduledTask
              ? _safePrompt(interaction.prompt)
              : _promptFor(interaction.kind),
          'source': 'notification_interaction',
        },
      ),
    );
  }

  void _flushPending() {
    if (!_bridgeActive || !_foreground.isForeground.value) return;
    if (!_interactionConsumerReady()) {
      _ensureConsumerReadyPoll();
      return;
    }
    _consumerReadyPoll?.cancel();
    _consumerReadyPoll = null;
    final pending = List<NotificationInteraction>.from(_pendingInteractions);
    _pendingInteractions.clear();
    for (final interaction in pending) {
      _routeInteraction(interaction);
    }
  }

  bool get _canRouteInteraction =>
      _bridgeActive &&
      _foreground.isForeground.value &&
      _interactionConsumerReady();

  void _enqueuePending(NotificationInteraction interaction) {
    _pendingInteractions.removeWhere(
      (pending) => pending.deliveryId == interaction.deliveryId,
    );
    _pendingInteractions.add(interaction);
    if (_pendingInteractions.length > 8) _pendingInteractions.removeAt(0);
    _ensureConsumerReadyPoll();
  }

  void _ensureConsumerReadyPoll() {
    if (_closed ||
        !_bridgeActive ||
        !_foreground.isForeground.value ||
        _pendingInteractions.isEmpty ||
        _consumerReadyPoll?.isActive == true) {
      return;
    }
    _consumerReadyPoll = Timer.periodic(consumerReadyPollInterval, (_) {
      if (_closed || _pendingInteractions.isEmpty) {
        _consumerReadyPoll?.cancel();
        _consumerReadyPoll = null;
        return;
      }
      if (_interactionConsumerReady()) _flushPending();
    });
  }

  MaasoNotificationKind? _allowedRemoteKind(
    Object? value, {
    required NotificationPreferences preferences,
  }) {
    if (value is! String ||
        !MaasoNotificationKind.values.any((kind) => kind.key == value)) {
      return null;
    }
    final kind = MaasoNotificationKind.fromKey(value);
    return switch (kind) {
      // Remote proactive greetings cannot currently share the durable local
      // delivery ledger. Rejecting them prevents category/budget bypass; the
      // local policy and OS scheduler remain the sole proactive producers.
      MaasoNotificationKind.morningGreeting ||
      MaasoNotificationKind.middayGreeting ||
      MaasoNotificationKind.eveningGreeting ||
      MaasoNotificationKind.randomCheckIn => null,
      MaasoNotificationKind.scheduledTask =>
        preferences.scheduledTasksEnabled ? kind : null,
      MaasoNotificationKind.remote => kind,
    };
  }

  bool _messageMatchesActiveScope(FirebasePushMessage message) {
    return _scopeClaimsMatch(message.data);
  }

  bool _scopeClaimsMatch(Map<String, Object?> data) {
    final scope = _readActiveScope();
    return scope != null && _scopeClaimsMatchScope(data, scope);
  }

  bool _scopeClaimsMatchScope(
    Map<String, Object?> data,
    _NotificationAccountScope scope,
  ) {
    final accountUuid = data['accountUuid'];
    final environmentKey = data['environmentKey'];
    if (accountUuid is! String || environmentKey is! String) return false;
    // Scope claims are canonical strings. Do not normalize attacker-controlled
    // values before comparison, otherwise malformed cross-scope payloads can
    // accidentally become valid.
    return accountUuid == accountUuid.trim() &&
        environmentKey == environmentKey.trim() &&
        accountUuid == scope.accountUuid &&
        environmentKey == scope.environmentKey;
  }

  _NotificationAccountScope? _readActiveScope() {
    final session = _session?.value;
    final environment = _environmentSignal?.value;
    final accountUuid = session?.accountUuid.trim() ?? '';
    if (session == null ||
        !session.isValid ||
        accountUuid.isEmpty ||
        environment == null) {
      return null;
    }
    return _NotificationAccountScope(
      accountUuid: accountUuid,
      environmentKey: environment.key,
    );
  }

  String _promptFor(MaasoNotificationKind kind) => switch (kind) {
    MaasoNotificationKind.morningGreeting => '用简短温暖的中文向用户道早安。',
    MaasoNotificationKind.middayGreeting => '用一句轻松的中文提醒用户午间休息。',
    MaasoNotificationKind.eveningGreeting => '用简短温柔的中文向用户问候晚上好。',
    MaasoNotificationKind.randomCheckIn => '用一句自然、低打扰的中文关心用户近况。',
    _ => '用户打开了一条 Agent 通知，简短自然地回应，不要猜测通知正文。',
  };

  String _safeText(String? value, {required String fallback}) {
    final normalized = value
        ?.replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (normalized == null || normalized.isEmpty) return fallback;
    return normalized.length <= 180 ? normalized : normalized.substring(0, 180);
  }

  String _safePrompt(String? value) {
    final normalized = value
        ?.replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (normalized == null || normalized.isEmpty) {
      return '用户打开了一个已安排的提醒，简短确认并询问是否需要继续。';
    }
    return normalized.length <= 500 ? normalized : normalized.substring(0, 500);
  }

  @override
  void onClose() {
    _closed = true;
    _accountFence++;
    _consumerReadyPoll?.cancel();
    unawaited(_foregroundSubscription?.cancel());
    unawaited(_openedSubscription?.cancel());
    unawaited(_localInteractionSubscription?.cancel());
    _lifecycleWorker?.dispose();
    _sessionScopeWorker?.dispose();
    _environmentScopeWorker?.dispose();
    for (final operation in _foregroundDeliveries.toList(growable: false)) {
      unawaited(_cancelForegroundDelivery(operation).catchError((Object _) {}));
    }
    super.onClose();
  }
}

final class _NotificationAccountScope {
  const _NotificationAccountScope({
    required this.accountUuid,
    required this.environmentKey,
  });

  final String accountUuid;
  final String environmentKey;

  @override
  bool operator ==(Object other) =>
      other is _NotificationAccountScope &&
      other.accountUuid == accountUuid &&
      other.environmentKey == environmentKey;

  @override
  int get hashCode => Object.hash(accountUuid, environmentKey);
}

final class _ForegroundDeliveryOperation {
  _ForegroundDeliveryOperation({
    required this.deliveryId,
    required this.scope,
    required this.fence,
  });

  final String deliveryId;
  final _NotificationAccountScope scope;
  final int fence;
  final Completer<void> showSettled = Completer<void>();
  bool showSucceeded = false;
  Future<void>? cancellation;
}

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/account_device_lease.dart';
import 'package:maaso/src/core/services/account_device_lease_transport.dart';
import 'package:maaso/src/core/services/account_runtime_discovery_service.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('starts from the atomic snapshot event sequence', () async {
    final gateway = _DiscoveryGateway()
      ..enqueueSnapshot(_snapshot(eventSequence: 41))
      ..enqueueEvents(_page(nextSequence: 41, highWaterSequence: 41));
    final timers = _ManualTimerFactory();
    final service = _service(gateway, timers);
    addTearDown(service.closeLifecycle);

    service.start(environment: MaasoEnvironment.test, accountUuid: 'account-a');

    expect(service.isObserving, isTrue);
    expect(service.snapshot, isNull);
    await _flushAsync();

    expect(service.snapshot?.eventSequence, 41);
    expect(gateway.snapshotCalls.single.environment, MaasoEnvironment.test);
    expect(gateway.snapshotCalls.single.accountUuid, 'account-a');
    expect(timers.active.single.delay, const Duration(seconds: 4));

    timers.fireNext();
    await _flushAsync();

    expect(gateway.eventCalls.single.afterSequence, 41);
  });

  test('persists server nextSequence across filtered internal rows', () async {
    final gateway = _DiscoveryGateway()
      ..enqueueSnapshot(_snapshot(eventSequence: 10))
      ..enqueueEvents(_page(nextSequence: 18, highWaterSequence: 18))
      ..enqueueEvents(_page(nextSequence: 18, highWaterSequence: 18));
    final timers = _ManualTimerFactory();
    final service = _service(gateway, timers);
    addTearDown(service.closeLifecycle);

    service.start(environment: MaasoEnvironment.test, accountUuid: 'account-a');
    await _flushAsync();

    timers.fireNext();
    await _flushAsync();
    timers.fireNext();
    await _flushAsync();

    expect(gateway.eventCalls.map((call) => call.afterSequence), <int>[10, 18]);
    expect(gateway.snapshotCalls, hasLength(1));
  });

  test('debounces lifecycle hints into one canonical reconciliation', () async {
    final gateway = _DiscoveryGateway()
      ..enqueueSnapshot(_snapshot(eventSequence: 10))
      ..enqueueEvents(
        _page(
          events: <AccountRuntimeLifecycleEvent>[
            _event(sequence: 11),
            _event(sequence: 12),
          ],
          nextSequence: 12,
          highWaterSequence: 13,
          hasMore: true,
        ),
      )
      ..enqueueEvents(
        _page(
          events: <AccountRuntimeLifecycleEvent>[_event(sequence: 13)],
          nextSequence: 13,
          highWaterSequence: 13,
        ),
      )
      ..enqueueSnapshot(_snapshot(eventSequence: 13));
    final timers = _ManualTimerFactory();
    final service = _service(gateway, timers);
    addTearDown(service.closeLifecycle);

    service.start(environment: MaasoEnvironment.test, accountUuid: 'account-a');
    await _flushAsync();
    timers.fireNext();
    await _flushAsync();

    expect(gateway.eventCalls.map((call) => call.afterSequence), <int>[10, 12]);
    expect(gateway.snapshotCalls, hasLength(2));
    expect(service.snapshot?.eventSequence, 13);
  });

  test('bounds hasMore draining within a single poll', () async {
    final gateway = _DiscoveryGateway()
      ..enqueueSnapshot(_snapshot(eventSequence: 1))
      ..enqueueEvents(
        _page(nextSequence: 2, highWaterSequence: 9, hasMore: true),
      )
      ..enqueueEvents(
        _page(nextSequence: 3, highWaterSequence: 9, hasMore: true),
      )
      ..enqueueEvents(_page(nextSequence: 9, highWaterSequence: 9));
    final timers = _ManualTimerFactory();
    final service = _service(gateway, timers, maximumPagesPerPoll: 2);
    addTearDown(service.closeLifecycle);

    service.start(environment: MaasoEnvironment.test, accountUuid: 'account-a');
    await _flushAsync();
    timers.fireNext();
    await _flushAsync();

    expect(gateway.eventCalls, hasLength(2));

    timers.fireNext();
    await _flushAsync();
    expect(gateway.eventCalls.last.afterSequence, 3);
  });

  test('resynchronizes the canonical snapshot after a 410 cursor', () async {
    final gateway = _DiscoveryGateway()
      ..enqueueSnapshot(_snapshot(eventSequence: 5))
      ..enqueueEventError(
        const AccountDeviceLeaseRequestException(
          statusCode: 410,
          code: 'RUNTIME_EVENT_CURSOR_EXPIRED',
        ),
      )
      ..enqueueSnapshot(_snapshot(eventSequence: 30))
      ..enqueueEvents(_page(nextSequence: 30, highWaterSequence: 30));
    final timers = _ManualTimerFactory();
    final service = _service(gateway, timers);
    addTearDown(service.closeLifecycle);

    service.start(environment: MaasoEnvironment.test, accountUuid: 'account-a');
    await _flushAsync();
    timers.fireNext();
    await _flushAsync();

    expect(gateway.snapshotCalls, hasLength(2));
    expect(service.snapshot?.eventSequence, 30);
    expect(service.lastError, isNull);

    timers.fireNext();
    await _flushAsync();
    expect(gateway.eventCalls.last.afterSequence, 30);
  });

  test('late account A event cannot replace account B state', () async {
    final lateAccountEvent = Completer<AccountRuntimeLifecycleEventPage>();
    final gateway = _DiscoveryGateway()
      ..enqueueSnapshot(
        _snapshot(
          eventSequence: 10,
          presences: <AccountDevicePresenceView>[
            _presence(installationId: 'install-a', runtimeInstanceId: 'run-a'),
          ],
        ),
      )
      ..enqueueEventFuture(lateAccountEvent.future)
      ..enqueueSnapshot(
        _snapshot(
          eventSequence: 20,
          presences: <AccountDevicePresenceView>[
            _presence(installationId: 'install-b', runtimeInstanceId: 'run-b'),
          ],
        ),
      );
    final timers = _ManualTimerFactory();
    final service = _service(gateway, timers);
    addTearDown(service.closeLifecycle);

    service.start(environment: MaasoEnvironment.test, accountUuid: 'account-a');
    await _flushAsync();
    timers.fireNext();
    await _flushAsync();

    service.start(
      environment: MaasoEnvironment.production,
      accountUuid: 'account-b',
    );
    await _flushAsync();
    expect(service.snapshot?.eventSequence, 20);

    lateAccountEvent.complete(
      _page(
        events: <AccountRuntimeLifecycleEvent>[_event(sequence: 11)],
        nextSequence: 11,
        highWaterSequence: 11,
      ),
    );
    await _flushAsync();

    expect(service.snapshot?.eventSequence, 20);
    expect(service.presences.single.installationId, 'install-b');
    expect(gateway.snapshotCalls, hasLength(2));
  });

  test('late account A snapshot cannot replace account B state', () async {
    final lateAccountSnapshot = Completer<AccountDevicePresenceListResult>();
    final gateway = _DiscoveryGateway()
      ..enqueueSnapshotFuture(lateAccountSnapshot.future)
      ..enqueueSnapshot(
        _snapshot(
          eventSequence: 20,
          presences: <AccountDevicePresenceView>[
            _presence(installationId: 'install-b', runtimeInstanceId: 'run-b'),
          ],
        ),
      );
    final timers = _ManualTimerFactory();
    final service = _service(gateway, timers);
    addTearDown(service.closeLifecycle);

    service.start(environment: MaasoEnvironment.test, accountUuid: 'account-a');
    service.start(
      environment: MaasoEnvironment.production,
      accountUuid: 'account-b',
    );
    await _flushAsync();
    expect(service.snapshot?.eventSequence, 20);

    lateAccountSnapshot.complete(
      _snapshot(
        eventSequence: 10,
        presences: <AccountDevicePresenceView>[
          _presence(installationId: 'install-a', runtimeInstanceId: 'run-a'),
        ],
      ),
    );
    await _flushAsync();

    expect(service.snapshot?.eventSequence, 20);
    expect(service.presences.single.installationId, 'install-b');
    expect(timers.active, hasLength(1));
  });

  test('stop fences a late event and clears account state', () async {
    final lateEvent = Completer<AccountRuntimeLifecycleEventPage>();
    final gateway = _DiscoveryGateway()
      ..enqueueSnapshot(_snapshot(eventSequence: 10))
      ..enqueueEventFuture(lateEvent.future);
    final timers = _ManualTimerFactory();
    final service = _service(gateway, timers);
    addTearDown(service.closeLifecycle);

    service.start(environment: MaasoEnvironment.test, accountUuid: 'account-a');
    await _flushAsync();
    timers.fireNext();
    await _flushAsync();

    service.stop();
    expect(service.isObserving, isFalse);
    expect(service.snapshot, isNull);
    expect(service.presences, isEmpty);

    lateEvent.complete(
      _page(
        events: <AccountRuntimeLifecycleEvent>[_event(sequence: 11)],
        nextSequence: 11,
        highWaterSequence: 11,
      ),
    );
    await _flushAsync();

    expect(service.snapshot, isNull);
    expect(gateway.snapshotCalls, hasLength(1));
    expect(timers.active, isEmpty);
  });

  test('temporary replay failure keeps the last canonical snapshot', () async {
    final gateway = _DiscoveryGateway()
      ..enqueueSnapshot(_snapshot(eventSequence: 7))
      ..enqueueEventError(StateError('temporary outage'))
      ..enqueueEvents(_page(nextSequence: 7, highWaterSequence: 7));
    final timers = _ManualTimerFactory();
    final service = _service(gateway, timers);
    addTearDown(service.closeLifecycle);

    service.start(environment: MaasoEnvironment.test, accountUuid: 'account-a');
    await _flushAsync();
    final beforeFailure = service.snapshot;

    timers.fireNext();
    await _flushAsync();

    expect(service.snapshot, same(beforeFailure));
    expect(service.lastError, isA<StateError>());

    timers.fireNext();
    await _flushAsync();
    expect(service.snapshot, same(beforeFailure));
    expect(service.lastError, isNull);
  });

  test('periodically reconciles even without lifecycle hints', () async {
    final gateway = _DiscoveryGateway()
      ..enqueueSnapshot(_snapshot(eventSequence: 7))
      ..enqueueEvents(_page(nextSequence: 7, highWaterSequence: 7))
      ..enqueueEvents(_page(nextSequence: 7, highWaterSequence: 7))
      ..enqueueSnapshot(_snapshot(eventSequence: 9));
    final timers = _ManualTimerFactory();
    final service = _service(gateway, timers, safetyReconcileEveryPolls: 2);
    addTearDown(service.closeLifecycle);

    service.start(environment: MaasoEnvironment.test, accountUuid: 'account-a');
    await _flushAsync();

    timers.fireNext();
    await _flushAsync();
    expect(gateway.snapshotCalls, hasLength(1));

    timers.fireNext();
    await _flushAsync();

    expect(gateway.snapshotCalls, hasLength(2));
    expect(service.snapshot?.eventSequence, 9);
  });

  test('failed hint reconciliation retries the canonical snapshot', () async {
    final gateway = _DiscoveryGateway()
      ..enqueueSnapshot(_snapshot(eventSequence: 7))
      ..enqueueEvents(
        _page(
          events: <AccountRuntimeLifecycleEvent>[_event(sequence: 8)],
          nextSequence: 8,
          highWaterSequence: 8,
        ),
      )
      ..enqueueSnapshotError(StateError('snapshot unavailable'))
      ..enqueueSnapshot(_snapshot(eventSequence: 12));
    final timers = _ManualTimerFactory();
    final service = _service(gateway, timers);
    addTearDown(service.closeLifecycle);

    service.start(environment: MaasoEnvironment.test, accountUuid: 'account-a');
    await _flushAsync();
    final beforeFailure = service.snapshot;

    timers.fireNext();
    await _flushAsync();

    expect(service.snapshot, same(beforeFailure));
    expect(service.lastError, isA<StateError>());
    expect(gateway.eventCalls, hasLength(1));

    timers.fireNext();
    await _flushAsync();

    expect(gateway.eventCalls, hasLength(1));
    expect(gateway.snapshotCalls, hasLength(3));
    expect(service.snapshot?.eventSequence, 12);
    expect(service.lastError, isNull);
  });

  test(
    'thisRuntimePresence requires both stable and runtime identity',
    () async {
      final exact = _presence(
        installationId: 'this-install',
        runtimeInstanceId: 'this-runtime',
        presenceSessionId: 'exact-session',
      );
      final gateway = _DiscoveryGateway()
        ..enqueueSnapshot(
          _snapshot(
            eventSequence: 1,
            presences: <AccountDevicePresenceView>[
              _presence(
                installationId: 'this-install',
                runtimeInstanceId: 'other-runtime',
                presenceSessionId: 'same-install',
              ),
              _presence(
                installationId: 'other-install',
                runtimeInstanceId: 'this-runtime',
                presenceSessionId: 'same-runtime',
              ),
              exact,
            ],
          ),
        );
      final service = _service(
        gateway,
        _ManualTimerFactory(),
        identity: const AccountDeviceIdentity(
          installationId: 'this-install',
          runtimeInstanceId: 'this-runtime',
        ),
      );
      addTearDown(service.closeLifecycle);

      service.start(
        environment: MaasoEnvironment.test,
        accountUuid: 'account-a',
      );
      await _flushAsync();

      expect(service.thisRuntimePresence?.presenceSessionId, 'exact-session');
    },
  );

  test('validates scope identity and closes pending observation', () async {
    expect(
      () => AccountRuntimeDiscoveryService(
        gateway: _DiscoveryGateway(),
        identity: const AccountDeviceIdentity(
          installationId: 'invalid id',
          runtimeInstanceId: 'runtime',
        ),
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => AccountRuntimeDiscoveryService(
        gateway: _DiscoveryGateway(),
        identity: const AccountDeviceIdentity(
          installationId: 'installation',
          runtimeInstanceId: ' runtime',
        ),
      ),
      throwsA(isA<FormatException>()),
    );

    final gateway = _DiscoveryGateway()
      ..enqueueSnapshot(_snapshot(eventSequence: 1));
    final timers = _ManualTimerFactory();
    final service = _service(gateway, timers);

    expect(
      () => service.start(
        environment: MaasoEnvironment.test,
        accountUuid: ' account-a',
      ),
      throwsA(isA<FormatException>()),
    );

    service.start(environment: MaasoEnvironment.test, accountUuid: 'account-a');
    await _flushAsync();
    final scheduled = timers.active.single;

    service.closeLifecycle();

    expect(service.isClosed, isTrue);
    expect(service.isObserving, isFalse);
    expect(service.snapshot, isNull);
    expect(scheduled.isActive, isFalse);
    expect(
      () => service.start(
        environment: MaasoEnvironment.test,
        accountUuid: 'account-a',
      ),
      throwsStateError,
    );
  });
}

AccountRuntimeDiscoveryService _service(
  _DiscoveryGateway gateway,
  _ManualTimerFactory timers, {
  AccountDeviceIdentity identity = const AccountDeviceIdentity(
    installationId: 'this-install',
    runtimeInstanceId: 'this-runtime',
  ),
  int maximumPagesPerPoll = 4,
  int safetyReconcileEveryPolls = 15,
}) => AccountRuntimeDiscoveryService(
  gateway: gateway,
  identity: identity,
  timerFactory: timers.create,
  maximumPagesPerPoll: maximumPagesPerPoll,
  safetyReconcileEveryPolls: safetyReconcileEveryPolls,
);

AccountDevicePresenceListResult _snapshot({
  required int eventSequence,
  List<AccountDevicePresenceView> presences =
      const <AccountDevicePresenceView>[],
}) => AccountDevicePresenceListResult(
  presences: presences,
  snapshotAt: DateTime.utc(2026, 8, 22, 12),
  eventSequence: eventSequence,
  truncated: false,
);

AccountDevicePresenceView _presence({
  required String installationId,
  required String runtimeInstanceId,
  String presenceSessionId = 'presence-session',
}) => AccountDevicePresenceView(
  agentId: 'self',
  installationId: installationId,
  runtimeInstanceId: runtimeInstanceId,
  presenceSessionId: presenceSessionId,
  deviceLabel: 'Maaso test device',
  platform: 'macos',
  appVersion: '1.0.0',
  openedAt: DateTime.utc(2026, 8, 22, 11),
  lastSeenAt: DateTime.utc(2026, 8, 22, 12),
  expiresAt: DateTime.utc(2026, 8, 22, 12, 5),
  isCurrentHolder: false,
);

AccountRuntimeLifecycleEvent _event({required int sequence}) =>
    AccountRuntimeLifecycleEvent(
      eventId: 'event-$sequence',
      sequence: sequence,
      type: 'presence.opened',
      leaseEpoch: 0,
      createdAt: DateTime.utc(2026, 8, 22, 12),
    );

AccountRuntimeLifecycleEventPage _page({
  List<AccountRuntimeLifecycleEvent> events =
      const <AccountRuntimeLifecycleEvent>[],
  required int nextSequence,
  required int highWaterSequence,
  bool hasMore = false,
}) => AccountRuntimeLifecycleEventPage(
  events: events,
  nextSequence: nextSequence,
  highWaterSequence: highWaterSequence,
  hasMore: hasMore,
);

Future<void> _flushAsync() async {
  for (var index = 0; index < 6; index++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _DiscoveryGateway implements AccountRuntimeDiscoveryGateway {
  final List<_SnapshotCall> snapshotCalls = <_SnapshotCall>[];
  final List<_EventCall> eventCalls = <_EventCall>[];
  final List<Future<AccountDevicePresenceListResult> Function()>
  _snapshotResponses = <Future<AccountDevicePresenceListResult> Function()>[];
  final List<Future<AccountRuntimeLifecycleEventPage> Function()>
  _eventResponses = <Future<AccountRuntimeLifecycleEventPage> Function()>[];

  void enqueueSnapshot(AccountDevicePresenceListResult response) {
    _snapshotResponses.add(() async => response);
  }

  void enqueueSnapshotFuture(Future<AccountDevicePresenceListResult> response) {
    _snapshotResponses.add(() => response);
  }

  void enqueueSnapshotError(Object error) {
    _snapshotResponses.add(() async => throw error);
  }

  void enqueueEvents(AccountRuntimeLifecycleEventPage response) {
    _eventResponses.add(() async => response);
  }

  void enqueueEventFuture(Future<AccountRuntimeLifecycleEventPage> response) {
    _eventResponses.add(() => response);
  }

  void enqueueEventError(Object error) {
    _eventResponses.add(() async => throw error);
  }

  @override
  Future<AccountDevicePresenceListResult> listActivePresences({
    required MaasoEnvironment environment,
    required String accountUuid,
    String agentId = 'self',
    int limit = 50,
  }) {
    snapshotCalls.add(_SnapshotCall(environment, accountUuid, agentId, limit));
    if (_snapshotResponses.isEmpty) {
      return Future<AccountDevicePresenceListResult>.error(
        StateError('No queued runtime presence snapshot'),
      );
    }
    return _snapshotResponses.removeAt(0)();
  }

  @override
  Future<AccountRuntimeLifecycleEventPage> replayRuntimeLifecycleEvents({
    required MaasoEnvironment environment,
    required String accountUuid,
    required int afterSequence,
    String agentId = 'self',
    int limit = 50,
  }) {
    eventCalls.add(
      _EventCall(environment, accountUuid, afterSequence, agentId, limit),
    );
    if (_eventResponses.isEmpty) {
      return Future<AccountRuntimeLifecycleEventPage>.error(
        StateError('No queued runtime lifecycle event page'),
      );
    }
    return _eventResponses.removeAt(0)();
  }
}

class _SnapshotCall {
  const _SnapshotCall(
    this.environment,
    this.accountUuid,
    this.agentId,
    this.limit,
  );

  final MaasoEnvironment environment;
  final String accountUuid;
  final String agentId;
  final int limit;
}

class _EventCall {
  const _EventCall(
    this.environment,
    this.accountUuid,
    this.afterSequence,
    this.agentId,
    this.limit,
  );

  final MaasoEnvironment environment;
  final String accountUuid;
  final int afterSequence;
  final String agentId;
  final int limit;
}

class _ManualTimerFactory {
  final List<_ManualTimer> timers = <_ManualTimer>[];

  List<_ManualTimer> get active =>
      timers.where((timer) => timer.isActive).toList(growable: false);

  Timer create(Duration delay, void Function() callback) {
    final timer = _ManualTimer(delay, callback);
    timers.add(timer);
    return timer;
  }

  void fireNext() {
    final activeTimers = active;
    if (activeTimers.isEmpty) throw StateError('No active discovery timer');
    activeTimers.first.fire();
  }
}

class _ManualTimer implements Timer {
  _ManualTimer(this.delay, this._callback);

  final Duration delay;
  final void Function() _callback;
  bool _active = true;
  int _tick = 0;

  @override
  bool get isActive => _active;

  @override
  int get tick => _tick;

  @override
  void cancel() => _active = false;

  void fire() {
    if (!_active) return;
    _active = false;
    _tick++;
    _callback();
  }
}

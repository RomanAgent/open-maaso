import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_services.dart';
import 'package:maaso/src/core/models/account_device_lease.dart';
import 'package:maaso/src/core/services/account_device_lease_coordinator.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';

import 'device_handoff_skill_fixture.dart';

/// Explicit shared-execution authority for focused Live host tests. The
/// coordinator acquires a real holder proof through the handoff fixture's
/// network boundary; Live admission still validates that proof and receipt.
class LiveSharedExecutionFixture {
  LiveSharedExecutionFixture._(this.sharedHandoff)
    : account = LiveSharedExecutionAccountSession(sharedHandoff.authority);

  final HandoffSkillFixture sharedHandoff;
  final LiveSharedExecutionAccountSession account;

  AccountDeviceLeaseCoordinator get authority => sharedHandoff.authority;

  static Future<LiveSharedExecutionFixture> install() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final fixture = LiveSharedExecutionFixture._(
      await HandoffSkillFixture.create(),
    );
    appServices.put<AccountDeviceLeaseCoordinator>(fixture.authority);
    appServices.put<AccountSessionLifecycleService>(fixture.account);
    return fixture;
  }

  void close() {
    account.closeLifecycle();
    sharedHandoff.dispose();
    if (authority.state != AccountDeviceLeaseCoordinatorState.closed) {
      authority.abandonLocalAuthority();
      authority.close();
    }
  }
}

class LiveSharedExecutionAccountSession
    implements AccountSessionLifecycleService {
  LiveSharedExecutionAccountSession(this.authority);

  final AccountDeviceLeaseCoordinator authority;
  @override
  AccountStorageScope? activeScope = AccountStorageScope(
    environmentKey: 'test',
    accountUuid: 'account-owner',
  );
  final Set<VoidCallback> _listeners = <VoidCallback>{};
  bool _closed = false;
  bool _mounted = true;
  bool _executionAllowed = true;

  @override
  bool get isClosed => _closed;

  @override
  bool get isMounted => !_closed && _mounted;

  set isMounted(bool value) => _mounted = value;

  @override
  bool get canChatLocally => isMounted;

  @override
  bool get canExecuteAgent =>
      isMounted && _executionAllowed && authority.canAdmitMutations;

  set canExecuteAgent(bool value) => _executionAllowed = value;

  @override
  int generation = 1;

  @override
  AccountDeviceLeaseReceipt? get activeDeviceLease => authority.currentReceipt;

  @override
  void addListener(VoidCallback listener) {
    if (!_closed) _listeners.add(listener);
  }

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  int get listenerCount => _listeners.length;

  void notifyListeners() {
    for (final listener in _listeners.toList()) {
      listener();
    }
  }

  @override
  void initializeLifecycle() {}

  @override
  void closeLifecycle() {
    if (_closed) return;
    _closed = true;
    notifyListeners();
    _listeners.clear();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

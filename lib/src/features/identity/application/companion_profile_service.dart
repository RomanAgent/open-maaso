import 'dart:convert';
import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import '../data/companion_profile_store.dart';
import '../domain/companion_profile.dart';

/// Account-owned private setup cache and CAS client. No memory store is read.
final class CompanionProfileService extends AppService
    with WidgetsBindingObserver {
  CompanionProfileService({
    required CompanionProfileGateway gateway,
    required CompanionProfileStore store,
    required bool Function() isCurrent,
    Future<void> Function(CompanionProfile)? projectProfile,
    void Function()? closeGateway,
  }) : _gateway = gateway,
       _store = store,
       _isCurrent = isCurrent,
       _projectProfile = projectProfile,
       _closeGateway = closeGateway,
       boundContextKey = gateway.requestContextKey;
  final CompanionProfileGateway _gateway;
  final CompanionProfileStore _store;
  final bool Function() _isCurrent;
  final Future<void> Function(CompanionProfile)? _projectProfile;
  final void Function()? _closeGateway;
  final String boundContextKey;
  final profile = Rxn<CompanionProfile>();
  final loading = false.obs;
  final saving = false.obs;
  final error = Rxn<CompanionProfileFailure>();
  bool _retired = false;
  bool _watching = false;
  Timer? _syncTimer;

  /// Only the small explicit account profile is refreshed. Memories are never read.
  void startSync() {
    if (_watching || !isCurrent) return;
    _watching = true;
    WidgetsBinding.instance.addObserver(this);
    _scheduleSync();
  }

  void _scheduleSync() {
    _syncTimer?.cancel();
    if (!isCurrent) return;
    unawaited(_refreshWhileActive());
    _syncTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(_refreshWhileActive());
    });
  }

  Future<void> _refreshWhileActive() async {
    if (!isCurrent || saving.value) return;
    try {
      await refresh();
    } catch (_) {
      /* retain the last verified profile */
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _scheduleSync();
    } else {
      _syncTimer?.cancel();
    }
  }

  Future<void>? _restore;
  Future<CompanionProfile>? _refresh;
  Future<void> _tail = Future.value();
  bool get isCurrent =>
      !_retired &&
      _isCurrent() &&
      boundContextKey == _gateway.requestContextKey;
  bool get onboardingCompleted => isCurrent && profile.value?.completed == true;
  void _check() {
    if (!isCurrent) {
      throw const CompanionProfileException(
        CompanionProfileFailure.contextChanged,
      );
    }
  }

  Future<void> restore() => _restore ??= _restoreLocal();
  Future<void> _restoreLocal() async {
    _check();
    try {
      final cached = await _store.read();
      _check();
      if (cached != null) await _apply(cached, persist: false);
    } on FormatException {
      _check();
      error.value = CompanionProfileFailure.invalidResponse;
    }
  }

  Future<CompanionProfile> refresh() {
    _check();
    return _refresh ??= _refreshRemote().whenComplete(() => _refresh = null);
  }

  Future<CompanionProfile> _refreshRemote() async {
    loading.value = true;
    try {
      await restore();
      _check();
      final next = await _gateway.fetch(expectedContextKey: boundContextKey);
      await _apply(next);
      _check();
      error.value = null;
      return profile.value!;
    } on CompanionProfileException catch (e) {
      if (isCurrent) error.value = e.failure;
      rethrow;
    } finally {
      if (isCurrent) loading.value = false;
    }
  }

  Future<CompanionProfile> save(CompanionProfile draft) async {
    _check();
    if (saving.value ||
        loading.value ||
        profile.value == null ||
        draft.version != profile.value!.version) {
      throw const CompanionProfileException(CompanionProfileFailure.conflict);
    }
    saving.value = true;
    try {
      final next = await _gateway.update(
        expectedContextKey: boundContextKey,
        profile: draft,
      );
      _check();
      if (next.version != draft.version + 1) {
        throw const CompanionProfileException(
          CompanionProfileFailure.invalidResponse,
        );
      }
      await _apply(next);
      _check();
      error.value = null;
      return profile.value!;
    } on CompanionProfileException catch (e) {
      if (isCurrent) error.value = e.failure;
      rethrow;
    } finally {
      if (isCurrent) saving.value = false;
    }
  }

  Future<void> _apply(CompanionProfile next, {bool persist = true}) {
    final task = _tail.then((_) async {
      _check();
      final previous = profile.value;
      if (previous != null && next.version < previous.version) return;
      if (previous != null &&
          next.version == previous.version &&
          jsonEncode(next.toJson()) != jsonEncode(previous.toJson())) {
        throw const CompanionProfileException(
          CompanionProfileFailure.invalidResponse,
        );
      }
      if (previous != null && next.version == previous.version) return;
      if (persist) await _store.write(next);
      _check();
      await _projectProfile?.call(next);
      _check();
      profile.value = next;
    });
    _tail = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return task;
  }

  Future<void> shutdown() async {
    _retire();
    await _tail;
  }

  void _retire() {
    if (_retired) return;
    _retired = true;
    _syncTimer?.cancel();
    if (_watching) WidgetsBinding.instance.removeObserver(this);
    _closeGateway?.call();
    profile.value = null;
    loading.value = false;
    saving.value = false;
  }

  @override
  void onClose() {
    _retire();
    super.onClose();
  }
}

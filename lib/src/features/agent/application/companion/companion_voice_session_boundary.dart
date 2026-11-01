import 'dart:async';
import 'dart:collection';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/companion/companion_voice_session_controller.dart';

/// Device-lifetime boundary between account teardown and companion voice.
///
/// Controllers are attached by [AppAgentShell]. Account teardown drains every
/// attached controller before disposing the account runtime registry or its
/// database, so a turn started under account A cannot finish against account
/// B's graph.
class CompanionVoiceSessionBoundary extends AppService {
  final Set<CompanionVoiceSessionController> _controllers =
      LinkedHashSet<CompanionVoiceSessionController>.identity();
  final Map<CompanionVoiceSessionController, Future<void>> _controllerDrains =
      LinkedHashMap<CompanionVoiceSessionController, Future<void>>.identity();
  Future<void>? _drainFuture;
  bool _retiring = false;
  bool _sealed = false;

  bool get hasAttachedControllers => _controllers.isNotEmpty;
  bool get isRetiring => _retiring;

  void attach(CompanionVoiceSessionController controller) {
    _controllers.add(controller);
    if (_retiring || _sealed) {
      unawaited(deactivateAndDrain().catchError((Object _, StackTrace _) {}));
    }
  }

  void detach(CompanionVoiceSessionController controller) {
    _controllers.remove(controller);
  }

  /// Opens the boundary for the next mounted account only after every late
  /// controller from the retiring account has also drained.
  Future<void> activateAccount() async {
    if (!_retiring) return;
    await deactivateAndDrain();
    _sealed = false;
    _retiring = false;
  }

  /// Final account-teardown seal. Main calls this immediately before deleting
  /// account services so a controller reattached after the initial parallel
  /// drain is also awaited. Controllers attached after the seal are retired
  /// synchronously on entry and cannot admit a new voice turn.
  Future<void> sealAndDrain() {
    _sealed = true;
    return deactivateAndDrain();
  }

  Future<void> deactivateAndDrain() {
    _retiring = true;
    for (final controller in _controllers.toList(growable: false)) {
      _launchControllerDrain(controller);
    }
    final inFlight = _drainFuture;
    if (inFlight != null) return inFlight;
    late final Future<void> draining;
    draining = _drainAllControllers().whenComplete(() {
      if (identical(_drainFuture, draining)) _drainFuture = null;
    });
    _drainFuture = draining;
    return draining;
  }

  void _launchControllerDrain(CompanionVoiceSessionController controller) {
    if (_controllerDrains.containsKey(controller)) return;
    late final Future<void> tracked;
    tracked = Future<void>.sync(controller.deactivateAndDrain)
        .then<void>((_) {
          _controllers.remove(controller);
        })
        .whenComplete(() {
          if (identical(_controllerDrains[controller], tracked)) {
            _controllerDrains.remove(controller);
          }
        });
    _controllerDrains[controller] = tracked;
  }

  Future<void> _drainAllControllers() async {
    final attempted = LinkedHashSet<CompanionVoiceSessionController>.identity();
    Object? firstError;
    StackTrace? firstStackTrace;

    while (true) {
      for (final controller in _controllers.toList(growable: false)) {
        if (attempted.add(controller)) _launchControllerDrain(controller);
      }
      final pending = _controllerDrains.values.toList(growable: false);
      if (pending.isEmpty) break;
      try {
        await Future.wait<void>(pending, eagerError: false);
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
  }

  @override
  void onClose() {
    unawaited(deactivateAndDrain().catchError((Object _, StackTrace _) {}));
    super.onClose();
  }
}

import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/widgets.dart';

/// Gives both native Quit and tray Quit the same account teardown boundary.
/// A lost network must not prevent an explicit application exit indefinitely;
/// the server lease deadline remains the fallback after the process exits.
final class DesktopApplicationExitCoordinator with WidgetsBindingObserver {
  DesktopApplicationExitCoordinator({
    required Future<void> Function() prepareForExit,
    Future<void> Function()? dismissUiBeforeExit,
    Duration dismissalTimeout = const Duration(milliseconds: 500),
    Duration timeout = const Duration(seconds: 5),
    void Function(Object error)? onPreparationFailure,
  }) : _prepareForExit = prepareForExit,
       _dismissUiBeforeExit = dismissUiBeforeExit,
       _dismissalTimeout = dismissalTimeout,
       _timeout = timeout,
       _onPreparationFailure = onPreparationFailure;

  final Future<void> Function() _prepareForExit;
  final Future<void> Function()? _dismissUiBeforeExit;
  final Duration _dismissalTimeout;
  final Duration _timeout;
  final void Function(Object error)? _onPreparationFailure;
  Future<void>? _preparation;

  /// Shared by native Quit and tray actions, including while teardown awaits.
  bool get isExiting => _preparation != null;

  Future<void> prepare() {
    final pending = _preparation;
    if (pending != null) return pending;
    // Publish the terminal intent before any callback can synchronously reenter.
    final completion = Completer<void>();
    _preparation = completion.future;
    _prepareOnce().then(completion.complete, onError: completion.completeError);
    return completion.future;
  }

  Future<void> _prepareOnce() async {
    final dismiss = _dismissUiBeforeExit;
    if (dismiss != null) {
      try {
        await dismiss().timeout(_dismissalTimeout);
      } catch (error) {
        _onPreparationFailure?.call(error);
      }
    }
    // Even a missing/unresponsive window bridge must not skip lease release.
    try {
      await _prepareForExit().timeout(_timeout);
    } catch (error) {
      _onPreparationFailure?.call(error);
    }
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    await prepare();
    return AppExitResponse.exit;
  }
}

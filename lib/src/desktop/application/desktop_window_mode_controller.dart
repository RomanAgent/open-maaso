import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:maaso/src/desktop/application/desktop_window_gateway.dart';

enum DesktopWindowMode { unsupported, pet, app }

/// Serializes transitions between the compact desktop pet and the full app.
class DesktopWindowModeController extends ChangeNotifier {
  DesktopWindowModeController({required DesktopWindowGateway gateway})
    : _gateway = gateway,
      _mode = gateway.isSupported
          ? DesktopWindowMode.app
          : DesktopWindowMode.unsupported;

  final DesktopWindowGateway _gateway;
  Future<void> _pendingTransition = Future<void>.value();
  DesktopWindowMode _mode;
  DesktopWindowBounds? _lastAppBounds;
  bool _isTransitioning = false;
  bool _petVisible = false;
  bool _authenticationRoute = false;

  DesktopWindowMode get mode => _mode;
  DesktopWindowBounds? get lastAppBounds => _lastAppBounds;
  bool get isTransitioning => _isTransitioning;
  bool get petVisible => _petVisible;
  bool get authenticationRoute => _authenticationRoute;
  bool get supportsIndependentPetWindow =>
      _gateway is IndependentDesktopPetWindowGateway &&
      (_gateway as IndependentDesktopPetWindowGateway)
          .supportsIndependentPetWindow;

  Future<void> enterPetMode() =>
      _enqueue(DesktopWindowMode.pet, petVisible: true);

  /// Presents an independent pet without hiding, focusing or resizing the app.
  /// If the app is already hidden, it remains hidden until explicitly opened.
  Future<void> showIndependentPet() => supportsIndependentPetWindow
      ? _enqueue(null, petVisible: true)
      : enterPetMode();

  Future<void> enterAppMode() => _enqueue(DesktopWindowMode.app);

  /// Reveals and focuses the normal app window even when its mode is already
  /// active. The independent pet remains visible beside it.
  Future<void> revealAppMode() =>
      _enqueue(DesktopWindowMode.app, forceGateway: true);

  /// Reveals the app without a pet, preserving the current route's window size.
  Future<void> enterAuthMode() =>
      _enqueue(DesktopWindowMode.app, petVisible: false, forceGateway: true);

  /// The router owns phone sizing. Tray actions can reveal the current window
  /// without ending the login presentation before the doorway animation ends.
  Future<void> setAuthenticationRoute(bool active) => _enqueue(
    DesktopWindowMode.app,
    petVisible: active ? false : null,
    authenticationRoute: active,
  );

  /// Hides only the independent pet. The tray can summon it again later.
  Future<void> hidePet() => _enqueue(null, petVisible: false);

  Future<void> startDragging() async {
    if (!_gateway.isSupported || _mode != DesktopWindowMode.pet) return;
    await _gateway.startDragging();
  }

  Future<void> _enqueue(
    DesktopWindowMode? target, {
    bool? petVisible,
    bool forceGateway = false,
    bool? authenticationRoute,
  }) {
    final result = _pendingTransition.then<void>(
      (_) => _transitionTo(
        // Null means preserve the state produced by earlier queued intents,
        // rather than restoring a snapshot taken before their native awaits.
        target ?? _mode,
        petVisible: petVisible ?? _petVisible,
        forceGateway: forceGateway,
        authenticationRoute: authenticationRoute ?? _authenticationRoute,
      ),
    );
    _pendingTransition = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> _transitionTo(
    DesktopWindowMode target, {
    required bool petVisible,
    required bool forceGateway,
    required bool authenticationRoute,
  }) async {
    if (!_gateway.isSupported || _mode == DesktopWindowMode.unsupported) {
      return;
    }

    final effectiveAuthenticationRoute =
        authenticationRoute && target == DesktopWindowMode.app;
    final effectivePetVisible = effectiveAuthenticationRoute
        ? false
        : supportsIndependentPetWindow
        ? petVisible
        : target == DesktopWindowMode.pet;
    if (target == _mode &&
        effectivePetVisible == _petVisible &&
        effectiveAuthenticationRoute == _authenticationRoute &&
        !forceGateway) {
      return;
    }

    final previousMode = _mode;
    final previousPetVisible = _petVisible;
    final previousAuthenticationRoute = _authenticationRoute;
    DesktopWindowBounds? capturedAppBounds;
    _setTransitioning(true);
    try {
      if (target != _mode ||
          effectiveAuthenticationRoute != _authenticationRoute ||
          forceGateway) {
        if (target == DesktopWindowMode.pet) {
          if (!previousAuthenticationRoute) {
            capturedAppBounds = await _gateway.readBounds();
          }
          await _gateway.enterPetMode();
        } else if (effectiveAuthenticationRoute) {
          if (!previousAuthenticationRoute &&
              previousMode == DesktopWindowMode.app) {
            capturedAppBounds = await _gateway.readBounds();
          }
          await _enterAuthenticationWindow();
        } else {
          await _gateway.enterAppMode(restoreBounds: _lastAppBounds);
        }
      }
      _lastAppBounds = capturedAppBounds ?? _lastAppBounds;
      _mode = target;
      _petVisible = effectivePetVisible;
      _authenticationRoute = effectiveAuthenticationRoute;
      if (previousMode != _mode ||
          previousPetVisible != _petVisible ||
          previousAuthenticationRoute != _authenticationRoute) {
        notifyListeners();
      }
    } catch (_) {
      await _restoreAfterFailure(
        previousMode,
        capturedAppBounds ?? _lastAppBounds,
        previousAuthenticationRoute,
      );
      rethrow;
    } finally {
      _setTransitioning(false);
    }
  }

  Future<void> _enterAuthenticationWindow() {
    final gateway = _gateway;
    if (gateway is DesktopAuthWindowGateway) {
      return (gateway as DesktopAuthWindowGateway).enterAuthMode();
    }
    return gateway.enterAppMode(restoreBounds: _lastAppBounds);
  }

  Future<void> _restoreAfterFailure(
    DesktopWindowMode previousMode,
    DesktopWindowBounds? previousAppBounds,
    bool previousAuthenticationRoute,
  ) async {
    try {
      switch (previousMode) {
        case DesktopWindowMode.app:
          if (previousAuthenticationRoute) {
            await _enterAuthenticationWindow();
          } else {
            await _gateway.enterAppMode(restoreBounds: previousAppBounds);
          }
        case DesktopWindowMode.pet:
          await _gateway.enterPetMode();
        case DesktopWindowMode.unsupported:
          break;
      }
    } catch (_) {
      // Preserve the original transition error. The native gateway logs its
      // own rollback failure and the controller remains in the prior mode.
    }
  }

  void _setTransitioning(bool value) {
    if (_isTransitioning == value) return;
    _isTransitioning = value;
    notifyListeners();
  }
}

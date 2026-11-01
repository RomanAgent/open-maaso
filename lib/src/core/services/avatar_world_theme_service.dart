import 'dart:async';

import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/core/services/theme_service.dart';

/// Keeps the active avatar world's lighting aligned with the resolved app
/// brightness, including the value selected by system appearance mode.
class AvatarWorldThemeService extends AppService {
  AvatarWorldThemeService({
    ThemeService? themeService,
    ActiveAvatarRuntime? avatarRuntime,
  }) : _themeService = themeService,
       _avatarRuntime = avatarRuntime;

  final ThemeService? _themeService;
  final ActiveAvatarRuntime? _avatarRuntime;
  late final Worker _brightnessWorker;

  ThemeService get _theme => _themeService ?? appServices.find<ThemeService>();

  ActiveAvatarRuntime get _avatars =>
      _avatarRuntime ?? appServices.find<ActiveAvatarRuntime>();

  @override
  void onInit() {
    super.onInit();
    _brightnessWorker = ever<Brightness>(
      _theme.brightness,
      (_) => unawaited(syncNow()),
    );
    unawaited(syncNow());
  }

  /// Sends the currently resolved brightness immediately.
  Future<void> syncNow() {
    final lighting = _theme.brightness.value == Brightness.dark
        ? AvatarWorldLighting.night
        : AvatarWorldLighting.day;
    return _avatars.current?.setWorldLighting(lighting) ?? Future.value();
  }

  @override
  void onClose() {
    _brightnessWorker.dispose();
    super.onClose();
  }
}

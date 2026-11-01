import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/foundation/app_localization.dart';
import 'package:maaso/src/desktop/application/companion_menu_catalog.dart';
import 'package:maaso/src/desktop/application/desktop_companion_tray_controller.dart';
import 'package:maaso/src/desktop/application/desktop_application_exit_coordinator.dart';

final class TrayManagerDesktopCompanionGateway
    with TrayListener, WindowListener
    implements DesktopCompanionTrayGateway {
  TrayManagerDesktopCompanionGateway({
    required DesktopApplicationExitCoordinator exitCoordinator,
  }) : _exitCoordinator = exitCoordinator;

  final DesktopApplicationExitCoordinator _exitCoordinator;
  static const String _showPetKey = 'show-pet';
  static const String _showAppKey = 'show-app';
  static const String _quitKey = 'quit';
  static const String _destinationKeyPrefix = 'destination:';
  static const String _iconPath = 'assets/brand/masso_launcher_foreground.png';
  static const String _macMenuBarIconPath =
      'assets/brand/masso_macos_status_icon.png';

  Future<void> Function()? _onIconActivated;
  Future<void> Function()? _onWindowCloseRequested;
  Future<void> Function(DesktopCompanionTrayCommand command)? _onCommand;
  bool _initialized = false;
  bool _quitting = false;

  @override
  Future<void> initialize({
    required Future<void> Function() onIconActivated,
    required Future<void> Function() onWindowCloseRequested,
    required Future<void> Function(DesktopCompanionTrayCommand command)
    onCommand,
  }) async {
    if (_initialized) return;
    _onIconActivated = onIconActivated;
    _onWindowCloseRequested = onWindowCloseRequested;
    _onCommand = onCommand;
    await windowManager.ensureInitialized();
    WidgetsBinding.instance.addObserver(_exitCoordinator);
    windowManager.addListener(this);
    trayManager.addListener(this);
    try {
      await windowManager.setPreventClose(true);
      // The dedicated template has a 36 px mark on a 40 px Retina canvas:
      // 20 pt image size gives an 18 pt mark without adaptive-icon padding.
      await trayManager.setIcon(
        Platform.isMacOS ? _macMenuBarIconPath : _iconPath,
        isTemplate: Platform.isMacOS,
        iconSize: 20,
      );
      await trayManager.setToolTip('Maaso');
      await trayManager.setContextMenu(
        Menu(
          items: <MenuItem>[
            MenuItem(
              key: _showPetKey,
              label: _text(zh: '显示桌宠', en: 'Show Desktop Pet'),
            ),
            MenuItem(
              key: _showAppKey,
              label: _text(zh: '打开完整应用', en: 'Open Full App'),
            ),
            MenuItem.separator(),
            for (final entry in CompanionMenuCatalog.preferredEntries)
              MenuItem(
                key: '$_destinationKeyPrefix${entry.destination.id}',
                label: entry.labelKey.isEmpty
                    ? entry.destination.title
                    : entry.labelKey.tr,
              ),
            MenuItem.separator(),
            MenuItem(
              key: _quitKey,
              label: _text(zh: '退出 Maaso', en: 'Quit Maaso'),
            ),
          ],
        ),
      );
      _initialized = true;
    } catch (_) {
      WidgetsBinding.instance.removeObserver(_exitCoordinator);
      windowManager.removeListener(this);
      trayManager.removeListener(this);
      rethrow;
    }
  }

  @override
  Future<void> showAndFocus() async {
    if (_exitCoordinator.isExiting) return;
    await windowManager.show();
    if (_exitCoordinator.isExiting) return;
    await windowManager.focus();
  }

  @override
  Future<void> hide() => windowManager.hide();

  @override
  Future<void> quit() async {
    if (_quitting) return;
    _quitting = true;
    await _exitCoordinator.prepare();
    await windowManager.setPreventClose(false);
    await trayManager.destroy();
    await windowManager.destroy();
  }

  @override
  Future<void> dispose() async {
    WidgetsBinding.instance.removeObserver(_exitCoordinator);
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    _onIconActivated = null;
    _onWindowCloseRequested = null;
    _onCommand = null;
    if (!_initialized || _quitting) return;
    _initialized = false;
    await windowManager.setPreventClose(false);
    await trayManager.destroy();
  }

  @override
  void onWindowClose() {
    if (!_exitCoordinator.isExiting) _run(_onWindowCloseRequested);
  }

  @override
  void onTrayIconMouseDown() {
    if (!_exitCoordinator.isExiting) _run(_onIconActivated);
  }

  @override
  void onTrayIconRightMouseDown() {
    if (_exitCoordinator.isExiting) return;
    unawaited(
      trayManager.popUpContextMenu().catchError((Object _, StackTrace _) {}),
    );
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (_exitCoordinator.isExiting) return;
    final command = switch (menuItem.key) {
      _showPetKey => DesktopCompanionTrayCommand.showPet,
      _showAppKey => DesktopCompanionTrayCommand.showApp,
      _quitKey => DesktopCompanionTrayCommand.quit,
      final key when key?.startsWith(_destinationKeyPrefix) == true =>
        _destinationCommand(key!.substring(_destinationKeyPrefix.length)),
      _ => null,
    };
    if (command == null) return;
    final callback = _onCommand;
    if (callback == null) return;
    unawaited(callback(command).catchError((Object _, StackTrace _) {}));
  }

  static void _run(Future<void> Function()? callback) {
    if (callback == null) return;
    unawaited(callback().catchError((Object _, StackTrace _) {}));
  }

  static DesktopCompanionTrayCommand? _destinationCommand(String id) =>
      switch (id) {
        'world' => DesktopCompanionTrayCommand.openWorld,
        'chat' => DesktopCompanionTrayCommand.openChat,
        'skills' => DesktopCompanionTrayCommand.openSkills,
        'widgets_hub' => DesktopCompanionTrayCommand.openWidgetsHub,
        'moments' => DesktopCompanionTrayCommand.openMoments,
        'settings' => DesktopCompanionTrayCommand.openSettings,
        _ => null,
      };

  static String _text({required String zh, required String en}) =>
      AppLocalization.locale.languageCode == 'zh' ? zh : en;
}

import 'package:maaso/src/core/foundation/app_navigation.dart';
import 'package:maaso/src/desktop/application/companion_menu_catalog.dart';
import 'package:maaso/src/desktop/application/desktop_window_mode_controller.dart';

enum DesktopCompanionTrayCommand {
  showPet,
  showApp,
  openWorld,
  openChat,
  openSkills,
  openWidgetsHub,
  openMoments,
  openSettings,
  quit,
}

abstract interface class DesktopCompanionTrayGateway {
  Future<void> initialize({
    required Future<void> Function() onIconActivated,
    required Future<void> Function() onWindowCloseRequested,
    required Future<void> Function(DesktopCompanionTrayCommand command)
    onCommand,
  });

  Future<void> showAndFocus();

  Future<void> hide();

  Future<void> quit();

  Future<void> dispose();
}

final class UnsupportedDesktopCompanionTrayGateway
    implements DesktopCompanionTrayGateway {
  const UnsupportedDesktopCompanionTrayGateway();

  @override
  Future<void> initialize({
    required Future<void> Function() onIconActivated,
    required Future<void> Function() onWindowCloseRequested,
    required Future<void> Function(DesktopCompanionTrayCommand command)
    onCommand,
  }) async {}

  @override
  Future<void> showAndFocus() async {}

  @override
  Future<void> hide() async {}

  @override
  Future<void> quit() async {}

  @override
  Future<void> dispose() async {}
}

/// Owns close-to-pet and tray command semantics without importing native APIs.
final class DesktopCompanionTrayController {
  DesktopCompanionTrayController({
    required DesktopWindowModeController windowController,
    required DesktopCompanionTrayGateway gateway,
    bool Function()? canShowPet,
    Future<void> Function()? requestShowPet,
  }) : _windowController = windowController,
       _gateway = gateway,
       _canShowPet = canShowPet ?? _alwaysAllowPet,
       _requestShowPet = requestShowPet ?? windowController.enterPetMode;

  final DesktopWindowModeController _windowController;
  final DesktopCompanionTrayGateway _gateway;
  final bool Function() _canShowPet;
  final Future<void> Function() _requestShowPet;
  bool _initialized = false;
  bool _disposed = false;

  Future<void> initialize() async {
    if (_initialized || _disposed) return;
    _initialized = true;
    try {
      await _gateway.initialize(
        onIconActivated: handleIconActivated,
        onWindowCloseRequested: handleWindowCloseRequested,
        onCommand: handleCommand,
      );
    } catch (_) {
      _initialized = false;
      rethrow;
    }
  }

  Future<void> handleIconActivated() async {
    if (!_canShowPet()) {
      await _windowController.enterAuthMode();
      await _gateway.showAndFocus();
      return;
    }
    if (_windowController.supportsIndependentPetWindow) {
      await _requestShowPet();
      return;
    }
    await _gateway.showAndFocus();
  }

  Future<void> handleWindowCloseRequested() async {
    if (_disposed) return;
    if (_windowController.supportsIndependentPetWindow) {
      // Closing chat is independent of renderer readiness and avatar location.
      // Never summon/recover a pet as a prerequisite for hiding this window.
      await _gateway.hide();
      return;
    }
    if (!_canShowPet()) {
      await _windowController.enterAuthMode();
      await _gateway.showAndFocus();
      return;
    }
    if (_windowController.mode == DesktopWindowMode.app) {
      await _requestShowPet();
      return;
    }
    await _gateway.hide();
  }

  Future<void> handleCommand(DesktopCompanionTrayCommand command) async {
    if (_disposed) return;
    switch (command) {
      case DesktopCompanionTrayCommand.showPet:
        if (!_canShowPet()) {
          await _windowController.enterAuthMode();
          await _gateway.showAndFocus();
          return;
        }
        await _requestShowPet();
        if (!_windowController.supportsIndependentPetWindow) {
          await _gateway.showAndFocus();
        }
      case DesktopCompanionTrayCommand.showApp:
        await _windowController.enterAppMode();
        await _gateway.showAndFocus();
      case DesktopCompanionTrayCommand.openWorld:
      case DesktopCompanionTrayCommand.openChat:
      case DesktopCompanionTrayCommand.openSkills:
      case DesktopCompanionTrayCommand.openWidgetsHub:
      case DesktopCompanionTrayCommand.openMoments:
      case DesktopCompanionTrayCommand.openSettings:
        await _windowController.enterAppMode();
        await _gateway.showAndFocus();
        final destinationId = switch (command) {
          DesktopCompanionTrayCommand.openWorld => 'world',
          DesktopCompanionTrayCommand.openChat => 'chat',
          DesktopCompanionTrayCommand.openSkills => 'skills',
          DesktopCompanionTrayCommand.openWidgetsHub => 'widgets_hub',
          DesktopCompanionTrayCommand.openMoments => 'moments',
          DesktopCompanionTrayCommand.openSettings => 'settings',
          _ => '',
        };
        if (appNavigation.isConfigured) {
          final entry = CompanionMenuCatalog.entries.singleWhere(
            (candidate) => candidate.destination.id == destinationId,
          );
          appNavigation.go(entry.destination.route);
        }
      case DesktopCompanionTrayCommand.quit:
        await _gateway.quit();
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _gateway.dispose();
  }

  static bool _alwaysAllowPet() => true;
}

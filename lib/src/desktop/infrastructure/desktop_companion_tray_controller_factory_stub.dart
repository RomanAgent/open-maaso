import 'package:maaso/src/desktop/application/desktop_companion_tray_controller.dart';
import 'package:maaso/src/desktop/application/desktop_window_mode_controller.dart';

DesktopCompanionTrayController createPlatformDesktopCompanionTrayController(
  DesktopWindowModeController windowController, {
  bool Function()? canShowPet,
  Future<void> Function()? requestShowPet,
}) => DesktopCompanionTrayController(
  windowController: windowController,
  gateway: const UnsupportedDesktopCompanionTrayGateway(),
  canShowPet: canShowPet,
  requestShowPet: requestShowPet,
);

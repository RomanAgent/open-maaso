import 'package:maaso/src/desktop/application/desktop_companion_tray_controller.dart';
import 'package:maaso/src/desktop/application/desktop_window_mode_controller.dart';
import 'package:maaso/src/desktop/infrastructure/desktop_companion_tray_controller_factory_stub.dart'
    if (dart.library.io) 'package:maaso/src/desktop/infrastructure/desktop_companion_tray_controller_factory_io.dart';

DesktopCompanionTrayController createDesktopCompanionTrayController(
  DesktopWindowModeController windowController, {
  bool Function()? canShowPet,
  Future<void> Function()? requestShowPet,
}) => createPlatformDesktopCompanionTrayController(
  windowController,
  canShowPet: canShowPet,
  requestShowPet: requestShowPet,
);

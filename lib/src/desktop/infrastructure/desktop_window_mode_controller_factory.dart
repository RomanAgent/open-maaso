import 'package:maaso/src/desktop/application/desktop_window_mode_controller.dart';
import 'package:maaso/src/desktop/infrastructure/desktop_window_mode_controller_factory_stub.dart'
    if (dart.library.io) 'package:maaso/src/desktop/infrastructure/desktop_window_mode_controller_factory_io.dart';

DesktopWindowModeController createDesktopWindowModeController() =>
    createPlatformDesktopWindowModeController();

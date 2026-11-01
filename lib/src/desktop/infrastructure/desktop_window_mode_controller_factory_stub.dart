import 'package:maaso/src/desktop/application/desktop_window_gateway.dart';
import 'package:maaso/src/desktop/application/desktop_window_mode_controller.dart';

DesktopWindowModeController createPlatformDesktopWindowModeController() =>
    DesktopWindowModeController(
      gateway: const UnsupportedDesktopWindowGateway(),
    );

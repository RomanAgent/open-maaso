import 'dart:io';

import 'package:maaso/src/desktop/application/desktop_window_gateway.dart';
import 'package:maaso/src/desktop/application/desktop_window_mode_controller.dart';
import 'package:maaso/src/desktop/infrastructure/window_manager_desktop_window_gateway.dart';

DesktopWindowModeController createPlatformDesktopWindowModeController() {
  final isFlutterTest =
      Platform.environment.containsKey('FLUTTER_TEST') &&
      Platform.environment['FLUTTER_TEST'] != 'false';
  final gateway = !isFlutterTest && (Platform.isMacOS || Platform.isWindows)
      ? const WindowManagerDesktopWindowGateway()
      : const UnsupportedDesktopWindowGateway();
  return DesktopWindowModeController(gateway: gateway);
}

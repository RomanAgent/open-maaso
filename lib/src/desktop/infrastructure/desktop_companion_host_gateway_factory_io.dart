import 'dart:io';

import 'package:maaso/src/desktop/application/desktop_companion_host_gateway.dart';
import 'package:maaso/src/desktop/infrastructure/method_channel_macos_desktop_companion_host_gateway.dart';

DesktopCompanionHostGateway createPlatformDesktopCompanionHostGateway() {
  final isFlutterTest =
      Platform.environment.containsKey('FLUTTER_TEST') &&
      Platform.environment['FLUTTER_TEST'] != 'false';
  if (!isFlutterTest && (Platform.isMacOS || Platform.isWindows)) {
    // Both native runners implement the same semantic companion channel.
    // Keep one Dart owner so Agent reply/menu/gaze state cannot diverge by OS.
    return MethodChannelMacOSDesktopCompanionHostGateway();
  }
  return const UnsupportedDesktopCompanionHostGateway();
}

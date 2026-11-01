import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';
import 'package:maaso/src/desktop/application/desktop_application_exit_coordinator.dart';
import 'package:maaso/src/desktop/application/desktop_companion_tray_controller.dart';
import 'package:maaso/src/desktop/application/desktop_window_mode_controller.dart';
import 'package:maaso/src/desktop/infrastructure/tray_manager_desktop_companion_gateway.dart';

DesktopCompanionTrayController createPlatformDesktopCompanionTrayController(
  DesktopWindowModeController windowController, {
  bool Function()? canShowPet,
  Future<void> Function()? requestShowPet,
}) {
  final isFlutterTest =
      Platform.environment.containsKey('FLUTTER_TEST') &&
      Platform.environment['FLUTTER_TEST'] != 'false';
  final gateway = !isFlutterTest && (Platform.isMacOS || Platform.isWindows)
      ? TrayManagerDesktopCompanionGateway(
          exitCoordinator: DesktopApplicationExitCoordinator(
            dismissUiBeforeExit: () async {
              if (Platform.isMacOS) {
                await const MethodChannel(
                  'maaso/application_exit',
                ).invokeMethod<void>('beginExit');
              } else {
                await windowManager.hide();
              }
            },
            prepareForExit: () async {
              await appServices
                  .maybeFind<AccountSessionLifecycleService>()
                  ?.prepareForApplicationExit();
            },
            onPreparationFailure: (error) => debugPrint(
              '[AvatarPresence] exit_cleanup=${error.runtimeType}',
            ),
          ),
        )
      : const UnsupportedDesktopCompanionTrayGateway();
  return DesktopCompanionTrayController(
    windowController: windowController,
    gateway: gateway,
    canShowPet: canShowPet,
    requestShowPet: requestShowPet,
  );
}

import 'package:maaso/src/desktop/application/desktop_companion_host_gateway.dart';
import 'package:maaso/src/desktop/infrastructure/desktop_companion_host_gateway_factory_stub.dart'
    if (dart.library.io) 'package:maaso/src/desktop/infrastructure/desktop_companion_host_gateway_factory_io.dart';

DesktopCompanionHostGateway createDesktopCompanionHostGateway() =>
    createPlatformDesktopCompanionHostGateway();

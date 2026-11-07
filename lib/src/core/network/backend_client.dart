import 'package:http/http.dart' as http;
import 'package:maaso/src/core/foundation/app_framework.dart';

/// Installed only by the standalone edition. Backend DTO clients keep explicit
/// test injection and the normal runtime retains its platform HTTP transport.
final class MaasoBackendClientFactory {
  const MaasoBackendClientFactory(this.create);
  final http.Client Function() create;
}

http.Client createMaasoBackendClient() =>
    appServices.maybeFind<MaasoBackendClientFactory>()?.create() ??
    http.Client();

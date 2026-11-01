import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/desktop_local_asr_pack_runtime_contract.dart';
import 'package:maaso/src/core/services/desktop_local_asr_service.dart';

DesktopLocalAsrRecognizerFactory createDesktopLocalAsrRecognizerFactory({
  required AppPlatformCapabilities platformCapabilities,
  required DesktopLocalAsrPackRuntime packRuntime,
  required DesktopLocalAsrMountFence isCurrentMount,
  int numThreads = 2,
}) => const UnsupportedDesktopLocalAsrRecognizerFactory();

final class UnsupportedDesktopLocalAsrRecognizerFactory
    implements DesktopLocalAsrRecognizerFactory {
  const UnsupportedDesktopLocalAsrRecognizerFactory();

  @override
  Future<DesktopLocalAsrRecognizer> create(
    DesktopLocalAsrModelPack modelPack,
  ) => Future<DesktopLocalAsrRecognizer>.error(
    UnsupportedError('desktop_local_asr_recognizer_unsupported'),
  );
}

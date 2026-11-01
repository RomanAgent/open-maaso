import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/desktop_local_asr_model_catalog.dart';
import 'package:maaso/src/core/services/desktop_local_asr_pack_runtime_contract.dart';
import 'package:maaso/src/core/services/desktop_local_asr_service.dart';

DesktopLocalAsrPackRuntime createDesktopLocalAsrPackRuntime({
  required AppPlatformCapabilities platformCapabilities,
  required String accountScopeDigest,
  required int generation,
  required DesktopLocalAsrMountFence isCurrentMount,
  Iterable<DesktopLocalAsrModelDescriptor>? descriptors,
  DesktopLocalAsrSupportDirectoryProvider? supportDirectoryProvider,
  DesktopLocalAsrFileDigestProvider? fileDigestProvider,
  DesktopLocalAsrStagingDelete? stagingDelete,
  DesktopLocalAsrPackOperationObserver? operationObserver,
}) => UnsupportedDesktopLocalAsrPackRuntime(
  accountScopeDigest: accountScopeDigest,
  generation: generation,
  descriptors: descriptors ?? DesktopLocalAsrModelCatalog.all,
);

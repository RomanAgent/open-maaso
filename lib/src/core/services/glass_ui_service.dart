import 'dart:ui' as ui;

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/widgets/ui/glass/glass_render_policy.dart';

class GlassUiService extends AppService {
  GlassUiService({
    bool Function()? supportsShaderFilters,
    bool forceFrosted = false,
  }) : _supportsShaderFilters =
           supportsShaderFilters ??
           (() => ui.ImageFilter.isShaderFilterSupported) {
    this.forceFrosted.value = forceFrosted;
  }

  final bool Function() _supportsShaderFilters;

  final forceFrosted = false.obs;
  final shaderFailed = false.obs;

  GlassRenderMode modeFor(GlassBackdropKind backdrop) {
    return resolveGlassRenderMode(
      backdrop: backdrop,
      shaderFilterSupported: _supportsShaderFilters(),
      forceFrosted: forceFrosted.value,
      shaderFailed: shaderFailed.value,
    );
  }

  void markShaderFailed() {
    shaderFailed.value = true;
  }
}

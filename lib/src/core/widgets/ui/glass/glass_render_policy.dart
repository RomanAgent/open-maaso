enum GlassBackdropKind { flutter, platformView, unityUnderlay }

// Legacy values remain source-compatible; White Frost has no liquid pipeline.
enum GlassRenderMode { live, captured, frosted }

GlassRenderMode resolveGlassRenderMode({
  required GlassBackdropKind backdrop,
  required bool shaderFilterSupported,
  bool forceFrosted = false,
  bool shaderFailed = false,
}) => GlassRenderMode.frosted;

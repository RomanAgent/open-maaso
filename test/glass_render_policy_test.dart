import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/widgets/ui/glass/glass_render_policy.dart';

void main() {
  test('Flutter backdrop uses frosted mode with shader filter support', () {
    expect(
      resolveGlassRenderMode(
        backdrop: GlassBackdropKind.flutter,
        shaderFilterSupported: true,
      ),
      GlassRenderMode.frosted,
    );
  });

  test('Flutter backdrop uses frosted mode without shader filters', () {
    expect(
      resolveGlassRenderMode(
        backdrop: GlassBackdropKind.flutter,
        shaderFilterSupported: false,
      ),
      GlassRenderMode.frosted,
    );
  });

  test('PlatformView backdrops always use frosted mode', () {
    expect(
      resolveGlassRenderMode(
        backdrop: GlassBackdropKind.platformView,
        shaderFilterSupported: true,
      ),
      GlassRenderMode.frosted,
    );
  });

  test('Unity underlay uses native-safe frosted mode', () {
    expect(
      resolveGlassRenderMode(
        backdrop: GlassBackdropKind.unityUnderlay,
        shaderFilterSupported: true,
      ),
      GlassRenderMode.frosted,
    );
  });

  test('explicit override and shader failure use frosted mode', () {
    expect(
      resolveGlassRenderMode(
        backdrop: GlassBackdropKind.flutter,
        shaderFilterSupported: true,
        forceFrosted: true,
      ),
      GlassRenderMode.frosted,
    );
    expect(
      resolveGlassRenderMode(
        backdrop: GlassBackdropKind.flutter,
        shaderFilterSupported: true,
        shaderFailed: true,
      ),
      GlassRenderMode.frosted,
    );
  });
}

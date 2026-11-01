import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Reports the complete composer slot, including editing banners, after layout.
class HomeComposerFootprint extends SingleChildRenderObjectWidget {
  const HomeComposerFootprint({
    super.key,
    required this.onHeight,
    required super.child,
  });
  final ValueChanged<double> onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderHomeComposerFootprint(onHeight);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    (renderObject as _RenderHomeComposerFootprint).onHeight = onHeight;
  }
}

class _RenderHomeComposerFootprint extends RenderProxyBox {
  _RenderHomeComposerFootprint(this.onHeight);
  ValueChanged<double> onHeight;
  double? _reported;
  bool _scheduled = false;

  @override
  void performLayout() {
    super.performLayout();
    if (_scheduled ||
        (_reported != null && (_reported! - size.height).abs() < .5)) {
      return;
    }
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!attached || !hasSize) {
        return;
      }
      _reported = size.height;
      onHeight(size.height);
    });
  }
}

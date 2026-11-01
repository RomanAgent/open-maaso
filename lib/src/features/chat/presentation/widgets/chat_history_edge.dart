import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Fades the Flutter conversation at both vertical edges. The platform avatar
/// underneath is never sampled, filtered, or included in this layer.
class ChatHistoryEdge extends StatelessWidget {
  const ChatHistoryEdge({
    required this.child,
    this.extent = 56,
    this.bottomExtent = 24,
    super.key,
  });

  final Widget child;
  final double extent;
  final double bottomExtent;

  @override
  Widget build(BuildContext context) => ClipRect(
    child: ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          extent > 0 ? Colors.transparent : Colors.white,
          Colors.white,
          Colors.white,
          bottomExtent > 0 ? Colors.transparent : Colors.white,
        ],
        stops: [
          0,
          (extent / bounds.height).clamp(0, .49),
          1 - (bottomExtent / bounds.height).clamp(0, .49),
          1,
        ],
      ).createShader(bounds),
      child: child,
    ),
  );
}

/// A departing row softens as its last visible lines approach either edge.
/// Tall messages remain sharp while their body is still being read.
/// Only rows inside the narrow fade band allocate a content-filter layer.
class ChatHistoryEdgeItem extends SingleChildRenderObjectWidget {
  const ChatHistoryEdgeItem({
    required super.child,
    this.extent = 56,
    this.bottomExtent = 24,
    super.key,
  });

  final double extent;
  final double bottomExtent;

  @override
  RenderChatHistoryEdgeItem createRenderObject(BuildContext context) =>
      RenderChatHistoryEdgeItem(
        extent: extent,
        bottomExtent: bottomExtent,
        soften: !_reduceEffects(context),
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderChatHistoryEdgeItem renderObject,
  ) {
    renderObject
      ..extent = extent
      ..bottomExtent = bottomExtent
      ..soften = !_reduceEffects(context);
  }

  static bool _reduceEffects(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context) ||
      MediaQuery.accessibleNavigationOf(context) ||
      MediaQuery.highContrastOf(context);
}

class RenderChatHistoryEdgeItem extends RenderProxyBox {
  RenderChatHistoryEdgeItem({
    required double extent,
    double bottomExtent = 24,
    required bool soften,
  }) : _extent = extent,
       _bottomExtent = bottomExtent,
       _soften = soften;

  double _extent;
  double _bottomExtent;
  bool _soften;
  final _filterLayer = LayerHandle<ImageFilterLayer>();

  set extent(double value) {
    if (_extent == value) return;
    _extent = value;
    markNeedsPaint();
  }

  set bottomExtent(double value) {
    if (_bottomExtent == value) return;
    _bottomExtent = value;
    markNeedsPaint();
  }

  set soften(bool value) {
    if (_soften == value) return;
    _soften = value;
    markNeedsCompositingBitsUpdate();
    markNeedsPaint();
  }

  @override
  bool get alwaysNeedsCompositing => _soften;

  @override
  void paint(PaintingContext context, Offset offset) {
    final viewport = RenderAbstractViewport.maybeOf(this);
    final bottom = viewport == null
        ? double.infinity
        : localToGlobal(Offset(0, size.height), ancestor: viewport).dy;
    final top = viewport == null
        ? double.negativeInfinity
        : localToGlobal(Offset.zero, ancestor: viewport).dy;
    final viewportHeight = viewport is RenderBox
        ? (viewport as RenderBox).size.height
        : double.infinity;
    final topProgress = _extent > 0
        ? (1 - bottom / _extent).clamp(0.0, 1.0)
        : 0.0;
    final bottomProgress = _bottomExtent > 0
        ? (1 - (viewportHeight - top) / _bottomExtent).clamp(0.0, 1.0)
        : 0.0;
    final progress = _soften
        ? (topProgress > bottomProgress ? topProgress : bottomProgress)
        : 0.0;
    if (progress <= .01) {
      _filterLayer.layer = null;
      super.paint(context, offset);
      return;
    }
    final layer = _filterLayer.layer ??= ImageFilterLayer();
    layer.imageFilter = ui.ImageFilter.blur(
      sigmaX: 3 * progress,
      sigmaY: 3 * progress,
      tileMode: ui.TileMode.decal,
    );
    context.pushLayer(layer, super.paint, offset);
  }

  @override
  void dispose() {
    _filterLayer.layer = null;
    super.dispose();
  }
}

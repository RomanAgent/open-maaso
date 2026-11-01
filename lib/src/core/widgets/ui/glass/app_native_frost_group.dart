import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/glass_ui_service.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass_surface.dart';

/// One native sampler behind a bounded conversation, independent of Flutter's
/// text filters. Regions describe real laid-out bubbles, never copied text.
class AppNativeFrostGroup extends StatefulWidget {
  const AppNativeFrostGroup({
    required this.child,
    this.enabled = true,
    this.opacity = 1,
    this.topFadeHeight = 44,
    this.bottomFadeHeight = 24,
    this.fit = StackFit.expand,
    this.deferRevealUntilReady = false,
    this.onReady,
    super.key,
  });

  final Widget child;
  final bool enabled;
  final double opacity;
  final double topFadeHeight;
  final double bottomFadeHeight;

  /// Menus size to their content; conversations keep filling their viewport.
  final StackFit fit;

  /// Transient panels lay out invisibly until their current native geometry is
  /// acknowledged. Persistent conversations retain their readable fallback.
  final bool deferRevealUntilReady;

  /// Starts foreground/native mask animations only after the material exists.
  /// Called once per native view generation, or after non-native layout.
  final VoidCallback? onReady;

  static const viewKey = ValueKey('native-frost-conversation');

  @override
  State<AppNativeFrostGroup> createState() => _AppNativeFrostGroupState();
}

class _AppNativeFrostGroupState extends State<AppNativeFrostGroup> {
  final _hostKey = GlobalKey();
  late final _regions = _FrostRegions(_scheduleUpdate);
  MethodChannel? _channel;
  String? _lastPayload;
  String? _acknowledgedGeometry;
  bool _scheduled = false;
  bool _sending = false;
  bool _sendAgain = false;
  bool _native = false;
  bool _nativeFailed = false;
  bool _materialReady = false;
  bool? _nativeDark;
  int _viewGeneration = 0;
  int _readyNotificationGeneration = -1;

  bool get _waitingForMaterial =>
      _native && widget.deferRevealUntilReady && !_materialReady;

  double get _visibleOpacity =>
      _waitingForMaterial ? 0 : widget.opacity.clamp(0.0, 1.0);

  void _resetNativeView({bool? dark}) {
    _viewGeneration++;
    _nativeDark = dark;
    _channel = null;
    _lastPayload = null;
    _acknowledgedGeometry = null;
    _sending = false;
    _sendAgain = false;
    _materialReady = false;
  }

  void _notifyReadyAfterLayout() {
    if (widget.onReady == null ||
        _readyNotificationGeneration == _viewGeneration) {
      return;
    }
    final generation = _viewGeneration;
    _readyNotificationGeneration = generation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          generation == _viewGeneration &&
          (!_native || _materialReady)) {
        widget.onReady?.call();
      }
    });
  }

  void _scheduleUpdate() {
    if (!mounted || _scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted && _native) unawaited(_updateRegions());
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _updateRegions() async {
    final channel = _channel;
    final generation = _viewGeneration;
    final host = _hostKey.currentContext?.findRenderObject();
    if (channel == null || host is! RenderBox || !host.hasSize) return;
    if (_sending) {
      _sendAgain = true;
      return;
    }
    final viewport = Offset.zero & host.size;
    final regions = <Map<String, Object>>[];
    for (final region in _regions.items) {
      if (!region.attached || !region.hasSize) continue;
      final rect = MatrixUtils.transformRect(
        region.getTransformTo(host),
        Offset.zero & region.size,
      );
      if (!rect.isFinite || rect.isEmpty || !rect.overlaps(viewport)) continue;
      regions.add({
        'x': rect.left,
        'y': rect.top,
        'width': rect.width,
        'height': rect.height,
        'radius': region.radius,
        'userTint': region.userTint,
      });
    }
    final geometry = <String, Object>{
      'regions': regions,
      'topFade': widget.topFadeHeight,
      'bottomFade': widget.bottomFadeHeight,
      'viewportWidth': host.size.width,
      'viewportHeight': host.size.height,
    };
    final encodedGeometry = jsonEncode(geometry);
    // Readiness depends on the current layout, not animated visibility. An
    // opacity change must neither delay readiness nor accept a stale layout.
    if (!_materialReady &&
        regions.isNotEmpty &&
        encodedGeometry == _acknowledgedGeometry) {
      setState(() => _materialReady = true);
    }
    final payload = <String, Object>{...geometry, 'opacity': _visibleOpacity};
    final encoded = jsonEncode(payload);
    if (encoded == _lastPayload) return;
    _sending = true;
    try {
      await channel.invokeMethod<void>('regions', payload);
      if (mounted &&
          generation == _viewGeneration &&
          identical(channel, _channel)) {
        _lastPayload = encoded;
        _acknowledgedGeometry = encodedGeometry;
        if (!_materialReady && regions.isNotEmpty) _scheduleUpdate();
      }
    } on MissingPluginException {
      _useFallbackAfterFailure(generation, channel);
    } on PlatformException {
      _useFallbackAfterFailure(generation, channel);
    } finally {
      if (generation == _viewGeneration) {
        _sending = false;
        if (_sendAgain) {
          _sendAgain = false;
          if (mounted) _scheduleUpdate();
        }
      }
    }
  }

  void _useFallbackAfterFailure(int generation, MethodChannel channel) {
    if (widget.deferRevealUntilReady &&
        mounted &&
        generation == _viewGeneration &&
        identical(channel, _channel)) {
      // Keep controls usable if the native bridge fails. Closing/reopening a
      // transient panel creates a fresh view and retries the native material.
      setState(() => _nativeFailed = true);
    }
  }

  @override
  void didUpdateWidget(covariant AppNativeFrostGroup oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleUpdate();
  }

  @override
  void dispose() {
    _channel = null;
    _regions.items.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final service = appServices.maybeFind<GlassUiService>();
    _native =
        widget.enabled &&
        !_nativeFailed &&
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.iOS &&
        !media.highContrast &&
        !media.accessibleNavigation &&
        service?.forceFrosted.value != true;
    if (!_native) {
      if (_nativeDark != null) _resetNativeView();
      _notifyReadyAfterLayout();
      // A nested panel must not borrow the conversation's sampler when its own
      // material is unavailable. Its children then choose their own fallback.
      return _NativeFrostScope(
        regions: null,
        materialReady: false,
        child: Opacity(opacity: widget.opacity, child: widget.child),
      );
    }
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (_nativeDark != dark) _resetNativeView(dark: dark);
    final generation = _viewGeneration;
    if (_materialReady) _notifyReadyAfterLayout();
    _scheduleUpdate();
    return _NativeFrostScope(
      regions: _regions,
      materialReady: _materialReady,
      child: NotificationListener<ScrollMetricsNotification>(
        onNotification: (_) {
          _scheduleUpdate();
          return false;
        },
        child: NotificationListener<ScrollNotification>(
          onNotification: (_) {
            _scheduleUpdate();
            return false;
          },
          child: Stack(
            key: _hostKey,
            fit: widget.fit,
            children: [
              Positioned.fill(
                child: ExcludeSemantics(
                  child: IgnorePointer(
                    child: UiKitView(
                      key: ValueKey((AppNativeFrostGroup.viewKey, dark)),
                      viewType: AppFrostedInputBackground.nativeViewType,
                      creationParamsCodec: const StandardMessageCodec(),
                      creationParams: <String, Object>{
                        'dark': dark,
                        'group': true,
                        'cornerRadius': 0.0,
                      },
                      onPlatformViewCreated: (id) {
                        if (!mounted || generation != _viewGeneration) return;
                        _channel = MethodChannel('maaso/frosted_input/$id');
                        _lastPayload = null;
                        _acknowledgedGeometry = null;
                        _scheduleUpdate();
                      },
                    ),
                  ),
                ),
              ),
              // Opacity and ShaderMask affect only Flutter foreground. UIKit
              // uses its effect view's own mask, with effect alpha kept at 1.
              IgnorePointer(
                ignoring: _waitingForMaterial,
                child: ExcludeSemantics(
                  excluding: _waitingForMaterial,
                  child: ExcludeFocus(
                    excluding: _waitingForMaterial,
                    child: Opacity(
                      opacity: _visibleOpacity,
                      child: widget.child,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NativeFrostScope extends InheritedWidget {
  const _NativeFrostScope({
    required this.regions,
    required this.materialReady,
    required super.child,
  });
  final _FrostRegions? regions;
  final bool materialReady;

  @override
  bool updateShouldNotify(_NativeFrostScope oldWidget) =>
      regions != oldWidget.regions || materialReady != oldWidget.materialReady;
}

class _FrostRegions {
  _FrostRegions(this.changed);
  final VoidCallback changed;
  final items = <_RenderFrostRegion>{};
}

/// Geometry for one bubble in the group's single sampler. It allocates no
/// platform view; offscreen regions are excluded from the native mask.
class AppNativeFrostRegion extends SingleChildRenderObjectWidget {
  const AppNativeFrostRegion({
    required super.child,
    required this.radius,
    this.userTint = false,
    super.key,
  });

  final double radius;
  final bool userTint;

  static bool available(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_NativeFrostScope>()
          ?.regions !=
      null;

  /// Geometry can register before the current native view has accepted it.
  /// Until then, foreground widgets retain their non-sampling fallback fill.
  static bool materialReady(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_NativeFrostScope>()
          ?.materialReady ??
      false;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderFrostRegion(
    context.dependOnInheritedWidgetOfExactType<_NativeFrostScope>()!.regions!,
    radius,
    userTint,
  );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    final region = renderObject as _RenderFrostRegion;
    region
      ..radius = radius
      ..userTint = userTint;
    region.regions.changed();
  }
}

class _RenderFrostRegion extends RenderProxyBox {
  _RenderFrostRegion(this.regions, this.radius, this.userTint);
  final _FrostRegions regions;
  double radius;
  bool userTint;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    regions.items.add(this);
    regions.changed();
  }

  @override
  void detach() {
    regions.items.remove(this);
    regions.changed();
    super.detach();
  }

  @override
  void performLayout() {
    super.performLayout();
    regions.changed();
  }
}

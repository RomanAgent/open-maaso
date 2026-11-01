import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/glass_ui_service.dart';
import 'package:maaso/src/core/widgets/ui/glass/glass_render_policy.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_frost_tokens.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_glass_theme.dart';

enum AppGlassSurfaceRole {
  chrome,
  surface,
  control,
  field,
  transient,
  orb,
  staticSurface,
  message,
}

enum AppGlassSurfaceBehavior { automatic, staticSurface }

class MaasoGlassBackdropScope extends InheritedWidget {
  const MaasoGlassBackdropScope({
    required this.backdropKind,
    required this.renderMode,
    this.allowBlur = true,
    required super.child,
    super.key,
  });

  final GlassBackdropKind backdropKind;
  final GlassRenderMode renderMode;
  final bool allowBlur;

  static MaasoGlassBackdropScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MaasoGlassBackdropScope>();

  @override
  bool updateShouldNotify(MaasoGlassBackdropScope oldWidget) =>
      backdropKind != oldWidget.backdropKind ||
      renderMode != oldWidget.renderMode ||
      allowBlur != oldWidget.allowBlur;
}

/// White Frost's shared surface. Lists and cards never sample their backdrop.
/// A page may opt at most two bounded, fixed capsule/input regions into [blur].
class AppGlassSurface extends StatelessWidget {
  const AppGlassSurface({
    required this.child,
    this.role = AppGlassSurfaceRole.surface,
    this.behavior = AppGlassSurfaceBehavior.automatic,
    this.renderMode,
    this.tintColor,
    this.cornerRadius,
    this.padding = EdgeInsets.zero,
    this.margin = EdgeInsets.zero,
    this.alignment,
    this.width,
    this.height,
    this.constraints,
    this.clipBehavior = Clip.antiAlias,
    this.blur = false,
    super.key,
  });

  static const Key frostedLayerKey = ValueKey<String>(
    'app-glass-frosted-layer',
  );
  static const Key liveLayerKey = ValueKey<String>('app-glass-live-layer');
  static const Key backdropFilterKey = ValueKey<String>('app-frost-local-blur');

  final Widget child;
  final AppGlassSurfaceRole role;
  final AppGlassSurfaceBehavior behavior;
  final GlassRenderMode? renderMode;
  final Color? tintColor;
  final double? cornerRadius;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final AlignmentGeometry? alignment;
  final double? width;
  final double? height;
  final BoxConstraints? constraints;
  final Clip clipBehavior;
  final bool blur;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final scope = MaasoGlassBackdropScope.maybeOf(context);
    final media = MediaQuery.maybeOf(context);
    final nativeBackdrop =
        scope != null && scope.backdropKind != GlassBackdropKind.flutter;
    final service = appServices.maybeFind<GlassUiService>();
    final reduceTransparency =
        (media?.highContrast ?? false) ||
        (media?.accessibleNavigation ?? false) ||
        service?.forceFrosted.value == true ||
        service?.shaderFailed.value == true;
    final matte =
        role == AppGlassSurfaceRole.surface ||
        role == AppGlassSurfaceRole.staticSurface;
    final canBlur =
        blur &&
        !matte &&
        role != AppGlassSurfaceRole.message &&
        !nativeBackdrop &&
        !reduceTransparency &&
        scope?.allowBlur != false &&
        renderMode != GlassRenderMode.frosted &&
        Scrollable.maybeOf(context) == null;
    final alpha = matte || reduceTransparency
        ? 1.0
        : role == AppGlassSurfaceRole.message
        ? MaasoFrostTokens.messageFillAlpha
        : nativeBackdrop || role == AppGlassSurfaceRole.transient
        ? MaasoFrostTokens.overlayFillAlpha
        : role == AppGlassSurfaceRole.field
        ? (canBlur
              ? MaasoFrostTokens.blurredInputFillAlpha
              : MaasoFrostTokens.inputFillAlpha)
        : (canBlur
              ? MaasoFrostTokens.blurredCapsuleFillAlpha
              : MaasoFrostTokens.capsuleFillAlpha);
    var fill =
        tintColor ??
        (matte ? glass.muted : glass.surface.withValues(alpha: alpha));
    if (matte || reduceTransparency) {
      fill = Color.alphaBlend(fill, glass.surface).withValues(alpha: 1);
    } else if (nativeBackdrop &&
        role != AppGlassSurfaceRole.message &&
        fill.a < MaasoFrostTokens.overlayFillAlpha) {
      fill = fill.withValues(alpha: MaasoFrostTokens.overlayFillAlpha);
    }
    final radius = BorderRadius.circular(cornerRadius ?? _radiusForRole(role));
    final content = MaasoGlassBackdropScope(
      backdropKind: scope?.backdropKind ?? GlassBackdropKind.flutter,
      renderMode: GlassRenderMode.frosted,
      allowBlur: !canBlur && !matte && scope?.allowBlur != false,
      child: Padding(padding: padding, child: child),
    );
    Widget painted = DecoratedBox(
      key: frostedLayerKey,
      decoration: BoxDecoration(color: fill, borderRadius: radius),
      child: content,
    );
    if (canBlur) {
      painted = BackdropFilter(
        key: backdropFilterKey,
        filter: ui.ImageFilter.blur(
          sigmaX: MaasoFrostTokens.blurSigma,
          sigmaY: MaasoFrostTokens.blurSigma,
        ),
        child: painted,
      );
    }
    return Container(
      width: width,
      height: height,
      constraints: constraints,
      margin: margin,
      alignment: alignment,
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: matte
            ? null
            : <BoxShadow>[
                BoxShadow(
                  color: glass.shadow,
                  blurRadius: MaasoGlassTheme.staticShadowBlur,
                  offset: MaasoGlassTheme.staticShadowOffset,
                ),
              ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        clipBehavior: canBlur ? Clip.antiAlias : clipBehavior,
        child: painted,
      ),
    );
  }

  double _radiusForRole(AppGlassSurfaceRole surfaceRole) =>
      switch (surfaceRole) {
        AppGlassSurfaceRole.chrome ||
        AppGlassSurfaceRole.control ||
        AppGlassSurfaceRole.orb => MaasoGlassTheme.capsuleRadius,
        AppGlassSurfaceRole.surface ||
        AppGlassSurfaceRole.staticSurface => MaasoGlassTheme.surfaceRadius,
        AppGlassSurfaceRole.field => MaasoGlassTheme.fieldRadius,
        AppGlassSurfaceRole.message => MaasoFrostTokens.compactRadius,
        AppGlassSurfaceRole.transient => MaasoGlassTheme.sheetRadius,
      };
}

/// One fixed input background. UIKit can diffuse the actual Unity underlay;
/// Flutter's BackdropFilter cannot sample that separate native render surface.
/// Never place this native path in a scrolling list or on individual messages.
class AppFrostedInputBackground extends StatelessWidget {
  const AppFrostedInputBackground({required this.cornerRadius, super.key});

  static const nativeViewType = 'maaso/frosted_input';
  static const nativeKey = ValueKey<String>('maaso-native-frosted-input');
  final double cornerRadius;

  @override
  Widget build(BuildContext context) {
    final scope = MaasoGlassBackdropScope.maybeOf(context);
    final media = MediaQuery.maybeOf(context);
    final service = appServices.maybeFind<GlassUiService>();
    final accessible =
        (media?.highContrast ?? false) ||
        (media?.accessibleNavigation ?? false) ||
        service?.forceFrosted.value == true;
    final native =
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.iOS &&
        scope?.backdropKind == GlassBackdropKind.unityUnderlay &&
        !accessible &&
        Scrollable.maybeOf(context) == null;
    if (native) {
      final dark = Theme.of(context).brightness == Brightness.dark;
      return ExcludeSemantics(
        child: IgnorePointer(
          child: UiKitView(
            // Creation parameters are immutable. A theme change recreates only
            // this decorative background, never the editor or its focus node.
            key: ValueKey<Object>((nativeKey, dark, cornerRadius)),
            viewType: nativeViewType,
            creationParamsCodec: const StandardMessageCodec(),
            creationParams: <String, Object>{
              'dark': dark,
              'cornerRadius': cornerRadius,
            },
          ),
        ),
      );
    }
    return AppGlassSurface(
      role: AppGlassSurfaceRole.field,
      cornerRadius: cornerRadius,
      blur: true,
      child: const SizedBox.expand(),
    );
  }
}

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass_surface.dart';
import 'package:maaso/src/core/widgets/ui/glass/glass_render_policy.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_glass_theme.dart';
import 'package:maaso/src/core/services/glass_ui_service.dart';

class AppGlassScaffold extends StatelessWidget {
  const AppGlassScaffold({
    required this.body,
    this.backdropKind = GlassBackdropKind.flutter,
    this.background,
    this.backgroundColor,
    this.appBar,
    this.bottomNavigationBar,
    this.floatingActionButton,
    this.lenses = const <Widget>[],
    this.safeArea = true,
    this.resizeToAvoidBottomInset = true,
    this.capturePixelRatio = 0.75,
    this.realTimeCapture = false,
    super.key,
  });

  static const Key livePipelineKey = ValueKey<String>(
    'app-glass-live-pipeline',
  );
  static const Key capturedPipelineKey = ValueKey<String>(
    'app-glass-captured-pipeline',
  );
  static const Key frostedPipelineKey = ValueKey<String>(
    'app-glass-frosted-pipeline',
  );
  static const Key defaultBackgroundKey = ValueKey<String>(
    'app-glass-default-background',
  );
  static const Key unityUnderlayWashKey = ValueKey<String>(
    'app-glass-unity-underlay-wash',
  );

  final Widget body;
  final GlassBackdropKind backdropKind;
  final Widget? background;
  final Color? backgroundColor;
  final Widget? appBar;
  final Widget? bottomNavigationBar;
  final Widget? floatingActionButton;
  final List<Widget> lenses;
  final bool safeArea;
  final bool resizeToAvoidBottomInset;
  final double capturePixelRatio;
  final bool realTimeCapture;

  @override
  Widget build(BuildContext context) {
    if (backdropKind == GlassBackdropKind.unityUnderlay) {
      if (appServices.isRegistered<ActiveAvatarRuntime>()) {
        return AppReactiveBuilder(() => _buildUnityUnderlay(context));
      }
      return _buildUnityUnderlay(context);
    }
    if (!appServices.isRegistered<GlassUiService>()) {
      return _buildForMode(context, GlassRenderMode.frosted, backdropKind);
    }
    final service = appServices.find<GlassUiService>();
    return AppReactiveBuilder(
      () => _buildForMode(context, service.modeFor(backdropKind), backdropKind),
    );
  }

  Widget _buildUnityUnderlay(BuildContext context) {
    final effectiveBackdrop = _canRevealUnityUnderlay()
        ? GlassBackdropKind.unityUnderlay
        : GlassBackdropKind.flutter;
    final mode = appServices.isRegistered<GlassUiService>()
        ? appServices.find<GlassUiService>().modeFor(effectiveBackdrop)
        : GlassRenderMode.frosted;
    return _buildForMode(context, mode, effectiveBackdrop);
  }

  bool _canRevealUnityUnderlay() {
    if (defaultTargetPlatform != TargetPlatform.iOS ||
        !appServices.isRegistered<ActiveAvatarRuntime>()) {
      return false;
    }
    final active = appServices.find<ActiveAvatarRuntime>();
    final runtime = active.current;
    return active.backend.value == AvatarBackendKind.unity &&
        runtime?.isReady.value == true;
  }

  Widget _buildForMode(
    BuildContext context,
    GlassRenderMode mode,
    GlassBackdropKind effectiveBackdrop,
  ) {
    const key = frostedPipelineKey;
    if (effectiveBackdrop == GlassBackdropKind.platformView ||
        effectiveBackdrop == GlassBackdropKind.unityUnderlay) {
      return KeyedSubtree(
        key: key,
        child: Scaffold(
          backgroundColor: backgroundColor ?? Colors.transparent,
          resizeToAvoidBottomInset: resizeToAvoidBottomInset,
          body: _PlatformViewScaffoldSlots(
            body: _scope(
              _nativeUnderlayBody(effectiveBackdrop),
              mode,
              effectiveBackdrop,
            ),
            appBar: _nullableScope(appBar, mode, effectiveBackdrop),
            bottomNavigationBar: _nullableScope(
              bottomNavigationBar,
              mode,
              effectiveBackdrop,
            ),
            floatingActionButton: _nullableScope(
              floatingActionButton,
              mode,
              effectiveBackdrop,
            ),
            lenses: lenses
                .map((lens) => _scope(lens, mode, effectiveBackdrop))
                .toList(),
            safeArea: safeArea,
          ),
        ),
      );
    }
    final header = appBar;
    return KeyedSubtree(
      key: key,
      child: Scaffold(
        backgroundColor:
            backgroundColor ?? Theme.of(context).scaffoldBackgroundColor,
        resizeToAvoidBottomInset: resizeToAvoidBottomInset,
        appBar: header == null
            ? null
            : PreferredSize(
                preferredSize: header is PreferredSizeWidget
                    ? header.preferredSize
                    : const Size.fromHeight(64),
                child: SafeArea(
                  bottom: false,
                  child: _scope(header, mode, effectiveBackdrop),
                ),
              ),
        body: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            background ?? const _DefaultGlassBackground(),
            _scope(
              safeArea ? SafeArea(child: body) : body,
              mode,
              effectiveBackdrop,
            ),
            ...lenses.map((lens) => _scope(lens, mode, effectiveBackdrop)),
          ],
        ),
        bottomNavigationBar: _nullableScope(
          bottomNavigationBar,
          mode,
          effectiveBackdrop,
        ),
        floatingActionButton: _nullableScope(
          floatingActionButton,
          mode,
          effectiveBackdrop,
        ),
      ),
    );
  }

  Widget _scope(
    Widget child,
    GlassRenderMode mode,
    GlassBackdropKind effectiveBackdrop,
  ) {
    return MaasoGlassBackdropScope(
      backdropKind: effectiveBackdrop,
      renderMode: mode,
      allowBlur:
          effectiveBackdrop == GlassBackdropKind.flutter &&
          appServices.maybeFind<GlassUiService>()?.forceFrosted.value != true &&
          appServices.maybeFind<GlassUiService>()?.shaderFailed.value != true,
      child: Material(type: MaterialType.transparency, child: child),
    );
  }

  Widget? _nullableScope(
    Widget? child,
    GlassRenderMode mode,
    GlassBackdropKind effectiveBackdrop,
  ) {
    return child == null ? null : _scope(child, mode, effectiveBackdrop);
  }

  Widget _nativeUnderlayBody(GlassBackdropKind effectiveBackdrop) {
    final nativeBackground = background;
    if (nativeBackground == null &&
        effectiveBackdrop != GlassBackdropKind.unityUnderlay) {
      return body;
    }
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        ?nativeBackground,
        if (effectiveBackdrop == GlassBackdropKind.unityUnderlay)
          const _UnityUnderlayWash(),
        body,
      ],
    );
  }
}

class _DefaultGlassBackground extends StatelessWidget {
  const _DefaultGlassBackground();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      key: AppGlassScaffold.defaultBackgroundKey,
      color: Theme.of(context).scaffoldBackgroundColor,
    );
  }
}

class _UnityUnderlayWash extends StatelessWidget {
  const _UnityUnderlayWash();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      key: AppGlassScaffold.unityUnderlayWashKey,
      color: MaasoGlassTheme.of(context).surface.withValues(alpha: 0.65),
    );
  }
}

class _PlatformViewScaffoldSlots extends StatelessWidget {
  const _PlatformViewScaffoldSlots({
    required this.body,
    required this.appBar,
    required this.bottomNavigationBar,
    required this.floatingActionButton,
    required this.lenses,
    required this.safeArea,
  });

  final Widget body;
  final Widget? appBar;
  final Widget? bottomNavigationBar;
  final Widget? floatingActionButton;
  final List<Widget> lenses;
  final bool safeArea;

  @override
  Widget build(BuildContext context) {
    final top = safeArea ? MediaQuery.paddingOf(context).top : 0.0;
    final bottom = safeArea ? MediaQuery.paddingOf(context).bottom : 0.0;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        body,
        ...lenses,
        if (appBar != null)
          Positioned(top: top, left: 0, right: 0, child: appBar!),
        if (bottomNavigationBar != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: bottom,
            child: bottomNavigationBar!,
          ),
        if (floatingActionButton != null)
          Positioned(
            right: 16,
            bottom: bottom + 16,
            child: floatingActionButton!,
          ),
      ],
    );
  }
}

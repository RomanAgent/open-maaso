import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:maaso/src/features/agent_games/data/agent_game_cloud_service.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/widgets_hub/presentation/applet_player_like_button.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';
import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:maaso/src/core/widgets/surface_web_view.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/widget_stage_controller.dart';

enum SurfaceStageLayer { all, background, foreground }

class SurfaceStage extends StatelessWidget {
  const SurfaceStage({
    super.key,
    this.layer = SurfaceStageLayer.all,
    this.showBackButton = true,
  });

  final SurfaceStageLayer layer;
  final bool showBackButton;

  static const cardFrameKey = ValueKey('surface-stage-card-frame');
  static const headerKey = ValueKey('surface-stage-header');
  static const fullscreenHostKey = ValueKey('surface-stage-fullscreen-host');
  static const safeControlsKey = ValueKey('surface-stage-safe-controls');
  static const backButtonKey = ValueKey('surface-stage-back-button');
  static const floatingHostKey = ValueKey('surface-stage-floating-host');
  static const overlayHostKey = ValueKey('surface-stage-overlay-host');
  static const backgroundHostKey = ValueKey('surface-stage-background-host');

  @override
  Widget build(BuildContext context) {
    return _RuntimeSurfaceStage(layer: layer, showBackButton: showBackButton);
  }
}

class _RuntimeSurfaceStage extends StatelessWidget {
  const _RuntimeSurfaceStage({
    required this.layer,
    required this.showBackButton,
  });

  final SurfaceStageLayer layer;
  final bool showBackButton;

  @override
  Widget build(BuildContext context) {
    if (!appServices.isRegistered<SurfaceRuntime>()) {
      return const SizedBox.shrink();
    }
    final runtime = appServices.find<SurfaceRuntime>();
    return AppReactiveBuilder(() {
      final project = runtime.activeProject.value;
      if (!runtime.isVisible.value || project == null) {
        return const SizedBox.shrink();
      }
      // Games are route/feed owned. Keeping Home's persistent stage detached
      // prevents a second WebView from running the same worker behind it.
      if (project.experienceType == SurfaceExperienceType.game) {
        return const SizedBox.shrink();
      }
      final active = appServices
          .maybeFind<WidgetStageController>()
          ?.active
          .value;
      final savedApplet =
          active?.isSurface == true &&
          active!.spec['surfaceId'] == project.id &&
          AppletLocalOwnership.isVisible(active);
      final kind = savedApplet ? SurfaceKind.fullscreen : project.kind;
      final cloud = savedApplet
          ? AgentGameCloudMetadata.fromSpec(active.spec['cloud'])
          : null;
      if (!_isInLayer(kind, layer)) {
        return const SizedBox.shrink();
      }
      final surface = switch (kind) {
        SurfaceKind.card => _CardSurface(project: project, runtime: runtime),
        SurfaceKind.fullscreen => _FullscreenSurface(
          project: project,
          appletId: cloud?.hasPublished == true ? cloud!.gameId : null,
        ),
        SurfaceKind.floatingCanvas => _FloatingSurface(project: project),
        SurfaceKind.transparentOverlay => const _FillSurface(
          key: SurfaceStage.overlayHostKey,
          backgroundColor: Colors.transparent,
        ),
        SurfaceKind.background => const _FillSurface(
          key: SurfaceStage.backgroundHostKey,
          backgroundColor: Colors.transparent,
        ),
      };
      if (!showBackButton || kind == SurfaceKind.background) {
        return surface;
      }
      return Stack(
        fit: StackFit.expand,
        children: [
          surface,
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: _SurfaceBackButton(runtime: runtime),
              ),
            ),
          ),
        ],
      );
    });
  }

  bool _isInLayer(SurfaceKind kind, SurfaceStageLayer layer) {
    return switch (layer) {
      SurfaceStageLayer.all => true,
      SurfaceStageLayer.background => kind == SurfaceKind.background,
      SurfaceStageLayer.foreground => kind != SurfaceKind.background,
    };
  }
}

class _CardSurface extends StatelessWidget {
  const _CardSurface({required this.project, required this.runtime});

  final SurfaceProject project;
  final SurfaceRuntime runtime;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final safe = MediaQuery.of(context).padding;
        final maxWidth = math.max(0.0, constraints.maxWidth - 24);
        final maxHeight = math.max(
          0.0,
          constraints.maxHeight - safe.vertical - 24,
        );
        final width = math.min(420.0, maxWidth);
        final height = math.min(
          maxHeight,
          math.max(240.0, constraints.maxHeight * 0.46),
        );

        return SafeArea(
          child: Align(
            alignment: Alignment.center,
            child: SizedBox(
              width: width,
              height: height,
              child: _SurfaceCardFrame(project: project, runtime: runtime),
            ),
          ),
        );
      },
    );
  }
}

class _SurfaceCardFrame extends StatelessWidget {
  const _SurfaceCardFrame({required this.project, required this.runtime});

  final SurfaceProject project;
  final SurfaceRuntime runtime;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: SurfaceStage.cardFrameKey,
      color: Colors.transparent,
      child: AppGlassSurface(
        role: AppGlassSurfaceRole.staticSurface,
        behavior: AppGlassSurfaceBehavior.staticSurface,
        cornerRadius: 22,
        tintColor: Colors.white.withValues(alpha: 0.54),
        child: Column(
          children: [
            _SurfaceHeader(project: project, runtime: runtime),
            const Expanded(child: SurfaceWebView()),
          ],
        ),
      ),
    );
  }
}

class _SurfaceHeader extends StatelessWidget {
  const _SurfaceHeader({required this.project, required this.runtime});

  final SurfaceProject project;
  final SurfaceRuntime runtime;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: SurfaceStage.headerKey,
      height: 48,
      padding: const EdgeInsets.only(left: 14, right: 4),
      decoration: BoxDecoration(
        color: ColorConstant.skyColor.withValues(alpha: 0.12),
        border: Border(
          bottom: BorderSide(
            color: ColorConstant.textPrimary.withValues(alpha: 0.08),
          ),
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.auto_awesome_rounded,
            color: ColorConstant.textPrimary,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              project.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: ColorConstant.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          AppGlassIconButton(
            tooltip: 'common.close'.tr,
            icon: Icons.keyboard_arrow_down_rounded,
            onPressed: () => _closeSurface(runtime),
            size: 44,
            iconSize: 24,
          ),
        ],
      ),
    );
  }
}

class _FullscreenSurface extends StatelessWidget {
  const _FullscreenSurface({required this.project, this.appletId});

  final SurfaceProject project;
  final String? appletId;

  @override
  Widget build(BuildContext context) {
    return Stack(
      key: SurfaceStage.fullscreenHostKey,
      fit: StackFit.expand,
      children: [
        SurfaceWebView(backgroundColor: _solidBackground(project)),
        SafeArea(
          child: Align(
            alignment: Alignment.topRight,
            child: Padding(
              key: SurfaceStage.safeControlsKey,
              padding: const EdgeInsets.all(10),
              child: AppletPlayerLikeButton(appletId: appletId),
            ),
          ),
        ),
      ],
    );
  }
}

class _FloatingSurface extends StatelessWidget {
  const _FloatingSurface({required this.project});

  final SurfaceProject project;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final placement = _rectFor(constraints.biggest, project.placement);
        return Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fromRect(
              rect: placement,
              child: const SizedBox.expand(
                key: SurfaceStage.floatingHostKey,
                child: SurfaceWebView(backgroundColor: Colors.transparent),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _FillSurface extends StatelessWidget {
  const _FillSurface({super.key, required this.backgroundColor});

  final Color backgroundColor;

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: SurfaceWebView(backgroundColor: backgroundColor),
    );
  }
}

class _SurfaceBackButton extends StatelessWidget {
  const _SurfaceBackButton({required this.runtime});

  final SurfaceRuntime runtime;

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      key: SurfaceStage.backButtonKey,
      child: AppGlassIconButton(
        tooltip: 'common.back'.tr,
        icon: Icons.arrow_back_rounded,
        color: ColorConstant.primaryColor.withValues(alpha: 0.62),
        foregroundColor: Colors.white,
        onPressed: () => _closeSurface(runtime),
        size: 50,
        iconSize: 24,
      ),
    );
  }
}

Future<void> _closeSurface(SurfaceRuntime runtime) async {
  if (await runtime.goBackInBundle()) return;
  await runtime.close();
  if (!appServices.isRegistered<WidgetStageController>()) return;
  final stage = appServices.find<WidgetStageController>();
  if (stage.active.value?.isSurface == true) {
    stage.minimize();
  }
}

Rect _rectFor(Size viewport, SurfacePlacement placement) {
  final left = viewport.width * placement.x;
  final top = viewport.height * placement.y;
  final width = viewport.width * placement.width;
  final height = viewport.height * placement.height;
  return Rect.fromLTWH(left, top, width, height);
}

Color _solidBackground(SurfaceProject project) {
  return project.transparent ? Colors.transparent : Colors.white;
}

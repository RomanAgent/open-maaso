import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:maaso/src/core/foundation/app_localization.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass_surface.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_glass_theme.dart';
import 'package:maaso/src/desktop/application/companion_menu_catalog.dart';
import 'package:maaso/src/desktop/application/desktop_window_mode_controller.dart';
import 'package:maaso/src/desktop/presentation/companion_function_menu.dart';
import 'package:maaso/src/desktop/presentation/windows_unity_player_host_view.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_portal_coordinator.dart';
import 'package:maaso/src/features/agent/presentation/companion/avatar_portal_texture.dart';
import 'package:maaso/src/features/agent/presentation/companion/avatar_portal_scope.dart';

class DesktopPetStage extends StatefulWidget {
  const DesktopPetStage({
    required this.windowController,
    required this.onDestinationSelected,
    super.key,
  });

  static const Key toolbarKey = ValueKey<String>('desktop-pet-toolbar');
  static const Key dragAreaKey = ValueKey<String>('desktop-pet-drag-area');
  static const Key menuButtonKey = ValueKey<String>('desktop-pet-menu-button');
  static const Key openAppButtonKey = ValueKey<String>(
    'desktop-pet-open-app-button',
  );
  static const Key fallbackAvatarKey = ValueKey<String>(
    'desktop-pet-fallback-avatar',
  );

  final DesktopWindowModeController windowController;
  final ValueChanged<CompanionMenuEntry> onDestinationSelected;

  @override
  State<DesktopPetStage> createState() => _DesktopPetStageState();
}

class _DesktopPetStageState extends State<DesktopPetStage> {
  AvatarPortalCoordinator? _portal;
  bool _portalRebuildScheduled = false;
  bool _menuOpen = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextPortal = AvatarPortalScope.maybeOf(context)?.portal;
    if (identical(nextPortal, _portal)) return;
    _portal?.removeListener(_handlePortalChanged);
    _portal = nextPortal;
    nextPortal?.addListener(_handlePortalChanged);
    if (nextPortal != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !identical(nextPortal, _portal)) return;
        unawaited(
          nextPortal.summon().then<void>(
            (_) {},
            onError: (Object _, StackTrace _) {},
          ),
        );
      });
    }
  }

  @override
  void dispose() {
    final portal = _portal;
    portal?.removeListener(_handlePortalChanged);
    if (portal != null) unawaited(portal.release());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final motionDuration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : MaasoGlassTheme.motionStandard;
    return Material(
      type: MaterialType.transparency,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Positioned.fill(
            top: 58,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: _buildAvatar(glass),
            ),
          ),
          Positioned(top: 8, left: 8, right: 8, child: _buildToolbar(context)),
          Positioned.fill(
            top: 62,
            left: 8,
            right: 8,
            bottom: 8,
            child: IgnorePointer(
              ignoring: !_menuOpen,
              child: AnimatedOpacity(
                opacity: _menuOpen ? 1 : 0,
                duration: motionDuration,
                child: AppGlassSurface(
                  role: AppGlassSurfaceRole.transient,
                  behavior: AppGlassSurfaceBehavior.staticSurface,
                  padding: const EdgeInsets.all(2),
                  child: CompanionFunctionMenu(
                    onSelected: widget.onDestinationSelected,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return AppGlassSurface(
      key: DesktopPetStage.toolbarKey,
      role: AppGlassSurfaceRole.chrome,
      behavior: AppGlassSurfaceBehavior.staticSurface,
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Row(
        children: <Widget>[
          IconButton(
            key: DesktopPetStage.menuButtonKey,
            tooltip: _text(
              'companion.menu.open',
              zh: '打开功能菜单',
              en: 'Open function menu',
            ),
            onPressed: () => setState(() => _menuOpen = !_menuOpen),
            icon: Icon(
              _menuOpen ? Icons.close_rounded : Icons.apps_rounded,
              color: glass.foregroundPrimary,
            ),
          ),
          Expanded(
            child: GestureDetector(
              key: DesktopPetStage.dragAreaKey,
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => unawaited(
                widget.windowController.startDragging().catchError(
                  (Object _, StackTrace _) {},
                ),
              ),
              child: Center(
                child: Text(
                  'Maaso',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: glass.foregroundPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            key: DesktopPetStage.openAppButtonKey,
            tooltip: _text(
              'companion.open_app',
              zh: '打开完整应用',
              en: 'Open full app',
            ),
            onPressed: () => unawaited(
              widget.windowController.enterAppMode().catchError(
                (Object _, StackTrace _) {},
              ),
            ),
            icon: Icon(
              Icons.open_in_full_rounded,
              color: glass.foregroundPrimary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAvatar(MaasoGlassTheme glass) {
    final fallback = _buildFallbackAvatar(glass);
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      return WindowsUnityPlayerHostView(fallback: fallback);
    }
    final portal = _portal;
    final lease = portal?.lease;
    if (portal?.phase == AvatarPortalPhase.visible && lease != null) {
      return AvatarPortalTexture(lease: lease);
    }
    return fallback;
  }

  Widget _buildFallbackAvatar(MaasoGlassTheme glass) {
    return Center(
      key: DesktopPetStage.fallbackAvatarKey,
      child: AppGlassSurface(
        role: AppGlassSurfaceRole.orb,
        behavior: AppGlassSurfaceBehavior.staticSurface,
        width: 112,
        height: 112,
        alignment: Alignment.center,
        child: Icon(
          Icons.auto_awesome_rounded,
          size: 52,
          color: glass.accent,
          semanticLabel: _text(
            'companion.avatar.preparing',
            zh: '桌宠形象准备中',
            en: 'Desktop avatar is preparing',
          ),
        ),
      ),
    );
  }

  void _handlePortalChanged() {
    if (!mounted) return;
    if (WidgetsBinding.instance.schedulerPhase !=
        SchedulerPhase.persistentCallbacks) {
      setState(() {});
      return;
    }
    if (_portalRebuildScheduled) return;
    _portalRebuildScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _portalRebuildScheduled = false;
      if (mounted) setState(() {});
    });
  }

  String _text(String key, {required String zh, required String en}) {
    final translated = key.tr;
    if (translated != key) return translated;
    return AppLocalization.locale.languageCode == 'zh' ? zh : en;
  }
}

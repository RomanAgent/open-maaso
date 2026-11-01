import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/features/applets/data/applet_catalog_service.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/applets/domain/applet_catalog_models.dart';
import 'package:maaso/src/features/widgets_hub/application/widgets_hub_controller.dart';

/// Shared native chrome for standalone, official, and Home applet players.
class AppletPlayerLikeButton extends StatefulWidget {
  const AppletPlayerLikeButton({
    super.key,
    this.appletId,
    this.likedByMe = false,
    this.official = false,
  });
  final String? appletId;
  final bool likedByMe;
  final bool official;

  @override
  State<AppletPlayerLikeButton> createState() => _AppletPlayerLikeButtonState();
}

class _AppletPlayerLikeButtonState extends State<AppletPlayerLikeButton> {
  late final String _scopeKey = AppletLocalOwnership.currentScopeKey();
  AppletEngagementSnapshot? _snapshot;
  bool _busy = false;
  int _generation = 0;

  bool get _isCurrent =>
      mounted && _scopeKey == AppletLocalOwnership.currentScopeKey();

  @override
  void initState() {
    super.initState();
    _refreshEngagement();
  }

  @override
  void didUpdateWidget(covariant AppletPlayerLikeButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.appletId != oldWidget.appletId ||
        widget.official != oldWidget.official) {
      _snapshot = null;
      _refreshEngagement();
    }
  }

  Future<void> _refreshEngagement() async {
    final generation = ++_generation;
    _busy = false;
    final id = widget.appletId;
    final catalog = appServices.maybeFind<AppletCatalogService>();
    if (id == null || catalog == null) return;
    _busy = true;
    final contextKey = catalog.requestContextKey;
    try {
      final snapshot = widget.official
          ? await catalog.officialEngagement(id, expectedContextKey: contextKey)
          : await catalog.getEngagement(id, expectedContextKey: contextKey);
      if (_isCurrent &&
          generation == _generation &&
          contextKey == catalog.requestContextKey) {
        appServices.maybeFind<WidgetsHubController>()?.appletEngagement[id] =
            snapshot;
        setState(() => _snapshot = snapshot);
      }
    } catch (_) {
      // A failed count lookup must not prevent opening the applet.
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _toggle(bool liked) async {
    final id = widget.appletId;
    final catalog = appServices.maybeFind<AppletCatalogService>();
    if (!_isCurrent || _busy || id == null || catalog == null) return;
    final generation = _generation;
    final contextKey = catalog.requestContextKey;
    setState(() => _busy = true);
    try {
      final hub = appServices.maybeFind<WidgetsHubController>();
      if (!widget.official && hub != null) {
        await hub.toggleAppletLike(id, likedByMe: liked);
        if (_isCurrent && generation == _generation) {
          setState(() => _snapshot = hub.appletEngagement[id]);
        }
      } else {
        final snapshot = widget.official
            ? await catalog.setOfficialLiked(
                id,
                !liked,
                expectedContextKey: contextKey,
              )
            : await catalog.setLiked(
                id,
                !liked,
                expectedContextKey: contextKey,
              );
        if (_isCurrent &&
            generation == _generation &&
            contextKey == catalog.requestContextKey) {
          hub?.appletEngagement[id] = snapshot;
          setState(() => _snapshot = snapshot);
        }
      }
    } catch (_) {
      if (_isCurrent && generation == _generation) {
        showAppGlassNotice(
          title: 'game_feed.like_failed_title'.tr,
          message: 'game_feed.like_failed'.tr,
          icon: Icons.cloud_off_rounded,
        );
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hub = appServices.maybeFind<WidgetsHubController>();
    Widget button(AppletEngagementSnapshot? snapshot, bool busy) {
      final liked = snapshot?.likedByMe ?? widget.likedByMe;
      final available =
          widget.appletId != null &&
          _isCurrent &&
          appServices.isRegistered<AppletCatalogService>();
      return Semantics(
        toggled: liked,
        child: AppGlassIconButton(
          key: const ValueKey('applet-player-like'),
          size: 48,
          icon: liked ? Icons.thumb_up_rounded : Icons.thumb_up_outlined,
          tooltip: available
              ? 'game_feed.like'.tr
              : 'widgets.like_unavailable'.tr,
          onPressed: available && !busy ? () => _toggle(liked) : null,
        ),
      );
    }

    if (widget.official || hub == null || widget.appletId == null) {
      return button(_snapshot, _busy);
    }
    return AppReactiveBuilder(
      () => button(
        hub.appletEngagement[widget.appletId] ?? _snapshot,
        _busy || hub.isAppletLikeInFlight(widget.appletId!),
      ),
    );
  }
}

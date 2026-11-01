import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/capability/app_route_capability_policy.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass_notice_surface.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_frost_tokens.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_glass_theme.dart';

import 'app_services.dart';

final rootNavigatorKey = GlobalKey<NavigatorState>();

enum AppTransition { cupertino }

enum AppSnackPosition { top, bottom }

class AppNavigation {
  GoRouter? _router;
  Object? currentExtra;
  bool _dialogOpen = false;
  final ValueNotifier<_AppTopNoticeRequest?> _topNotice =
      ValueNotifier<_AppTopNoticeRequest?>(null);
  int _topNoticeGeneration = 0;
  int _topNoticeHostCount = 0;

  GoRouter get router =>
      _router ?? (throw StateError('App router has not been configured'));

  bool get isConfigured => _router != null;

  void configure(GoRouter router) {
    _router = router;
  }

  String get currentRoute {
    final configuration = _router?.routerDelegate.currentConfiguration;
    if (configuration == null) return '/';
    RouteMatchList matches = configuration;
    // push/replace retain the base URI on the outer configuration. The last
    // leaf includes ShellRoute children and identifies the actual visible page.
    var top = matches.lastOrNull;
    while (top is ImperativeRouteMatch) {
      matches = top.matches;
      top = matches.lastOrNull;
    }
    return matches.uri.toString();
  }

  BuildContext? get context => rootNavigatorKey.currentContext;

  double get viewportWidth {
    final current = context;
    return current == null ? 0 : MediaQuery.sizeOf(current).width;
  }

  bool get isDialogOpen => _dialogOpen;

  /// Returns the public destinations exposed by one immutable capability
  /// snapshot. The legacy platform matrix remains the fallback while tests or
  /// early bootstrap code have not registered the process-wide service yet.
  List<AppDestination> visibleDestinations({
    AppCapabilitySnapshot? snapshot,
    AppPlatformCapabilities? platformCapabilities,
  }) {
    final registeredSnapshots = snapshot == null
        ? appServices.maybeFind<AppCapabilitySnapshotService>()
        : null;
    if (registeredSnapshots?.isClosed == true) {
      return const <AppDestination>[];
    }
    final resolvedSnapshot = snapshot ?? registeredSnapshots?.value;
    if (resolvedSnapshot != null) {
      return AppRouteCatalog.menuDestinations
          .where(
            (destination) => resolvedSnapshot.allows(
              AppCapabilityKey.route(destination.id),
              requireVisible: true,
            ),
          )
          .toList(growable: false);
    }

    final capabilities =
        platformCapabilities ?? AppPlatformCapabilities.current();
    return AppRouteCatalog.menuDestinations
        .where(
          (destination) =>
              capabilities.destinationStatus(destination.id).routeAvailable,
        )
        .toList(growable: false);
  }

  /// Synchronous final gate for registered navigation callbacks.
  bool canNavigateTo(String route) {
    final service = appServices.maybeFind<AppCapabilitySnapshotService>();
    if (service == null) return true;
    if (service.isClosed) return false;
    final snapshot = service.value;
    final decision = routeCapabilityDecisionForLocation(
      route,
      snapshot: snapshot,
      platformCapabilities: AppPlatformCapabilities.forPlatform(
        snapshot.context.hostPlatform,
      ),
    );
    return decision?.isAllowed ?? true;
  }

  Future<T?> push<T extends Object?>(String route, {Object? extra}) async {
    if (!canNavigateTo(route)) return null;
    currentExtra = extra;
    return router.push<T>(route, extra: extra);
  }

  void go(String route, {Object? extra}) {
    if (!canNavigateTo(route)) return;
    currentExtra = extra;
    router.go(route, extra: extra);
  }

  Future<T?> replace<T extends Object?>(String route, {Object? extra}) {
    if (!canNavigateTo(route)) return Future<T?>.value();
    currentExtra = extra;
    return router.replace<T>(route, extra: extra);
  }

  void pop<T extends Object?>({
    T? result,
    BuildContext? from,
    String? fallbackRoute,
  }) {
    final rootNavigator = rootNavigatorKey.currentState;
    final navigator =
        rootNavigator ?? (from == null ? null : Navigator.maybeOf(from));
    if (navigator?.canPop() == true) {
      navigator!.pop<T>(result);
      return;
    }
    if (fallbackRoute != null && _router != null) {
      go(fallbackRoute);
    } else if (rootNavigator != null && _shouldReturnDesktopRouteToHome()) {
      go(AppRouteCatalog.home);
    }
  }

  bool _shouldReturnDesktopRouteToHome() {
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.macOS &&
            defaultTargetPlatform != TargetPlatform.windows)) {
      return false;
    }
    final path = Uri.tryParse(currentRoute)?.path;
    return path != null &&
        path.isNotEmpty &&
        path != AppRouteCatalog.home &&
        path != AppRouteCatalog.login &&
        path != AppRouteCatalog.accountStandby &&
        path != AppRouteCatalog.onboarding;
  }

  Future<T?> pushPage<T extends Object?>(
    Widget Function() page, {
    AppTransition? transition,
  }) {
    final navigator = rootNavigatorKey.currentState;
    if (navigator == null) return Future<T?>.value();
    final route = transition == AppTransition.cupertino
        ? CupertinoPageRoute<T>(builder: (_) => page())
        : MaterialPageRoute<T>(builder: (_) => page());
    return navigator.push<T>(route);
  }

  Future<T?> dialog<T>(
    Widget dialog, {
    bool barrierDismissible = true,
    Color barrierColor = Colors.black54,
  }) async {
    final current = context;
    if (current == null) return null;
    _dialogOpen = true;
    try {
      return await showDialog<T>(
        context: current,
        barrierDismissible: barrierDismissible,
        barrierColor: barrierColor,
        builder: (_) => dialog,
      );
    } finally {
      _dialogOpen = false;
    }
  }

  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? showSnackBar({
    String? title,
    String? message,
    Duration duration = const Duration(seconds: 3),
    AppSnackPosition snackPosition = AppSnackPosition.top,
    Color? backgroundColor,
    Color? colorText,
    EdgeInsetsGeometry? margin,
    EdgeInsetsGeometry? padding,
    double? borderRadius,
    List<BoxShadow>? boxShadows,
    Widget? icon,
    Widget? messageText,
  }) {
    final text = title == null || title.isEmpty
        ? (message ?? '')
        : '$title\n${message ?? ''}';
    if (snackPosition == AppSnackPosition.top && _topNoticeHostCount > 0) {
      final request = _AppTopNoticeRequest(
        generation: ++_topNoticeGeneration,
        text: text,
        duration: duration,
        margin: margin,
        padding: padding,
        borderRadius: borderRadius,
        icon: icon,
        messageText: messageText,
      );
      _topNotice.value = request;
      return null;
    }
    final current = context;
    if (current == null) return null;
    final messenger = ScaffoldMessenger.maybeOf(current);
    return messenger?.showSnackBar(
      appGlassSnackBar(
        content: messageText ?? _AppNoticeText(text: text, icon: icon),
        duration: duration,
        margin: margin,
        padding: padding,
        cornerRadius: borderRadius,
      ),
    );
  }

  void dismissTopSnackBar({int? generation}) {
    final current = _topNotice.value;
    if (current == null ||
        (generation != null && current.generation != generation)) {
      return;
    }
    _topNotice.value = null;
  }
}

final appNavigation = AppNavigation();

class AppTopNoticeHost extends StatefulWidget {
  const AppTopNoticeHost({super.key});

  @override
  State<AppTopNoticeHost> createState() => _AppTopNoticeHostState();
}

class _AppTopNoticeHostState extends State<AppTopNoticeHost> {
  @override
  void initState() {
    super.initState();
    appNavigation._topNoticeHostCount += 1;
  }

  @override
  void dispose() {
    appNavigation._topNoticeHostCount -= 1;
    if (appNavigation._topNoticeHostCount == 0) {
      appNavigation.dismissTopSnackBar();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          ValueListenableBuilder<_AppTopNoticeRequest?>(
            valueListenable: appNavigation._topNotice,
            builder: (context, request, _) {
              if (request == null) return const SizedBox.shrink();
              return _AppTopNoticeEntry(
                key: ValueKey<int>(request.generation),
                request: request,
                onDismissed: () => appNavigation.dismissTopSnackBar(
                  generation: request.generation,
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _AppTopNoticeRequest {
  const _AppTopNoticeRequest({
    required this.generation,
    required this.text,
    required this.duration,
    required this.margin,
    required this.padding,
    required this.borderRadius,
    required this.icon,
    required this.messageText,
  });

  final int generation;
  final String text;
  final Duration duration;
  final EdgeInsetsGeometry? margin;
  final EdgeInsetsGeometry? padding;
  final double? borderRadius;
  final Widget? icon;
  final Widget? messageText;
}

class _AppTopNoticeEntry extends StatefulWidget {
  const _AppTopNoticeEntry({
    required this.request,
    required this.onDismissed,
    super.key,
  });

  final _AppTopNoticeRequest request;
  final VoidCallback onDismissed;

  @override
  State<_AppTopNoticeEntry> createState() => _AppTopNoticeEntryState();
}

class _AppTopNoticeEntryState extends State<_AppTopNoticeEntry> {
  Timer? _timer;
  bool _visible = false;
  bool _dismissing = false;

  Duration get _motionDuration => MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : kThemeAnimationDuration;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _visible = true);
      final media = MediaQuery.maybeOf(context);
      final requested = widget.request.duration;
      final effective =
          media?.accessibleNavigation == true &&
              requested < const Duration(seconds: 5)
          ? const Duration(seconds: 5)
          : requested;
      if (effective <= Duration.zero) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _beginDismiss());
      } else {
        _timer = Timer(effective, _beginDismiss);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _beginDismiss() {
    if (!mounted || _dismissing) return;
    _dismissing = true;
    setState(() => _visible = false);
    final duration = _motionDuration;
    if (duration == Duration.zero) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onDismissed();
      });
      return;
    }
    _timer = Timer(duration, () {
      if (mounted) widget.onDismissed();
    });
  }

  @override
  Widget build(BuildContext context) {
    final request = widget.request;
    final decoratedNotice = AppGlassNoticeSurface(
      key: const ValueKey<String>('app-top-notice'),
      cornerRadius: request.borderRadius ?? MaasoFrostTokens.compactRadius,
      padding:
          request.padding ??
          const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child:
          request.messageText ??
          _AppNoticeText(text: request.text, icon: request.icon),
    );
    final notice = request.messageText == null
        ? Semantics(
            key: const ValueKey<String>('app-top-notice-semantics'),
            container: true,
            liveRegion: true,
            excludeSemantics: true,
            label: request.text,
            child: decoratedNotice,
          )
        : decoratedNotice;
    final motionDuration = _motionDuration;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: request.margin ?? const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: AnimatedSlide(
                duration: motionDuration,
                curve: Curves.easeOutCubic,
                offset: _visible ? Offset.zero : const Offset(0, -0.12),
                child: AnimatedOpacity(
                  duration: motionDuration,
                  curve: Curves.easeOutCubic,
                  opacity: _visible ? 1 : 0,
                  alwaysIncludeSemantics: true,
                  child: notice,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AppNoticeText extends StatelessWidget {
  const _AppNoticeText({required this.text, this.icon});

  final String text;
  final Widget? icon;

  @override
  Widget build(BuildContext context) {
    final foreground = MaasoGlassTheme.of(context).foregroundPrimary;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (icon != null) ...<Widget>[
          ColorFiltered(
            key: const ValueKey<String>('app-top-notice-icon'),
            colorFilter: ColorFilter.mode(foreground, BlendMode.srcIn),
            child: icon!,
          ),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: foreground,
              decoration: TextDecoration.none,
            ),
          ),
        ),
      ],
    );
  }
}

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/applet_chat_reference.dart';
import 'package:maaso/src/core/widgets/surface_web_view.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';
import 'package:maaso/src/features/applets/application/applet_reuse.dart';
import 'package:maaso/src/features/applets/data/applet_catalog_service.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/applets/domain/applet_catalog_models.dart';

class AppletChatCard extends StatelessWidget {
  const AppletChatCard({super.key, required this.reference});
  final AppletChatReference reference;
  @override
  Widget build(BuildContext context) {
    if (reference.scopeKey != AppletLocalOwnership.currentScopeKey()) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        key: ValueKey('chat-applet-${reference.id}'),
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.apps_rounded),
        title: Text(
          reference.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text('widgets.title'.tr),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => appNavigation.pushPage(
          () => ReusedAppletPage(reference: reference),
        ),
      ),
    );
  }
}

/// A configured instance uses a separate runtime and never becomes an owned applet.
class ReusedAppletPage extends StatefulWidget {
  const ReusedAppletPage({super.key, required this.reference});
  final AppletChatReference reference;
  @override
  State<ReusedAppletPage> createState() => _ReusedAppletPageState();
}

class _ReusedAppletPageState extends State<ReusedAppletPage>
    with WidgetsBindingObserver {
  final _runtime = SurfaceRuntime();
  final List<Worker> _scopeWorkers = [];
  AppletEngagementSnapshot? _engagement;
  bool _loading = true;
  bool _failed = false;
  bool _liking = false;
  int? _configuredSession;
  bool _configurationComplete = false;
  bool _recordingView = false;
  final _viewEventId = 'applet_${DateTime.now().microsecondsSinceEpoch}';
  Timer? _viewTimer;
  bool _foreground = true;
  bool get _current =>
      mounted &&
      widget.reference.scopeKey == AppletLocalOwnership.currentScopeKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _runtime.initializeLifecycle();
    _scopeWorkers.addAll(
      AppletLocalOwnership.watchScope(() {
        if (!_current) {
          unawaited(_runtime.close());
          if (mounted) {
            setState(() {
              _failed = true;
              _loading = false;
            });
          }
        }
      }),
    );
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final catalog = appServices.find<AppletCatalogService>();
      final context = catalog.requestContextKey;
      final source = await loadReusedAppletSource(
        widget.reference,
        fetch: () =>
            catalog.source(widget.reference.id, expectedContextKey: context),
      );
      if (!_current ||
          catalog.requestContextKey != context ||
          source.sourceSha256 != widget.reference.sourceSha256 ||
          source.revisionNo != widget.reference.revision) {
        throw StateError('applet_revision_changed');
      }
      validateAppletReuse(source, widget.reference.actions);
      await _runtime.showWithSession(
        SurfaceProject.fromJson(
          source.toProjectJson(
            instanceId:
                'reuse_${source.id}_${DateTime.now().microsecondsSinceEpoch}',
          ),
        ),
      );
      if (!_current) {
        await _runtime.close();
        return;
      }
      setState(() => _loading = false);
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }
  }

  Future<void> _configure() async {
    final session = _runtime.activeSession;
    if (!_current || _configuredSession == session) return;
    _configuredSession = session;
    for (final action in widget.reference.actions) {
      if (!_current || !_runtime.isSessionCurrent(session)) return;
      final error = await _runtime.surfaceCall(
        action['name'] as String,
        action['arguments'],
      );
      if (error != null) {
        if (_current) setState(() => _failed = true);
        return;
      }
    }
    _configurationComplete = true;
    _scheduleView(session);
  }

  void _scheduleView(int session) {
    if (_engagement != null || _recordingView || !_configurationComplete) {
      return;
    }
    _viewTimer?.cancel();
    _viewTimer = Timer(const Duration(seconds: 2), () async {
      if (!_current ||
          !_foreground ||
          !(ModalRoute.of(context)?.isCurrent ?? true) ||
          !_runtime.isSessionCurrent(session)) {
        return;
      }
      _recordingView = true;
      try {
        final catalog = appServices.find<AppletCatalogService>();
        final result = await catalog.recordView(
          widget.reference.id,
          eventId: _viewEventId,
          expectedContextKey: catalog.requestContextKey,
        );
        if (_current) setState(() => _engagement = result);
      } catch (_) {
        /* Offline playback keeps its configured content. */
      } finally {
        _recordingView = false;
      }
    });
  }

  Future<void> _like() async {
    if (!_current || _liking || _engagement == null) return;
    setState(() => _liking = true);
    try {
      final catalog = appServices.find<AppletCatalogService>();
      final result = await catalog.setLiked(
        widget.reference.id,
        !_engagement!.likedByMe,
        expectedContextKey: catalog.requestContextKey,
      );
      if (_current) setState(() => _engagement = result);
    } catch (_) {
      if (_current) {
        appNavigation.showSnackBar(message: 'widgets.open_failed'.tr);
      }
    } finally {
      if (mounted) setState(() => _liking = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground &&
        !_loading &&
        !_failed &&
        _configuredSession == null &&
        _current) {
      setState(() => _loading = true);
      unawaited(_load());
    } else if (_foreground && _current && !_failed && _configurationComplete) {
      _scheduleView(_runtime.activeSession);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _viewTimer?.cancel();
    for (final worker in _scopeWorkers) {
      worker.dispose();
    }
    unawaited(_runtime.close().whenComplete(_runtime.closeLifecycle));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Stack(
      fit: StackFit.expand,
      children: [
        if (_failed)
          Center(child: Text('widgets.open_failed'.tr))
        else if (_loading)
          const Center(child: CircularProgressIndicator())
        else
          SurfaceWebView(
            runtime: _runtime,
            onFirstFrameReady: (_) => unawaited(_configure()),
            onWorkerFatal: (_) {
              if (mounted) setState(() => _failed = true);
            },
          ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  AppGlassIconButton(
                    icon: Icons.arrow_back_rounded,
                    tooltip: 'common.back'.tr,
                    onPressed: () => appNavigation.pop(),
                  ),
                  const Spacer(),
                  AppGlassIconButton(
                    icon: _engagement?.likedByMe == true
                        ? Icons.thumb_up_alt
                        : Icons.thumb_up_alt_outlined,
                    tooltip: _engagement?.likedByMe == true
                        ? 'widgets.unlike'.tr
                        : 'widgets.like'.tr,
                    onPressed:
                        _loading || _failed || _liking || _engagement == null
                        ? null
                        : _like,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

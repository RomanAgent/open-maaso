import 'package:maaso/src/features/project_build/data/project_bundle_installation_store.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_catalog.dart';
import 'package:maaso/src/features/project_build/domain/project_bundle_verification.dart';
import 'package:maaso/src/features/project_build/presentation/project_build_saved_management.dart';
import 'package:maaso/src/features/agent/application/surface/surface_bundle_presentation.dart';
import 'package:maaso/src/core/widgets/surface_bundle_controls.dart';
import 'package:maaso/src/features/applets/presentation/applet_version_history_sheet.dart';
import 'package:maaso/src/features/people_safety/presentation/people_block_dialog.dart';
import 'package:maaso/src/features/people_safety/domain/people_block.dart';
import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart' as crypto;
import 'package:maaso/src/features/widgets_hub/application/game_companion_context.dart';
import 'package:maaso/src/features/widgets_hub/presentation/game_companion_controls.dart';
import 'dart:math' as math;
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/features/applets/application/applet_edit_reference.dart';
import 'package:maaso/src/features/widgets_hub/presentation/applet_my_page_adapter_scope.dart';
import 'package:maaso/src/features/widgets_hub/presentation/applet_player_like_button.dart';
import 'package:maaso/src/features/content_engagement/application/content_consumption_controller.dart';
import 'package:maaso/src/features/content_engagement/data/content_engagement_client.dart';
import 'package:maaso/src/features/content_engagement/domain/content_engagement.dart';
import 'package:maaso/src/features/content_engagement/domain/comment_reporting.dart';
import 'package:maaso/src/features/content_engagement/presentation/comment_report_button.dart';
import 'package:maaso/src/features/content_engagement/domain/public_consumption_hint.dart';
import 'package:maaso/src/features/identity/domain/identity_profile.dart';
import 'package:maaso/src/features/identity/application/identity_service.dart';
import 'package:maaso/src/features/identity/presentation/identity_badge.dart';
import 'package:maaso/src/features/home/application/home_draft_intent.dart';

import 'package:flutter/material.dart';
import 'package:maaso/src/features/widgets_hub/data/game_document_loader.dart';
import 'package:maaso/src/features/widgets_hub/presentation/game_frost_chrome.dart';
import 'package:maaso/src/features/widgets_hub/presentation/game_comment_feedback.dart';
import 'package:maaso/src/features/widgets_hub/presentation/game_screenshot_preview.dart';
import 'package:maaso/src/features/widgets_hub/presentation/opened_game_snapshot.dart';
import 'package:maaso/src/features/widgets_hub/application/game_voice_companion.dart';
import 'package:maaso/src/features/widgets_hub/presentation/game_voice_host.dart';
import 'package:maaso/src/features/widgets_hub/presentation/game_voice_observation_adapter.dart';
import 'package:maaso/src/core/widgets/ui/immersive_feed_tab.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_worker_health_gate.dart';
import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:maaso/src/features/agent_games/data/agent_game_cloud_service.dart';
import 'package:maaso/src/features/applets/domain/official_applet.dart';
import 'package:maaso/src/features/applets/data/applet_catalog_service.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/applets/data/applet_presentation_state.dart';
import 'package:maaso/src/features/applets/domain/applet_catalog_models.dart';
import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/ble/yoturetoys/yoturetoys_device.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/widgets/surface_web_view.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary.dart';
import 'package:maaso/src/core/widgets/ui/world_portal.dart';
import 'package:maaso/src/core/widgets/widget_stage_controller.dart';
import 'package:maaso/src/features/widgets_hub/application/applet_category_taxonomy.dart';
import 'package:maaso/src/features/widgets_hub/application/applet_hub_route_intent.dart';
import 'package:maaso/src/features/widgets_hub/application/widgets_hub_controller.dart';
import 'package:maaso/src/features/widgets_hub/application/widgets_hub_route_dependencies.dart';
import 'package:maaso/src/features/widgets_hub/presentation/applet_category_widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';

typedef GameFeedShareCallback =
    Future<bool> Function({
      required String title,
      required String text,
      Rect? origin,
    });

/// Test seam for the native share sheet. Production always keeps this null.
GameFeedShareCallback? gameFeedShareCallbackOverride;

/// Test seam for saved first-frame Surface validation. Production uses the
/// app-root [SurfaceWorkerHealthGate].
SurfaceWorkerFirstFrameWaiter? gameFeedFirstFrameWaiterOverride;

/// Test seam for the two-second public-game impression contract.
ValueChanged<AppletCatalogItem>? gameFeedImpressionOverride;
Future<bool> Function(AppletCatalogItem item)?
gameFeedImpressionRecorderOverride;
String Function()? gameFeedImpressionScopeKeyOverride;

final _openGameRoutes = Expando<Set<String>>();

/// Opens the exact source inspected by the composer through the existing
/// player, including its loading, first-frame, back and retry behavior.
/// This is a user open operation, not an Agent execution grant.
Future<bool> openAppInvocationTarget(
  AppInvocationOpenTarget target, {
  required bool Function() canContinue,
}) async {
  bool current() =>
      canContinue() &&
      target.isCurrent &&
      target.entry.scopeKey == AppletLocalOwnership.currentScopeKey();
  if (!current() || rootNavigatorKey.currentState == null) return false;
  if (target.officialAppletId case final id?) {
    final applet = OfficialAppletRegistry.byId(id);
    if (applet == null || !current()) return false;
    unawaited(
      appNavigation.pushPage(
        () => Builder(
          builder: (context) {
            if (current()) return applet.builder();
            final route = ModalRoute.of(context);
            final navigator = Navigator.of(context);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (context.mounted && route?.isActive == true) {
                navigator.removeRoute(route!);
              }
            });
            return const SizedBox.shrink();
          },
        ),
        transition: AppTransition.cupertino,
      ),
    );
    return true;
  }
  if (!SurfaceRuntime.presentationCapabilityAvailable) return false;
  final local = target.localWidget;
  final source = target.surface;
  if (local == null && source == null) return false;
  final item =
      local ?? _CatalogSourcePlayerWidget(target: target, project: source!);
  if (!current()) return false;
  final runtime = SurfaceRuntime();
  unawaited(
    appNavigation.pushPage(
      () => RouteDependenciesScope(
        dependencies: WidgetsHubRouteDependencies(),
        child: _SurfaceViewPage(
          item: item,
          runtime: runtime,
          sourceIsCurrent: current,
        ),
      ),
      transition: AppTransition.cupertino,
    ),
  );
  return true;
}

/// A catalog source is playable without becoming a saved personal work.
/// Persisted JSON cannot construct this type or acquire this live source check.
final class _CatalogSourcePlayerWidget extends AgentWidget {
  _CatalogSourcePlayerWidget({
    required this.target,
    required SurfaceProject project,
  }) : super(
         agentId: 'self',
         title: project.title,
         subtitle: target.entry.summary,
         kind: 'surface',
         createdAt: DateTime.now(),
         spec: {...project.toJson(), 'surfaceId': project.id},
       ) {
    AppletLocalOwnership.stamp(this, scopeKey: target.entry.scopeKey);
  }

  final AppInvocationOpenTarget target;
}

void _pushGamePage(String identity, Widget Function() page) {
  final navigator = rootNavigatorKey.currentState;
  if (navigator == null) return;
  final routes = _openGameRoutes[navigator] ??= <String>{};
  final key = '${AppletLocalOwnership.currentScopeKey()}|$identity';
  if (!routes.add(key)) return;
  unawaited(
    appNavigation
        .pushPage(page, transition: AppTransition.cupertino)
        .whenComplete(() => routes.remove(key)),
  );
}

/// Native-only view identity. JSON can never construct an unsaved candidate
/// with execution authority or bypass the persisted-widget ownership checks.
final class _VerifiedBundlePlayerWidget extends AgentWidget {
  _VerifiedBundlePlayerWidget({
    required this.installed,
    required this.permit,
    required this.hostServices,
    required this.preview,
    required this.ownerIsCurrent,
    required String scopeKey,
  }) : super(
         agentId: hostServices.agentId ?? 'self',
         title: installed.bundle.title,
         subtitle: installed.bundle.summary,
         kind: 'surface',
         createdAt: installed.installedAt,
         spec: {
           'surfaceId': installed.bundle.manifest.projectId,
           'rendering': 'projectBundle',
           'surfaceKind': 'fullscreen',
           'experienceType': installed.bundle.manifest.projectKind == 'game'
               ? 'game'
               : 'utility',
           'category': installed.bundle.manifest.projectKind == 'game'
               ? 'game'
               : 'tools',
           'summary': installed.bundle.summary,
           if (permit is VerifiedProjectBundlePermit)
             'bundleReference': {
               'packageSchema': 2,
               'projectId': installed.bundle.manifest.projectId,
               'revisionId': installed.bundle.manifest.revisionId,
               'candidateDigest': installed.candidateDigest,
               'reportDigest': permit.reportDigest,
             },
         },
       ) {
    AppletLocalOwnership.stamp(this, scopeKey: scopeKey);
  }
  final InstalledProjectBundleV2 installed;
  final ProjectBundleExecutionPermit permit;
  final SurfaceBundleHostServices hostServices;
  final bool preview;
  final bool Function() ownerIsCurrent;
}

/// Reuses the existing Surface player destination. Previews have no DB row;
/// only a private native object carries the installed bytes and live permit.
Future<bool> presentProjectBundleInPlayer(
  InstalledProjectBundleV2 installed, {
  required ProjectBundleExecutionPermit permit,
  required SurfaceBundleHostServices hostServices,
  required SurfaceRuntime runtime,
  required String expectedScopeKey,
  required bool preview,
  required bool Function() isCurrent,
  required VoidCallback onDisposed,
  VoidCallback? onHandoff,
}) async {
  var alive = true;
  BuildContext? routeContext;
  bool current() {
    final context = routeContext;
    return alive &&
        isCurrent() &&
        expectedScopeKey == AppletLocalOwnership.currentScopeKey() &&
        (context == null ||
            (context.mounted && (ModalRoute.of(context)?.isCurrent ?? true)));
  }

  Future<void> dispose() async {
    if (!alive) return;
    alive = false;
    await runtime.close();
    runtime.closeLifecycle();
    onDisposed();
  }

  if (rootNavigatorKey.currentState == null ||
      !current() ||
      (!preview && !installed.isAccepted)) {
    await dispose();
    return false;
  }
  final item = _VerifiedBundlePlayerWidget(
    installed: installed,
    permit: permit,
    hostServices: hostServices,
    preview: preview,
    ownerIsCurrent: current,
    scopeKey: expectedScopeKey,
  );
  int session;
  try {
    session = await runtime.showInstalledBundle(
      installed,
      permit: permit,
      hostServices: hostServices,
      preview: preview,
      canContinue: current,
    );
  } catch (_) {
    await dispose();
    return false;
  }
  if (!current()) {
    await dispose();
    return false;
  }
  onHandoff?.call();
  unawaited(
    appNavigation
        .pushPage<void>(
          () => Builder(
            builder: (context) {
              routeContext = context;
              return RouteDependenciesScope(
                dependencies: WidgetsHubRouteDependencies(),
                child: _SurfaceViewPage(
                  item: item,
                  runtime: runtime,
                  surfaceSession: session,
                ),
              );
            },
          ),
          transition: AppTransition.cupertino,
        )
        .whenComplete(dispose),
  );
  try {
    await runtime.waitForBundleFirstFrame(session);
    return current() && runtime.isSessionCurrent(session);
  } catch (_) {
    return false;
  }
}

/// Open an agent-made hub item from the Hub itself. Hub opens normal pages and
/// does not route back to Home; the Home depth stack uses
/// [presentAgentWidgetOnHome] below instead.
Future<void> openAgentWidget(
  AgentWidget item, {
  WidgetStageMode mode = WidgetStageMode.compact,
  bool Function()? canContinue,
}) async {
  if (canContinue?.call() == false ||
      !SurfaceRuntime.presentationCapabilityAvailable) {
    return;
  }
  final scopeKey = AppletLocalOwnership.currentScopeKey();
  if (!AppletLocalOwnership.isVisible(item, scopeKey: scopeKey)) return;
  final category = AppletCategoryTaxonomy.forWidget(item);
  if (category == AppletCategory.game) {
    // Push the immersive loading frame before reading/preparing any game.
    // This same entry point serves Home, the feed, and the owned game grid.
    _pushGamePage(
      'local:${item.id ?? item.spec['surfaceId']}',
      () => RouteDependenciesScope(
        dependencies: WidgetsHubRouteDependencies(),
        child: _SurfaceViewPage(item: item, runtime: SurfaceRuntime()),
      ),
    );
    return;
  }
  final runtime = SurfaceRuntime()..initializeLifecycle();
  final prepared = item.isSurface
      ? await _prepareSurface(
          item,
          expectedScopeKey: scopeKey,
          runtime: runtime,
          canContinue: canContinue,
        )
      : null;
  if (prepared != null) {
    if (canContinue?.call() == false ||
        !runtime.isSessionCurrent(prepared.session)) {
      await runtime.closeIfSession(prepared.session);
      runtime.closeLifecycle();
      return;
    }
    appNavigation.pushPage(() {
      final page = _SurfaceViewPage(
        item: prepared.item,
        surfaceSession: prepared.session,
        runtime: runtime,
      );
      if (category != AppletCategory.game) return page;
      return RouteDependenciesScope(
        dependencies: WidgetsHubRouteDependencies(),
        child: page,
      );
    }, transition: AppTransition.cupertino);
  } else {
    runtime.closeLifecycle();
  }
}

Future<void> presentAgentWidgetOnHome(
  AgentWidget item, {
  WidgetStageMode mode = WidgetStageMode.compact,
}) async {
  if (!SurfaceRuntime.presentationCapabilityAvailable) return;
  final scopeKey = AppletLocalOwnership.currentScopeKey();
  if (!AppletLocalOwnership.isVisible(item, scopeKey: scopeKey)) return;
  if (!shouldPresentAgentWidgetOnHome(item)) {
    await openAgentWidget(item, mode: mode);
    return;
  }
  if (!appServices.isRegistered<WidgetStageController>()) {
    await openAgentWidget(item, mode: mode);
    return;
  }
  if (!item.isSurface) return;
  final prepared = await _prepareSurface(item, expectedScopeKey: scopeKey);
  if (prepared == null) return;
  final runtime = appServices.find<SurfaceRuntime>();
  if (!runtime.isSessionCurrent(prepared.session)) {
    await runtime.closeIfSession(prepared.session);
    return;
  }
  appServices.find<WidgetStageController>().present(
    prepared.item,
    nextMode: mode,
  );
}

bool shouldPresentAgentWidgetOnHome(AgentWidget item) {
  return item.isSurface &&
      AppletCategoryTaxonomy.forWidget(item) != AppletCategory.game;
}

Future<void> _closeGlobalGameSurface() async {
  if (!appServices.isRegistered<SurfaceRuntime>()) return;
  final runtime = appServices.find<SurfaceRuntime>();
  if (runtime.activeProject.value?.experienceType !=
      SurfaceExperienceType.game) {
    return;
  }
  final healthGate = appServices.maybeFind<SurfaceWorkerHealthGate>();
  if (healthGate?.hasValidationClaim == true) return;
  final session = runtime.activeSession;
  await runtime.closeIfSession(session);
}

Future<_PreparedSurface?> _prepareSurface(
  AgentWidget item, {
  required String expectedScopeKey,
  SurfaceRuntime? runtime,
  bool Function()? canContinue,
}) async {
  final selectedRuntime =
      runtime ??
      (appServices.isRegistered<SurfaceRuntime>()
          ? appServices.find<SurfaceRuntime>()
          : null);
  if (selectedRuntime == null ||
      !SurfaceRuntime.presentationCapabilityAvailable ||
      expectedScopeKey != AppletLocalOwnership.currentScopeKey()) {
    return null;
  }
  if (item is _VerifiedBundlePlayerWidget) {
    if (!item.ownerIsCurrent() ||
        !item.permit.isCurrent ||
        !item.installed.isCurrent ||
        !AppletLocalOwnership.isVisible(item, scopeKey: expectedScopeKey) ||
        (!item.preview && !item.installed.isAccepted)) {
      return null;
    }
    try {
      final session = await selectedRuntime.showInstalledBundle(
        item.installed,
        permit: item.permit,
        hostServices: item.hostServices,
        preview: item.preview,
        canContinue: () =>
            item.ownerIsCurrent() && (canContinue?.call() ?? true),
      );
      return _PreparedSurface(item: item, session: session);
    } catch (_) {
      return null;
    }
  }
  final current = await _reloadDiscoverableSurface(
    item,
    expectedScopeKey: expectedScopeKey,
  );
  if (current == null) return null;
  if (current.spec['rendering'] == 'projectBundle' ||
      current.spec.containsKey('bundleReference')) {
    final services = appServices.maybeFind<SurfaceBundleHostServices>();
    final reference = current.spec['bundleReference'];
    if (services == null ||
        reference is! Map ||
        reference.length != 5 ||
        reference['packageSchema'] != 2 ||
        reference['candidateDigest'] is! String ||
        reference['reportDigest'] is! String ||
        current.spec['rendering'] != 'projectBundle') {
      return null;
    }
    bool authorized() =>
        expectedScopeKey == AppletLocalOwnership.currentScopeKey() &&
        SurfaceRuntime.presentationCapabilityAvailable &&
        (canContinue?.call() ?? true);
    int? bundleSession;
    try {
      final installed = await services.installations.openCandidate(
        reference['candidateDigest']! as String,
        expectedScopeKey: services.installations.scopeKey,
        reportDigest: reference['reportDigest']! as String,
      );
      if (installed == null ||
          !installed.isAccepted ||
          !authorized() ||
          installed.bundle.manifest.projectId != reference['projectId'] ||
          installed.bundle.manifest.revisionId != reference['revisionId'] ||
          installed.verificationReport == null) {
        return null;
      }
      final permit = await services.verifier.verifyReport(
        installed.bundle,
        installed.verificationReport,
        expectedReportDigest: reference['reportDigest']! as String,
      );
      if (!authorized()) return null;
      final session = await selectedRuntime.showInstalledBundle(
        installed,
        permit: permit,
        hostServices: services,
        canContinue: authorized,
      );
      bundleSession = session;
      final discoverable = await _reloadDiscoverableSurface(
        current,
        expectedScopeKey: expectedScopeKey,
      );
      final reopenedReference = discoverable?.spec['bundleReference'];
      final sameReference =
          reopenedReference is Map &&
          reference.keys.every(
            (key) => reference[key] == reopenedReference[key],
          );
      if (discoverable == null ||
          !sameReference ||
          !authorized() ||
          !selectedRuntime.isSessionCurrent(session)) {
        await selectedRuntime.closeIfSession(session);
        return null;
      }
      return _PreparedSurface(item: discoverable, session: session);
    } catch (_) {
      if (bundleSession != null) {
        await selectedRuntime.closeIfSession(bundleSession);
      }
      return null;
    }
  }
  final project = surfaceProjectFromWidget(current);
  final requiresFirstFramePreflight = surfaceRequiresFirstFrameValidation(
    project,
  );
  final firstFrameWaiter = requiresFirstFramePreflight
      ? gameFeedFirstFrameWaiterOverride ??
            appServices.maybeFind<SurfaceWorkerHealthGate>()
      : null;
  if (requiresFirstFramePreflight && firstFrameWaiter == null) return null;
  var firstFrameClaimed = false;
  var session = -1;
  try {
    if (canContinue?.call() == false) return null;
    if (firstFrameWaiter case final SurfaceWorkerHealthGate healthGate) {
      firstFrameClaimed = await healthGate.beginPresentationWhenAvailable(
        runtime: selectedRuntime,
        canBegin: () =>
            SurfaceRuntime.presentationCapabilityAvailable &&
            expectedScopeKey == AppletLocalOwnership.currentScopeKey() &&
            (canContinue?.call() ?? true),
      );
      if (!firstFrameClaimed) return null;
    } else {
      firstFrameWaiter?.beginPresentation(runtime: selectedRuntime);
      firstFrameClaimed = firstFrameWaiter != null;
    }
    if (!SurfaceRuntime.presentationCapabilityAvailable ||
        canContinue?.call() == false) {
      firstFrameWaiter?.cancelPresentation();
      return null;
    }
    session = await selectedRuntime.showWithSession(project);
    if (!selectedRuntime.isSessionCurrent(session)) {
      throw const SurfaceWorkerFirstFrameException.superseded();
    }
    if (firstFrameWaiter != null) {
      final document = selectedRuntime.document.value;
      if (document == null) {
        throw const SurfaceWorkerFirstFrameException.unavailable();
      }
      await firstFrameWaiter.waitForFirstFrame(
        session: session,
        document: document,
        timeout: project.rendering == SurfaceRendering.webApp
            ? const Duration(seconds: 15)
            : const Duration(seconds: 6),
      );
      if (!selectedRuntime.isSessionCurrent(session) ||
          selectedRuntime.activeSurfaceId != project.id) {
        throw const SurfaceWorkerFirstFrameException.superseded();
      }
    }
  } catch (error, stackTrace) {
    if (firstFrameClaimed) firstFrameWaiter?.cancelPresentation();
    if (session >= 0) await selectedRuntime.closeIfSession(session);
    Log.w(
      '[Applets] saved Surface failed first-frame preflight',
      error: error,
      stackTrace: stackTrace,
    );
    return null;
  }
  if (!selectedRuntime.isSessionCurrent(session) ||
      expectedScopeKey != AppletLocalOwnership.currentScopeKey()) {
    await selectedRuntime.closeIfSession(session);
    return null;
  }
  final discoverable = await _reloadDiscoverableSurface(
    current,
    expectedScopeKey: expectedScopeKey,
  );
  if (discoverable == null || !selectedRuntime.isSessionCurrent(session)) {
    await selectedRuntime.closeIfSession(session);
    return null;
  }
  return _PreparedSurface(item: current, session: session);
}

Future<AgentWidget?> _reloadDiscoverableSurface(
  AgentWidget item, {
  required String expectedScopeKey,
}) async {
  if (expectedScopeKey != AppletLocalOwnership.currentScopeKey()) return null;
  if (item is _CatalogSourcePlayerWidget) {
    return item.target.isCurrent &&
            isAppletPresentationDiscoverable(item, scopeKey: expectedScopeKey)
        ? item
        : null;
  }
  final id = item.id;
  if (!appServices.isRegistered<DBService>()) {
    return isAppletPresentationDiscoverable(item, scopeKey: expectedScopeKey)
        ? item
        : null;
  }
  if (id == null) return null;
  final widgets = await appServices.find<DBService>().getAllWidgets();
  if (expectedScopeKey != AppletLocalOwnership.currentScopeKey()) return null;
  final current = widgets.where((widget) => widget.id == id).firstOrNull;
  if (current == null ||
      !isAppletPresentationDiscoverable(current, scopeKey: expectedScopeKey)) {
    return null;
  }
  return current;
}

class _PreparedSurface {
  const _PreparedSurface({required this.item, required this.session});

  final AgentWidget item;
  final int session;
}

/// The Applet library. Games have their own standalone [GameFeedPage].
class WidgetsHubPage extends AppView<WidgetsHubController> {
  const WidgetsHubPage({super.key});

  @override
  Widget build(BuildContext context) {
    final routeIntent = AppletHubRouteIntent.tryParse(
      appNavigation.currentRoute,
    );
    return AppSecondaryScaffold(
      header: AppSecondaryHeader(
        title: 'widgets.title'.tr,
        onBack: () => appNavigation.pop(),
        trailing: AppGlassIconButton(
          key: const ValueKey('applet-hub-mine'),
          icon: Icons.person_outline_rounded,
          tooltip: 'widgets.mine_title'.tr,
          size: 48,
          onPressed: () => appNavigation.push(AppRouteCatalog.myApplets),
        ),
      ),
      body: Column(
        children: <Widget>[
          _AppletHubRouteEffect(
            key: ValueKey<String?>(routeIntent?.location),
            intent: routeIntent,
          ),
          const _AppletSearchBar(),
          const Expanded(child: _AppletsFunctionalList()),
        ],
      ),
    );
  }
}

class _AppletHubRouteEffect extends StatefulWidget {
  const _AppletHubRouteEffect({super.key, required this.intent});

  final AppletHubRouteIntent? intent;

  @override
  State<_AppletHubRouteEffect> createState() => _AppletHubRouteEffectState();
}

class _AppletHubRouteEffectState extends State<_AppletHubRouteEffect> {
  @override
  void initState() {
    super.initState();
    final intent = widget.intent;
    final controller = appServices.find<WidgetsHubController>();
    if (intent?.category != AppletCategory.game) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && controller.appletDiscoveryItems.isEmpty) {
          unawaited(controller.loadApplets());
        }
      });
    }
    if (intent == null) return;
    controller.selectSection(
      intent.category == AppletCategory.game
          ? AppletHubSection.games
          : AppletHubSection.applets,
    );
    controller.selectCategory(intent.category);
    if (intent.openId == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          controller.selectedCategory.value != intent.category ||
          !appServices.isRegistered<AppletCatalogService>()) {
        appletHubOpenBroker.revokeIntent(ownerAgentId: 'self', intent: intent);
        return;
      }
      final catalog = appServices.find<AppletCatalogService>();
      final item = appletHubOpenBroker.claim(
        ownerAgentId: 'self',
        intent: intent,
        currentLocation: appNavigation.currentRoute,
        requestContextKey: catalog.requestContextKey,
        latestContextKey: catalog.latestContextKey.value,
        latestPage: catalog.latestPage.value,
      );
      if (!mounted || item == null) return;
      _openCatalogItem(item);
    });
  }

  @override
  void dispose() {
    final intent = widget.intent;
    if (intent?.openId != null) {
      appletHubOpenBroker.revokeIntent(ownerAgentId: 'self', intent: intent!);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Only the current owner's confirmed creations are manageable here.
class MyAppletsPage extends AppView<WidgetsHubController> {
  const MyAppletsPage({super.key});

  @override
  Widget build(BuildContext context) => AppletMyPageAdapterScope(
    controller: controller,
    child: AppSecondaryScaffold(
      header: AppSecondaryHeader(
        title: 'widgets.mine_title'.tr,
        onBack: appNavigation.pop,
      ),
      contentMaxWidth: 680,
      body: RefreshIndicator(
        onRefresh: controller.reload,
        child: AppReactiveBuilder(() {
          final local = controller.widgets
              .where(
                (item) =>
                    item.agentId == 'self' &&
                    AppletCategoryTaxonomy.forWidget(item) !=
                        AppletCategory.game,
              )
              .toList();
          final cloud = controller.cloudOnlyItems
              .where((item) => item.item.type == AppletCatalogType.applet)
              .toList();
          final count = local.length + cloud.length;
          return ListView.separated(
            key: const ValueKey('my-applets-list'),
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            itemCount: count + 1,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              if (index < local.length) {
                return _FunctionalAppletRow(item: local[index], index: index);
              }
              if (index < count) {
                final scoped = cloud[index - local.length];
                return _CloudAppletTile(
                  key: ValueKey((
                    scoped.scopeKey,
                    scoped.item.id,
                    scoped.item.clientSurfaceId,
                  )),
                  scoped: scoped,
                );
              }
              if (controller.isRefreshing.value ||
                  controller.isLoadingCloudInventory.value) {
                return const Center(child: CircularProgressIndicator());
              }
              final error = controller.cloudInventoryErrorKey.value;
              if (error != null) {
                return _AppletSearchMessage(
                  icon: Icons.cloud_off_rounded,
                  message: error.tr,
                  onRetry: controller.reload,
                );
              }
              return count == 0
                  ? _AppletSearchMessage(
                      icon: Icons.apps_rounded,
                      message: 'widgets.mine_empty'.tr,
                    )
                  : const SizedBox.shrink();
            },
          );
        }),
      ),
    ),
  );
}

enum GameFeedSection { recommended, popular, mine }

/// Standalone full-screen game discovery.
/// Navigation floats above the content; the game keeps the whole viewport.
class GameFeedPage extends StatefulWidget {
  const GameFeedPage({super.key, this.playbackEnabled = true});
  final bool playbackEnabled;

  @override
  State<GameFeedPage> createState() => _GameFeedPageState();
}

class _GameFeedPageState extends State<GameFeedPage>
    with WidgetsBindingObserver {
  bool _foreground = true;
  bool get _playbackEnabled =>
      widget.playbackEnabled &&
      _foreground &&
      (ModalRoute.of(context)?.isCurrent ?? true);
  GameFeedSection _section = GameFeedSection.recommended;

  WidgetsHubController get _controller =>
      appServices.find<WidgetsHubController>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller.selectSection(AppletHubSection.games);
      if (_controller.recommendedGameFeedItems.isEmpty) {
        unawaited(_controller.loadGameFeed(sort: GameFeedSort.recommended));
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (_foreground != foreground) setState(() => _foreground = foreground);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final routeIntent = AppletHubRouteIntent.tryParse(
      appNavigation.currentRoute,
    );
    return Scaffold(
      key: const ValueKey<String>('game-feed-page'),
      backgroundColor: const Color(0xFF0D0D0D),
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          _AppletHubRouteEffect(
            key: ValueKey<String?>(routeIntent?.location),
            intent: routeIntent,
          ),
          switch (_section) {
            GameFeedSection.recommended => _GamesChannel(
              key: const ValueKey<String>('game-feed-recommended-view'),
              playbackEnabled: _playbackEnabled,
              sort: GameFeedSort.recommended,
              publicOnly: true,
            ),
            GameFeedSection.popular => _GamesChannel(
              key: const ValueKey<String>('game-feed-popular-view'),
              playbackEnabled: _playbackEnabled,
              sort: GameFeedSort.popular,
              publicOnly: true,
            ),
            GameFeedSection.mine => IgnorePointer(
              ignoring: !_playbackEnabled,
              child: const _OwnedGamesGrid(
                key: ValueKey<String>('game-feed-mine-grid'),
              ),
            ),
          },
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height:
                MediaQuery.paddingOf(context).top +
                (MediaQuery.textScalerOf(context).scale(20) * 4 + 48),
            child: const IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[
                      Color(0xCC000000),
                      Color(0xA6000000),
                      Colors.transparent,
                    ],
                    stops: [0, .6, 1],
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            bottom: false,
            minimum: const EdgeInsets.fromLTRB(10, 8, 10, 0),
            child: Align(
              alignment: Alignment.topCenter,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _GameFeedChromeButton(
                    key: const ValueKey<String>('game-feed-back'),
                    icon: Icons.arrow_back_rounded,
                    tooltip: 'common.back'.tr,
                    onPressed: appNavigation.pop,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _GameFeedTabs(
                      selected: _section,
                      onSelected: (section) {
                        if (!_playbackEnabled || section == _section) {
                          return;
                        }
                        setState(() => _section = section);
                        final sort = switch (section) {
                          GameFeedSection.recommended =>
                            GameFeedSort.recommended,
                          GameFeedSection.popular => GameFeedSort.popular,
                          GameFeedSection.mine => null,
                        };
                        if (sort != null &&
                            _controller.gameFeedItemsFor(sort).isEmpty) {
                          unawaited(_controller.loadGameFeed(sort: sort));
                        }
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GameFeedTabs extends StatelessWidget {
  const _GameFeedTabs({required this.selected, required this.onSelected});

  final GameFeedSection selected;
  final ValueChanged<GameFeedSection> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 4,
      children: [
        for (final section in GameFeedSection.values)
          ImmersiveFeedTab(
            key: ValueKey<String>('game-feed-tab-${section.name}'),
            selected: selected == section,
            onPressed: () => onSelected(section),
            label: switch (section) {
              GameFeedSection.recommended => 'game_feed.recommended'.tr,
              GameFeedSection.popular => 'game_feed.popular'.tr,
              GameFeedSection.mine => 'game_feed.mine'.tr,
            },
          ),
      ],
    );
  }
}

class _GameFeedChromeButton extends StatelessWidget {
  const _GameFeedChromeButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return GameFrostIconButton(
      blur: true,
      icon: icon,
      tooltip: tooltip,
      onPressed: onPressed,
    );
  }
}

/// Exercises the local/remote channel engine without restoring a hidden Games
/// branch in the Applet library. Product navigation uses [GameFeedPage].
@visibleForTesting
class GameFeedChannelTestHost extends StatelessWidget {
  const GameFeedChannelTestHost({super.key});

  @override
  Widget build(BuildContext context) => const _GamesChannel();
}

class _GamesChannel extends StatefulWidget {
  const _GamesChannel({
    super.key,
    this.sort = GameFeedSort.recommended,
    this.publicOnly = false,
    this.playbackEnabled = true,
  });

  final GameFeedSort sort;
  final bool publicOnly;
  final bool playbackEnabled;

  @override
  State<_GamesChannel> createState() => _GamesChannelState();
}

class _GamesChannelState extends State<_GamesChannel> {
  late final PageController _pages;
  int _activeIndex = 0;
  String? _activatedEntryKey;
  bool _pageCorrectionScheduled = false;
  int? _desiredPageCorrection;
  Timer? _impressionTimer;
  StreamSubscription<WidgetCreatedEvent>? _widgetCreatedSub;
  final Set<String> _recordedImpressions = <String>{};
  final Set<String> _recordingImpressions = <String>{};
  bool _openingGameDraft = false;

  WidgetsHubController get _controller =>
      appServices.find<WidgetsHubController>();

  @override
  void initState() {
    super.initState();
    _pages = PageController();
    // A previously opened Home game must not continue behind discovery.
    unawaited(_closeGlobalGameSurface());
    _widgetCreatedSub = EventBus().on<WidgetCreatedEvent>().listen((_) {
      unawaited(_closeGlobalGameSurface());
    });
  }

  @override
  void didUpdateWidget(covariant _GamesChannel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playbackEnabled == widget.playbackEnabled) return;
    _impressionTimer?.cancel();
    _activatedEntryKey = null;
  }

  @override
  void dispose() {
    _impressionTimer?.cancel();
    unawaited(_widgetCreatedSub?.cancel());
    _pages.dispose();
    super.dispose();
  }

  List<_GameFeedEntry> _entries() {
    final inheritedQuery = _controller.searchQuery.value
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .toLowerCase();
    final query = widget.publicOnly ? '' : inheritedQuery;
    final local = _controller.widgets
        .where(
          (item) =>
              AppletCategoryTaxonomy.forWidget(item) == AppletCategory.game &&
              (query.isEmpty || _localGameMatchesQuery(item, query)),
        )
        .map(_GameFeedEntry.local);
    final remote =
        <AppletCatalogItem>[
              if (query.isEmpty) ..._controller.gameFeedItemsFor(widget.sort),
              if (!widget.publicOnly) ..._controller.searchResults,
            ]
            .where((item) => item.type == AppletCatalogType.game)
            .fold<Map<String, AppletCatalogItem>>(
              <String, AppletCatalogItem>{},
              (items, item) => items..putIfAbsent(item.id, () => item),
            )
            .values
            .map(_GameFeedEntry.public);
    final cloud = _controller.cloudOnlyItems
        .where(
          (scoped) =>
              scoped.item.type == AppletCatalogType.game &&
              (query.isEmpty ||
                  '${scoped.item.title} ${scoped.item.summary}'
                      .toLowerCase()
                      .contains(query)),
        )
        .map(_GameFeedEntry.cloud);
    if (widget.publicOnly) {
      return remote.toList(growable: false);
    }
    return <_GameFeedEntry>[...local, ...remote, ...cloud];
  }

  bool _localGameMatchesQuery(AgentWidget item, String query) {
    return '${item.title} ${item.subtitle ?? ''} ${item.spec['summary'] ?? ''}'
        .toLowerCase()
        .contains(query);
  }

  bool get _hasEndPage =>
      (widget.publicOnly || _controller.searchQuery.value.trim().isEmpty) &&
      _controller.hasReachedGameFeedEndFor(widget.sort);

  int _pageCount(List<_GameFeedEntry> entries) {
    if (entries.isEmpty) return 0;
    final hasTrailingPage =
        _hasEndPage ||
        _controller.gameFeedLoadingFor(widget.sort).value ||
        _controller.gameFeedErrorFor(widget.sort).value != null;
    return entries.length + (hasTrailingPage ? 1 : 0);
  }

  Future<void> _activate(int index) async {
    final entries = _entries();
    final pageCount = _pageCount(entries);
    if (!mounted || index < 0 || index >= pageCount) {
      return;
    }
    if (index == entries.length) {
      _impressionTimer?.cancel();
      setState(() {
        _activeIndex = index;
        _activatedEntryKey = null;
      });
      return;
    }
    if (!widget.playbackEnabled) return;
    final entry = entries[index];
    _scheduleImpression(entry);
    setState(() {
      _activeIndex = index;
      _activatedEntryKey = '$_currentImpressionScopeKey|${entry.identityKey}';
    });
    // Pagination fetches catalog metadata only. Game documents are exclusively
    // owned by the detail route created in response to an explicit cover tap.
    if (index >= entries.length - 2 &&
        _controller.hasMoreGameFeedItemsFor(widget.sort)) {
      unawaited(_controller.loadGameFeed(sort: widget.sort, loadMore: true));
    }
  }

  void _scheduleImpression(_GameFeedEntry entry) {
    _impressionTimer?.cancel();
    final item = entry.publicItem;
    if (item == null || !widget.playbackEnabled) return;
    final scopeKey = _currentImpressionScopeKey;
    final impressionKey = '$scopeKey|${item.id}';
    if (_recordedImpressions.contains(impressionKey)) return;
    _impressionTimer = Timer(const Duration(seconds: 2), () async {
      if (!mounted ||
          !widget.playbackEnabled ||
          scopeKey != _currentImpressionScopeKey ||
          _entries().elementAtOrNull(_activeIndex)?.identityKey !=
              entry.identityKey) {
        return;
      }
      if (_recordedImpressions.contains(impressionKey) ||
          !_recordingImpressions.add(impressionKey)) {
        return;
      }
      try {
        final legacyOverride = gameFeedImpressionOverride;
        final recorderOverride = gameFeedImpressionRecorderOverride;
        bool recorded;
        if (recorderOverride != null) {
          recorded = await recorderOverride(item);
        } else if (legacyOverride != null) {
          legacyOverride(item);
          recorded = true;
        } else {
          recorded = await _controller.recordGameView(item);
        }
        if (recorded && scopeKey == _currentImpressionScopeKey) {
          _recordedImpressions.add(impressionKey);
        } else if (mounted &&
            scopeKey == _currentImpressionScopeKey &&
            _entries().elementAtOrNull(_activeIndex)?.identityKey ==
                entry.identityKey) {
          _impressionTimer = Timer(
            const Duration(seconds: 2),
            () => _scheduleImpression(entry),
          );
        }
      } finally {
        _recordingImpressions.remove(impressionKey);
      }
    });
  }

  String get _currentImpressionScopeKey =>
      gameFeedImpressionScopeKeyOverride?.call() ??
      AppletLocalOwnership.currentScopeKey();

  void _move(int delta) {
    final pageCount = _pageCount(_entries());
    if (pageCount == 0) return;
    final target = (_activeIndex + delta).clamp(0, pageCount - 1);
    if (target == _activeIndex) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _pages.jumpToPage(target);
      return;
    }
    _pages.animateToPage(
      target,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppReactiveBuilder(() {
      final entries = _entries();
      final hasEndPage = _hasEndPage;
      final pageCount = _pageCount(entries);
      if (pageCount == 0) {
        _activatedEntryKey = null;
        _impressionTimer?.cancel();
        final loading = _controller.gameFeedLoadingFor(widget.sort).value;
        final errorKey = _controller.gameFeedErrorFor(widget.sort).value;
        return _GameFeedEmpty(
          loading: loading,
          message: errorKey?.tr ?? 'game_feed.empty_public'.tr,
          onRefresh: widget.publicOnly
              ? () => _controller.loadGameFeed(sort: widget.sort)
              : _controller.reload,
        );
      }
      final active = _activeIndex.clamp(0, pageCount - 1);
      if (active != _activeIndex) {
        _activeIndex = active;
        _desiredPageCorrection = active;
      }
      if (_desiredPageCorrection != null && !_pageCorrectionScheduled) {
        _pageCorrectionScheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _pageCorrectionScheduled = false;
          if (!mounted || !_pages.hasClients) return;
          final latestPageCount = _pageCount(_entries());
          if (latestPageCount == 0) {
            _desiredPageCorrection = null;
            return;
          }
          final target = (_desiredPageCorrection ?? _activeIndex).clamp(
            0,
            latestPageCount - 1,
          );
          _desiredPageCorrection = null;
          _activeIndex = target;
          _pages.jumpToPage(target);
        });
      }
      final activeEntry = entries.elementAtOrNull(active);
      final activationKey = activeEntry == null
          ? null
          : '$_currentImpressionScopeKey|${activeEntry.identityKey}';
      if (activeEntry == null) {
        _activatedEntryKey = null;
        _impressionTimer?.cancel();
      } else if (widget.playbackEnabled &&
          _activatedEntryKey != activationKey) {
        _activatedEntryKey = activationKey;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && widget.playbackEnabled && _activeIndex == active) {
            unawaited(_activate(active));
          }
        });
      }
      return Stack(
        key: const ValueKey<String>('applet-games-feed'),
        fit: StackFit.expand,
        children: <Widget>[
          PageView.builder(
            controller: _pages,
            scrollDirection: Axis.vertical,
            physics: MediaQuery.disableAnimationsOf(context)
                ? const PageScrollPhysics()
                : const BouncingScrollPhysics(parent: PageScrollPhysics()),
            onPageChanged: _activate,
            itemCount: pageCount,
            itemBuilder: (_, index) => index == entries.length
                ? hasEndPage
                      ? _GameFeedEnd(
                          onCreate: _openingGameDraft ? null : _prepareNewGame,
                        )
                      : KeyedSubtree(
                          key: const ValueKey('game-feed-continuation'),
                          child: _GameFeedEmpty(
                            loading: _controller
                                .gameFeedLoadingFor(widget.sort)
                                .value,
                            message:
                                _controller
                                    .gameFeedErrorFor(widget.sort)
                                    .value
                                    ?.tr ??
                                'game_feed.loading_game'.tr,
                            onRefresh: () => _controller.loadGameFeed(
                              sort: widget.sort,
                              loadMore: _controller.hasMoreGameFeedItemsFor(
                                widget.sort,
                              ),
                            ),
                          ),
                        )
                : KeyedSubtree(
                    key: ValueKey<String>(entries[index].identityKey),
                    child: _GameFeedPage(
                      entry: entries[index],
                      isActive: widget.playbackEnabled && index == active,
                    ),
                  ),
          ),
          if (activeEntry != null)
            Positioned(
              right: 8,
              top: 0,
              bottom: 0,
              child: SafeArea(
                minimum: const EdgeInsets.symmetric(vertical: 8),
                child: GameFrostGroup(
                  child: _GameSwipeRail(
                    entry: activeEntry,
                    likeBusy:
                        activeEntry.publicItem != null &&
                        _controller.isGameLikeInFlight(
                          activeEntry.publicItem!.id,
                        ),
                    canGoPrevious: active > 0,
                    canGoNext: active < pageCount - 1,
                    onPrevious: () => _move(-1),
                    onNext: () => _move(1),
                    onLike: activeEntry.publicItem == null
                        ? null
                        : () => _toggleGameLike(
                            _controller,
                            activeEntry.publicItem!,
                          ),
                    onComments: activeEntry.publicItem == null
                        ? null
                        : () => _showGameComments(
                            context,
                            _controller,
                            activeEntry.publicItem!,
                          ),
                    onShare: activeEntry.publicItem == null
                        ? null
                        : () => unawaited(
                            _sharePublicGame(
                              context,
                              _controller,
                              activeEntry.publicItem!,
                            ),
                          ),
                  ),
                ),
              ),
            ),
        ],
      );
    });
  }

  Future<void> _prepareNewGame() async {
    if (_openingGameDraft ||
        !_hasEndPage ||
        !appNavigation.isConfigured ||
        !appNavigation.canNavigateTo(AppRouteCatalog.home)) {
      return;
    }
    setState(() => _openingGameDraft = true);
    try {
      await appNavigation.push<void>(
        AppRouteCatalog.home,
        extra: HomeDraftIntent.gameCreation(
          scopeKey: AppletLocalOwnership.currentScopeKey(),
          prompt: 'game_feed.create_game_prompt'.tr,
        ),
      );
    } finally {
      if (mounted) setState(() => _openingGameDraft = false);
    }
  }

  void _toggleGameLike(
    WidgetsHubController controller,
    AppletCatalogItem item,
  ) {
    controller.toggleGameLike(item).catchError((Object error) {
      if (!mounted) return;
      showAppGlassNotice(
        title: 'game_feed.like_failed_title'.tr,
        message: 'game_feed.like_failed'.tr,
        icon: Icons.cloud_off_rounded,
      );
    });
  }
}

class _GameFeedEntry {
  const _GameFeedEntry._({this.localItem, this.publicItem, this.cloudItem});

  factory _GameFeedEntry.local(AgentWidget item) =>
      _GameFeedEntry._(localItem: item);
  factory _GameFeedEntry.public(AppletCatalogItem item) =>
      _GameFeedEntry._(publicItem: item);
  factory _GameFeedEntry.cloud(ScopedAppletInventoryItem item) =>
      _GameFeedEntry._(cloudItem: item);

  final AgentWidget? localItem;
  final AppletCatalogItem? publicItem;
  final ScopedAppletInventoryItem? cloudItem;

  String get title =>
      localItem?.title ?? publicItem?.title ?? cloudItem!.item.title;
  String get summary =>
      localItem?.subtitle ??
      publicItem?.summary ??
      cloudItem?.item.summary ??
      'widgets.kind_game'.tr;
  String get identityKey => localItem != null
      ? 'local:${localItem!.id ?? localItem!.spec['surfaceId']}'
      : publicItem != null
      ? 'public:${publicItem!.id}'
      : 'cloud:${cloudItem!.item.id}';
}

class _GameFeedPage extends StatelessWidget {
  const _GameFeedPage({required this.entry, required this.isActive});

  final _GameFeedEntry entry;
  final bool isActive;

  void _open() {
    if (!isActive) return;
    if (entry.publicItem case final item?) {
      _openCatalogItem(item);
    } else if (entry.localItem case final item?) {
      unawaited(openAgentWidget(item));
    } else if (entry.cloudItem case final scoped?) {
      _openOwnedCloudGame(scoped);
    }
  }

  @override
  Widget build(BuildContext context) {
    final publicItem = entry.publicItem;
    final localItem = entry.localItem;
    final cloudItem = entry.cloudItem?.item;
    final shareUrl =
        publicItem?.shareUrl ??
        (cloudItem?.published == true ? cloudItem?.shareUrl : null);
    final interactive = _GameCoverButton(
      key: ValueKey<String>(
        'game-feed-cover-${publicItem?.id ?? localItem?.id ?? cloudItem?.id}',
      ),
      identityKey: entry.identityKey,
      title: entry.title,
      shareUrl: shareUrl,
      localItem: localItem,
      revision:
          (publicItem?.updatedAt ??
                  localItem?.createdAt ??
                  cloudItem!.updatedAt)
              .toIso8601String(),
      active: isActive,
      onTap: isActive ? _open : null,
    );
    return ColoredBox(
      color: const Color(0xFF0D0D0D),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Positioned.fill(child: interactive),
          if (isActive)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: <Color>[Colors.transparent, Color(0xD9000000)],
                    ),
                  ),
                  child: SafeArea(
                    top: false,
                    child: Padding(
                      padding: EdgeInsets.only(
                        right: 72 + MediaQuery.paddingOf(context).right,
                      ),
                      child: ConstrainedBox(
                        key: const ValueKey<String>(
                          'game-feed-metadata-region',
                        ),
                        constraints: const BoxConstraints(minHeight: 132),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(18, 44, 18, 14),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Row(
                                children: <Widget>[
                                  Expanded(
                                    child: Text(
                                      entry.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 18,
                                        height: 1.15,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: -0.25,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  const AppletCategoryBadge(
                                    category: AppletCategory.game,
                                  ),
                                ],
                              ),
                              if (entry.summary.trim().isNotEmpty) ...<Widget>[
                                const SizedBox(height: 4),
                                Text(
                                  entry.summary,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Color(0xE6FFFFFF),
                                    fontSize: 14,
                                    height: 1.35,
                                    shadows: <Shadow>[
                                      Shadow(
                                        color: Colors.black54,
                                        blurRadius: 8,
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _GameCoverButton extends StatelessWidget {
  const _GameCoverButton({
    super.key,
    required this.identityKey,
    required this.title,
    this.shareUrl,
    this.localItem,
    required this.revision,
    required this.active,
    required this.onTap,
  });

  final String identityKey;
  final String title;
  final Uri? shareUrl;
  final AgentWidget? localItem;
  final String revision;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: onTap != null,
      excludeSemantics: true,
      label: 'game_feed.play_named'.trParams({'name': title}),
      onTap: onTap,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: shareUrl == null && localItem == null
              ? _GameCoverArt(identityKey: identityKey)
              : GameScreenshotPreview(
                  identity: identityKey,
                  revision: revision,
                  title: title,
                  shareUrl: shareUrl,
                  localItem: localItem,
                  active: active,
                ),
        ),
      ),
    );
  }
}

class _GameCoverArt extends StatelessWidget {
  const _GameCoverArt({
    super.key,
    required this.identityKey,
    this.loading = false,
  });
  final String identityKey;
  final bool loading;

  @override
  Widget build(BuildContext context) => ColoredBox(
    key: ValueKey<String>('game-cover-placeholder-$identityKey'),
    color: GameFrostChrome.canvas,
    child: Center(
      child: loading
          ? _GameLoadingStatus(
              reduceMotion: MediaQuery.disableAnimationsOf(context),
            )
          : Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'game_feed.preview_unavailable'.tr,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white60, fontSize: 13),
              ),
            ),
    ),
  );
}

class _GameLoadingStatus extends StatelessWidget {
  const _GameLoadingStatus({required this.reduceMotion});

  final bool reduceMotion;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: const ValueKey<String>('game-cover-loading'),
      container: true,
      liveRegion: true,
      label: 'game_feed.loading_game'.tr,
      child: GameFrostChrome(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: <Widget>[
            if (reduceMotion)
              Icon(Icons.hourglass_top_rounded, color: Colors.white, size: 18)
            else
              SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 2,
                ),
              ),
            Text(
              'game_feed.loading_game'.tr,
              style: TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GameFeedEnd extends StatelessWidget {
  const _GameFeedEnd({required this.onCreate});

  final VoidCallback? onCreate;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      key: const ValueKey<String>('game-feed-end'),
      color: const Color(0xFF0D0D0D),
      child: SafeArea(
        minimum: const EdgeInsets.fromLTRB(24, 112, 24, 24),
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Icon(
                      Icons.sports_esports_outlined,
                      color: Colors.white70,
                      size: 48,
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'game_feed.end_title'.tr,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'game_feed.end_description'.tr,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70),
                    ),
                    const SizedBox(height: 24),
                    AppGlassButton(
                      key: const ValueKey<String>('game-feed-create-game'),
                      label: 'game_feed.create_game'.tr,
                      icon: Icons.add_rounded,
                      onPressed: onCreate,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GameFeedEmpty extends StatelessWidget {
  const _GameFeedEmpty({
    required this.loading,
    required this.message,
    required this.onRefresh,
  });

  final bool loading;
  final String message;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF0D0D0D),
      child: RefreshIndicator(
        color: Colors.white,
        backgroundColor: const Color(0xFF212121),
        onRefresh: onRefresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(
            24,
            MediaQuery.paddingOf(context).top + 112,
            24,
            MediaQuery.paddingOf(context).bottom + 24,
          ),
          children: <Widget>[
            SizedBox(
              height: 420,
              child: Center(
                child: loading
                    ? const CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          const Icon(
                            Icons.sports_esports_outlined,
                            color: Color(0xBFFFFFFF),
                            size: 42,
                          ),
                          const SizedBox(height: 14),
                          Text(
                            message,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 12),
                          IconButton(
                            tooltip: 'common.retry'.tr,
                            onPressed: () => unawaited(onRefresh()),
                            style: IconButton.styleFrom(
                              minimumSize: const Size.square(48),
                              foregroundColor: Colors.white,
                              backgroundColor: const Color(0x29FFFFFF),
                            ),
                            icon: const Icon(Icons.refresh_rounded),
                          ),
                        ],
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OwnedGamesGrid extends StatefulWidget {
  const _OwnedGamesGrid({super.key});

  @override
  State<_OwnedGamesGrid> createState() => _OwnedGamesGridState();
}

class _OwnedGamesGridState extends State<_OwnedGamesGrid> {
  String? _openingIdentity;

  Future<void> _open(AgentWidget item) async {
    if (_openingIdentity != null) return;
    final identity = 'local:${item.id ?? item.spec['surfaceId']}';
    setState(() => _openingIdentity = identity);
    if (!item.seen) {
      unawaited(appServices.find<WidgetsHubController>().markSeen(item));
    }
    try {
      await openAgentWidget(item);
    } finally {
      if (mounted && _openingIdentity == identity) {
        setState(() => _openingIdentity = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = appServices.find<WidgetsHubController>();
    return ColoredBox(
      color: const Color(0xFF0D0D0D),
      child: AppReactiveBuilder(() {
        final localItems = controller.widgets
            .where(
              (item) =>
                  AppletCategoryTaxonomy.forWidget(item) == AppletCategory.game,
            )
            .toList(growable: false);
        final cloudItems = controller.cloudOnlyItems
            .where((scoped) => scoped.item.type == AppletCatalogType.game)
            .toList(growable: false);
        if (localItems.isEmpty && cloudItems.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Text(
                'game_feed.empty_mine'.tr,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  height: 1.4,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          );
        }
        final columns = MediaQuery.sizeOf(context).width >= 720 ? 3 : 2;
        return GridView.builder(
          key: const ValueKey<String>('game-feed-owned-grid'),
          padding: EdgeInsets.fromLTRB(
            12,
            MediaQuery.paddingOf(context).top + 82,
            12,
            MediaQuery.paddingOf(context).bottom + 24,
          ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 9 / 16,
          ),
          itemCount: localItems.length + cloudItems.length,
          itemBuilder: (_, index) {
            if (index < localItems.length) {
              final item = localItems[index];
              final identity = 'local:${item.id ?? item.spec['surfaceId']}';
              return _OwnedGamePreviewCard(
                key: ValueKey<String>(
                  'owned-game-${item.id ?? item.spec['surfaceId']}',
                ),
                item: item,
                engagement: _inventoryEngagementForLocal(item, controller),
                opening: _openingIdentity == identity,
                openEnabled: _openingIdentity == null,
                onOpen: () => unawaited(_open(item)),
              );
            }
            final scoped = cloudItems[index - localItems.length];
            return _OwnedCloudGameCard(
              key: ValueKey<String>('owned-cloud-game-${scoped.item.id}'),
              scoped: scoped,
            );
          },
        );
      }),
    );
  }
}

class _OwnedGamePreviewCard extends StatefulWidget {
  const _OwnedGamePreviewCard({
    super.key,
    required this.item,
    this.engagement,
    required this.opening,
    required this.openEnabled,
    required this.onOpen,
  });

  final AgentWidget item;
  final AppletInventoryItem? engagement;
  final bool opening;
  final bool openEnabled;
  final VoidCallback onOpen;

  @override
  State<_OwnedGamePreviewCard> createState() => _OwnedGamePreviewCardState();
}

class _OwnedGamePreviewCardState extends State<_OwnedGamePreviewCard> {
  bool _publishing = false;
  bool _sharing = false;
  bool _deleting = false;
  final String _scopeKey = AppletLocalOwnership.currentScopeKey();

  AgentWidget get _item => widget.item;
  bool get _busy => _publishing || _sharing || _deleting;
  bool get _current =>
      mounted &&
      _scopeKey == AppletLocalOwnership.currentScopeKey() &&
      AppletLocalOwnership.isVisible(_item);

  @override
  Widget build(BuildContext context) {
    final identity = 'local:${widget.item.id ?? widget.item.spec['surfaceId']}';
    final canOpen = widget.openEnabled && !_busy;
    return Stack(
      fit: StackFit.expand,
      children: [
        Semantics(
          button: true,
          enabled: canOpen,
          liveRegion: widget.opening,
          excludeSemantics: true,
          label: widget.opening
              ? 'game_feed.loading_game'.tr
              : 'game_feed.play_named'.trParams({'name': widget.item.title}),
          onTap: canOpen ? widget.onOpen : null,
          child: Material(
            color: const Color(0xFF1F1F1F),
            borderRadius: BorderRadius.circular(18),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: canOpen ? widget.onOpen : null,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  IgnorePointer(
                    child: KeyedSubtree(
                      key: ValueKey<String>(
                        'owned-game-cover-${widget.item.id ?? widget.item.spec['surfaceId']}',
                      ),
                      child: GameScreenshotPreview(
                        identity: identity,
                        revision: widget.item.createdAt.toIso8601String(),
                        title: widget.item.title,
                        localItem: widget.item,
                        active: !widget.opening,
                      ),
                    ),
                  ),
                  if (widget.opening)
                    Center(
                      child: _GameLoadingStatus(
                        reduceMotion: MediaQuery.disableAnimationsOf(context),
                      ),
                    ),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.center,
                        end: Alignment.bottomCenter,
                        colors: <Color>[Colors.transparent, Color(0xD9000000)],
                      ),
                    ),
                  ),
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 12,
                    child: _OwnedGameCardDetails(
                      title: widget.item.title,
                      item: widget.engagement,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          top: 4,
          right: 4,
          child: Semantics(
            container: true,
            child: GameFrostIconButton(
              key: ValueKey<String>(
                'owned-game-more-${widget.item.id ?? widget.item.spec['surfaceId']}',
              ),
              tooltip: 'common.more'.tr,
              icon: Icons.more_horiz_rounded,
              onPressed: _busy || !widget.openEnabled
                  ? null
                  : () => _showMore(context),
            ),
          ),
        ),
      ],
    );
  }

  void _showMore(BuildContext context) {
    if (!_current || _busy) return;
    if (_item.spec.containsKey('bundleReference')) {
      unawaited(_manageSavedBundle());
      return;
    }
    final cloud = AgentGameCloudMetadata.fromSpec(_item.spec['cloud']);
    _showOwnedGameMoreSheet(
      context: context,
      keyPrefix: 'owned-game-detail',
      isCurrent: () => _current,
      isCurrentPublished: cloud.isCurrentPublished,
      hasPublished: cloud.hasPublished,
      publishing: _publishing,
      sharing: _sharing,
      deleting: _deleting,
      onPublish: _publishOwnedGame,
      onShare: () => _shareOwnedGame(context),
      onDelete: () => unawaited(_delete()),
    );
  }

  Future<bool> _publishOwnedGame() async {
    if (!_current || _busy) return false;
    if (!isCloudAppletWidget(_item)) {
      showAppGlassNotice(
        title: 'game_feed.publish_unsupported_title'.tr,
        message: 'game_feed.publish_unsupported_message'.tr,
        icon: Icons.public_off_rounded,
      );
      return false;
    }
    final previous = AgentGameCloudMetadata.fromSpec(_item.spec['cloud']);
    if (previous.isCurrentPublished) {
      showAppGlassNotice(
        title: 'game_feed.published_title'.tr,
        message: 'game_feed.published_message'.tr,
        icon: Icons.check_circle_rounded,
      );
      return _trustedOwnedGameShareUri(
            _item,
            appServices.find<WidgetsHubController>(),
          ) !=
          null;
    }
    if (!appServices.isRegistered<AgentGameCloudService>()) {
      showAppGlassNotice(
        title: 'agent_games.publish_failed_title'.tr,
        message: 'agent_games.publish_failed'.tr,
        icon: Icons.cloud_off_rounded,
      );
      return false;
    }
    setState(() => _publishing = true);
    try {
      final published = await appServices.find<AgentGameCloudService>().publish(
        _item,
      );
      if (!_current) return false;
      final controller = appServices.find<WidgetsHubController>();
      try {
        await controller.refreshAllGameFeeds();
      } catch (error, stackTrace) {
        Log.w(
          '[GameFeed] published game feed refresh failed',
          error: error,
          stackTrace: stackTrace,
        );
      }
      if (!_current) return false;
      showAppGlassNotice(
        title: 'game_feed.published_title'.tr,
        message: 'game_feed.published_message'.tr,
        icon: Icons.check_circle_rounded,
      );
      return published.isCurrentPublished &&
          _trustedOwnedGameShareUri(_item, controller) != null;
    } on AppletPublicationUnavailableException catch (error, stackTrace) {
      Log.w(
        '[GameFeed] owned game publication unavailable',
        error: error,
        stackTrace: stackTrace,
      );
      if (_current) {
        showAppGlassNotice(
          title: 'agent_games.publication_unavailable_title'.tr,
          message: 'agent_games.publication_unavailable'.tr,
          icon: Icons.cloud_off_rounded,
        );
      }
      return false;
    } catch (error, stackTrace) {
      Log.w(
        '[GameFeed] owned game publication failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (_current) {
        showAppGlassNotice(
          title: 'agent_games.publish_failed_title'.tr,
          message: 'agent_games.publish_failed'.tr,
          icon: Icons.cloud_off_rounded,
        );
      }
      return false;
    } finally {
      if (mounted) setState(() => _publishing = false);
    }
  }

  Future<bool> _shareOwnedGame(BuildContext context) async {
    if (!_current || _busy) return false;
    final controller = appServices.find<WidgetsHubController>();
    final cloud = AgentGameCloudMetadata.fromSpec(_item.spec['cloud']);
    final shareUri = _trustedOwnedGameShareUri(_item, controller);
    if (shareUri == null) {
      showAppGlassNotice(
        title: 'game_feed.publish_first_title'.tr,
        message: 'game_feed.publish_first_message'.tr,
        icon: Icons.public_off_rounded,
      );
      return false;
    }
    if (cloud.hasPublished && !cloud.isCurrentPublished) {
      showAppGlassNotice(
        title: 'game_feed.share_previous_version_title'.tr,
        message: 'game_feed.share_previous_version_message'.tr,
        icon: Icons.history_rounded,
      );
    }
    final inventory = _inventoryEngagementForLocal(_item, controller);
    final publicItem = _publicGameForOwnedIds(
      controller,
      ids: <String>{cloud.gameId, inventory?.id ?? ''},
      isCurrentPublished: cloud.hasPublished,
    );
    final origin = _globalRect(context);
    setState(() => _sharing = true);
    try {
      final opened = await _openGameSystemShare(
        title: _item.title,
        text: '${_item.title}\n$shareUri',
        origin: origin,
      );
      if (!_current) return false;
      if (opened && publicItem != null) {
        await controller.recordGameShare(publicItem);
      } else if (!opened) {
        showAppGlassNotice(
          title: 'agent_games.share_unavailable_title'.tr,
          message: 'game_feed.share_unavailable'.tr,
          icon: Icons.ios_share_rounded,
        );
      }
      return opened;
    } catch (error, stackTrace) {
      Log.w(
        '[GameFeed] owned game share failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (_current) {
        showAppGlassNotice(
          title: 'agent_games.share_failed_title'.tr,
          message: 'agent_games.share_failed'.tr,
          icon: Icons.cloud_off_rounded,
        );
      }
      return false;
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _delete() async {
    if (!_current || _busy) return;
    if (_item.spec.containsKey('bundleReference')) {
      await _manageSavedBundle();
      return;
    }
    final confirmed = await _confirmOwnedGameDelete(context, _item.title);
    if (!confirmed || !_current) return;
    setState(() => _deleting = true);
    try {
      await appServices.find<WidgetsHubController>().dismiss(_item);
    } catch (error, stackTrace) {
      Log.w(
        '[GameFeed] owned game delete failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (_current) {
        showAppGlassNotice(
          title: 'agent_games.delete_failed_title'.tr,
          message: 'agent_games.delete_failed'.tr,
          icon: Icons.cloud_off_rounded,
        );
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  Future<void> _manageSavedBundle() async {
    if (!_current) return;
    await showProjectBuildSavedManagement(context, _item);
  }
}

AppletInventoryItem? _inventoryEngagementForLocal(
  AgentWidget item,
  WidgetsHubController controller,
) {
  final cloud = AgentGameCloudMetadata.fromSpec(item.spec['cloud']);
  final surfaceId = item.spec['surfaceId']?.toString().trim() ?? '';
  for (final inventoryItem in controller.ownerInventoryItems) {
    if ((cloud.gameId.isNotEmpty && inventoryItem.id == cloud.gameId) ||
        (surfaceId.isNotEmpty && inventoryItem.clientSurfaceId == surfaceId)) {
      return inventoryItem;
    }
  }
  return null;
}

Uri? _trustedOwnedGameShareUri(
  AgentWidget item,
  WidgetsHubController controller,
) {
  final inventory = _inventoryEngagementForLocal(item, controller);
  if (inventory?.published == true && inventory?.shareUrl != null) {
    return inventory!.shareUrl;
  }
  final cloud = AgentGameCloudMetadata.fromSpec(item.spec['cloud']);
  if (!cloud.hasPublished || cloud.shareUrl.isEmpty) return null;
  final candidate = Uri.tryParse(cloud.shareUrl);
  if (candidate == null) return null;
  if (appServices.isRegistered<AppEnvironmentService>()) {
    final trustedOrigin = appServices.find<AppEnvironmentService>().baseUri;
    return isTrustedAppletShareUrl(candidate, trustedOrigin: trustedOrigin)
        ? candidate
        : null;
  }
  // Production registers AppEnvironmentService during startup. This fallback
  // exists only for isolated widget tests whose injected cloud service has
  // already validated the returned URL against its own base URI.
  if (!appServices.testMode ||
      candidate.scheme != 'https' ||
      candidate.userInfo.isNotEmpty ||
      candidate.fragment.isNotEmpty ||
      candidate.query.isNotEmpty ||
      candidate.pathSegments.length != 2 ||
      candidate.pathSegments.first != 'g' ||
      candidate.pathSegments.last.trim().isEmpty) {
    return null;
  }
  return candidate;
}

class _OwnedGameCardDetails extends StatelessWidget {
  const _OwnedGameCardDetails({required this.title, required this.item});

  final String title;
  final AppletInventoryItem? item;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            height: 1.2,
            fontWeight: FontWeight.w800,
            shadows: <Shadow>[Shadow(color: Colors.black54, blurRadius: 8)],
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 9,
          runSpacing: 4,
          children: <Widget>[
            _OwnedGameCount(
              icon: Icons.visibility_outlined,
              count: item?.viewCount,
              tooltip: 'game_feed.views'.tr,
            ),
            _OwnedGameCount(
              icon: Icons.favorite_border_rounded,
              count: item?.likeCount,
              tooltip: 'game_feed.like'.tr,
            ),
            _OwnedGameCount(
              icon: Icons.mode_comment_outlined,
              count: item?.commentCount,
              tooltip: 'game_feed.comments'.tr,
            ),
            _OwnedGameCount(
              icon: Icons.reply_rounded,
              count: item?.shareCount,
              tooltip: 'game_feed.share'.tr,
            ),
          ],
        ),
      ],
    );
  }
}

class _OwnedGameCount extends StatelessWidget {
  const _OwnedGameCount({
    required this.icon,
    required this.count,
    required this.tooltip,
  });

  final IconData icon;
  final int? count;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final label = _compactGameCount(count);
    return Semantics(
      label: '$tooltip $label',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 13, color: Colors.white70),
          const SizedBox(width: 3),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

void _openOwnedCloudGame(ScopedAppletInventoryItem scoped) {
  if (scoped.scopeKey != AppletLocalOwnership.currentScopeKey()) return;
  _pushGamePage(
    'cloud:${scoped.item.id}',
    () => _OwnedCloudGameDetailPage(scoped: scoped),
  );
}

class _OwnedCloudGameCard extends StatefulWidget {
  const _OwnedCloudGameCard({super.key, required this.scoped});

  final ScopedAppletInventoryItem scoped;

  @override
  State<_OwnedCloudGameCard> createState() => _OwnedCloudGameCardState();
}

class _OwnedCloudGameCardState extends State<_OwnedCloudGameCard> {
  bool _sharing = false;
  bool _deleting = false;

  void _open() => _openOwnedCloudGame(widget.scoped);

  @override
  Widget build(BuildContext context) {
    final item = widget.scoped.item;
    return Stack(
      fit: StackFit.expand,
      children: [
        Semantics(
          button: true,
          label: 'widgets.open_named'.trParams({'name': item.title}),
          child: Material(
            color: const Color(0xFF1F1F1F),
            borderRadius: BorderRadius.circular(18),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: _sharing || _deleting ? null : _open,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  if (item.published && item.shareUrl != null)
                    GameScreenshotPreview(
                      identity: 'cloud:${item.id}',
                      revision: item.updatedAt.toIso8601String(),
                      title: item.title,
                      shareUrl: item.shareUrl,
                      active:
                          widget.scoped.scopeKey ==
                          AppletLocalOwnership.currentScopeKey(),
                    )
                  else
                    ColoredBox(
                      color: GameFrostChrome.canvas,
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            'game_feed.preview_unavailable'.tr,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white60),
                          ),
                        ),
                      ),
                    ),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.center,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Color(0xD9000000)],
                      ),
                    ),
                  ),
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 12,
                    child: _OwnedGameCardDetails(title: item.title, item: item),
                  ),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          top: 4,
          right: 4,
          child: Semantics(
            container: true,
            child: GameFrostIconButton(
              key: ValueKey<String>('owned-cloud-game-more-${item.id}'),
              tooltip: 'common.more'.tr,
              icon: Icons.more_horiz_rounded,
              onPressed: _sharing || _deleting
                  ? null
                  : () => _showMore(context),
            ),
          ),
        ),
      ],
    );
  }

  ScopedAppletInventoryItem? _activeScopedItem(
    WidgetsHubController controller,
  ) {
    if (!mounted ||
        widget.scoped.scopeKey != AppletLocalOwnership.currentScopeKey()) {
      return null;
    }
    for (final item in controller.cloudOnlyItems) {
      if (item.scopeKey == widget.scoped.scopeKey &&
          item.item.id == widget.scoped.item.id &&
          item.item.clientSurfaceId == widget.scoped.item.clientSurfaceId) {
        return item;
      }
    }
    return null;
  }

  void _showMore(BuildContext context) {
    if (_sharing || _deleting) return;
    final controller = appServices.find<WidgetsHubController>();
    final scoped = _activeScopedItem(controller);
    if (scoped == null) {
      return;
    }
    final item = scoped.item;
    _showOwnedGameMoreSheet(
      context: context,
      keyPrefix: 'owned-cloud-game-detail',
      isCurrent: () => _activeScopedItem(controller) != null,
      isCurrentPublished: item.published,
      hasPublished: item.published,
      publishing: false,
      sharing: _sharing,
      deleting: _deleting,
      onPublish: _publish,
      onShare: () => _share(context),
      onDelete: () => unawaited(_delete()),
    );
  }

  Future<bool> _publish() async {
    if (_sharing || _deleting) return false;
    final controller = appServices.find<WidgetsHubController>();
    final scoped = _activeScopedItem(controller);
    if (scoped == null) {
      return false;
    }
    if (scoped.item.published && scoped.item.shareUrl != null) {
      showAppGlassNotice(
        title: 'game_feed.published_title'.tr,
        message: 'game_feed.published_message'.tr,
        icon: Icons.check_circle_rounded,
      );
      return true;
    }
    showAppGlassNotice(
      title: 'game_feed.publish_original_device_title'.tr,
      message: 'game_feed.publish_original_device_message'.tr,
      icon: Icons.devices_rounded,
    );
    return false;
  }

  Future<bool> _share(BuildContext context) async {
    final controller = appServices.find<WidgetsHubController>();
    final scoped = _activeScopedItem(controller);
    if (scoped == null) {
      return false;
    }
    final item = scoped.item;
    final shareUrl = item.shareUrl;
    if (_sharing || _deleting) return false;
    if (shareUrl == null) {
      showAppGlassNotice(
        title: 'game_feed.publish_first_title'.tr,
        message: 'game_feed.publish_first_message'.tr,
        icon: Icons.public_off_rounded,
      );
      return false;
    }
    final publicItem = _publicGameForOwnedIds(
      controller,
      ids: <String>{item.id},
      isCurrentPublished: item.published,
    );
    final origin = _globalRect(context);
    setState(() => _sharing = true);
    try {
      final opened = await _openGameSystemShare(
        title: item.title,
        text: '${item.title}\n$shareUrl',
        origin: origin,
      );
      if (_activeScopedItem(controller) == null) return false;
      if (opened && publicItem != null) {
        await controller.recordGameShare(publicItem);
      } else if (!opened) {
        showAppGlassNotice(
          title: 'agent_games.share_unavailable_title'.tr,
          message: 'game_feed.share_unavailable'.tr,
          icon: Icons.ios_share_rounded,
        );
      }
      return opened;
    } catch (error, stackTrace) {
      Log.w(
        '[GameFeed] cloud-only owned game share failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (_activeScopedItem(controller) == null) return false;
      showAppGlassNotice(
        title: 'agent_games.share_failed_title'.tr,
        message: 'agent_games.share_failed'.tr,
        icon: Icons.cloud_off_rounded,
      );
      return false;
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _delete() async {
    if (_sharing || _deleting) return;
    final controller = appServices.find<WidgetsHubController>();
    var scoped = _activeScopedItem(controller);
    if (scoped == null) {
      return;
    }
    final confirmed = await _confirmOwnedGameDelete(context, scoped.item.title);
    if (!confirmed || !mounted) return;
    scoped = _activeScopedItem(controller);
    if (scoped == null) {
      return;
    }
    setState(() => _deleting = true);
    try {
      await controller.deleteCloudOnly(scoped);
    } catch (error, stackTrace) {
      Log.w(
        '[GameFeed] cloud-only owned game delete failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (_activeScopedItem(controller) != null) {
        showAppGlassNotice(
          title: 'agent_games.delete_failed_title'.tr,
          message: 'agent_games.delete_failed'.tr,
          icon: Icons.cloud_off_rounded,
        );
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }
}

class _OwnedCloudGameDetailPage extends StatefulWidget {
  const _OwnedCloudGameDetailPage({required this.scoped});

  final ScopedAppletInventoryItem scoped;

  @override
  State<_OwnedCloudGameDetailPage> createState() =>
      _OwnedCloudGameDetailPageState();
}

class _OwnedCloudGameDetailPageState extends State<_OwnedCloudGameDetailPage> {
  bool _accessRevoked = false;
  bool _scopeExitScheduled = false;
  final List<Worker> _scopeWorkers = <Worker>[];

  @override
  void initState() {
    super.initState();
    _accessRevoked =
        AppletLocalOwnership.currentScopeKey() != widget.scoped.scopeKey;
    _scopeWorkers.addAll(
      AppletLocalOwnership.watchScope(() {
        if (AppletLocalOwnership.currentScopeKey() == widget.scoped.scopeKey) {
          return;
        }
        _accessRevoked = true;
        if (mounted) {
          setState(() {});
          _scheduleScopeExit();
        }
      }),
    );
  }

  @override
  void dispose() {
    for (final worker in _scopeWorkers) {
      worker.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = appServices.find<WidgetsHubController>();
    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: false,
      body: AppGlassScaffold(
        safeArea: false,
        resizeToAvoidBottomInset: false,
        backgroundColor: Colors.black,
        body: AppReactiveBuilder(() {
          final scoped = _activeScopedItem(controller);
          if (_accessRevoked || scoped == null) {
            _accessRevoked = true;
            _scheduleScopeExit();
            return const ColoredBox(color: Colors.black);
          }
          final item = scoped.item;
          return _GamePlayerShell(
            hostKey: const ValueKey<String>('owned-cloud-game-detail'),
            backKey: const ValueKey<String>('owned-cloud-game-player-back'),
            onBack: appNavigation.pop,
            player: item.published && item.shareUrl != null
                ? _PublicAppletPage.inventory(item)
                : Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'widgets.cloud_game_original_device'.tr,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ),
                  ),
          );
        }),
      ),
    );
  }

  ScopedAppletInventoryItem? _activeScopedItem(
    WidgetsHubController controller,
  ) {
    if (_accessRevoked ||
        AppletLocalOwnership.currentScopeKey() != widget.scoped.scopeKey) {
      return null;
    }
    for (final candidate in controller.cloudOnlyItems) {
      if (candidate.scopeKey == widget.scoped.scopeKey &&
          candidate.item.id == widget.scoped.item.id &&
          candidate.item.clientSurfaceId ==
              widget.scoped.item.clientSurfaceId) {
        return candidate;
      }
    }
    return null;
  }

  void _scheduleScopeExit() {
    if (!mounted || _scopeExitScheduled) return;
    _scopeExitScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_popRouteAndOverlays(context)) return;
      _scopeExitScheduled = false;
      _scheduleScopeExit();
    });
  }
}

class _GamePlayerShell extends StatelessWidget {
  const _GamePlayerShell({
    required this.hostKey,
    required this.player,
    required this.onBack,
    this.backKey = const ValueKey<String>('game-player-back'),
  });

  final Key hostKey;
  final Key backKey;
  final Widget player;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return AppGlassScaffold(
      backdropKind: GlassBackdropKind.platformView,
      safeArea: false,
      resizeToAvoidBottomInset: false,
      body: ColoredBox(
        key: hostKey,
        color: GameFrostChrome.canvas,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            player,
            Positioned(
              left: 0,
              top: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                minimum: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  key: const ValueKey<String>('game-player-controls'),
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    GameFrostIconButton(
                      key: backKey,
                      tooltip: 'common.back'.tr,
                      onPressed: onBack,
                      icon: Icons.arrow_back_rounded,
                    ),
                    const GameCompanionControlsButton(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

AppletCatalogItem? _publicGameForOwnedIds(
  WidgetsHubController controller, {
  required Iterable<String> ids,
  required bool isCurrentPublished,
}) {
  if (!isCurrentPublished) return null;
  final candidates = ids.map((id) => id.trim()).where((id) => id.isNotEmpty);
  final candidateIds = candidates.toSet();
  if (candidateIds.isEmpty) return null;
  for (final feed in <Iterable<AppletCatalogItem>>[
    controller.recommendedGameFeedItems,
    controller.popularGameFeedItems,
    controller.searchResults,
  ]) {
    for (final item in feed) {
      if (candidateIds.contains(item.id)) return item;
    }
  }
  return null;
}

void _showOwnedGameMoreSheet({
  required BuildContext context,
  required String keyPrefix,
  required bool Function() isCurrent,
  required bool isCurrentPublished,
  required bool hasPublished,
  required bool publishing,
  required bool sharing,
  required bool deleting,
  required Future<bool> Function() onPublish,
  required Future<bool> Function() onShare,
  required VoidCallback onDelete,
}) {
  if (!isCurrent()) return;
  final colorScheme = Theme.of(context).colorScheme;
  ModalRoute<void>? sheetRoute;
  final scopeWorkers = AppletLocalOwnership.watchScope(() {
    if (isCurrent()) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final route = sheetRoute;
      if (route != null && route.isActive) {
        route.navigator?.removeRoute(route);
      }
    });
  });
  unawaited(
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: false,
      backgroundColor: colorScheme.surface,
      barrierColor: Colors.black.withValues(alpha: 0.54),
      elevation: 0,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      clipBehavior: Clip.antiAlias,
      builder: (sheetContext) {
        sheetRoute = ModalRoute.of<void>(sheetContext);
        return _OwnedGameActionSheet(
          keyPrefix: keyPrefix,
          surfaceColor: colorScheme.surface,
          isCurrentPublished: isCurrentPublished,
          hasPublished: hasPublished,
          publishing: publishing,
          sharing: sharing,
          deleting: deleting,
          onPublish: () => isCurrent() ? onPublish() : Future.value(false),
          onShare: () => isCurrent() ? onShare() : Future.value(false),
          onDelete: () {
            if (isCurrent()) onDelete();
          },
        );
      },
    ).whenComplete(() {
      for (final worker in scopeWorkers) {
        worker.dispose();
      }
    }),
  );
}

class _OwnedGameActionSheet extends StatefulWidget {
  const _OwnedGameActionSheet({
    required this.keyPrefix,
    required this.surfaceColor,
    required this.isCurrentPublished,
    required this.hasPublished,
    required this.publishing,
    required this.sharing,
    required this.deleting,
    required this.onPublish,
    required this.onShare,
    required this.onDelete,
  });

  final String keyPrefix;
  final Color surfaceColor;
  final bool isCurrentPublished;
  final bool hasPublished;
  final bool publishing;
  final bool sharing;
  final bool deleting;
  final Future<bool> Function() onPublish;
  final Future<bool> Function() onShare;
  final VoidCallback onDelete;

  @override
  State<_OwnedGameActionSheet> createState() => _OwnedGameActionSheetState();
}

class _OwnedGameActionSheetState extends State<_OwnedGameActionSheet> {
  late bool _isCurrentPublished;
  late bool _hasPublished;
  late bool _publishing;
  late bool _sharing;

  bool get _busy => _publishing || _sharing || widget.deleting;

  @override
  void initState() {
    super.initState();
    _isCurrentPublished = widget.isCurrentPublished;
    _hasPublished = widget.hasPublished;
    _publishing = widget.publishing;
    _sharing = widget.sharing;
  }

  Future<void> _publish() async {
    if (_busy) return;
    var published = false;
    setState(() => _publishing = true);
    try {
      // Let the busy state paint before a callback can complete synchronously.
      // This keeps fast validation failures responsive without adding an
      // artificial loading delay.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      published = await widget.onPublish();
    } catch (error, stackTrace) {
      Log.w(
        '[GameFeed] owned game publish action failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        showAppGlassNotice(
          title: 'agent_games.publish_failed_title'.tr,
          message: 'agent_games.publish_failed'.tr,
          icon: Icons.cloud_off_rounded,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _publishing = false;
          if (published) {
            _isCurrentPublished = true;
            _hasPublished = true;
          }
        });
      }
    }
  }

  Future<void> _share() async {
    if (_busy) return;
    var opened = false;
    setState(() => _sharing = true);
    try {
      // See [_publish]: one rendered busy frame is enough for rapid failures.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      opened = await widget.onShare();
    } catch (error, stackTrace) {
      Log.w(
        '[GameFeed] owned game share action failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        showAppGlassNotice(
          title: 'agent_games.share_failed_title'.tr,
          message: 'agent_games.share_failed'.tr,
          icon: Icons.cloud_off_rounded,
        );
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
    if (opened && mounted) Navigator.of(context).pop();
  }

  void _delete() {
    if (_busy) return;
    Navigator.of(context).pop();
    Future<void>.microtask(widget.onDelete);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final publishLabel = _publishing
        ? 'game_feed.publishing'.tr
        : _isCurrentPublished
        ? 'game_feed.published'.tr
        : _hasPublished
        ? 'game_feed.publish_update'.tr
        : 'game_feed.publish'.tr;
    final shareLabel = _sharing ? 'game_feed.sharing'.tr : 'game_feed.share'.tr;
    return PopScope(
      canPop: !_busy,
      child: Material(
        key: ValueKey<String>('${widget.keyPrefix}-more-sheet-surface'),
        color: widget.surfaceColor,
        child: SafeArea(
          top: false,
          child: Semantics(
            container: true,
            namesRoute: true,
            label: 'game_feed.actions_title'.tr,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
              child: Column(
                key: ValueKey<String>('${widget.keyPrefix}-more-sheet'),
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Center(
                    child: Container(
                      width: 38,
                      height: 4,
                      decoration: BoxDecoration(
                        color: colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.42,
                        ),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'game_feed.actions_title'.tr,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: colorScheme.onSurface,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    key: ValueKey<String>('${widget.keyPrefix}-actions-row'),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(
                        child: _OwnedGameSheetAction(
                          key: ValueKey<String>('${widget.keyPrefix}-publish'),
                          label: publishLabel,
                          icon: _isCurrentPublished
                              ? Icons.check_circle_rounded
                              : Icons.public_rounded,
                          busy: _publishing,
                          progressKey: ValueKey<String>(
                            '${widget.keyPrefix}-publish-progress',
                          ),
                          onPressed: _busy ? null : () => unawaited(_publish()),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _OwnedGameSheetAction(
                          key: ValueKey<String>('${widget.keyPrefix}-share'),
                          label: shareLabel,
                          icon: Icons.ios_share_rounded,
                          busy: _sharing,
                          progressKey: ValueKey<String>(
                            '${widget.keyPrefix}-share-progress',
                          ),
                          onPressed: _busy ? null : () => unawaited(_share()),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _OwnedGameSheetAction(
                          key: ValueKey<String>('${widget.keyPrefix}-delete'),
                          label: 'game_feed.delete'.tr,
                          icon: Icons.delete_outline_rounded,
                          destructive: true,
                          busy: widget.deleting,
                          onPressed: _busy ? null : _delete,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OwnedGameSheetAction extends StatelessWidget {
  const _OwnedGameSheetAction({
    super.key,
    required this.label,
    required this.icon,
    required this.busy,
    required this.onPressed,
    this.progressKey,
    this.destructive = false,
  });

  final String label;
  final IconData icon;
  final bool busy;
  final VoidCallback? onPressed;
  final Key? progressKey;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final foreground = destructive ? colorScheme.error : colorScheme.onSurface;
    final iconBackground = destructive
        ? colorScheme.errorContainer
        : colorScheme.surfaceContainerHighest;
    return Semantics(
      button: true,
      enabled: onPressed != null,
      liveRegion: busy,
      label: label,
      child: ExcludeSemantics(
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 96),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.start,
                  children: <Widget>[
                    Container(
                      width: 52,
                      height: 52,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: iconBackground,
                        shape: BoxShape.circle,
                      ),
                      child: busy
                          ? SizedBox.square(
                              key: progressKey,
                              dimension: 20,
                              child: disableAnimations
                                  ? Icon(
                                      Icons.hourglass_top_rounded,
                                      color: foreground,
                                      size: 20,
                                    )
                                  : CircularProgressIndicator(
                                      color: foreground,
                                      strokeWidth: 2,
                                    ),
                            )
                          : Icon(icon, color: foreground, size: 25),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      label,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: foreground,
                        fontWeight: FontWeight.w700,
                        height: 1.15,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<bool> _confirmOwnedGameDelete(
  BuildContext context,
  String title, {
  bool isGame = true,
}) async {
  final heading =
      (isGame ? 'game_feed.delete_title' : 'widgets.delete_title').tr;
  final scope = AppletLocalOwnership.currentScopeKey();
  ModalRoute<bool>? confirmationRoute;
  final scopeWorkers = AppletLocalOwnership.watchScope(() {
    if (scope == AppletLocalOwnership.currentScopeKey()) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final route = confirmationRoute;
      if (route != null && route.isActive) route.navigator?.removeRoute(route);
    });
  });
  try {
    final confirmed = await showAppGlassSheet<bool>(
      context: context,
      builder: (sheetContext) {
        confirmationRoute = ModalRoute.of<bool>(sheetContext);
        return Semantics(
          container: true,
          namesRoute: true,
          label: heading,
          child: Column(
            key: const ValueKey<String>('owned-game-delete-confirmation'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                heading,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'game_feed.delete_confirm'.trParams({'name': title}),
                style: const TextStyle(fontSize: 14, height: 1.4),
              ),
              const SizedBox(height: 20),
              Row(
                children: <Widget>[
                  Expanded(
                    child: AppGlassButton(
                      label: 'common.cancel'.tr,
                      primary: false,
                      fullWidth: true,
                      onPressed: () => Navigator.of(sheetContext).pop(false),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: AppGlassButton(
                      label: 'widgets.action_delete'.tr,
                      icon: Icons.delete_outline_rounded,
                      fullWidth: true,
                      color: ColorConstant.errorColor.withValues(alpha: 0.86),
                      foregroundColor: Colors.white,
                      onPressed: () => Navigator.of(sheetContext).pop(true),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
    return confirmed == true && scope == AppletLocalOwnership.currentScopeKey();
  } finally {
    for (final worker in scopeWorkers) {
      worker.dispose();
    }
  }
}

bool _popRouteAndOverlays(BuildContext context) {
  final route = ModalRoute.of(context);
  if (route == null) return false;
  final navigator = Navigator.of(context);
  if (!route.isCurrent) {
    navigator.popUntil((candidate) => identical(candidate, route));
  }
  if (!route.isCurrent) return false;
  unawaited(navigator.maybePop());
  return true;
}

class _GameSwipeRail extends StatelessWidget {
  const _GameSwipeRail({
    required this.entry,
    required this.likeBusy,
    required this.canGoPrevious,
    required this.canGoNext,
    required this.onPrevious,
    required this.onNext,
    required this.onLike,
    required this.onComments,
    required this.onShare,
  });

  final _GameFeedEntry entry;
  final bool likeBusy;
  final bool canGoPrevious;
  final bool canGoNext;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback? onLike;
  final VoidCallback? onComments;
  final VoidCallback? onShare;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final label = TextPainter(
          text: TextSpan(
            text: '0',
            style: DefaultTextStyle.of(context).style.merge(
              const TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
            ),
          ),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        final labeledActionHeight = 48 + 2 + label.height;
        label.dispose();
        final showCounts =
            labeledActionHeight * 4 + 10 * 3 <= constraints.maxHeight;
        // Counts remain in semantics when the viewport cannot fit large text
        // beside four full-size controls. Never shrink the 48px touch targets.
        final actionHeight = showCounts ? labeledActionHeight : 48.0;
        final buttonPitch = actionHeight + 10;
        final railHeight = actionHeight * 4 + 10 * 3;
        final availableOffset = math.max(
          0.0,
          constraints.maxHeight - railHeight,
        );
        // Move two full action pitches below the old centered position while
        // keeping every action inside the safe viewport on smaller screens.
        final top = (availableOffset / 2 + buttonPitch * 2).clamp(
          0.0,
          availableOffset,
        );
        return Semantics(
          label: 'widgets.game_swipe_rail'.tr,
          onIncrease: canGoNext ? onNext : null,
          onDecrease: canGoPrevious ? onPrevious : null,
          child: GestureDetector(
            key: const ValueKey<String>('game-swipe-rail'),
            behavior: HitTestBehavior.opaque,
            onVerticalDragEnd: (details) {
              final velocity = details.primaryVelocity ?? 0;
              if (velocity < 0 && canGoNext) {
                onNext();
              } else if (velocity > 0 && canGoPrevious) {
                onPrevious();
              }
            },
            child: SizedBox(
              width: 56,
              child: SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                child: Padding(
                  padding: EdgeInsets.only(top: top),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      _GameEngagementAction(
                        icon: Icons.visibility_outlined,
                        showLabel: showCounts,
                        label: _compactGameCount(entry.publicItem?.viewCount),
                        tooltip: 'game_feed.views'.tr,
                      ),
                      const SizedBox(height: 10),
                      _GameEngagementAction(
                        key: const ValueKey<String>('game-feed-like'),
                        showLabel: showCounts,
                        icon: entry.publicItem?.likedByMe == true
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                        iconColor: entry.publicItem?.likedByMe == true
                            ? const Color(0xFFFF4869)
                            : Colors.white,
                        label: _compactGameCount(entry.publicItem?.likeCount),
                        tooltip: 'game_feed.like'.tr,
                        busy: likeBusy,
                        onPressed: likeBusy ? null : onLike,
                      ),
                      const SizedBox(height: 10),
                      _GameEngagementAction(
                        key: const ValueKey<String>('game-feed-comments'),
                        showLabel: showCounts,
                        icon: Icons.mode_comment_outlined,
                        label: _compactGameCount(
                          entry.publicItem?.commentCount,
                        ),
                        tooltip: 'game_feed.comments'.tr,
                        onPressed: onComments,
                      ),
                      const SizedBox(height: 10),
                      _GameEngagementAction(
                        key: const ValueKey<String>('game-feed-share'),
                        showLabel: showCounts,
                        icon: Icons.reply_rounded,
                        label: _compactGameCount(entry.publicItem?.shareCount),
                        tooltip: 'game_feed.share'.tr,
                        onPressed: onShare,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _GameEngagementAction extends StatelessWidget {
  const _GameEngagementAction({
    super.key,
    required this.icon,
    required this.label,
    required this.tooltip,
    this.iconColor = Colors.white,
    this.busy = false,
    this.showLabel = true,
    this.onPressed,
  });

  final IconData icon;
  final Color iconColor;
  final String label;
  final String tooltip;
  final bool busy;
  final bool showLabel;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final interactive = onPressed != null || busy;
    final valueLabel = label == tooltip ? tooltip : '$tooltip $label';
    return Semantics(
      button: interactive,
      enabled: interactive ? !busy && onPressed != null : null,
      liveRegion: busy,
      excludeSemantics: true,
      onTap: !busy ? onPressed : null,
      label: busy ? '$valueLabel ${'game_feed.updating'.tr}' : valueLabel,
      child: SizedBox(
        width: 56,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            GameFrostIconButton(
              icon: icon,
              tooltip: tooltip,
              onPressed: onPressed,
              foregroundColor: iconColor,
              busy: busy,
            ),
            if (showLabel) ...<Widget>[
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  shadows: <Shadow>[Shadow(color: Colors.black, blurRadius: 5)],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _compactGameCount(int? count) {
  if (count == null) return '—';
  if (count >= 1000000) {
    return '${(count / 1000000).toStringAsFixed(count >= 10000000 ? 0 : 1)}M';
  }
  if (count >= 1000) {
    return '${(count / 1000).toStringAsFixed(count >= 10000 ? 0 : 1)}K';
  }
  return '$count';
}

Future<void> _sharePublicGame(
  BuildContext context,
  WidgetsHubController controller,
  AppletCatalogItem item,
) async {
  final shared = await _openGameSystemShare(
    title: item.title,
    text: '${item.title}\n${item.shareUrl}',
    origin: _globalRect(context),
  );
  if (shared) {
    await controller.recordGameShare(item);
  } else {
    showAppGlassNotice(
      title: 'agent_games.share_unavailable_title'.tr,
      message: 'game_feed.share_unavailable'.tr,
      icon: Icons.ios_share_rounded,
    );
  }
}

void _showGameComments(
  BuildContext context,
  WidgetsHubController controller,
  AppletCatalogItem item,
) {
  unawaited(controller.loadGameComments(item));
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _GameCommentsSheet(controller: controller, item: item),
  );
}

class _GameCommentsSheet extends StatefulWidget {
  const _GameCommentsSheet({required this.controller, required this.item});

  final WidgetsHubController controller;
  final AppletCatalogItem item;

  @override
  State<_GameCommentsSheet> createState() => _GameCommentsSheetState();
}

class _GameCommentsSheetState extends State<_GameCommentsSheet> {
  final TextEditingController _text = TextEditingController();
  bool _sending = false;
  String? _replyTo;
  String? _requestId;
  String? _requestKey;
  String? _sendError;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Container(
        key: const ValueKey<String>('game-feed-comments-sheet'),
        height: MediaQuery.sizeOf(context).height * 0.68,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            children: <Widget>[
              const SizedBox(height: 10),
              Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(14),
                child: Text(
                  'game_feed.comments'.tr,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: AppReactiveBuilder(() {
                  if (widget.controller.isLoadingGameFeedComments.value) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (widget.controller.gameFeedCommentsItemId.value !=
                      widget.item.id) {
                    return const SizedBox.shrink();
                  }
                  if (widget.controller.gameFeedCommentsErrorKey.value !=
                      null) {
                    return _AppletSearchMessage(
                      icon: Icons.cloud_off_rounded,
                      message:
                          widget.controller.gameFeedCommentsErrorKey.value!.tr,
                      onRetry: () => unawaited(
                        widget.controller.loadGameComments(widget.item),
                      ),
                    );
                  }
                  if (widget.controller.gameFeedComments.isEmpty) {
                    return Center(child: Text('game_feed.no_comments'.tr));
                  }
                  final showLoadMore =
                      widget.controller.hasMoreGameFeedComments ||
                      widget.controller.isLoadingMoreGameFeedComments.value;
                  return ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount:
                        widget.controller.gameFeedComments.length +
                        (showLoadMore ? 1 : 0),
                    separatorBuilder: (_, _) => const SizedBox(height: 14),
                    itemBuilder: (_, index) {
                      if (index == widget.controller.gameFeedComments.length) {
                        return Center(
                          child:
                              widget
                                  .controller
                                  .isLoadingMoreGameFeedComments
                                  .value
                              ? const Padding(
                                  padding: EdgeInsets.all(8),
                                  child: SizedBox.square(
                                    dimension: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                )
                              : TextButton(
                                  key: const ValueKey<String>(
                                    'game-feed-comments-load-more',
                                  ),
                                  onPressed: () => unawaited(
                                    widget.controller.loadGameComments(
                                      widget.item,
                                      loadMore: true,
                                    ),
                                  ),
                                  child: Text(
                                    'game_feed.load_more_comments'.tr,
                                  ),
                                ),
                        );
                      }
                      final comment = widget.controller.gameFeedComments[index];
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          CircleAvatar(
                            radius: 17,
                            backgroundColor: MaasoGlassTheme.of(context).muted,
                            child: Icon(
                              Icons.person_rounded,
                              color: MaasoGlassTheme.of(
                                context,
                              ).foregroundSecondary,
                              size: 18,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                IdentityBadge(
                                  name: comment.displayName,
                                  publicActorId: comment.actorId,
                                  kind: comment.actorKind,
                                  style: TextStyle(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                if (comment.parentCommentId != null)
                                  Text(
                                    Localizations.localeOf(
                                              context,
                                            ).languageCode ==
                                            'zh'
                                        ? '回复'
                                        : 'Reply',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.labelSmall,
                                  ),
                                Text(comment.text),
                                Row(
                                  children: [
                                    TextButton(
                                      key: ValueKey(
                                        'game-feed-reply-${comment.id}',
                                      ),
                                      onPressed: _sending
                                          ? null
                                          : () => setState(
                                              () => _replyTo =
                                                  comment.parentCommentId ??
                                                  comment.id,
                                            ),
                                      child: Text(
                                        Localizations.localeOf(
                                                  context,
                                                ).languageCode ==
                                                'zh'
                                            ? '回复'
                                            : 'Reply',
                                      ),
                                    ),
                                    if (appServices
                                            .maybeFind<
                                              ContentEngagementClient
                                            >()
                                        case final ContentCommentReporter
                                            reporter)
                                      CommentReportButton(
                                        reporter: reporter,
                                        target: CommentReportTarget(
                                          surface:
                                              CommentReportSurface.agentGame,
                                          contentId: widget.item.id,
                                          commentId: comment.id,
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  );
                }),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_sendError != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(
                            _sendError!,
                            key: const ValueKey('game-feed-comment-error'),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      ),
                    if (_replyTo != null)
                      TextButton(
                        key: const ValueKey('game-feed-cancel-reply'),
                        onPressed: _sending
                            ? null
                            : () => setState(() => _replyTo = null),
                        child: Text(
                          Localizations.localeOf(context).languageCode == 'zh'
                              ? '正在回复评论 · 取消'
                              : 'Replying to a comment · Cancel',
                        ),
                      ),
                    AppReactiveBuilder(() {
                      final identity = appServices
                          .maybeFind<IdentityService>()
                          ?.profile;
                      return identity?.completed == true
                          ? Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: IdentityBadge(
                                name: identity!.playerName,
                                kind: IdentityActorKind.player,
                              ),
                            )
                          : const SizedBox.shrink();
                    }),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: AppGlassField(
                            key: const ValueKey<String>(
                              'game-feed-comment-field',
                            ),
                            controller: _text,
                            enabled: !_sending,
                            maxLength: 180,
                            decoration: InputDecoration(
                              counterText: '',
                              hintText: 'game_feed.comment_hint'.tr,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filled(
                          key: const ValueKey<String>('game-feed-comment-send'),
                          tooltip: 'game_feed.send_comment'.tr,
                          onPressed: _sending ? null : _send,
                          icon: _sending
                              ? const SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.arrow_upward_rounded),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _send() async {
    if (_sending || _text.text.trim().isEmpty) return;
    final body = _text.text.trim();
    final key = '${_replyTo ?? ''}|$body';
    if (_requestKey != key) {
      _requestKey = key;
      _requestId = newContentRequestId();
    }
    final requestScope = appServices
        .maybeFind<AppletCatalogService>()
        ?.requestContextKey;
    setState(() {
      _sending = true;
      _sendError = null;
    });
    try {
      final saved = await widget.controller.postGameComment(
        widget.item,
        body,
        requestId: _requestId,
        parentCommentId: _replyTo,
      );
      if (mounted &&
          requestScope ==
              appServices
                  .maybeFind<AppletCatalogService>()
                  ?.requestContextKey) {
        if (!saved) throw StateError('applet_comment_not_saved');
        _text.clear();
        setState(() {
          _replyTo = _requestId = _requestKey = null;
        });
      }
    } catch (error, stackTrace) {
      Log.w('[GameFeed] comment failed', error: error, stackTrace: stackTrace);
      if (mounted &&
          requestScope ==
              appServices
                  .maybeFind<AppletCatalogService>()
                  ?.requestContextKey) {
        final message = gameCommentFailureMessage(
          error,
          chinese: Localizations.localeOf(context).languageCode == 'zh',
        );
        setState(() => _sendError = message);
        showAppGlassNotice(
          title: 'game_feed.comment_failed_title'.tr,
          message: message,
          icon: Icons.cloud_off_rounded,
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }
}

class _AppletsFunctionalList extends StatelessWidget {
  const _AppletsFunctionalList();

  @override
  Widget build(BuildContext context) {
    final controller = appServices.find<WidgetsHubController>();
    return RefreshIndicator(
      onRefresh: controller.refreshApplets,
      child: AppReactiveBuilder(() {
        final query = controller.searchQuery.value.trim().toLowerCase();
        final official = OfficialAppletRegistry.all
            .where(
              (item) =>
                  query.isEmpty ||
                  '${item.nameKey.tr} ${AppletCategoryTaxonomy.forOfficialId(item.id).labelKey.tr}'
                      .toLowerCase()
                      .contains(query),
            )
            .toList(growable: false);
        final public =
            (query.isEmpty
                    ? controller.appletDiscoveryItems
                    : controller.searchResults)
                .where((item) => item.type == AppletCatalogType.applet)
                .toList()
              ..sort((a, b) => b.likeCount.compareTo(a.likeCount));
        final loading = query.isEmpty
            ? controller.isLoadingApplets.value
            : controller.isSearching.value;
        final error = query.isEmpty
            ? controller.appletDiscoveryErrorKey.value
            : controller.searchErrorKey.value;
        final hasMore = query.isEmpty
            ? controller.hasMoreApplets
            : controller.hasMoreSearchResults;
        final count = official.length + public.length;
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: ListView.separated(
              key: const ValueKey<String>('applet-functional-list'),
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              itemCount: count + 1,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                if (index < official.length) {
                  return _OfficialTile(applet: official[index]);
                }
                if (index < count) {
                  return _AppletCatalogTile(
                    item: public[index - official.length],
                  );
                }
                if (loading) {
                  return const Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  );
                }
                if (error != null) {
                  return _AppletSearchMessage(
                    icon: Icons.cloud_off_rounded,
                    message: error.tr,
                    onRetry: query.isEmpty
                        ? () => controller.loadApplets()
                        : () => controller.search(
                            query,
                            type: AppletCatalogType.applet,
                          ),
                  );
                }
                if (hasMore) {
                  return TextButton(
                    onPressed: query.isEmpty
                        ? () => controller.loadApplets(loadMore: true)
                        : controller.loadMoreSearchResults,
                    child: Text('widgets.search_more'.tr),
                  );
                }
                if (count == 0) {
                  return _AppletSearchMessage(
                    icon: Icons.search_rounded,
                    message: 'widgets.search_empty_offer'.trParams({
                      'query': query,
                    }),
                  );
                }
                return const SizedBox.shrink();
              },
            ),
          ),
        );
      }),
    );
  }
}

class _AppletSearchBar extends StatefulWidget {
  const _AppletSearchBar();

  @override
  State<_AppletSearchBar> createState() => _AppletSearchBarState();
}

class _AppletSearchBarState extends State<_AppletSearchBar> {
  late final TextEditingController _input;

  WidgetsHubController get _controller =>
      appServices.find<WidgetsHubController>();

  @override
  void initState() {
    super.initState();
    _input = TextEditingController(text: _controller.searchQuery.value);
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
      child: AppGlassField(
        blur: true,
        key: const ValueKey<String>('applet-hub-search-field'),
        controller: _input,
        textInputAction: TextInputAction.search,
        maxLength: 80,
        decoration: InputDecoration(
          counterText: '',
          hintText: 'widgets.search_hint'.tr,
          prefixIcon: const Icon(Icons.search_rounded),
          suffixIcon: AppReactiveBuilder(
            () => _controller.isSearching.value
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton(
                    tooltip: 'widgets.search_action'.tr,
                    onPressed: () => _controller.search(
                      _input.text,
                      type: AppletCatalogType.applet,
                    ),
                    icon: const Icon(Icons.arrow_forward_rounded),
                  ),
          ),
        ),
        onChanged: (query) {
          if (query.trim().isEmpty) _controller.clearSearch();
        },
        onSubmitted: (query) =>
            _controller.search(query, type: AppletCatalogType.applet),
      ),
    );
  }
}

class _AppletSearchMessage extends StatelessWidget {
  const _AppletSearchMessage({
    required this.icon,
    required this.message,
    this.onRetry,
  });

  final IconData icon;
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: AppSecondaryCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: <Widget>[
            Icon(icon, color: ColorConstant.secondaryColor),
            const SizedBox(width: 10),
            Expanded(child: Text(message, maxLines: 3)),
            if (onRetry != null)
              IconButton(
                tooltip: 'common.retry'.tr,
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
              ),
          ],
        ),
      ),
    );
  }
}

class _AppletCatalogTile extends StatelessWidget {
  const _AppletCatalogTile({required this.item});
  final AppletCatalogItem item;

  @override
  Widget build(BuildContext context) => _AppletListRow(
    key: ValueKey('public-applet-${item.id}'),
    icon: const Icon(Icons.apps_rounded),
    title: item.title,
    subtitle: item.summary,
    badges: [
      AppletCategoryBadge(
        category: AppletCategoryTaxonomy.forCatalogItem(item),
      ),
      _AppletPill(
        label: 'widgets.rating_score'.trParams({'count': '${item.likeCount}'}),
      ),
    ],
    onTap: () => _openCatalogItem(item),
    trailing: IconButton(
      tooltip: Localizations.localeOf(context).languageCode == 'zh'
          ? '屏蔽设置'
          : 'Block settings',
      onPressed: () => showPeopleBlockDialog(
        context,
        PeopleActor(
          id: item.author.agentId,
          kind: 'agent',
          name: item.author.displayName,
        ),
      ),
      icon: const Icon(Icons.more_horiz_rounded),
    ),
  );
}

class _CloudAppletTile extends StatefulWidget {
  const _CloudAppletTile({required this.scoped, super.key});

  final ScopedAppletInventoryItem scoped;

  @override
  State<_CloudAppletTile> createState() => _CloudAppletTileState();
}

class _CloudAppletTileState extends State<_CloudAppletTile> {
  bool _deleting = false;
  bool _publishing = false;
  AgentGamePublicationPhase? _publicationPhase;

  bool _isCurrentTarget(ScopedAppletInventoryItem scoped) =>
      mounted &&
      AppletLocalOwnership.currentScopeKey() == scoped.scopeKey &&
      widget.scoped.scopeKey == scoped.scopeKey &&
      widget.scoped.item.id == scoped.item.id &&
      widget.scoped.item.clientSurfaceId == scoped.item.clientSurfaceId;

  Future<void> _open() async {
    final scoped = widget.scoped;
    if (!_isCurrentTarget(scoped) || _deleting || _publishing) return;
    final localItems = await appServices.find<DBService>().getAllWidgets();
    if (!_isCurrentTarget(scoped)) return;
    for (final local in localItems) {
      if (!local.isSurface ||
          !AppletLocalOwnership.isVisible(local, scopeKey: scoped.scopeKey) ||
          local.spec['cloudDelete'] != null ||
          isAppletPresentationPending(local)) {
        continue;
      }
      final cloud = AgentGameCloudMetadata.fromSpec(local.spec['cloud']);
      if (local.spec['surfaceId'] == scoped.item.clientSurfaceId ||
          cloud.gameId == scoped.item.id) {
        await openAgentWidget(local);
        return;
      }
    }
    if (scoped.item.published && scoped.item.shareUrl != null) {
      appNavigation.pushPage(
        () => _CloudAppletPlayerPage(item: scoped.item),
        transition: AppTransition.cupertino,
      );
      return;
    }
    showAppGlassNotice(
      title: scoped.item.title,
      message: 'widgets.cloud_applet_original_device'.tr,
      icon: Icons.devices_rounded,
    );
  }

  Future<void> _showManagement() async {
    final scoped = widget.scoped;
    if (!_isCurrentTarget(scoped) || _deleting || _publishing) return;
    final action = await _showAppletManagement(
      context,
      title: scoped.item.title,
      status: scoped.item.published
          ? 'widgets.published'.tr
          : 'widgets.saved_private'.tr,
      key: const ValueKey('cloud-applet-management'),
    );
    if (action == null || !_isCurrentTarget(scoped)) return;
    switch (action) {
      case _AppletManagementAction.history:
        try {
          final cloud = appServices.find<AgentGameCloudService>();
          final local = await cloud.restoreOwned(
            scoped.item,
            expectedScopeKey: scoped.scopeKey,
          );
          if (!_isCurrentTarget(scoped) || !mounted) return;
          await showAppletVersionHistory(
            context,
            local,
            canContinue: () => _isCurrentTarget(scoped),
          );
        } catch (_) {
          if (_isCurrentTarget(scoped)) {
            showAppGlassNotice(
              title: scoped.item.title,
              message: 'widgets.version_cloud_unavailable'.tr,
            );
          }
        }
        return;
      case _AppletManagementAction.delete:
        await _delete(scoped);
      case _AppletManagementAction.edit:
        try {
          await beginCloudAppletEditing(
            scoped.item,
            scopeKey: scoped.scopeKey,
            canContinue: () => _isCurrentTarget(scoped),
          );
        } catch (error, stackTrace) {
          Log.w(
            '[Applets] cloud-only edit preparation failed',
            error: error,
            stackTrace: stackTrace,
          );
          if (_isCurrentTarget(scoped)) {
            showAppGlassNotice(
              title: scoped.item.title,
              message: 'widgets.edit_failed'.tr,
              icon: Icons.cloud_off_rounded,
            );
          }
        }
      case _AppletManagementAction.publish:
        await _publish(scoped);
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.scoped.item;
    return _AppletListRow(
      icon: const Icon(Icons.apps_rounded),
      title: item.title,
      subtitle: item.summary,
      badges: [
        AppletCategoryBadge(
          category: AppletCategoryTaxonomy.forInventoryItem(item),
        ),
        _AppletPill(
          label:
              (_publishing
                      ? (_publicationPhase ==
                                AgentGamePublicationPhase.reviewing
                            ? 'widgets.reviewing'
                            : 'widgets.publishing')
                      : item.published
                      ? 'widgets.published'
                      : 'widgets.saved_private')
                  .tr,
        ),
      ],
      onTap: () => unawaited(_open()),
      onLongPress: () => unawaited(_showManagement()),
      trailing: IconButton(
        key: ValueKey('cloud-applet-more-${item.id}'),
        tooltip: 'widgets.manage_named'.trParams({'name': item.title}),
        onPressed: _deleting || _publishing ? null : _showManagement,
        icon: _deleting
            ? const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.more_horiz_rounded),
      ),
    );
  }

  Future<void> _publish(ScopedAppletInventoryItem scoped) async {
    if (_publishing || !_isCurrentTarget(scoped)) return;
    final confirmed = await _confirmAppletPublish(context);
    if (!confirmed || !_isCurrentTarget(scoped)) return;
    setState(() => _publishing = true);
    try {
      final cloud = appServices.find<AgentGameCloudService>();
      final local = await cloud.restoreOwned(
        scoped.item,
        expectedScopeKey: scoped.scopeKey,
      );
      if (!_isCurrentTarget(scoped)) return;
      await cloud.publish(
        local,
        onPhase: (phase) {
          if (_isCurrentTarget(scoped)) {
            setState(() => _publicationPhase = phase);
          }
        },
      );
      if (!_isCurrentTarget(scoped)) return;
      await appServices.find<WidgetsHubController>().reload();
    } catch (error, stackTrace) {
      Log.w(
        '[Applets] cloud-only publish failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (_isCurrentTarget(scoped)) {
        showAppGlassNotice(
          title: scoped.item.title,
          message: 'widgets.publish_failed'.tr,
          icon: Icons.cloud_off_rounded,
        );
      }
    } finally {
      if (mounted) setState(() => _publishing = false);
    }
  }

  Future<void> _delete(ScopedAppletInventoryItem scoped) async {
    if (!_isCurrentTarget(scoped) || _deleting || _publishing) return;
    final confirmed = await _confirmOwnedGameDelete(
      context,
      scoped.item.title,
      isGame: false,
    );
    if (!confirmed || !_isCurrentTarget(scoped) || _deleting) return;
    setState(() => _deleting = true);
    try {
      await appServices.find<WidgetsHubController>().deleteCloudOnly(scoped);
    } catch (error, stackTrace) {
      Log.w(
        '[Applets] cloud-only delete failed',
        error: error,
        stackTrace: stackTrace,
      );
      showAppGlassNotice(
        title: 'agent_games.delete_failed_title'.tr,
        message: 'agent_games.delete_failed'.tr,
        icon: Icons.cloud_off_rounded,
      );
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }
}

void _openCatalogItem(AppletCatalogItem item) {
  if (item.type == AppletCatalogType.game) {
    _pushGamePage('public:${item.id}', () => _PublicAppletPage(item: item));
    return;
  }
  appNavigation.pushPage(
    () => _PublicAppletPage(item: item),
    transition: AppTransition.cupertino,
  );
}

class _PublicAppletPage extends StatefulWidget {
  const _PublicAppletPage({required this.item}) : inventory = null;
  const _PublicAppletPage.inventory(AppletInventoryItem value)
    : item = null,
      inventory = value;

  final AppletCatalogItem? item;
  final AppletInventoryItem? inventory;
  String get id => item?.id ?? inventory!.id;
  String get title => item?.title ?? inventory!.title;
  AppletCatalogType get type => item?.type ?? inventory!.type;
  Uri get shareUrl => item?.shareUrl ?? inventory!.shareUrl!;
  DateTime get updatedAt => item?.updatedAt ?? inventory!.updatedAt;

  @override
  State<_PublicAppletPage> createState() => _PublicAppletPageState();
}

class _PublicAppletPageState extends State<_PublicAppletPage>
    with WidgetsBindingObserver {
  WebViewController? _web;
  final Map<String, String> _gameObservations = {};
  GameContentIdentity? _gameContentIdentity;
  GameDocumentLoader? _documentLoader;
  final List<Worker> _scopeWorkers = [];
  late final String _scopeKey;
  late final Uri? _trustedOrigin;
  Timer? _pageLoadTimer;
  int _loadGeneration = 0;
  late bool _loading;
  bool _loadFailed = false;
  ContentConsumptionController? _consumption;
  bool _resumed = true;

  bool get _isGame => widget.type == AppletCatalogType.game;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _resumed =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    final gateway = appServices.maybeFind<ContentEngagementClient>();
    if (gateway != null) {
      _consumption = ContentConsumptionController(
        gateway: gateway,
        target: ContentConsumptionTarget(
          _isGame ? ContentConsumptionKind.game : ContentConsumptionKind.applet,
          widget.id,
        ),
      );
    }
    _loading = true;
    _scopeKey = AppletLocalOwnership.currentScopeKey();
    _trustedOrigin = appServices.maybeFind<AppEnvironmentService>()?.baseUri;
    if (_isGame) {
      _scopeWorkers.addAll(
        AppletLocalOwnership.watchScope(() {
          if (_scopeKey == AppletLocalOwnership.currentScopeKey() &&
              _trustedOrigin ==
                  appServices.maybeFind<AppEnvironmentService>()?.baseUri) {
            return;
          }
          _cancelGameLoad();
        }),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_loadGame());
      });
    } else {
      _web = _createWebController();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    if (!_resumed && _isGame && _loading) _cancelGameLoad();
    _syncConsumptionVisibility();
  }

  void _syncConsumptionVisibility() {
    if (!mounted) return;
    final visible =
        _resumed &&
        !_loading &&
        !_loadFailed &&
        (ModalRoute.of(context)?.isCurrent ?? true);
    final consumption = _consumption;
    if (consumption != null) unawaited(consumption.setVisible(visible));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _loadGeneration++;
    _gameObservations.clear();
    _gameContentIdentity = null;
    _pageLoadTimer?.cancel();
    _documentLoader?.close();
    for (final worker in _scopeWorkers) {
      worker.dispose();
    }
    final web = _web;
    if (_isGame && web != null) {
      unawaited(web.loadHtmlString('<!doctype html><html></html>'));
    }
    final consumption = _consumption;
    if (consumption != null) unawaited(consumption.close());
    super.dispose();
  }

  bool _canLoad(int generation) =>
      mounted &&
      generation == _loadGeneration &&
      _scopeKey == AppletLocalOwnership.currentScopeKey() &&
      _trustedOrigin ==
          appServices.maybeFind<AppEnvironmentService>()?.baseUri &&
      _resumed &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  bool _continueLoading(int generation) {
    if (_canLoad(generation)) return true;
    if (mounted && generation == _loadGeneration) _cancelGameLoad();
    return false;
  }

  void _cancelGameLoad() {
    _loadGeneration++;
    _pageLoadTimer?.cancel();
    _documentLoader?.close();
    _documentLoader = null;
    final web = _web;
    _web = null;
    if (web != null) {
      unawaited(web.loadHtmlString('<!doctype html><html></html>'));
    }
    if (mounted) {
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
    }
    _syncConsumptionVisibility();
  }

  Future<void> _loadGame() async {
    final generation = ++_loadGeneration;
    _gameObservations.clear();
    _gameContentIdentity = null;
    _documentLoader?.close();
    final origin = appServices.maybeFind<AppEnvironmentService>()?.baseUri;
    if (origin == null || !_canLoad(generation)) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadFailed = true;
        });
      }
      return;
    }
    final loader = GameDocumentLoader(trustedOrigin: origin);
    _documentLoader = loader;
    try {
      final document = await loader.fetch(widget.shareUrl);
      if (!_continueLoading(generation)) return;
      _gameContentIdentity = GameContentIdentity(
        kind: GameContentIdentityKind.publishedRenderDocument,
        sha256: document.renderedDocumentDigest,
      );
      final controller = WebViewController();
      await GameVoiceObservationAdapter.addChannel(controller, (source) {
        if (!_canLoad(generation)) return;
        final envelope = GameVoiceEnvelope.parse(source);
        final snapshot = GameCompanionDomSnapshot.parseMessage(source);
        if (envelope == null && snapshot == null) return;
        setState(
          () => _gameObservations[snapshot != null ? 'dom' : 'structured'] =
              source,
        );
      });
      if (!_continueLoading(generation)) return;
      if (_consumption != null) {
        await controller.addJavaScriptChannel(
          'MaasoConsumption',
          onMessageReceived: (message) =>
              _handleConsumptionMessage(generation, message),
        );
        if (!_continueLoading(generation)) return;
      }
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      if (!_continueLoading(generation)) return;
      await controller.setBackgroundColor(Colors.black);
      if (!_continueLoading(generation)) return;
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) => _handlePageStarted(generation, url),
          onPageFinished: (url) => _handlePageFinished(generation, url),
          onWebResourceError: (error) =>
              _handleWebResourceError(generation, error),
          onNavigationRequest: (request) {
            if (!_canLoad(generation)) return NavigationDecision.prevent;
            final uri = Uri.tryParse(request.url);
            final allowed = request.isMainFrame
                ? uri == document.embedUrl
                : request.url == 'about:srcdoc';
            return allowed
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
        ),
      );
      if (!_continueLoading(generation)) return;
      setState(() => _web = controller);
      _pageLoadTimer?.cancel();
      _pageLoadTimer = Timer(GameDocumentLoader.timeout, () {
        if (_canLoad(generation) && _loading) _cancelGameLoad();
      });
      await controller.loadHtmlString(
        GameVoiceObservationAdapter.publishedDocument(document.sandboxedHtml),
        baseUrl: document.embedUrl.toString(),
      );
    } catch (error, stackTrace) {
      if (!_continueLoading(generation)) return;
      Log.w(
        '[GameFeed] game document load failed',
        error: error,
        stackTrace: stackTrace,
      );
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
      _syncConsumptionVisibility();
    } finally {
      loader.close();
      if (identical(_documentLoader, loader)) _documentLoader = null;
    }
  }

  void _handleConsumptionMessage(int generation, JavaScriptMessage message) {
    if (!mounted ||
        generation != _loadGeneration ||
        _loading ||
        _loadFailed ||
        !_resumed ||
        !(ModalRoute.of(context)?.isCurrent ?? true)) {
      return;
    }
    final hint = PublicConsumptionHint.parse(
      message.message,
      _isGame ? ContentConsumptionKind.game : ContentConsumptionKind.applet,
    );
    if (hint == null) return;
    if (hint.operation) _consumption?.recordOperation();
    if (hint.progress case final progress?) {
      _consumption?.recordProgress(progress);
    }
  }

  WebViewController _createWebController() {
    final generation = ++_loadGeneration;
    final controller = WebViewController();
    unawaited(_configureWebController(controller, generation));
    return controller;
  }

  Future<void> _configureWebController(
    WebViewController controller,
    int generation,
  ) async {
    try {
      if (_consumption != null) {
        await controller.addJavaScriptChannel(
          'MaasoConsumption',
          onMessageReceived: (message) =>
              _handleConsumptionMessage(generation, message),
        );
        if (!mounted || generation != _loadGeneration) return;
      }
      await _trustedAppletController(
        controller,
        widget.item!,
        onPageStarted: (url) => _handlePageStarted(generation, url),
        onPageFinished: (url) => _handlePageFinished(generation, url),
        onWebResourceError: (error) =>
            _handleWebResourceError(generation, error),
      );
    } catch (error, stackTrace) {
      Log.w(
        '[GameFeed] public applet WebView configuration failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
      _syncConsumptionVisibility();
    }
  }

  void _handlePageStarted(int generation, String _) {
    if (!mounted ||
        generation != _loadGeneration ||
        (_isGame && !_canLoad(generation))) {
      return;
    }
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    _syncConsumptionVisibility();
  }

  void _handlePageFinished(int generation, String _) {
    if (!mounted ||
        generation != _loadGeneration ||
        _loadFailed ||
        (_isGame && !_canLoad(generation))) {
      return;
    }
    _pageLoadTimer?.cancel();
    setState(() {
      _loading = false;
    });
    _syncConsumptionVisibility();
    final web = _web;
    if (_isGame && web != null) {
      unawaited(
        GameScreenshotStore.captureOpenedPlayer(
          identity: 'public:${widget.id}',
          revision: widget.updatedAt.toIso8601String(),
          shareUrl: widget.shareUrl,
          capture: () => OpenedGameSnapshot.capture(web),
          isCurrent: () =>
              _canLoad(generation) &&
              !_loading &&
              !_loadFailed &&
              identical(_web, web),
        ),
      );
    }
  }

  void _handleWebResourceError(int generation, WebResourceError error) {
    if (!mounted ||
        generation != _loadGeneration ||
        error.isForMainFrame == false) {
      return;
    }
    _pageLoadTimer?.cancel();
    setState(() {
      _loading = false;
      _loadFailed = true;
    });
    _syncConsumptionVisibility();
  }

  void _retry() {
    if (_loading) return;
    if (_isGame) {
      final previous = _web;
      if (previous != null) {
        unawaited(previous.loadHtmlString('<!doctype html><html></html>'));
      }
      setState(() {
        _loading = true;
        _loadFailed = false;
        _web = null;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_loadGame());
      });
      return;
    }
    final nextWeb = _createWebController();
    if (!mounted) return;
    setState(() {
      _loading = true;
      _loadFailed = false;
      _web = nextWeb;
    });
    _syncConsumptionVisibility();
  }

  @override
  Widget build(BuildContext context) {
    _syncConsumptionVisibility();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final content = Stack(
      fit: StackFit.expand,
      children: <Widget>[
        const ColoredBox(color: GameFrostChrome.canvas),
        if (_web case final web?)
          KeyedSubtree(
            key: const ValueKey<String>('public-game-webview'),
            child: WebViewWidget(
              key: ValueKey<int>(_loadGeneration),
              controller: web,
            ),
          ),
        if (_isGame)
          AnimatedSwitcher(
            duration: reduceMotion
                ? Duration.zero
                : const Duration(milliseconds: 220),
            child: _loadFailed
                ? _GameLoadFailure(
                    key: const ValueKey<String>('public-game-load-error'),
                    onRetry: _retry,
                  )
                : _loading
                ? _GameCoverArt(
                    key: const ValueKey<String>('public-game-loading'),
                    identityKey: 'public:${widget.id}',
                    loading: true,
                  )
                : const SizedBox.shrink(),
          ),
      ],
    );
    final player = _isGame
        ? GameVoiceHost(
            playerId: 'public:${widget.id}',
            scopeKey: _scopeKey,
            documentGeneration: _loadGeneration,
            title: widget.title,
            summary: widget.item?.summary ?? '',
            ready: !_loading && !_loadFailed,
            controller: _web,
            bufferedObservations: _gameObservations.values.toList(
              growable: false,
            ),
            contentIdentity: _gameContentIdentity,
            playerIsCurrent: () => _canLoad(_loadGeneration),
            child: content,
          )
        : content;
    if (widget.inventory != null) return player;
    if (_isGame) {
      return _GamePlayerShell(
        hostKey: const ValueKey<String>('public-game-player-host'),
        backKey: const ValueKey<String>('public-game-player-back'),
        player: player,
        onBack: appNavigation.pop,
      );
    }
    return _AppletPlayerShell(
      appletId: widget.id,
      likedByMe: widget.item?.likedByMe ?? false,
      player: Stack(
        fit: StackFit.expand,
        children: [
          player,
          if (_loadFailed)
            _AppletSearchMessage(
              icon: Icons.cloud_off_rounded,
              message: 'widgets.search_failed'.tr,
              onRetry: _retry,
            )
          else if (_loading)
            const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}

class _GameLoadFailure extends StatelessWidget {
  const _GameLoadFailure({super.key, required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF0D0D0D),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(
                Icons.cloud_off_rounded,
                color: Colors.white70,
                size: 44,
              ),
              const SizedBox(height: 14),
              Text(
                'game_feed.load_failed'.tr,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  height: 1.35,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 18),
              GameFrostChrome(
                child: TextButton.icon(
                  onPressed: onRetry,
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white,
                    minimumSize: const Size(96, 48),
                  ),
                  icon: const Icon(Icons.refresh_rounded),
                  label: Text('common.retry'.tr),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> _trustedAppletController(
  WebViewController controller,
  AppletCatalogItem item, {
  PageEventCallback? onPageStarted,
  PageEventCallback? onPageFinished,
  WebResourceErrorCallback? onWebResourceError,
}) => _trustedAppletUrlController(
  controller,
  item.shareUrl,
  type: item.type,
  onPageStarted: onPageStarted,
  onPageFinished: onPageFinished,
  onWebResourceError: onWebResourceError,
);

Future<void> _trustedAppletUrlController(
  WebViewController controller,
  Uri shellUrl, {
  required AppletCatalogType type,
  PageEventCallback? onPageStarted,
  PageEventCallback? onPageFinished,
  WebResourceErrorCallback? onWebResourceError,
}) async {
  if (!isTrustedAppletShareUrl(shellUrl, trustedOrigin: shellUrl)) {
    throw ArgumentError.value(shellUrl, 'item.shareUrl', 'untrusted share URL');
  }
  final embedUrl = shellUrl.replace(
    pathSegments: <String>[...shellUrl.pathSegments, 'embed'],
  );
  // The native player owns navigation and engagement chrome. Open only the
  // isolated content endpoint so the website title/header is not duplicated.
  final launchUrl = embedUrl;
  final trustedSrcdocUrl = Uri.parse('about:srcdoc');
  await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
  await controller.setBackgroundColor(Colors.black);
  await controller.setNavigationDelegate(
    NavigationDelegate(
      onPageStarted: onPageStarted,
      onPageFinished: onPageFinished,
      onWebResourceError: onWebResourceError,
      onNavigationRequest: (request) {
        final uri = Uri.tryParse(request.url);
        final isTrustedSrcdoc = !request.isMainFrame && uri == trustedSrcdocUrl;
        final allowed =
            uri != null &&
            (isTrustedSrcdoc || (request.isMainFrame && uri == embedUrl));
        return allowed
            ? NavigationDecision.navigate
            : NavigationDecision.prevent;
      },
    ),
  );
  await controller.loadRequest(launchUrl);
}

/// Inventory records have no author metadata. Their published content uses
/// the same trusted shell/embed navigation policy as public catalog Applets.
class _CloudAppletPlayerPage extends StatefulWidget {
  const _CloudAppletPlayerPage({required this.item});
  final AppletInventoryItem item;

  @override
  State<_CloudAppletPlayerPage> createState() => _CloudAppletPlayerPageState();
}

class _CloudAppletPlayerPageState extends State<_CloudAppletPlayerPage> {
  late WebViewController _web;
  bool _loading = true;
  bool _failed = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final generation = ++_generation;
    _web = WebViewController();
    _loading = true;
    _failed = false;
    unawaited(_configure(generation));
  }

  Future<void> _configure(int generation) async {
    try {
      await _trustedAppletUrlController(
        _web,
        widget.item.shareUrl!,
        type: widget.item.type,
        onPageFinished: (_) {
          if (mounted && generation == _generation) {
            setState(() => _loading = false);
          }
        },
        onWebResourceError: (error) {
          if (error.isForMainFrame == false) return;
          if (mounted && generation == _generation) {
            setState(() {
              _failed = true;
              _loading = false;
            });
          }
        },
      );
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _failed = true;
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => _AppletPlayerShell(
    appletId: widget.item.id,
    player: Stack(
      fit: StackFit.expand,
      key: const ValueKey('cloud-applet-player'),
      children: [
        if (_failed)
          Center(
            child: IconButton(
              tooltip: 'common.retry'.tr,
              onPressed: () => setState(_load),
              icon: const Icon(Icons.refresh_rounded),
            ),
          )
        else
          Positioned.fill(child: WebViewWidget(controller: _web)),
        if (_loading) const Center(child: CircularProgressIndicator()),
      ],
    ),
  );
}

class _AppletPlayerShell extends StatelessWidget {
  const _AppletPlayerShell({
    required this.player,
    this.appletId,
    this.likedByMe = false,
    this.onBack,
  });
  final VoidCallback? onBack;
  final Widget player;
  final String? appletId;
  final bool likedByMe;

  @override
  Widget build(BuildContext context) => AppGlassScaffold(
    backdropKind: GlassBackdropKind.platformView,
    safeArea: false,
    body: Stack(
      key: const ValueKey('applet-player-fullscreen'),
      fit: StackFit.expand,
      children: [
        player,
        SafeArea(
          bottom: false,
          minimum: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Align(
            alignment: Alignment.topCenter,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                AppGlassIconButton(
                  key: const ValueKey('applet-player-back'),
                  size: 48,
                  icon: Icons.arrow_back_rounded,
                  tooltip: 'common.back'.tr,
                  onPressed: onBack ?? appNavigation.pop,
                ),
                AppletPlayerLikeButton(
                  appletId: appletId,
                  likedByMe: likedByMe,
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

class _OfficialTile extends StatelessWidget {
  const _OfficialTile({required this.applet});
  final OfficialApplet applet;

  @override
  Widget build(BuildContext context) => _AppletListRow(
    key: ValueKey('official-applet-${applet.id}'),
    icon: Icon(applet.icon, color: MaasoGlassTheme.of(context).accentText),
    title: applet.nameKey.tr,
    subtitle: AppletCategoryTaxonomy.forOfficialId(applet.id).labelKey.tr,
    badges: [
      _AppletPill(label: 'widgets.official_badge'.tr, official: true),
      _OfficialAppletRating(appletId: applet.id),
      if (applet.id == 'ble_yoturetoys_projector')
        const _ProjectorConnectedDot(),
    ],
    onTap: () => appNavigation.pushPage(
      applet.builder,
      transition: AppTransition.cupertino,
    ),
  );
}

class _OfficialAppletRating extends StatefulWidget {
  const _OfficialAppletRating({required this.appletId});
  final String appletId;
  @override
  State<_OfficialAppletRating> createState() => _OfficialAppletRatingState();
}

class _OfficialAppletRatingState extends State<_OfficialAppletRating> {
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final catalog = appServices.maybeFind<AppletCatalogService>();
    final controller = appServices.maybeFind<WidgetsHubController>();
    if (catalog == null || controller == null) return;
    final contextKey = catalog.requestContextKey;
    try {
      final snapshot = await catalog.officialEngagement(
        widget.appletId,
        expectedContextKey: contextKey,
      );
      if (mounted && contextKey == catalog.requestContextKey) {
        controller.appletEngagement[widget.appletId] = snapshot;
      }
    } catch (_) {
      // Keep the native applet available when its rating is offline.
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = appServices.maybeFind<WidgetsHubController>();
    if (controller == null) return const SizedBox.shrink();
    return AppReactiveBuilder(() {
      final score = controller.appletEngagement[widget.appletId]?.likeCount;
      return score == null
          ? const SizedBox.shrink()
          : _AppletPill(
              label: 'widgets.rating_score'.trParams({'count': '$score'}),
            );
    });
  }
}

class _AppletPill extends StatelessWidget {
  const _AppletPill({required this.label, this.official = false});
  final String label;
  final bool official;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: official ? glass.accentText.withValues(alpha: .10) : glass.muted,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: official ? glass.accentText : glass.foregroundSecondary,
          ),
        ),
      ),
    );
  }
}

class _AppletListRow extends StatelessWidget {
  const _AppletListRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.badges,
    required this.onTap,
    this.onLongPress,
    this.trailing,
  });
  final Widget icon;
  final String title;
  final String subtitle;
  final List<Widget> badges;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => _AppletMatteCard(
    onTap: onTap,
    onLongPress: onLongPress,
    padding: const EdgeInsets.all(16),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: MaasoGlassTheme.of(context).surface,
            borderRadius: BorderRadius.circular(16),
          ),
          alignment: Alignment.center,
          child: icon,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
              ),
              if (subtitle.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: MaasoGlassTheme.of(context).foregroundSecondary,
                  ),
                ),
              ],
              if (badges.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: badges,
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 8), trailing!],
      ],
    ),
  );
}

/// Live "paired" indicator on the projector tile — a small green dot shown
/// while the Yoturetoys device is connected, so the user sees it's paired
/// straight from the hub without opening the applet.
class _ProjectorConnectedDot extends StatelessWidget {
  const _ProjectorConnectedDot();

  @override
  Widget build(BuildContext context) {
    if (!appServices.isRegistered<YoturetoysDevice>()) {
      return const SizedBox.shrink();
    }
    final device = appServices.find<YoturetoysDevice>();
    return AppReactiveBuilder(() {
      if (!device.isConnected.value) return const SizedBox.shrink();
      return Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          color: const Color(0xFF2BB673),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
        ),
      );
    });
  }
}

class _FunctionalAppletRow extends StatelessWidget {
  const _FunctionalAppletRow({required this.item, required this.index});
  final AgentWidget item;
  final int index;

  @override
  Widget build(BuildContext context) {
    final category = AppletCategoryTaxonomy.forWidget(item);
    final controller = appServices.find<WidgetsHubController>();
    return AppReactiveBuilder(
      () => _AppletListRow(
        key: ValueKey('owned-applet-${item.id}'),
        icon: _FunctionalAppletIcon(item: item, category: category),
        title: item.title,
        subtitle: item.subtitle?.trim() ?? '',
        badges: [
          AppletCategoryBadge(category: category),
          _AppletPill(label: _localAppletStatus(item, controller)),
        ],
        onTap: () {
          if (!item.seen) unawaited(controller.markSeen(item));
          unawaited(openAgentWidget(item));
        },
        onLongPress: () => unawaited(_manageLocalApplet(context, item)),
        trailing: IconButton(
          key: ValueKey('owned-applet-more-${item.id}'),
          tooltip: 'widgets.manage_named'.trParams({'name': item.title}),
          onPressed: controller.publishingAppletIds.contains(item.id)
              ? null
              : () => unawaited(_manageLocalApplet(context, item)),
          icon: const Icon(Icons.more_horiz_rounded),
        ),
      ),
    );
  }
}

String _localAppletStatus(AgentWidget item, WidgetsHubController controller) {
  if (controller.appletPublicationPhases[item.id] ==
      AgentGamePublicationPhase.reviewing) {
    return 'widgets.reviewing'.tr;
  }
  if (controller.publishingAppletIds.contains(item.id)) {
    return 'widgets.publishing'.tr;
  }
  if (controller.appletPublishErrors[item.id] != null) {
    return 'widgets.publish_failed'.tr;
  }
  final cloud = AgentGameCloudMetadata.fromSpec(item.spec['cloud']);
  return (cloud.isCurrentPublished
          ? 'widgets.published'
          : 'widgets.saved_private')
      .tr;
}

enum _AppletManagementAction { edit, history, publish, delete }

Future<_AppletManagementAction?> _showAppletManagement(
  BuildContext context, {
  required String title,
  required String status,
  bool showHistory = true,
  Key? key,
}) => showAppGlassSheet<_AppletManagementAction>(
  context: context,
  builder: (sheetContext) => Column(
    key: key,
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: Theme.of(sheetContext).textTheme.titleMedium),
      const SizedBox(height: 8),
      _AppletPill(label: status),
      const SizedBox(height: 16),
      for (final action in _AppletManagementAction.values)
        if (showHistory || action != _AppletManagementAction.history)
          ListTile(
            key: ValueKey('applet-management-${action.name}'),
            leading: Icon(switch (action) {
              _AppletManagementAction.edit => Icons.auto_fix_high_rounded,
              _AppletManagementAction.history => Icons.history_rounded,
              _AppletManagementAction.publish => Icons.publish_rounded,
              _AppletManagementAction.delete => Icons.delete_outline_rounded,
            }),
            title: Text('widgets.action_${action.name}'.tr),
            onTap: () => Navigator.of(sheetContext).pop(action),
          ),
    ],
  ),
);

Future<bool> _confirmAppletPublish(BuildContext context) async =>
    await showAppGlassSheet<bool>(
      context: context,
      builder: (sheetContext) => Column(
        key: const ValueKey('applet-publish-confirmation'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'widgets.publish_confirm_title'.tr,
            style: Theme.of(sheetContext).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          Text('widgets.publish_confirm_message'.tr),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: AppGlassButton(
                  label: 'common.cancel'.tr,
                  primary: false,
                  onPressed: () => Navigator.of(sheetContext).pop(false),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: AppGlassButton(
                  label: 'widgets.action_publish'.tr,
                  onPressed: () => Navigator.of(sheetContext).pop(true),
                ),
              ),
            ],
          ),
        ],
      ),
    ) ??
    false;

Future<void> _manageLocalApplet(BuildContext context, AgentWidget item) async {
  final scopeKey = AppletLocalOwnership.currentScopeKey();
  if (!isAppletPresentationDiscoverable(item, scopeKey: scopeKey)) return;
  if (item.spec.containsKey('bundleReference')) {
    await showProjectBuildSavedManagement(context, item);
    return;
  }
  final controller = appServices.find<WidgetsHubController>();
  final action = await _showAppletManagement(
    context,
    title: item.title,
    status: _localAppletStatus(item, controller),
  );
  if (action == null ||
      !context.mounted ||
      scopeKey != AppletLocalOwnership.currentScopeKey()) {
    return;
  }
  if (item.spec.containsKey('bundleReference') &&
      action != _AppletManagementAction.delete) {
    showAppGlassNotice(
      title: item.title,
      message: 'project_bundle.private_preview'.tr,
      icon: Icons.lock_outline_rounded,
    );
    return;
  }
  if (action == _AppletManagementAction.edit) {
    await beginAppletEditing(item);
    return;
  }
  if (action == _AppletManagementAction.history) {
    await showAppletVersionHistory(context, item);
    return;
  }
  if (action == _AppletManagementAction.publish) {
    final confirmed = await _confirmAppletPublish(context);
    if (!confirmed ||
        !context.mounted ||
        scopeKey != AppletLocalOwnership.currentScopeKey()) {
      return;
    }
    try {
      await controller.publishApplet(item);
    } catch (error, stackTrace) {
      Log.w(
        '[Applets] publication failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (scopeKey != AppletLocalOwnership.currentScopeKey()) return;
      showAppGlassNotice(
        title: item.title,
        message: 'widgets.publish_failed'.tr,
        icon: Icons.cloud_off_rounded,
      );
    }
    return;
  }
  final confirmed = await _confirmOwnedGameDelete(
    context,
    item.title,
    isGame: false,
  );
  if (!confirmed ||
      !context.mounted ||
      scopeKey != AppletLocalOwnership.currentScopeKey()) {
    return;
  }
  try {
    await controller.dismiss(item);
  } catch (error, stackTrace) {
    Log.w(
      '[Applets] local delete failed',
      error: error,
      stackTrace: stackTrace,
    );
    showAppGlassNotice(
      title: 'agent_games.delete_failed_title'.tr,
      message: 'agent_games.delete_failed'.tr,
      icon: Icons.cloud_off_rounded,
    );
  }
}

class _FunctionalAppletIcon extends StatelessWidget {
  const _FunctionalAppletIcon({required this.item, required this.category});

  final AgentWidget item;
  final AppletCategory category;

  @override
  Widget build(BuildContext context) {
    final emoji = item.icon?.trim();
    if (emoji?.isNotEmpty == true) {
      return Center(
        child: Text(
          emoji!,
          maxLines: 1,
          style: const TextStyle(fontSize: 24, height: 1),
        ),
      );
    }
    return Icon(switch (category) {
      AppletCategory.all => Icons.apps_rounded,
      AppletCategory.game => Icons.sports_esports_rounded,
      AppletCategory.travel => Icons.travel_explore_rounded,
      AppletCategory.tools => Icons.handyman_rounded,
    }, color: ColorConstant.secondaryColor);
  }
}

/// One rounded iOS-style tile.
///
/// Premium motion: a staggered fade/slide/scale entrance (each tile a beat
/// after the last) plus a soft press-scale on tap — both honoring the system
/// reduce-motion setting.
class _HubTile extends StatefulWidget {
  final AgentWidget item;
  final int index;
  const _HubTile({required this.item, required this.index});

  @override
  State<_HubTile> createState() => _HubTileState();
}

class _HubTileState extends State<_HubTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entrance;
  bool _pressed = false;
  bool _sharing = false;
  bool _deleting = false;

  AgentWidget get item => widget.item;

  String get _surfaceKind =>
      (item.spec['surfaceKind'] ?? item.spec['surface'] ?? item.spec['kind'])
          .toString()
          .trim();

  String get _rendering => (item.spec['rendering']?.toString() ?? '').trim();

  Color get _accent => MaasoGlassTheme.of(context).accentText;

  IconData get _surfaceIcon {
    if (_rendering == 'canvas' || _surfaceKind == 'floatingCanvas') {
      return Icons.brush_rounded;
    }
    if (_rendering == 'three') {
      return Icons.view_in_ar_rounded;
    }
    switch (_surfaceKind) {
      case 'fullscreen':
        return Icons.tv_rounded;
      case 'transparentOverlay':
        return Icons.layers_rounded;
      case 'background':
        return Icons.landscape_rounded;
      case 'card':
        return Icons.widgets_rounded;
      default:
        return Icons.auto_awesome_rounded;
    }
  }

  String get _kindLabel {
    switch (_surfaceKind) {
      case 'fullscreen':
        return 'widgets.kind_fullscreen'.tr;
      case 'floatingCanvas':
        return 'widgets.kind_floating_canvas'.tr;
      case 'transparentOverlay':
        return 'widgets.kind_transparent_overlay'.tr;
      case 'background':
        return 'widgets.kind_background'.tr;
      case 'card':
        return 'widgets.kind_card'.tr;
      default:
        return 'widgets.kind_applet'.tr;
    }
  }

  @override
  void initState() {
    super.initState();
    _entrance = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );
    // Cap the cascade so a long grid doesn't trail off-screen for seconds.
    final delay = Duration(milliseconds: 45 * widget.index.clamp(0, 8));
    Future.delayed(delay, () {
      if (mounted) _entrance.forward();
    });
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = appServices.find<WidgetsHubController>();
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;

    final tile = GestureDetector(
      onTap: () => _open(context),
      onLongPress: () => _showActions(context, c),
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed && !reduceMotion ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 130),
        curve: Curves.easeOut,
        child: _card(context),
      ),
    );

    if (reduceMotion) {
      if (_entrance.value != 1.0) _entrance.value = 1.0;
      return tile;
    }

    return AnimatedBuilder(
      animation: _entrance,
      builder: (_, child) {
        final t = Curves.easeOutCubic.transform(_entrance.value);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * 16),
            child: Transform.scale(scale: 0.96 + 0.04 * t, child: child),
          ),
        );
      },
      child: tile,
    );
  }

  Widget _card(BuildContext context) {
    return _SecondaryHubCard(
      icon: _surfaceIcon,
      title: item.title,
      subtitle: item.subtitle ?? _kindLabel,
      accent: _accent,
      unseen: !item.seen,
      badge: AppletCategoryBadge(
        category: AppletCategoryTaxonomy.forWidget(item),
      ),
      portal: WorldPortalButton(
        icon: Icons.play_arrow_rounded,
        accent: _accent,
        tooltip: 'widgets.open_named'.trParams({'name': item.title}),
        onTap: () => _open(context),
      ),
    );
  }

  void _open(BuildContext context) {
    if (!item.seen) appServices.find<WidgetsHubController>().markSeen(item);
    // ignore: unawaited_futures
    openAgentWidget(item);
  }

  void _showActions(BuildContext context, WidgetsHubController c) {
    if (item.spec.containsKey('bundleReference')) {
      unawaited(showProjectBuildSavedManagement(context, item));
      return;
    }
    final actions = surfaceHubActions(item);
    final hasDeleteAction = actions.any(
      (action) => action.kind == SurfaceHubActionKind.delete,
    );
    showAppGlassSheet<void>(
      context: context,
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final action in actions)
            ListTile(
              enabled: action.enabled,
              leading: Icon(
                _hubActionIcon(action.kind),
                color: _hubActionColor(action.kind),
              ),
              title: Text(action.label),
              onTap: action.enabled
                  ? () {
                      appNavigation.pop();
                      _runHubAction(context, c, action.kind);
                    }
                  : null,
            ),
          if (actions.isNotEmpty && !hasDeleteAction) const Divider(height: 1),
          if (!hasDeleteAction)
            ListTile(
              leading: const Icon(
                Icons.delete_outline,
                color: ColorConstant.errorColor,
              ),
              title: Text('widgets.remove'.tr),
              onTap: () {
                appNavigation.pop();
                if (!_deleting) unawaited(_delete(c));
              },
            ),
        ],
      ),
    );
  }

  IconData _hubActionIcon(SurfaceHubActionKind kind) {
    switch (kind) {
      case SurfaceHubActionKind.open:
        return Icons.play_arrow_rounded;
      case SurfaceHubActionKind.remix:
        return Icons.auto_fix_high_rounded;
      case SurfaceHubActionKind.duplicate:
        return Icons.content_copy_rounded;
      case SurfaceHubActionKind.revert:
        return Icons.restore_rounded;
      case SurfaceHubActionKind.share:
        return Icons.ios_share_rounded;
      case SurfaceHubActionKind.delete:
        return Icons.delete_outline;
    }
  }

  Color? _hubActionColor(SurfaceHubActionKind kind) {
    return switch (kind) {
      SurfaceHubActionKind.delete => ColorConstant.errorColor,
      _ => null,
    };
  }

  void _runHubAction(
    BuildContext context,
    WidgetsHubController c,
    SurfaceHubActionKind kind,
  ) {
    switch (kind) {
      case SurfaceHubActionKind.open:
        _open(context);
        return;
      case SurfaceHubActionKind.remix:
        _open(context);
        showAppGlassNotice(
          title: 'widgets.remix_title'.tr,
          message: 'widgets.remix_message'.tr,
          icon: Icons.auto_fix_high_rounded,
        );
        return;
      case SurfaceHubActionKind.duplicate:
        _open(context);
        showAppGlassNotice(
          title: 'widgets.duplicate_title'.tr,
          message: 'widgets.duplicate_message'.tr,
          icon: Icons.content_copy_rounded,
        );
        return;
      case SurfaceHubActionKind.revert:
        _open(context);
        showAppGlassNotice(
          title: 'widgets.revert_title'.tr,
          message: 'widgets.revert_message'.tr,
          icon: Icons.restore_rounded,
        );
        return;
      case SurfaceHubActionKind.share:
        if (_sharing || _deleting) return;
        unawaited(_share(context));
        return;
      case SurfaceHubActionKind.delete:
        if (_deleting || _sharing) return;
        unawaited(_delete(c));
        return;
    }
  }

  Future<void> _delete(WidgetsHubController controller) async {
    if (item.spec.containsKey('bundleReference')) {
      await showProjectBuildSavedManagement(context, item);
      return;
    }
    setState(() => _deleting = true);
    try {
      await controller.dismiss(item);
    } catch (error, stackTrace) {
      Log.w('[Applets] delete failed', error: error, stackTrace: stackTrace);
      showAppGlassNotice(
        title: 'agent_games.delete_failed_title'.tr,
        message: 'agent_games.delete_failed'.tr,
        icon: Icons.cloud_off_rounded,
      );
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  Future<void> _share(BuildContext context) async {
    final origin = _globalRect(context);
    setState(() => _sharing = true);
    try {
      final opened = await _shareAgentGame(item, origin: origin);
      if (!opened) {
        showAppGlassNotice(
          title: 'agent_games.share_unavailable_title'.tr,
          message: 'agent_games.share_unavailable'.tr,
          icon: Icons.ios_share_rounded,
        );
      }
    } on AppletPublicationUnavailableException catch (error, stackTrace) {
      Log.w(
        '[Applets] publication unavailable',
        error: error,
        stackTrace: stackTrace,
      );
      showAppGlassNotice(
        title: 'agent_games.publication_unavailable_title'.tr,
        message: 'agent_games.publication_unavailable'.tr,
        icon: Icons.cloud_off_rounded,
      );
    } catch (error, stackTrace) {
      Log.w('[Applets] share failed', error: error, stackTrace: stackTrace);
      showAppGlassNotice(
        title: 'agent_games.share_failed_title'.tr,
        message: 'agent_games.share_failed'.tr,
        icon: Icons.cloud_off_rounded,
      );
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }
}

class _SecondaryHubCard extends StatelessWidget {
  const _SecondaryHubCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.accent,
    required this.portal,
    this.unseen = false,
    this.badge,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color accent;
  final Widget portal;
  final bool unseen;
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final iconBadge = DecoratedBox(
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(18),
      ),
      child: SizedBox.square(
        dimension: 50,
        child: Icon(icon, color: accent, size: 26),
      ),
    );
    final titleWidget = Text(
      title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: glass.foregroundPrimary,
        fontSize: 15,
        height: 1.16,
        fontWeight: FontWeight.w600,
      ),
    );
    final subtitleWidget = Text(
      subtitle,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: glass.foregroundSecondary,
        fontSize: 13,
        height: 1.2,
        fontWeight: FontWeight.w700,
      ),
    );

    return _AppletMatteCard(
      cornerRadius: 24,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              iconBadge,
              if (badge != null) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: Align(alignment: Alignment.centerRight, child: badge!),
                ),
              ] else
                const Spacer(),
              if (unseen) ...[
                if (badge != null) const SizedBox(width: 6),
                _HubUnseenDot(accent: accent),
              ],
            ],
          ),
          const Spacer(),
          titleWidget,
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: subtitleWidget),
              const SizedBox(width: 8),
              portal,
            ],
          ),
        ],
      ),
    );
  }
}

class _AppletMatteCard extends StatelessWidget {
  const _AppletMatteCard({
    required this.child,
    required this.padding,
    this.cornerRadius = MaasoGlassTheme.surfaceRadius,
    this.onTap,
    this.onLongPress,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double cornerRadius;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) => Semantics(
    button: onTap != null,
    child: Material(
      color: MaasoGlassTheme.of(context).muted,
      borderRadius: BorderRadius.circular(cornerRadius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(padding: padding, child: child),
      ),
    ),
  );
}

class _HubUnseenDot extends StatelessWidget {
  const _HubUnseenDot({required this.accent});

  final Color accent;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
      child: const SizedBox.square(dimension: 9),
    );
  }
}

class _SurfaceViewPage extends StatefulWidget {
  final AgentWidget item;
  final int? surfaceSession;
  final SurfaceRuntime runtime;
  final bool Function()? sourceIsCurrent;
  const _SurfaceViewPage({
    required this.item,
    this.surfaceSession,
    required this.runtime,
    this.sourceIsCurrent,
  });

  @override
  State<_SurfaceViewPage> createState() => _SurfaceViewPageState();
}

class _SurfaceViewPageState extends State<_SurfaceViewPage> {
  WebViewController? _openedGameController;
  bool _workerFatal = false;
  bool _retryingWorker = false;
  bool _accessRevoked = false;
  bool _scopeExitScheduled = false;
  final List<Worker> _scopeWorkers = <Worker>[];
  StreamSubscription<WidgetCreatedEvent>? _widgetCreatedSub;
  late int _surfaceSession;
  bool _opening = false;
  int _openingGeneration = 0;
  AgentWidget? _preparedItem;
  AgentWidget get _item => _preparedItem ?? widget.item;

  @override
  void initState() {
    super.initState();
    _surfaceSession = widget.surfaceSession ?? -1;
    if (widget.surfaceSession == null) {
      _opening = true;
      widget.runtime.initializeLifecycle();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_prepareOpenedGame());
      });
    }
    _accessRevoked =
        !AppletLocalOwnership.isVisible(_item) ||
        widget.sourceIsCurrent?.call() == false;
    _scopeWorkers.addAll(
      AppletLocalOwnership.watchScope(() {
        if (AppletLocalOwnership.isVisible(_item) &&
            widget.sourceIsCurrent?.call() != false) {
          return;
        }
        _accessRevoked = true;
        unawaited(widget.runtime.closeIfSession(_surfaceSession));
        if (mounted) {
          setState(() {});
          _scheduleScopeExit();
        }
      }),
    );
    _widgetCreatedSub = EventBus().on<WidgetCreatedEvent>().listen((_) {
      unawaited(_closeGlobalGameSurface());
    });
  }

  @override
  void dispose() {
    _openingGeneration++;
    for (final worker in _scopeWorkers) {
      worker.dispose();
    }
    unawaited(_widgetCreatedSub?.cancel());
    final session = _surfaceSession >= 0
        ? _surfaceSession
        : widget.runtime.activeSession;
    super.dispose();
    unawaited(_disposeRuntime(session));
  }

  Future<void> _prepareOpenedGame() async {
    final generation = ++_openingGeneration;
    if (!_opening && mounted) {
      setState(() {
        _opening = true;
        _workerFatal = false;
      });
    }
    final scope = AppletLocalOwnership.currentScopeKey();
    bool current() =>
        mounted &&
        !_accessRevoked &&
        widget.sourceIsCurrent?.call() != false &&
        generation == _openingGeneration &&
        scope == AppletLocalOwnership.currentScopeKey() &&
        (ModalRoute.of(context)?.isCurrent ?? true);
    try {
      await _closeGlobalGameSurface();
      if (!current()) return;
      final prepared = await _prepareSurface(
        _item,
        expectedScopeKey: scope,
        runtime: widget.runtime,
        canContinue: current,
      );
      if (!current()) {
        if (prepared != null) {
          await widget.runtime.closeIfSession(prepared.session);
        }
        if (mounted && generation == _openingGeneration) {
          setState(() {
            _opening = false;
            _workerFatal = true;
          });
        }
        return;
      }
      setState(() {
        _opening = false;
        _workerFatal = prepared == null;
        if (prepared != null) {
          _preparedItem = prepared.item;
          _surfaceSession = prepared.session;
        }
      });
    } catch (error, stackTrace) {
      if (!current()) return;
      Log.w(
        '[GameFeed] saved game preparation failed',
        error: error,
        stackTrace: stackTrace,
      );
      setState(() {
        _opening = false;
        _workerFatal = true;
      });
    }
  }

  void _captureOpenedGame(WebViewController controller) {
    if (mounted && !identical(_openedGameController, controller)) {
      setState(() => _openedGameController = controller);
    }
    if (_item.spec.containsKey('bundleReference')) return;
    final session = _surfaceSession;
    unawaited(
      GameScreenshotStore.captureOpenedPlayer(
        identity: 'local:${_item.id ?? _item.spec['surfaceId']}',
        revision: _item.createdAt.toIso8601String(),
        localItem: _item,
        capture: () => OpenedGameSnapshot.capture(controller),
        isCurrent: () =>
            mounted &&
            !_opening &&
            !_workerFatal &&
            !_accessRevoked &&
            widget.runtime.isSessionCurrent(session) &&
            (ModalRoute.of(context)?.isCurrent ?? true),
      ),
    );
  }

  Future<void> _disposeRuntime(int session) async {
    await widget.runtime.closeIfSession(session);
    widget.runtime.closeLifecycle();
  }

  @override
  Widget build(BuildContext context) {
    if (_accessRevoked ||
        !AppletLocalOwnership.isVisible(_item) ||
        widget.sourceIsCurrent?.call() == false) {
      _accessRevoked = true;
      _scheduleScopeExit();
      return const ColoredBox(color: Colors.black);
    }
    final isGame =
        AppletCategoryTaxonomy.forWidget(_item) == AppletCategory.game;
    final child = isGame
        ? _buildOwnedGameSurface(context)
        : _buildStandardSurface(context);
    return PopScope<Object?>(
      canPop: !_isNativeBundle || _allowBundlePop,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_back());
      },
      child: isGame
          ? GameVoiceHost(
              playerId: 'local:${_item.id ?? _item.spec['surfaceId']}',
              scopeKey: AppletLocalOwnership.storedScopeKey(_item),
              documentGeneration: _surfaceSession,
              contentIdentity: _companionContentIdentity(),
              title: _item.title,
              summary:
                  _item.subtitle ?? _item.spec['summary']?.toString() ?? '',
              ready: !_opening && !_workerFatal && !_accessRevoked,
              controller: _openedGameController,
              runtime: widget.runtime,
              playerIsCurrent: () =>
                  widget.runtime.isSessionCurrent(_surfaceSession),
              child: child,
            )
          : child,
    );
  }

  GameContentIdentity? _companionContentIdentity() {
    final bundle = widget.runtime.activeProject.value?.bundlePresentation;
    if (_isNativeBundle) {
      if (bundle?.isCurrent != true) return null;
      return GameContentIdentity(
        kind: GameContentIdentityKind.verifiedBundle,
        sha256: bundle!.installed.candidateDigest,
      );
    }
    return GameContentIdentity(
      kind: GameContentIdentityKind.ownedSource,
      sha256: crypto.sha256
          .convert(utf8.encode(jsonEncode(_item.spec)))
          .toString(),
    );
  }

  bool _allowBundlePop = false;
  bool get _isNativeBundle =>
      _item is _VerifiedBundlePlayerWidget ||
      _item.spec.containsKey('bundleReference');
  Future<void> _back() async {
    try {
      final presentation =
          widget.runtime.activeProject.value?.bundlePresentation;
      if (presentation?.appletGrant != null) {
        await widget.runtime.closeIfSession(_surfaceSession);
      } else if (await widget.runtime.goBackInBundle()) {
        return;
      }
    } catch (_) {
      return;
    }
    if (!mounted) return;
    if (_isNativeBundle && !_allowBundlePop) {
      setState(() => _allowBundlePop = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) appNavigation.pop();
      });
    } else {
      appNavigation.pop();
    }
  }

  Widget _bundleControls(Widget child) {
    final presentation = widget.runtime.activeProject.value?.bundlePresentation;
    if (presentation == null ||
        presentation.isGame ||
        presentation.services.appletControl == null) {
      return child;
    }
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          SizedBox(height: MediaQuery.paddingOf(context).top + 64),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: SurfaceBundleControls(presentation: presentation),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }

  void _scheduleScopeExit() {
    if (!mounted || _scopeExitScheduled) return;
    _scopeExitScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_popRouteAndOverlays(context)) return;
      _scopeExitScheduled = false;
      _scheduleScopeExit();
    });
  }

  Widget _buildOwnedGameSurface(BuildContext context) {
    return _GamePlayerShell(
      hostKey: const ValueKey<String>('game-player-host'),
      player: _opening
          ? _GameCoverArt(identityKey: 'local:${_item.id}', loading: true)
          : _workerFatal
          ? _GameLoadFailure(
              onRetry: () {
                if (_retryingWorker) return;
                setState(() {
                  _opening = true;
                  _workerFatal = false;
                });
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) unawaited(_prepareOpenedGame());
                });
              },
            )
          : _bundleControls(
              SurfaceWebView(
                backgroundColor: Colors.black,
                runtime: widget.runtime,
                onFirstFrameReady: _captureOpenedGame,
                onWorkerFatal: _handleWorkerFatal,
              ),
            ),
      onBack: () => unawaited(_back()),
    );
  }

  Widget _buildStandardSurface(BuildContext context) {
    final cloud = AgentGameCloudMetadata.fromSpec(_item.spec['cloud']);
    return AppReactiveBuilder(
      () => _AppletPlayerShell(
        onBack: () => unawaited(_back()),
        appletId: cloud.hasPublished && cloud.gameId.isNotEmpty
            ? cloud.gameId
            : null,
        player: _opening
            ? const Center(child: CircularProgressIndicator())
            : _workerFatal
            ? _AppletSearchMessage(
                icon: Icons.refresh_rounded,
                message: 'widgets.game_feed_failed'.tr,
                onRetry: _retryingWorker
                    ? null
                    : () => unawaited(
                        _surfaceSession < 0
                            ? _prepareOpenedGame()
                            : _retryWorkerSurface(),
                      ),
              )
            : _bundleControls(
                SurfaceWebView(
                  key: const ValueKey<String>('applet-player-surface'),
                  backgroundColor: Theme.of(context).colorScheme.surface,
                  runtime: widget.runtime,
                  onWorkerFatal: _handleWorkerFatal,
                ),
              ),
      ),
    );
  }

  void _handleWorkerFatal(SurfaceWorkerFatalReason reason) {
    if (!mounted || _workerFatal) return;
    final failedSession = _surfaceSession;
    setState(() => _workerFatal = true);
    unawaited(widget.runtime.closeIfSession(failedSession));
    Log.w('[Applets] detail game worker stopped: ${reason.wireName}');
  }

  Future<void> _retryWorkerSurface() async {
    if (_retryingWorker || !SurfaceRuntime.presentationCapabilityAvailable) {
      return;
    }
    setState(() => _retryingWorker = true);
    try {
      await widget.runtime.closeIfSession(_surfaceSession);
      final int nextSession;
      if (_item.spec.containsKey('bundleReference')) {
        final scope = AppletLocalOwnership.currentScopeKey();
        final prepared = await _prepareSurface(
          _item,
          expectedScopeKey: scope,
          runtime: widget.runtime,
          canContinue: () =>
              mounted &&
              !_accessRevoked &&
              scope == AppletLocalOwnership.currentScopeKey(),
        );
        if (prepared == null) return;
        nextSession = prepared.session;
      } else {
        nextSession = await widget.runtime.showWithSession(
          surfaceProjectFromWidget(_item),
        );
      }
      if (!mounted || !widget.runtime.isSessionCurrent(nextSession)) {
        await widget.runtime.closeIfSession(nextSession);
        return;
      }
      setState(() {
        _surfaceSession = nextSession;
        _workerFatal = false;
      });
    } catch (error, stackTrace) {
      Log.w(
        '[Applets] detail game retry failed',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      if (mounted) setState(() => _retryingWorker = false);
    }
  }
}

Future<bool> _shareAgentGame(AgentWidget item, {Rect? origin}) {
  if (!appServices.isRegistered<AgentGameCloudService>()) {
    throw StateError('Agent game cloud service is unavailable');
  }
  return appServices.find<AgentGameCloudService>().publishAndShare(
    item,
    origin: origin,
  );
}

Future<bool> _openGameSystemShare({
  required String title,
  required String text,
  Rect? origin,
}) {
  final override = gameFeedShareCallbackOverride;
  if (override != null) {
    return override(title: title, text: text, origin: origin);
  }
  return const PlatformAgentGameShareGateway().share(
    title: title,
    text: text,
    origin: origin,
  );
}

Rect? _globalRect(BuildContext context) {
  final renderObject = context.findRenderObject();
  if (renderObject is! RenderBox || !renderObject.hasSize) return null;
  return renderObject.localToGlobal(Offset.zero) & renderObject.size;
}

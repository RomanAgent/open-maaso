import 'dart:async';

import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/applets/data/applet_presentation_state.dart';
import 'package:maaso/src/features/applets/data/applet_catalog_service.dart';
import 'package:maaso/src/features/applets/domain/applet_catalog_models.dart';
import 'package:maaso/src/features/agent_games/data/agent_game_cloud_service.dart';
import 'package:maaso/src/features/widgets_hub/application/applet_category_taxonomy.dart';

class WidgetCreatedEvent extends ClawEvent {
  final int widgetId;
  WidgetCreatedEvent(this.widgetId);
}

class ScopedAppletInventoryItem {
  const ScopedAppletInventoryItem({required this.item, required this.scopeKey});

  final AppletInventoryItem item;
  final String scopeKey;
}

enum AppletHubSection {
  games(AppletCatalogType.game),
  applets(AppletCatalogType.applet);

  const AppletHubSection(this.catalogType);

  final AppletCatalogType catalogType;
}

enum GameFeedSort {
  recommended(AppletCatalogSort.recommended),
  popular(AppletCatalogSort.hot);

  const GameFeedSort(this.catalogSort);

  final AppletCatalogSort catalogSort;
}

enum SurfaceHubActionKind { open, remix, duplicate, revert, share, delete }

class SurfaceHubAction {
  const SurfaceHubAction({
    required this.kind,
    required this.label,
    required this.enabled,
  });

  final SurfaceHubActionKind kind;
  final String label;
  final bool enabled;
}

List<SurfaceHubAction> surfaceHubActions(AgentWidget item) {
  if (!item.isSurface) return const [];
  return [
    SurfaceHubAction(
      kind: SurfaceHubActionKind.open,
      label: 'widgets.action_open'.tr,
      enabled: true,
    ),
    SurfaceHubAction(
      kind: SurfaceHubActionKind.remix,
      label: 'widgets.action_remix'.tr,
      enabled: true,
    ),
    SurfaceHubAction(
      kind: SurfaceHubActionKind.duplicate,
      label: 'widgets.action_duplicate'.tr,
      enabled: true,
    ),
    SurfaceHubAction(
      kind: SurfaceHubActionKind.revert,
      label: 'widgets.action_revert'.tr,
      enabled: true,
    ),
    if (isCloudAppletWidget(item))
      SurfaceHubAction(
        kind: SurfaceHubActionKind.share,
        label: 'widgets.action_share'.tr,
        enabled: true,
      ),
    SurfaceHubAction(
      kind: SurfaceHubActionKind.delete,
      label: 'widgets.action_delete'.tr,
      enabled: true,
    ),
  ];
}

SurfaceProject surfaceProjectFromWidget(AgentWidget item) {
  final json = Map<String, Object?>.from(item.spec);
  json['id'] = (json['surfaceId'] ?? json['id'] ?? 'surface_${item.id ?? ''}')
      .toString();
  json['title'] = item.title;
  json['kind'] = json['surfaceKind'] ?? json['surface'] ?? json['kind'];
  return SurfaceProject.fromJson(json);
}

class WidgetsHubController extends AppController {
  final DBService _db = appServices.find<DBService>();

  final widgets = <AgentWidget>[].obs;
  final isRefreshing = false.obs;
  final searchResults = <AppletCatalogItem>[].obs;
  final appletDiscoveryItems = <AppletCatalogItem>[].obs;
  final isLoadingApplets = false.obs;
  final appletDiscoveryErrorKey = RxnString();
  final appletEngagement = <String, AppletEngagementSnapshot>{}.obs;
  final appletLikeInFlightIds = <String>{}.obs;
  final publishingAppletIds = <int>{}.obs;
  final appletPublicationPhases = <int, AgentGamePublicationPhase>{}.obs;
  final appletPublishErrors = <int, String>{}.obs;
  int _appletDiscoveryGeneration = 0;
  String? _appletDiscoveryCursor;
  bool get hasMoreApplets => _appletDiscoveryCursor != null;
  final recommendedGameFeedItems = <AppletCatalogItem>[].obs;
  final popularGameFeedItems = <AppletCatalogItem>[].obs;
  final gameFeedComments = <AppletComment>[].obs;
  final gameFeedCommentsItemId = RxnString();
  final gameFeedCommentsNextCursor = RxnString();
  final ownerInventoryItems = <AppletInventoryItem>[].obs;
  final cloudOnlyItems = <ScopedAppletInventoryItem>[].obs;
  final isSearching = false.obs;
  final isLoadingGameFeedComments = false.obs;
  final isLoadingMoreGameFeedComments = false.obs;
  final isLoadingCloudInventory = false.obs;
  final searchErrorKey = RxnString();
  final gameFeedCommentsErrorKey = RxnString();
  final cloudInventoryErrorKey = RxnString();
  final searchQuery = ''.obs;
  final Rxn<AppletQuotaSnapshot> remoteQuota = Rxn<AppletQuotaSnapshot>();
  final selectedCategory = AppletCategory.all.obs;
  final selectedSection = AppletHubSection.applets.obs;
  final isSearchExpanded = false.obs;
  StreamSubscription? _eventSub;
  final List<Worker> _scopeWorkers = <Worker>[];
  int _reloadGeneration = 0;
  int _searchGeneration = 0;
  final Map<GameFeedSort, int> _gameFeedGenerations = <GameFeedSort, int>{
    for (final sort in GameFeedSort.values) sort: 0,
  };
  final Map<GameFeedSort, RxBool> _gameFeedLoading = <GameFeedSort, RxBool>{
    for (final sort in GameFeedSort.values) sort: false.obs,
  };
  final Map<GameFeedSort, RxnString> _gameFeedErrors =
      <GameFeedSort, RxnString>{
        for (final sort in GameFeedSort.values) sort: RxnString(),
      };
  String? _searchCursor;
  final Map<GameFeedSort, String?> _gameFeedCursors = <GameFeedSort, String?>{
    for (final sort in GameFeedSort.values) sort: null,
  };
  final Map<GameFeedSort, RxnString> _loadedGameFeedContexts = {
    for (final sort in GameFeedSort.values) sort: RxnString(),
  };
  int _gameFeedEventSequence = 0;
  int _gameFeedCommentsGeneration = 0;
  final Map<String, Future<void>> _engagementTails = <String, Future<void>>{};
  final gameLikeInFlightIds = <String>{}.obs;
  final Map<String, Object> _gameLikeInFlightTokens = <String, Object>{};
  final Map<String, String> _pendingViewEventIds = <String, String>{};
  AppletCatalogType? _searchType;

  bool get hasMoreSearchResults => _searchCursor != null;
  bool isGameLikeInFlight(String itemId) => gameLikeInFlightIds.contains(
    _engagementKey(_interactionContextKey, itemId),
  );
  bool get hasMoreGameFeedComments => gameFeedCommentsNextCursor.value != null;
  RxList<AppletCatalogItem> gameFeedItemsFor(GameFeedSort sort) =>
      switch (sort) {
        GameFeedSort.recommended => recommendedGameFeedItems,
        GameFeedSort.popular => popularGameFeedItems,
      };

  RxBool gameFeedLoadingFor(GameFeedSort sort) => _gameFeedLoading[sort]!;
  RxnString gameFeedErrorFor(GameFeedSort sort) => _gameFeedErrors[sort]!;

  @Deprecated('Use gameFeedLoadingFor with an explicit sort.')
  RxBool get isLoadingGameFeed => gameFeedLoadingFor(GameFeedSort.recommended);

  @Deprecated('Use gameFeedErrorFor with an explicit sort.')
  RxnString get gameFeedErrorKey => gameFeedErrorFor(GameFeedSort.recommended);

  @Deprecated('Use recommendedGameFeedItems or gameFeedItemsFor instead.')
  RxList<AppletCatalogItem> get gameFeedItems => recommendedGameFeedItems;

  bool hasMoreGameFeedItemsFor(GameFeedSort sort) =>
      _gameFeedCursors[sort] != null;

  bool hasReachedGameFeedEndFor(GameFeedSort sort) {
    final loadedContext = _loadedGameFeedContexts[sort]!.value;
    return loadedContext != null &&
        loadedContext == _catalog?.requestContextKey &&
        gameFeedItemsFor(sort).isNotEmpty &&
        !gameFeedLoadingFor(sort).value &&
        gameFeedErrorFor(sort).value == null &&
        !hasMoreGameFeedItemsFor(sort);
  }

  bool get hasMoreGameFeedItems =>
      hasMoreGameFeedItemsFor(GameFeedSort.recommended);

  void selectCategory(AppletCategory category) {
    selectedCategory.value = category;
  }

  void selectSection(AppletHubSection section) {
    if (selectedSection.value == section) return;
    selectedSection.value = section;
    selectedCategory.value = AppletCategory.all;
    if (section == AppletHubSection.games && recommendedGameFeedItems.isEmpty) {
      unawaited(loadGameFeed());
    }
    final query = searchQuery.value.trim();
    if (query.isNotEmpty) {
      unawaited(search(query, type: section.catalogType));
    }
  }

  void toggleSearch() {
    isSearchExpanded.toggle();
    if (!isSearchExpanded.value) clearSearch();
  }

  AppletCatalogService? get _catalog =>
      appServices.isRegistered<AppletCatalogService>()
      ? appServices.find<AppletCatalogService>()
      : null;

  @override
  void onInit() {
    super.onInit();
    reload();
    _eventSub = EventBus().on<WidgetCreatedEvent>().listen((_) {
      reload();
    });
    _scopeWorkers.addAll(
      AppletLocalOwnership.watchScope(() {
        widgets.clear();
        appletDiscoveryItems.clear();
        appletEngagement.clear();
        appletLikeInFlightIds.clear();
        publishingAppletIds.clear();
        appletPublicationPhases.clear();
        appletPublishErrors.clear();
        _appletDiscoveryGeneration++;
        _appletDiscoveryCursor = null;
        isLoadingApplets.value = false;
        appletDiscoveryErrorKey.value = null;
        ownerInventoryItems.clear();
        cloudOnlyItems.clear();
        recommendedGameFeedItems.clear();
        popularGameFeedItems.clear();
        gameFeedComments.clear();
        gameFeedCommentsItemId.value = null;
        gameFeedCommentsNextCursor.value = null;
        gameFeedCommentsErrorKey.value = null;
        isLoadingGameFeedComments.value = false;
        isLoadingMoreGameFeedComments.value = false;
        _gameFeedCommentsGeneration++;
        _pendingViewEventIds.clear();
        _gameLikeInFlightTokens.clear();
        gameLikeInFlightIds.clear();
        for (final sort in GameFeedSort.values) {
          _gameFeedCursors[sort] = null;
          _loadedGameFeedContexts[sort]!.value = null;
          _gameFeedGenerations[sort] = (_gameFeedGenerations[sort] ?? 0) + 1;
          gameFeedLoadingFor(sort).value = false;
          gameFeedErrorFor(sort).value = null;
        }
        cloudInventoryErrorKey.value = null;
        clearSearch();
        reload();
        if (selectedSection.value == AppletHubSection.games) {
          loadGameFeed();
        } else {
          unawaited(loadApplets());
        }
      }),
    );
    _adoptLatestSearch();
  }

  @override
  void onClose() {
    _appletDiscoveryGeneration++;
    for (final sort in GameFeedSort.values) {
      _gameFeedGenerations[sort] = (_gameFeedGenerations[sort] ?? 0) + 1;
    }
    _eventSub?.cancel();
    for (final worker in _scopeWorkers) {
      worker.dispose();
    }
    super.onClose();
  }

  Future<void> reload() async {
    final generation = ++_reloadGeneration;
    final scopeKey = AppletLocalOwnership.currentScopeKey();
    isRefreshing.value = true;
    try {
      final saved = await _db.getAllWidgets();
      if (generation != _reloadGeneration ||
          scopeKey != AppletLocalOwnership.currentScopeKey()) {
        return;
      }
      final scopedLocalItems = saved
          .where(
            (widget) =>
                widget.isSurface &&
                AppletLocalOwnership.isVisible(widget, scopeKey: scopeKey),
          )
          .toList(growable: false);
      widgets.assignAll(
        scopedLocalItems.where(
          (widget) =>
              widget.spec['cloudDelete'] == null &&
              !isAppletPresentationPending(widget),
        ),
      );
      await _reloadCloudInventory(
        generation: generation,
        scopeKey: scopeKey,
        localItems: scopedLocalItems,
      );
    } finally {
      if (generation == _reloadGeneration) {
        isRefreshing.value = false;
      }
    }
  }

  Future<void> _reloadCloudInventory({
    required int generation,
    required String scopeKey,
    required List<AgentWidget> localItems,
  }) async {
    final catalog = _catalog;
    if (scopeKey == AppletLocalOwnership.deviceLegacyScope || catalog == null) {
      ownerInventoryItems.clear();
      cloudOnlyItems.clear();
      cloudInventoryErrorKey.value = null;
      return;
    }
    final contextKey = catalog.requestContextKey;
    isLoadingCloudInventory.value = true;
    cloudInventoryErrorKey.value = null;
    try {
      final page = await catalog.mine();
      if (generation != _reloadGeneration ||
          scopeKey != AppletLocalOwnership.currentScopeKey() ||
          contextKey != catalog.requestContextKey) {
        return;
      }
      final localGameIds = localItems
          .map((item) => AgentGameCloudMetadata.fromSpec(item.spec['cloud']))
          .map((metadata) => metadata.gameId)
          .where((id) => id.isNotEmpty)
          .toSet();
      final localSurfaceIds = localItems
          .map((item) => item.spec['surfaceId']?.toString().trim() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet();
      ownerInventoryItems.assignAll(page.items);
      cloudOnlyItems.assignAll(
        page.items
            .where(
              (item) =>
                  !localGameIds.contains(item.id) &&
                  !localSurfaceIds.contains(item.clientSurfaceId),
            )
            .map(
              (item) =>
                  ScopedAppletInventoryItem(item: item, scopeKey: scopeKey),
            ),
      );
      remoteQuota.value = page.quota;
    } on AppletInventoryUnavailableException {
      if (generation == _reloadGeneration &&
          scopeKey == AppletLocalOwnership.currentScopeKey() &&
          contextKey == catalog.requestContextKey) {
        ownerInventoryItems.clear();
        cloudOnlyItems.clear();
        remoteQuota.value = null;
        cloudInventoryErrorKey.value = null;
      }
    } catch (_) {
      if (generation == _reloadGeneration &&
          scopeKey == AppletLocalOwnership.currentScopeKey() &&
          contextKey == catalog.requestContextKey) {
        ownerInventoryItems.clear();
        cloudOnlyItems.clear();
        cloudInventoryErrorKey.value = 'widgets.cloud_inventory_failed';
      }
    } finally {
      if (generation == _reloadGeneration) {
        isLoadingCloudInventory.value = false;
      }
    }
  }

  Future<void> reloadCloudInventory() async => reload();

  Future<void> deleteCloudOnly(ScopedAppletInventoryItem scoped) async {
    if (!appServices.isRegistered<AgentGameCloudService>()) {
      throw StateError('Applet cloud service is unavailable');
    }
    if (AppletLocalOwnership.currentScopeKey() != scoped.scopeKey) {
      throw StateError('Applet belongs to another account or environment');
    }
    await appServices
        .find<AgentGameCloudService>()
        .deleteRemoteByClientSurfaceId(
          scoped.item.clientSurfaceId,
          expectedScopeKey: scoped.scopeKey,
        );
    await reload();
  }

  /// Public discovery is separate from the authenticated owner's inventory.
  Future<void> loadApplets({bool loadMore = false}) async {
    final catalog = _catalog;
    if (catalog == null || isLoadingApplets.value) return;
    final cursor = loadMore ? _appletDiscoveryCursor : null;
    if (loadMore && cursor == null) return;
    final generation = ++_appletDiscoveryGeneration;
    final contextKey = catalog.requestContextKey;
    isLoadingApplets.value = true;
    appletDiscoveryErrorKey.value = null;
    try {
      final page = await catalog.browse(
        type: AppletCatalogType.applet,
        sort: AppletCatalogSort.rating,
        cursor: cursor,
      );
      if (generation != _appletDiscoveryGeneration ||
          contextKey != catalog.requestContextKey) {
        return;
      }
      if (loadMore) {
        final seen = appletDiscoveryItems.map((item) => item.id).toSet();
        appletDiscoveryItems.addAll(
          page.items.where((item) => seen.add(item.id)),
        );
      } else {
        appletDiscoveryItems.assignAll(page.items);
      }
      _appletDiscoveryCursor = page.nextCursor;
    } catch (_) {
      if (generation == _appletDiscoveryGeneration &&
          contextKey == catalog.requestContextKey) {
        appletDiscoveryErrorKey.value = 'widgets.search_failed';
      }
    } finally {
      if (generation == _appletDiscoveryGeneration) {
        isLoadingApplets.value = false;
      }
    }
  }

  Future<void> refreshApplets() async {
    await reload();
    final query = searchQuery.value.trim();
    if (query.isNotEmpty) {
      await search(query, type: AppletCatalogType.applet);
    } else {
      await loadApplets();
    }
  }

  /// Uses the same idempotent server endpoint as games, with independent state.
  Future<void> toggleAppletLike(String id, {bool likedByMe = false}) async {
    final catalog = _catalog;
    if (catalog == null) throw StateError('Applet catalog unavailable');
    final contextKey = catalog.requestContextKey;
    final key = '$contextKey|$id';
    if (!appletLikeInFlightIds.add(key)) return;
    try {
      final before = appletEngagement[id]?.likedByMe ?? likedByMe;
      final snapshot = await catalog.setLiked(
        id,
        !before,
        expectedContextKey: contextKey,
      );
      if (contextKey != catalog.requestContextKey) return;
      appletEngagement[id] = snapshot;
      for (final list in [appletDiscoveryItems, searchResults]) {
        final index = list.indexWhere((item) => item.id == id);
        if (index < 0) continue;
        list[index] = list[index].copyWith(
          likeCount: snapshot.likeCount,
          likedByMe: snapshot.likedByMe,
        );
      }
    } finally {
      appletLikeInFlightIds.remove(key);
    }
  }

  bool isAppletLikeInFlight(String id) =>
      appletLikeInFlightIds.contains('$_interactionContextKey|$id');

  Future<bool> publishApplet(AgentWidget item) async {
    final id = item.id;
    final scopeKey = AppletLocalOwnership.currentScopeKey();
    if (id == null ||
        publishingAppletIds.contains(id) ||
        !isAppletPresentationDiscoverable(item, scopeKey: scopeKey)) {
      return false;
    }
    final service = appServices.maybeFind<AgentGameCloudService>();
    if (service == null) throw StateError('Applet cloud service unavailable');
    publishingAppletIds.add(id);
    appletPublishErrors.remove(id);
    try {
      await service.publish(
        item,
        onPhase: (phase) {
          if (scopeKey == AppletLocalOwnership.currentScopeKey()) {
            appletPublicationPhases[id] = phase;
          }
        },
      );
      if (scopeKey != AppletLocalOwnership.currentScopeKey()) return false;
      await reload();
      return true;
    } catch (_) {
      if (scopeKey == AppletLocalOwnership.currentScopeKey()) {
        appletPublishErrors[id] = 'widgets.publish_failed';
      }
      rethrow;
    } finally {
      if (scopeKey == AppletLocalOwnership.currentScopeKey()) {
        publishingAppletIds.remove(id);
        appletPublicationPhases.remove(id);
      }
    }
  }

  Future<void> search(String query, {AppletCatalogType? type}) async {
    final normalized = query.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) {
      clearSearch();
      return;
    }
    searchQuery.value = normalized;
    final catalog = _catalog;
    if (catalog == null) {
      searchErrorKey.value = 'widgets.search_unavailable';
      return;
    }
    final generation = ++_searchGeneration;
    final contextKey = catalog.requestContextKey;
    searchQuery.value = normalized;
    _searchType = type;
    _searchCursor = null;
    searchErrorKey.value = null;
    isSearching.value = true;
    try {
      final page = await catalog.search(query: normalized, type: type);
      if (!_acceptSearch(generation, contextKey, catalog)) return;
      searchResults.assignAll(page.items);
      remoteQuota.value = page.quota;
      _searchCursor = page.nextCursor;
    } catch (_) {
      if (_acceptSearch(generation, contextKey, catalog)) {
        searchResults.clear();
        searchErrorKey.value = 'widgets.search_failed';
      }
    } finally {
      if (generation == _searchGeneration) isSearching.value = false;
    }
  }

  Future<void> loadMoreSearchResults() async {
    final cursor = _searchCursor;
    final query = searchQuery.value.trim();
    final catalog = _catalog;
    if (cursor == null ||
        query.isEmpty ||
        catalog == null ||
        isSearching.value) {
      return;
    }
    final generation = ++_searchGeneration;
    final contextKey = catalog.requestContextKey;
    searchErrorKey.value = null;
    isSearching.value = true;
    try {
      final page = await catalog.search(
        query: query,
        type: _searchType,
        cursor: cursor,
      );
      if (!_acceptSearch(generation, contextKey, catalog)) return;
      final seen = searchResults.map((item) => item.id).toSet();
      searchResults.addAll(page.items.where((item) => seen.add(item.id)));
      remoteQuota.value = page.quota;
      _searchCursor = page.nextCursor;
    } catch (_) {
      if (_acceptSearch(generation, contextKey, catalog)) {
        searchErrorKey.value = 'widgets.search_failed';
      }
    } finally {
      if (generation == _searchGeneration) isSearching.value = false;
    }
  }

  Future<void> loadGameFeed({
    GameFeedSort sort = GameFeedSort.recommended,
    bool loadMore = false,
  }) async {
    final catalog = _catalog;
    final loading = gameFeedLoadingFor(sort);
    if (catalog == null || loading.value) return;
    final cursor = loadMore ? _gameFeedCursors[sort] : null;
    if (loadMore && cursor == null) return;
    final generation = (_gameFeedGenerations[sort] ?? 0) + 1;
    _gameFeedGenerations[sort] = generation;
    final contextKey = catalog.requestContextKey;
    loading.value = true;
    if (!loadMore) _loadedGameFeedContexts[sort]!.value = null;
    gameFeedErrorFor(sort).value = null;
    try {
      final page = await catalog.browse(
        type: AppletCatalogType.game,
        sort: sort.catalogSort,
        cursor: cursor,
      );
      if (generation != _gameFeedGenerations[sort] ||
          contextKey != catalog.requestContextKey) {
        return;
      }
      final target = gameFeedItemsFor(sort);
      if (loadMore) {
        final seen = target.map((item) => item.id).toSet();
        target.addAll(page.items.where((item) => seen.add(item.id)));
      } else {
        target.assignAll(page.items);
      }
      _gameFeedCursors[sort] = page.nextCursor;
      _loadedGameFeedContexts[sort]!.value = contextKey;
    } catch (_) {
      if (generation == _gameFeedGenerations[sort] &&
          contextKey == catalog.requestContextKey) {
        if (!loadMore) gameFeedItemsFor(sort).clear();
        gameFeedErrorFor(sort).value = 'widgets.game_feed_failed';
      }
    } finally {
      if (generation == _gameFeedGenerations[sort]) {
        loading.value = false;
      }
    }
  }

  Future<void> refreshAllGameFeeds() async {
    await Future.wait(<Future<void>>[
      loadGameFeed(sort: GameFeedSort.recommended),
      loadGameFeed(sort: GameFeedSort.popular),
    ]);
  }

  Future<bool> recordGameView(AppletCatalogItem item) async {
    final catalog = _catalog;
    if (catalog == null) return false;
    final contextKey = catalog.requestContextKey;
    final engagementKey = _engagementKey(contextKey, item.id);
    final eventId = _pendingViewEventIds.putIfAbsent(
      engagementKey,
      () => _nextGameFeedEventId(item.id, 'view'),
    );
    try {
      await _enqueueEngagement(contextKey, item.id, () async {
        final snapshot = await catalog.recordView(
          item.id,
          eventId: eventId,
          expectedContextKey: contextKey,
        );
        _applyEngagement(snapshot, expectedContextKey: contextKey);
      });
      if (contextKey != catalog.requestContextKey) return false;
      if (_pendingViewEventIds[engagementKey] == eventId) {
        _pendingViewEventIds.remove(engagementKey);
      }
      return true;
    } catch (error, stackTrace) {
      Log.w(
        '[GameFeed] view record failed',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  Future<void> toggleGameLike(AppletCatalogItem item) async {
    final catalog = _catalog;
    if (catalog == null) return;
    final contextKey = catalog.requestContextKey;
    final engagementKey = _engagementKey(contextKey, item.id);
    if (_gameLikeInFlightTokens.containsKey(engagementKey)) return;
    final marker = Object();
    _gameLikeInFlightTokens[engagementKey] = marker;
    gameLikeInFlightIds.add(engagementKey);
    try {
      await _enqueueEngagement(contextKey, item.id, () async {
        final before = _gameById(item.id) ?? item;
        final nextLiked = !before.likedByMe;
        _mutateGame(
          item.id,
          (current) => current.copyWith(
            likedByMe: nextLiked,
            likeCount: (current.likeCount + (nextLiked ? 1 : -1)).clamp(
              0,
              1 << 31,
            ),
          ),
        );
        try {
          final snapshot = await catalog.setLiked(
            item.id,
            nextLiked,
            expectedContextKey: contextKey,
          );
          _applyEngagement(snapshot, expectedContextKey: contextKey);
        } catch (error, stackTrace) {
          if (contextKey == catalog.requestContextKey) {
            _mutateGame(
              item.id,
              (current) => current.copyWith(
                likedByMe: before.likedByMe,
                likeCount: before.likeCount,
              ),
            );
          }
          Log.w('[GameFeed] like failed', error: error, stackTrace: stackTrace);
          rethrow;
        }
      });
    } finally {
      if (identical(_gameLikeInFlightTokens[engagementKey], marker)) {
        _gameLikeInFlightTokens.remove(engagementKey);
        gameLikeInFlightIds.remove(engagementKey);
      }
    }
  }

  Future<bool> loadGameComments(
    AppletCatalogItem item, {
    bool loadMore = false,
  }) async {
    final catalog = _catalog;
    if (catalog == null) return false;
    final cursor = loadMore ? gameFeedCommentsNextCursor.value : null;
    if (loadMore &&
        (gameFeedCommentsItemId.value != item.id ||
            cursor == null ||
            isLoadingGameFeedComments.value ||
            isLoadingMoreGameFeedComments.value)) {
      return false;
    }
    final generation = ++_gameFeedCommentsGeneration;
    final contextKey = catalog.requestContextKey;
    if (!loadMore) {
      isLoadingMoreGameFeedComments.value = false;
      gameFeedComments.clear();
      gameFeedCommentsItemId.value = item.id;
      gameFeedCommentsNextCursor.value = null;
    }
    gameFeedCommentsErrorKey.value = null;
    final loading = loadMore
        ? isLoadingMoreGameFeedComments
        : isLoadingGameFeedComments;
    loading.value = true;
    try {
      final page = await catalog.listComments(
        item.id,
        cursor: cursor,
        expectedContextKey: contextKey,
      );
      if (generation == _gameFeedCommentsGeneration &&
          gameFeedCommentsItemId.value == item.id &&
          contextKey == catalog.requestContextKey) {
        if (loadMore) {
          final seen = gameFeedComments.map((comment) => comment.id).toSet();
          gameFeedComments.addAll(
            page.items.where((comment) => seen.add(comment.id)),
          );
        } else {
          gameFeedComments.assignAll(page.items);
        }
        gameFeedCommentsNextCursor.value = page.nextCursor;
        return true;
      }
      return false;
    } catch (error, stackTrace) {
      Log.w(
        '[GameFeed] comments load failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (generation == _gameFeedCommentsGeneration &&
          gameFeedCommentsItemId.value == item.id &&
          contextKey == catalog.requestContextKey) {
        gameFeedCommentsErrorKey.value = 'game_feed.comments_failed';
      }
      return false;
    } finally {
      if (generation == _gameFeedCommentsGeneration &&
          gameFeedCommentsItemId.value == item.id &&
          contextKey == catalog.requestContextKey) {
        loading.value = false;
      } else if (loadMore) {
        isLoadingMoreGameFeedComments.value = false;
      }
    }
  }

  Future<bool> postGameComment(
    AppletCatalogItem item,
    String text, {
    String? requestId,
    String? parentCommentId,
  }) async {
    final catalog = _catalog;
    if (catalog == null) return false;
    final contextKey = catalog.requestContextKey;
    var accepted = false;
    await _enqueueEngagement(contextKey, item.id, () async {
      final comment = requestId == null
          ? await catalog.postComment(
              item.id,
              text,
              expectedContextKey: contextKey,
            )
          : await catalog.postCommentWithInput(
              item.id,
              text,
              requestId: requestId,
              parentCommentId: parentCommentId,
              expectedContextKey: contextKey,
            );
      if (contextKey != catalog.requestContextKey) return;
      final known =
          gameFeedCommentsItemId.value == item.id &&
          gameFeedComments.any((row) => row.id == comment.id);
      if (gameFeedCommentsItemId.value == item.id) {
        if (!known) gameFeedComments.insert(0, comment);
      }
      if (!known) {
        _mutateGame(item.id, (current) {
          return current.copyWith(commentCount: current.commentCount + 1);
        });
      }
      accepted = true;
    });
    return accepted;
  }

  Future<bool> recordGameShare(AppletCatalogItem item) async {
    final catalog = _catalog;
    if (catalog == null) return false;
    final contextKey = catalog.requestContextKey;
    try {
      await _enqueueEngagement(contextKey, item.id, () async {
        final snapshot = await catalog.recordShare(
          item.id,
          eventId: _nextGameFeedEventId(item.id, 'share'),
          expectedContextKey: contextKey,
        );
        _applyEngagement(snapshot, expectedContextKey: contextKey);
      });
      if (contextKey != catalog.requestContextKey) return false;
      return true;
    } catch (error, stackTrace) {
      Log.w(
        '[GameFeed] share record failed',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  Future<T> _enqueueEngagement<T>(
    String contextKey,
    String itemId,
    Future<T> Function() operation,
  ) {
    final engagementKey = _engagementKey(contextKey, itemId);
    final previous = _engagementTails[engagementKey];
    final start = previous == null
        ? Future<void>.value()
        : previous.then<void>((_) {}, onError: (_, _) {});
    final result = start.then((_) => operation());
    late final Future<void> tail;
    tail = result.then<void>(
      (_) => _clearEngagementTail(engagementKey, tail),
      onError: (_, _) => _clearEngagementTail(engagementKey, tail),
    );
    _engagementTails[engagementKey] = tail;
    return result;
  }

  void _clearEngagementTail(String engagementKey, Future<void> completed) {
    if (identical(_engagementTails[engagementKey], completed)) {
      _engagementTails.remove(engagementKey);
    }
  }

  String get _interactionContextKey =>
      _catalog?.requestContextKey ?? AppletLocalOwnership.currentScopeKey();

  String _engagementKey(String contextKey, String itemId) =>
      '$contextKey|$itemId';

  String _nextGameFeedEventId(String itemId, String kind) {
    final now = DateTime.now().toUtc().microsecondsSinceEpoch;
    return 'game-$kind-$itemId-$now-${_gameFeedEventSequence++}';
  }

  void _applyEngagement(
    AppletEngagementSnapshot snapshot, {
    required String expectedContextKey,
  }) {
    final catalog = _catalog;
    if (catalog == null || catalog.requestContextKey != expectedContextKey) {
      return;
    }
    _mutateGame(
      snapshot.id,
      (current) => current.copyWith(
        viewCount: snapshot.viewCount,
        likeCount: snapshot.likeCount,
        shareCount: snapshot.shareCount,
        commentCount: snapshot.commentCount,
        likedByMe: snapshot.likedByMe,
      ),
    );
  }

  void _mutateGame(
    String itemId,
    AppletCatalogItem Function(AppletCatalogItem) update,
  ) {
    for (final feed in <RxList<AppletCatalogItem>>[
      recommendedGameFeedItems,
      popularGameFeedItems,
      searchResults,
    ]) {
      final index = feed.indexWhere((item) => item.id == itemId);
      if (index >= 0) feed[index] = update(feed[index]);
    }
  }

  AppletCatalogItem? _gameById(String itemId) {
    for (final feed in <RxList<AppletCatalogItem>>[
      recommendedGameFeedItems,
      popularGameFeedItems,
      searchResults,
    ]) {
      final index = feed.indexWhere((item) => item.id == itemId);
      if (index >= 0) return feed[index];
    }
    return null;
  }

  void clearSearch() {
    _searchGeneration++;
    searchResults.clear();
    searchErrorKey.value = null;
    searchQuery.value = '';
    remoteQuota.value = null;
    _searchCursor = null;
    _searchType = null;
    isSearching.value = false;
  }

  bool _acceptSearch(
    int generation,
    String contextKey,
    AppletCatalogService catalog,
  ) =>
      generation == _searchGeneration &&
      contextKey == catalog.requestContextKey;

  void _adoptLatestSearch() {
    final catalog = _catalog;
    final page = catalog?.latestPage.value;
    if (catalog == null ||
        page == null ||
        catalog.latestContextKey.value != catalog.requestContextKey) {
      return;
    }
    searchQuery.value = catalog.latestQuery.value;
    _searchType = catalog.latestType.value;
    searchResults.assignAll(page.items);
    remoteQuota.value = page.quota;
    _searchCursor = page.nextCursor;
  }

  Future<void> dismiss(AgentWidget w) async {
    final id = w.id;
    if (id == null) return;
    final expectedScopeKey = AppletLocalOwnership.currentScopeKey();
    if (!AppletLocalOwnership.isVisible(w, scopeKey: expectedScopeKey)) {
      throw StateError('Applet belongs to another account or environment');
    }
    if (w.spec['rendering'] == 'projectBundle' ||
        w.spec.containsKey('bundleReference')) {
      throw StateError('project_bundle_requires_owner_management');
    }
    final cloud = AgentGameCloudMetadata.fromSpec(w.spec['cloud']);
    final requiresRemoteDelete =
        expectedScopeKey != AppletLocalOwnership.deviceLegacyScope ||
        cloud.gameId.isNotEmpty ||
        cloud.scopeKey.isNotEmpty ||
        w.spec['cloudDelete'] != null;
    if (requiresRemoteDelete &&
        !appServices.isRegistered<AgentGameCloudService>()) {
      throw StateError('Applet cloud service is unavailable');
    }
    if (requiresRemoteDelete) {
      await appServices.find<AgentGameCloudService>().deleteRemote(w);
    }
    await _db.deleteWidgetValidated(
      id,
      validate: (current) =>
          AppletLocalOwnership.currentScopeKey() == expectedScopeKey &&
          AppletLocalOwnership.isVisible(current, scopeKey: expectedScopeKey),
    );
    widgets.removeWhere((x) => x.id == id);
  }

  Future<void> markSeen(AgentWidget w) async {
    final id = w.id;
    if (id == null) return;
    final expectedScopeKey = AppletLocalOwnership.currentScopeKey();
    if (!AppletLocalOwnership.isVisible(w, scopeKey: expectedScopeKey)) return;
    await _db.markWidgetSeenValidated(
      id,
      validate: (current) =>
          AppletLocalOwnership.currentScopeKey() == expectedScopeKey &&
          AppletLocalOwnership.isVisible(current, scopeKey: expectedScopeKey),
    );
    w.seen = true;
    widgets.refresh();
  }
}

import 'dart:async';
import 'package:maaso/src/core/services/avatar_config_service.dart';
import 'package:maaso/src/core/services/avatar_selection_contract.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';

import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary.dart';
import 'package:maaso/src/features/store/data/asset_store_service.dart';
import 'package:maaso/src/features/store/presentation/store_asset_detail.dart';
import 'package:maaso/src/features/store/presentation/store_bundled_avatar_detail.dart';

/// One active asset type. The legacy reader is mounted only when the new route
/// is absent, so old deployments remain usable without masking server failures.
class StoreAssetCatalog extends StatefulWidget {
  const StoreAssetCatalog({
    super.key,
    required this.type,
    required this.header,
    required this.legacyBuilder,
    required this.canContinue,
    this.service,
    this.avatars,
  }) : assert(type == 'model' || type == 'skill');
  final String type;
  final Widget header;
  final WidgetBuilder legacyBuilder;
  final bool Function() canContinue;
  final AssetStoreService? service;
  final AvatarConfigService? avatars;
  @override
  State<StoreAssetCatalog> createState() => StoreAssetCatalogState();
}

class StoreAssetCatalogState extends State<StoreAssetCatalog> {
  late final AssetStoreService _service = widget.service ?? AssetStoreService();
  late final String _scope = _service.scopeKey;
  late final AvatarConfigService? _avatars =
      widget.avatars ?? appServices.maybeFind<AvatarConfigService>();
  final _search = TextEditingController();
  final _scroll = ScrollController();
  List<StoreAsset> _items = const [];
  String _sort = 'popular';
  String? _cursor;
  Object? _error;
  bool _loading = false;
  bool _legacy = false;
  bool _started = false;
  bool _detailOpen = false;
  int _generation = 0;
  bool get ready =>
      mounted &&
      widget.canContinue() &&
      _service.scopeKey == _scope &&
      !_legacy &&
      !_detailOpen;

  List<AvatarOption> get _bundledModels {
    if (widget.type != 'model' ||
        !widget.canContinue() ||
        _service.scopeKey != _scope) {
      return const [];
    }
    final query = _search.text.trim().toLowerCase();
    return [
      for (final option in _avatars?.catalog ?? <AvatarOption>[])
        if (option.remoteModelId == null &&
            AvatarConfigService.builtInCatalog.any(
              (bundled) =>
                  bundled.id == option.id &&
                  bundled.modelUrl == option.modelUrl,
            ) &&
            (query.isEmpty ||
                (option.id == 'agent'
                        ? 'joy agent female 女性 女生 女角色'
                        : option.name.toLowerCase())
                    .contains(query)))
          option,
    ];
  }

  String _bundledVersion(AvatarOption option) =>
      'bundled:$avatarBuiltinCatalogVersion:${option.id}';

  List<Map<String, Object?>> get visibleAssets => !ready
      ? const []
      : [
          for (final option in _bundledModels)
            {
              'id': 'builtin:${option.id}',
              'type': 'model',
              'versionId': _bundledVersion(option),
              'title': bundledAvatarStoreName(option),
              'source': 'builtin',
              'selected': _avatars?.selectedId.value == option.id,
            },
          for (final item in _items)
            {
              'id': item.id,
              'type': item.type,
              'versionId': item.versionId,
              'title': item.title,
              'metric': item.popularity['metric'],
              'count': item.popularity['value'],
              if (item.type == 'model')
                'selected': storeAssetModelSelected(item, _avatars),
            },
        ];
  Future<void> search(
    String query,
    String sort,
    bool Function() authority,
  ) async {
    if (!ready ||
        query.length > 160 ||
        !const {'popular', 'recent'}.contains(sort)) {
      return;
    }
    _search.text = query;
    _sort = sort;
    await _load(authority: authority);
  }

  Future<void> open(
    String id,
    String versionId, {
    bool Function()? authority,
  }) async {
    if (!ready || authority?.call() == false) return;
    final previousSelection = _avatars?.selectedId.value;
    final bundled = _bundledModels.where(
      (option) =>
          'builtin:${option.id}' == id && _bundledVersion(option) == versionId,
    );
    if (bundled.length == 1 && _avatars != null) {
      _detailOpen = true;
      try {
        await showBundledAvatarStoreDetail(
          context,
          bundled.single,
          _avatars,
          canContinue: () =>
              mounted && widget.canContinue() && _scope == _service.scopeKey,
        );
      } finally {
        await _afterDetail(previousSelection);
      }
      return;
    }
    final items = _items.where(
      (item) => item.id == id && item.versionId == versionId,
    );
    if (items.length != 1) return;
    _detailOpen = true;
    try {
      await showStoreAssetDetail(
        context,
        items.single,
        _service,
        avatars: _avatars,
        canContinue: () =>
            mounted && widget.canContinue() && _scope == _service.scopeKey,
      );
    } finally {
      await _afterDetail(previousSelection);
    }
  }

  Future<void> _afterDetail(String? previousSelection) async {
    _detailOpen = false;
    if (ready &&
        widget.type == 'model' &&
        previousSelection != _avatars?.selectedId.value) {
      // Refresh aggregate popularity from the server after a proven switch.
      // Current selection is rendered from AvatarConfig immediately, even if
      // this read fails or returns an older ownership snapshot.
      await _load(preserveItems: true);
    }
  }

  @override
  void initState() {
    super.initState();
    appServices
        .maybeFind<AccountStorageScopeService>()
        ?.activeMount
        ?.whenInvalidated
        .then((_) {
          if (mounted) {
            setState(() {
              ++_generation;
              _items = const [];
              _cursor = null;
              _loading = false;
              _error = const AssetStoreException('asset_store_scope_changed');
            });
          }
        });
  }

  @override
  void didUpdateWidget(covariant StoreAssetCatalog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.type != oldWidget.type) {
      _legacy = false;
      _search.clear();
      _sort = 'popular';
      _cursor = null;
      _items = const [];
      unawaited(_load());
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      unawaited(_load());
    }
  }

  Future<void> _load({
    bool more = false,
    bool preserveItems = false,
    bool Function()? authority,
  }) async {
    if (!mounted || !widget.canContinue() || _service.scopeKey != _scope) {
      return;
    }
    if (more && (_loading || _cursor == null)) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      if (!more) {
        if (!preserveItems) _items = const [];
        _cursor = null;
      }
    });
    try {
      final page = await _service.list(
        type: widget.type,
        query: _search.text.trim(),
        sort: _sort,
        cursor: more ? _cursor : null,
        locale: storeAssetLocale(context),
        platform: storeAssetPlatform,
      );
      if (!ready || generation != _generation || authority?.call() == false) {
        return;
      }
      setState(() {
        final visible = page.items.where((item) => item.type == widget.type);
        _items = more ? [..._items, ...visible] : visible.toList();
        _cursor = page.nextCursor;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        if (!more && error is AssetStoreException && error.isUnsupported) {
          _legacy = true;
        } else {
          _error = error;
        }
      });
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  void dispose() {
    ++_generation;
    _search.dispose();
    _scroll.dispose();
    if (widget.service == null) _service.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_legacy) return widget.legacyBuilder(context);
    return AppSecondaryScaffold(
      header: widget.header,
      contentMaxWidth: 640,
      body: AppReactiveBuilder(() {
        final bundled = _bundledModels;
        final selectedId = _avatars?.selectedId.value;
        return RefreshIndicator(
          onRefresh: _load,
          child: LayoutBuilder(
            builder: (context, size) {
              final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
              final columns =
                  widget.type == 'model' &&
                      size.maxWidth >= 360 &&
                      textScale <= 1.4
                  ? 2
                  : 1;
              final cards = <Widget>[
                for (final option in bundled) _bundledCard(option, selectedId),
                for (var index = 0; index < _items.length; index++)
                  _card(
                    _items[index],
                    first: index == 0,
                    last: index == _items.length - 1,
                  ),
              ];
              return ListView(
                controller: _scroll,
                padding: EdgeInsets.fromLTRB(
                  size.maxWidth < 360 ? 16 : 20,
                  8,
                  size.maxWidth < 360 ? 16 : 20,
                  MediaQuery.paddingOf(context).bottom + 24,
                ),
                children: [
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _search,
                    builder: (context, value, _) => AppGlassField(
                      key: const ValueKey('asset-store-search'),
                      controller: _search,
                      hintText:
                          (widget.type == 'model'
                                  ? 'avatar_store.search'
                                  : 'skill_store.search_hint')
                              .tr,
                      prefixIcon: Icons.search,
                      suffix: value.text.isEmpty
                          ? null
                          : IconButton(
                              key: const ValueKey('asset-store-clear-search'),
                              tooltip: 'skill_store.clear_search'.tr,
                              constraints: const BoxConstraints(
                                minWidth: 48,
                                minHeight: 48,
                              ),
                              onPressed: () {
                                _search.clear();
                                unawaited(_load());
                              },
                              icon: const Icon(Icons.close_rounded, size: 18),
                            ),
                      maxLength: 160,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _load(),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      Text(
                        (widget.type == 'model'
                                ? 'avatar_store.section.all_models'
                                : 'store_hub.discover_skills')
                            .tr,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      PopupMenuButton<String>(
                        key: const ValueKey('asset-store-sort'),
                        initialValue: _sort,
                        tooltip: 'skill_store.sort_label'.tr,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                        itemBuilder: (_) => [
                          for (final sort in ['popular', 'recent'])
                            PopupMenuItem(
                              value: sort,
                              child: Text('asset_store.sort.$sort'.tr),
                            ),
                        ],
                        onSelected: (sort) {
                          _sort = sort;
                          unawaited(_load());
                        },
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 48),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(
                                  child: Text(
                                    'asset_store.sort.$_sort'.tr,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                const Icon(Icons.expand_more_rounded, size: 18),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_error != null) ...[
                    Text(storeAssetError(_error!)),
                    TextButton(
                      onPressed: () => _load(),
                      child: Text('common.retry'.tr),
                    ),
                  ],
                  if (!_loading && cards.isEmpty && _error == null)
                    Text('asset_store.empty'.tr),
                  for (var offset = 0; offset < cards.length; offset += columns)
                    Padding(
                      padding: EdgeInsets.only(
                        bottom: widget.type == 'model' ? 12 : 0,
                      ),
                      child: IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (
                              var index = offset;
                              index < offset + columns;
                              index++
                            ) ...[
                              if (index > offset) const SizedBox(width: 12),
                              Expanded(
                                child: index < cards.length
                                    ? cards[index]
                                    : const SizedBox.shrink(),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  if (_loading)
                    const Center(child: CircularProgressIndicator()),
                  if (!_loading && _cursor != null)
                    TextButton(
                      onPressed: () => _load(more: true),
                      child: Text('asset_store.more'.tr),
                    ),
                  if (widget.type == 'model') ...[
                    const SizedBox(height: 8),
                    Text(
                      'store_hub.bundled_actions_note'.tr,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
              );
            },
          ),
        );
      }),
    );
  }

  Widget _bundledCard(AvatarOption option, String? selectedId) => _modelTile(
    key: ValueKey('asset-card-builtin:${option.id}'),
    title: bundledAvatarStoreName(option),
    source: 'avatar_store.source.maaso_original'.tr,
    selected: selectedId == option.id,
    artwork: option.previewAssetPath == null
        ? const Icon(Icons.person_outline, size: 48)
        : Image.asset(
            option.previewAssetPath!,
            fit: BoxFit.contain,
            alignment: Alignment.center,
          ),
    onOpen: () =>
        unawaited(open('builtin:${option.id}', _bundledVersion(option))),
  );

  Widget _card(StoreAsset item, {bool first = true, bool last = true}) {
    void openItem() => unawaited(open(item.id, item.versionId));
    if (item.type == 'model') {
      return _modelTile(
        key: ValueKey('asset-card-${item.key}'),
        title: item.title,
        source: item.author?['name'] as String? ?? 'store_hub.models'.tr,
        selected: storeAssetModelSelected(item, _avatars),
        artwork: _artwork(item),
        onOpen: openItem,
      );
    }
    final installed = item.ownership['installed'] == true;
    final glass = MaasoGlassTheme.of(context);
    return Material(
      key: ValueKey('asset-card-${item.key}'),
      color: glass.muted,
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(first ? 24 : 0),
        bottom: Radius.circular(last ? 24 : 0),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: openItem,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: glass.surface,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(
                      Icons.extension_outlined,
                      size: 24,
                      color: glass.accentText,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.title,
                          style: TextStyle(
                            color: glass.foregroundPrimary,
                            fontSize: 15,
                            height: 24 / 15,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          item.summary,
                          style: TextStyle(
                            color: glass.foregroundSecondary,
                            fontSize: 13,
                            height: 20 / 13,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          [
                            item.author?['name'] as String? ??
                                'store_hub.skills'.tr,
                            if (installed) 'asset_store.installed'.tr,
                          ].join(' · '),
                          style: TextStyle(
                            color: installed
                                ? glass.accentText
                                : glass.foregroundSecondary,
                            fontSize: 13,
                            height: 20 / 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Icon(
                      Icons.chevron_right_rounded,
                      color: glass.foregroundSecondary,
                      size: 18,
                    ),
                  ),
                ],
              ),
            ),
            if (!last)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Divider(height: 1, thickness: .5, color: glass.divider),
              ),
          ],
        ),
      ),
    );
  }

  Widget _artwork(StoreAsset item) {
    final local = storeAssetLocalArtwork(item);
    final fit = item.type == 'model' ? BoxFit.contain : BoxFit.cover;
    final alignment = item.type == 'model'
        ? Alignment.center
        : Alignment.topCenter;
    if (local != null) {
      return Image.asset(local, fit: fit, alignment: alignment);
    }
    if (storeAssetCoverUrl(item) case final coverUrl?) {
      return Image.network(
        coverUrl,
        fit: fit,
        alignment: alignment,
        errorBuilder: (_, _, _) => _icon(item),
      );
    }
    return _icon(item);
  }

  Widget _icon(StoreAsset item) => Center(
    child: Icon(
      item.type == 'model' ? Icons.person_outline : Icons.extension_outlined,
      size: 48,
    ),
  );

  Widget _modelTile({
    required Key key,
    required String title,
    required String source,
    required bool selected,
    required Widget artwork,
    required VoidCallback onOpen,
  }) => Material(
    key: key,
    color: MaasoGlassTheme.of(context).muted,
    borderRadius: BorderRadius.circular(24),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onOpen,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
            child: SizedBox(
              height: 232,
              width: double.infinity,
              child: artwork,
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (selected) ...[
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      key: const ValueKey('model-selected-status'),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: MaasoGlassTheme.of(context).surface,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.check_rounded,
                            size: 14,
                            color: MaasoGlassTheme.of(context).accentText,
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              'asset_store.selected'.tr,
                              style: TextStyle(
                                color: MaasoGlassTheme.of(context).accentText,
                                fontSize: 13,
                                height: 20 / 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                ] else
                  SizedBox(
                    height:
                        MediaQuery.textScalerOf(context).scale(13) * 20 / 13 +
                        16,
                  ),
                Text(
                  title,
                  style: TextStyle(
                    color: MaasoGlassTheme.of(context).foregroundPrimary,
                    fontSize: 22,
                    height: 28 / 22,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  source,
                  style: TextStyle(
                    color: MaasoGlassTheme.of(context).foregroundSecondary,
                    fontSize: 13,
                    height: 20 / 13,
                  ),
                ),
                const SizedBox(height: 12),
                AppGlassButton(
                  key: ValueKey('select-${key.toString()}'),
                  label: 'skill_store.view_details'.tr,
                  fullWidth: true,
                  primary: !selected,
                  foregroundColor: selected
                      ? MaasoGlassTheme.of(context).accentText
                      : null,
                  onPressed: onOpen,
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

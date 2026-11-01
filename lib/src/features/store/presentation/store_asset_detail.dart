import 'dart:async';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/avatar_config_service.dart';
import 'package:maaso/src/core/services/avatar_selection_contract.dart';
import 'package:maaso/src/core/services/avatar_model_catalog_service.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/features/avatars/application/avatar_model_store_controller.dart';
import 'package:maaso/src/features/skills/data/skill_marketplace_service.dart';
import 'package:maaso/src/features/skills/presentation/skill_store_page.dart';
import 'package:maaso/src/features/store/data/asset_store_service.dart';
import 'package:maaso/src/features/store/presentation/store_asset_preview.dart';

String get storeAssetPlatform => switch (defaultTargetPlatform) {
  TargetPlatform.iOS => 'ios',
  TargetPlatform.android => 'android',
  _ => '',
};
String storeAssetLocale(BuildContext context) =>
    Localizations.localeOf(context).languageCode == 'zh' ? 'zh' : 'en';

/// Local artwork is accepted only through the reviewed native model parser and
/// its strict builtin registry. Unknown model keys never receive builtin art.
String? storeAssetLocalArtwork(StoreAsset item) {
  if (item.type != 'model' || item.sourceRef['model'] is! Map) return null;
  try {
    return ApprovedAvatarModel.fromJson(
      Map<String, dynamic>.from(item.sourceRef['model'] as Map),
      platform: storeAssetPlatform,
    ).toAvatarOption().previewAssetPath;
  } catch (_) {
    return null;
  }
}

/// The model descriptor owns its cover across the workshop, store and detail.
/// Legacy catalog rows may have only coverUrl; Skill artwork stays unchanged.
String? storeAssetCoverUrl(StoreAsset item) {
  String? value;
  final rawModel = item.sourceRef['model'];
  if (item.type == 'model' &&
      rawModel is Map &&
      rawModel['previewImageUrl']?.toString().trim().isNotEmpty == true) {
    try {
      value = ApprovedAvatarModel.fromJson(
        Map<String, dynamic>.from(rawModel),
        platform: storeAssetPlatform,
      ).previewImageUrl;
    } catch (_) {
      return null;
    }
  } else {
    value = item.coverUrl;
  }
  final uri = Uri.tryParse(value?.trim() ?? '');
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri.toString();
}

String storeAssetMetric(StoreAsset item) =>
    'asset_store.metric.${item.popularity['metric']}'.trParams({
      'count': '${item.popularity['value']}',
    });

/// A loaded model's current selection belongs to the avatar authority, not a
/// possibly stale store-list or detail ownership snapshot.
bool storeAssetModelSelected(StoreAsset item, AvatarConfigService? avatars) =>
    avatars == null
    ? item.ownership['selected'] == true
    : '${avatars.selected.remoteModelId}' == item.id;

String storeAssetError(Object error) =>
    (error is AssetStoreException && error.isConflict ||
                error is AvatarSelectionValidationException &&
                    error.code == 'AVATAR_ASSET_VERSION_CHANGED'
            ? 'asset_store.version_changed'
            : 'asset_store.unavailable')
        .tr;

/// A modal on the existing store route, with no hidden execution API.
Future<void> showStoreAssetDetail(
  BuildContext context,
  StoreAsset item,
  AssetStoreService service, {
  required bool Function() canContinue,
  AvatarConfigService? avatars,
}) async {
  if (!canContinue()) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _AssetDetail(
      item: item,
      service: service,
      canContinue: canContinue,
      avatars: avatars ?? appServices.maybeFind<AvatarConfigService>(),
    ),
  );
}

class _AssetDetail extends StatefulWidget {
  const _AssetDetail({
    required this.item,
    required this.service,
    required this.canContinue,
    required this.avatars,
  });
  final StoreAsset item;
  final AssetStoreService service;
  final bool Function() canContinue;
  final AvatarConfigService? avatars;
  @override
  State<_AssetDetail> createState() => _AssetDetailState();
}

class _AssetDetailState extends State<_AssetDetail> {
  StoreAsset? _detail;
  Object? _error;
  bool _busy = false;
  bool _loaded = false;
  bool _preview = false;
  late final String _scope = widget.service.scopeKey;
  bool get _current =>
      mounted && _scope == widget.service.scopeKey && widget.canContinue();
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
              _detail = null;
              _preview = false;
              _error = const AssetStoreException('asset_store_scope_changed');
            });
          }
        });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    try {
      final detail = await widget.service.detail(
        widget.item,
        locale: storeAssetLocale(context),
        platform: storeAssetPlatform,
      );
      if (_current) setState(() => _detail = detail);
    } catch (error) {
      if (_current) setState(() => _error = error);
    }
  }

  Future<void> _execute() async {
    final item = _detail;
    if (!_current || _busy || item == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Re-read the exact version before opening consequential confirmation.
      await widget.service.detail(
        item,
        locale: storeAssetLocale(context),
        platform: storeAssetPlatform,
      );
      if (!_current || !mounted) return;
      final accepted = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(item.title),
          content: Text(
            (item.type == 'skill'
                    ? 'asset_store.confirm_install'
                    : 'asset_store.confirm_select')
                .tr,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: Text('common.cancel'.tr),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: Text('common.confirm'.tr),
            ),
          ],
        ),
      );
      if (accepted != true || !_current) return;
      if (item.type == 'skill') {
        final skill = await appServices
            .find<SkillMarketplaceService>()
            .getSkill(item.versionId);
        if (!_current) return;
        if ('${skill.skillVersionId}' != item.versionId ||
            skill.manifestDigest != item.sourceRef['manifestDigest']) {
          throw const AssetStoreException(
            'asset_store_version_changed',
            statusCode: 409,
          );
        }
        if (!mounted) return;
        await installStoreAssetSkill(
          context,
          skill,
          canContinue: () => _current,
        );
      } else if (item.type == 'model') {
        final controller = AvatarModelStoreController();
        await controller.refreshFreeModels();
        if (!_current) return;
        final candidates = controller.reviewedModels.where(
          (model) => '${model.id}' == item.id,
        );
        if (candidates.length != 1 || !candidates.single.isLoadableOnDevice) {
          throw const AssetStoreException('asset_store_unavailable');
        }
        await controller.select(
          candidates.single.toAvatarOption(),
          expectedAssetVersionDigest: item.versionId,
        );
      }
      if (_current) await _load();
    } catch (error) {
      if (_current) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = _detail;
    final glass = MaasoGlassTheme.of(context);
    return FractionallySizedBox(
      heightFactor: .9,
      child: AppGlassSheet(
        child: ListView(
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.item.title,
                    style: TextStyle(
                      color: glass.foregroundPrimary,
                      fontSize: 28,
                      height: 36 / 28,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'common.close'.tr,
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(storeAssetError(_error!)),
              ),
            if (item == null && _error == null)
              const Center(child: CircularProgressIndicator()),
            if (item != null) ...[
              const SizedBox(height: 16),
              Container(
                key: const ValueKey('asset-detail-frost-artwork'),
                decoration: BoxDecoration(
                  color: glass.muted,
                  borderRadius: BorderRadius.circular(24),
                ),
                padding: const EdgeInsets.all(16),
                child: switch ((
                  storeAssetLocalArtwork(item),
                  storeAssetCoverUrl(item),
                )) {
                  (final artwork?, _) => Image.asset(
                    artwork,
                    height: 300,
                    fit: BoxFit.contain,
                  ),
                  (_, final coverUrl?) => Image.network(
                    coverUrl,
                    height: item.type == 'model' ? 300 : 160,
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => Icon(
                      item.type == 'model'
                          ? Icons.person_outline
                          : Icons.extension_outlined,
                      size: 48,
                      color: glass.accentText,
                    ),
                  ),
                  _ => Padding(
                    padding: const EdgeInsets.all(32),
                    child: Icon(
                      item.type == 'model'
                          ? Icons.person_outline
                          : Icons.extension_outlined,
                      size: 48,
                      color: glass.accentText,
                    ),
                  ),
                },
              ),
              const SizedBox(height: 24),
              Text(
                item.summary,
                style: TextStyle(
                  color: glass.foregroundSecondary,
                  fontSize: 15,
                  height: 24 / 15,
                ),
              ),
              const SizedBox(height: 16),
              Container(
                decoration: BoxDecoration(
                  color: glass.muted,
                  borderRadius: BorderRadius.circular(24),
                ),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      storeAssetMetric(item),
                      style: TextStyle(
                        color: glass.foregroundPrimary,
                        fontSize: 13,
                        height: 20 / 13,
                      ),
                    ),
                    if (item.author case final author?) ...[
                      const SizedBox(height: 8),
                      Text(
                        author['name'] as String? ?? '',
                        style: TextStyle(
                          color: glass.foregroundSecondary,
                          fontSize: 13,
                          height: 20 / 13,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 24),
              if (_preview)
                StoreAssetPreview(
                  item: item,
                  service: widget.service,
                  canContinue: () => _current,
                )
              else if (item.preview['state'] == 'available')
                AppGlassButton(
                  key: const ValueKey('asset-preview'),
                  label: 'asset_store.preview'.tr,
                  icon: Icons.play_arrow,
                  onPressed: () => setState(() => _preview = true),
                )
              else
                Text('asset_store.preview_unavailable'.tr),
              if (item.examples.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  'asset_store.examples'.tr,
                  style: TextStyle(
                    color: glass.foregroundSecondary,
                    fontSize: 13,
                    height: 20 / 13,
                  ),
                ),
                for (final example in item.examples)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Container(
                      decoration: BoxDecoration(
                        color: glass.muted,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      padding: const EdgeInsets.all(16),
                      child: SelectableText(
                        example,
                        style: TextStyle(
                          color: glass.foregroundPrimary,
                          fontSize: 15,
                          height: 24 / 15,
                        ),
                      ),
                    ),
                  ),
              ],
              const SizedBox(height: 16),
              AppReactiveBuilder(() {
                final installed =
                    item.type == 'skill' && item.ownership['installed'] == true;
                final selected =
                    item.type == 'model' &&
                    storeAssetModelSelected(item, widget.avatars);
                return AppGlassButton(
                  key: const ValueKey('asset-execute'),
                  fullWidth: true,
                  label:
                      (_busy
                              ? 'asset_store.working'
                              : item.type == 'skill'
                              ? installed
                                    ? 'asset_store.installed'
                                    : 'asset_store.install'
                              : selected
                              ? 'asset_store.selected'
                              : 'asset_store.select')
                          .tr,
                  onPressed: _busy || installed || selected ? null : _execute,
                );
              }),
            ],
          ],
        ),
      ),
    );
  }
}

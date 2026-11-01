import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:maaso/src/features/avatars/application/avatar_model_store_controller.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_frost_tokens.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary.dart';
import 'package:maaso/src/core/services/avatar_config_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/services/avatar_model_catalog_service.dart';
import 'package:maaso/src/core/services/avatar_model_upload_cover.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_capability_profile.dart';
import 'package:maaso/src/features/store/presentation/store_bundled_avatar_detail.dart';

/// Reviewed model selection and the account-scoped model workshop.
class AvatarsPage extends StatefulWidget {
  const AvatarsPage({
    super.key,
    this.controller,
    this.sectionNavigation,
    this.header,
    this.ownedOnly = false,
    this.pickModelFile,
    this.pickCoverFile,
  });

  final Widget? sectionNavigation;
  final Widget? header;
  final bool ownedOnly;

  final AvatarModelStoreController? controller;
  @visibleForTesting
  final Future<PlatformFile?> Function()? pickModelFile;
  @visibleForTesting
  final Future<PlatformFile?> Function()? pickCoverFile;

  @override
  State<AvatarsPage> createState() => _AvatarsPageState();
}

class _AvatarsPageState extends State<AvatarsPage> {
  late final AvatarModelStoreController _store =
      widget.controller ?? AvatarModelStoreController();
  late final AvatarConfigService _avatars = _store.avatars;
  AppCapabilitySnapshotService? _capabilitySnapshots;
  final _search = TextEditingController();
  AccountStorageScopeService? _accountScopes;
  AccountStorageScopeMount? _mount;
  bool _detailOpen = false;

  bool get _accountCurrent =>
      identical(
        _accountScopes,
        appServices.maybeFind<AccountStorageScopeService>(),
      ) &&
      identical(_mount, _accountScopes?.activeMount) &&
      (_accountScopes == null || _mount != null);

  @override
  void initState() {
    super.initState();
    _accountScopes = appServices.maybeFind<AccountStorageScopeService>();
    _mount = _accountScopes?.activeMount;
    _mount?.whenInvalidated.then((_) {
      if (mounted) setState(() {});
    });
    _capabilitySnapshots = _avatars.capabilitySnapshots
      ?..addListener(_handleCapabilityChange);
    if (!widget.ownedOnly) {
      _store.refreshFreeModels();
    } else {
      _store.load();
    }
  }

  void _handleCapabilityChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _search.dispose();
    if (widget.controller == null) _store.closeLifecycle();
    _capabilitySnapshots?.removeListener(_handleCapabilityChange);
    super.dispose();
  }

  Future<void> _showModelDetail(AvatarOption option) async {
    if (_detailOpen || !_accountCurrent) return;
    final pageRoute = ModalRoute.of(context);
    bool authority() =>
        mounted &&
        _accountCurrent &&
        (pageRoute?.isActive ?? true) &&
        _avatars.catalog.any((candidate) => identical(candidate, option));
    if (!authority()) return;
    _detailOpen = true;
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => _ModelDetailSheet(
          option: option,
          avatars: _avatars,
          invalidated: _mount?.whenInvalidated,
          authority: authority,
          onSelect: () => _select(option, authority),
        ),
      );
    } finally {
      _detailOpen = false;
    }
  }

  Future<bool> _select(AvatarOption option, bool Function() authority) async {
    if (!authority() || !_accountCurrent || !_avatars.canSelectOption(option)) {
      AppGlassNotice.show(
        title: 'avatar_store.notice.model_select_failed.title'.tr,
        message: 'common.action_unavailable'.tr,
        icon: Icons.block_rounded,
      );
      return false;
    }
    try {
      await _store.select(option);
      if (!mounted || !authority() || !_accountCurrent) return false;
      AppGlassNotice.show(
        title: 'avatar_store.notice.model_selected.title'.tr,
        message: option.remoteModelId == null
            ? 'avatar_store.notice.model_selected.local'.trParams({
                'name': bundledAvatarStoreName(option),
              })
            : 'avatar_store.notice.model_selected.remote'.trParams({
                'name': bundledAvatarStoreName(option),
              }),
        icon: Icons.check_circle_rounded,
      );
      return true;
    } catch (exception, stackTrace) {
      Log.e(
        '🎭 [AvatarSwitch] model store selection failed '
        'option=${option.id} remoteModelId=${option.remoteModelId ?? '-'}',
        error: exception,
        stackTrace: stackTrace,
      );
      if (!mounted || !authority() || !_accountCurrent) return false;
      AppGlassNotice.show(
        title: 'avatar_store.notice.model_select_failed.title'.tr,
        message: 'avatar_store.notice.model_select_failed.message'.tr,
        icon: Icons.error_outline_rounded,
      );
      return false;
    }
  }

  Future<void> _pickAndUpload() async {
    if (!_accountCurrent) return;
    try {
      final upload = await _store.pickAndUpload(
        widget.pickModelFile ??
            () => FilePicker.pickFile(
              type: FileType.custom,
              allowedExtensions: const ['vrm'],
            ),
        pickCover: () async {
          if (!mounted || !_accountCurrent) return null;
          return widget.pickCoverFile != null
              ? widget.pickCoverFile!()
              : FilePicker.pickFile(
                  type: FileType.custom,
                  allowedExtensions: const ['png', 'jpg', 'jpeg'],
                );
        },
        confirm: _confirmUpload,
      );
      if (upload == null || !mounted || !_accountCurrent) return;
      AppGlassNotice.show(
        title: 'avatar_store.notice.uploaded.title'.tr,
        message: 'avatar_store.notice.uploaded.message'.tr,
        icon: Icons.upload_file_rounded,
      );
    } catch (exception, stackTrace) {
      Log.e(
        '🎭 [AvatarUpload] model upload did not start',
        error: exception,
        stackTrace: stackTrace,
      );
      if (!mounted || !_accountCurrent) return;
      AppGlassNotice.show(
        title: 'avatar_store.notice.upload_failed.title'.tr,
        message: exception is AvatarUploadCoverException
            ? exception.messageKey.tr
            : 'avatar_store.notice.upload_failed.message'.tr,
        icon: Icons.error_outline_rounded,
      );
    }
  }

  Future<bool> _confirmUpload(String name, AvatarModelUploadCover cover) async {
    if (!mounted ||
        !_accountCurrent ||
        !(ModalRoute.of(context)?.isCurrent ?? true)) {
      return false;
    }
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        key: const ValueKey<String>('model-upload-confirmation'),
        scrollable: true,
        title: Text(name),
        content: SizedBox(
          width: 280,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('avatar_store.cover.guidance'.tr),
              const SizedBox(height: 12),
              SizedBox(
                height: 300,
                width: double.infinity,
                child: Image.memory(
                  cover.bytes,
                  cacheWidth: 768,
                  key: const ValueKey<String>('model-upload-cover-preview'),
                  fit: BoxFit.contain,
                  alignment: Alignment.center,
                  semanticLabel: name,
                ),
              ),
              const SizedBox(height: 12),
              Text(cover.fileName),
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey<String>('model-upload-cancel'),
            onPressed: () => Navigator.pop(dialog, false),
            child: Text('common.cancel'.tr),
          ),
          FilledButton(
            key: const ValueKey<String>('model-upload-confirm'),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text('avatar_store.cover.confirm'.tr),
          ),
        ],
      ),
    );
    return accepted == true && mounted && _accountCurrent;
  }

  @override
  Widget build(BuildContext context) {
    return AppSecondaryScaffold(
      contentMaxWidth: widget.ownedOnly ? null : 640,
      header:
          widget.header ??
          AppSecondaryHeader(
            title:
                (widget.ownedOnly ? 'store_hub.workshop' : 'avatar_store.title')
                    .tr,
            subtitle: 'avatar_store.subtitle.models'.tr,
            onBack: appNavigation.pop,
          ),
      body: AppReactiveBuilder(() {
        final current = _avatars.selected;
        final switching = _avatars.isSwitching.value;
        final uploads = List<OwnAvatarUpload>.of(_store.myUploads);
        final ownedModelIds = uploads
            .where((upload) => upload.status == AvatarUploadStatus.approved)
            .map((upload) => upload.modelId)
            .whereType<int>()
            .toSet();
        final freeModels = _avatars.catalog
            .where(
              (option) =>
                  !widget.ownedOnly ||
                  option.remoteModelId == null ||
                  option.id == current.id ||
                  ownedModelIds.contains(option.remoteModelId),
            )
            .toList();
        final listedRemoteIds = freeModels
            .map((option) => option.remoteModelId)
            .whereType<int>()
            .toSet();
        for (final model
            in widget.ownedOnly
                ? <ApprovedAvatarModel>[]
                : _store.reviewedModels) {
          if (model.isLoadableOnDevice || listedRemoteIds.contains(model.id)) {
            continue;
          }
          freeModels.add(model.toAvatarOption());
          listedRemoteIds.add(model.id);
        }
        final query = _search.text.trim().toLowerCase();
        final visibleModels = freeModels
            .where(
              (option) =>
                  query.isEmpty ||
                  '${bundledAvatarStoreName(option)} ${option.name} ${_modelSource(option)}'
                      .toLowerCase()
                      .contains(query),
            )
            .toList();
        // Read authority in the reactive scope, including diagnostic-only rows.
        final selectableById = {
          for (final option in visibleModels)
            option.id: _avatars.canSelectOption(option),
        };
        return LayoutBuilder(
          builder: (context, constraints) {
            final horizontalPadding = widget.ownedOnly
                ? (constraints.maxWidth >= 700 ? 24.0 : 16.0)
                : (constraints.maxWidth < 360 ? 16.0 : 20.0);
            return CustomScrollView(
              key: const ValueKey<String>('model-store-scroll'),
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    horizontalPadding,
                    8,
                    horizontalPadding,
                    12,
                  ),
                  sliver: SliverList.list(
                    children: [
                      if (widget.sectionNavigation != null)
                        widget.sectionNavigation!,
                      AppGlassField(
                        key: const ValueKey<String>('model-store-search'),
                        controller: _search,
                        hintText: 'avatar_store.search'.tr,
                        prefixIcon: Icons.search_rounded,
                        maxLength: 160,
                        suffix: query.isEmpty
                            ? null
                            : IconButton(
                                key: const ValueKey<String>(
                                  'model-search-clear',
                                ),
                                tooltip: 'skill_store.clear_search'.tr,
                                onPressed: () => setState(_search.clear),
                                icon: const Icon(Icons.close_rounded),
                              ),
                        textInputAction: TextInputAction.search,
                        onChanged: (_) => setState(() {}),
                      ),
                      const SizedBox(height: 20),
                      if (widget.ownedOnly) ...[
                        const _StoreSectionHeader(
                          titleKey: 'avatar_store.section.equipped',
                          icon: Icons.check_circle_outline_rounded,
                        ),
                        const SizedBox(height: 8),
                        _EquippedModelShowcase(
                          option: current,
                          isSwitching: switching,
                        ),
                        const SizedBox(height: 24),
                      ],
                      if (widget.ownedOnly)
                        _StoreSectionHeader(
                          titleKey: 'avatar_store.section.choose_model',
                          subtitleKey:
                              'avatar_store.section.choose_model_subtitle',
                          icon: Icons.view_in_ar_outlined,
                          trailing: _store.isCatalogLoading.value
                              ? const _CompactProgress()
                              : AppGlassIconButton(
                                  tooltip: 'avatar_store.refresh.models'.tr,
                                  icon: Icons.refresh_rounded,
                                  onPressed: _store.refreshFreeModels,
                                  size: 48,
                                ),
                        )
                      else
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'avatar_store.section.all_models'.tr,
                                style: TextStyle(
                                  color: MaasoGlassTheme.of(
                                    context,
                                  ).foregroundPrimary,
                                  fontSize: 16,
                                  height: 24 / 16,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                            if (_store.isCatalogLoading.value)
                              const _CompactProgress()
                            else
                              AppGlassIconButton(
                                tooltip: 'avatar_store.refresh.models'.tr,
                                icon: Icons.refresh_rounded,
                                onPressed: _store.refreshFreeModels,
                                size: 48,
                              ),
                          ],
                        ),
                      if (_store.catalogError.value != null) ...[
                        const SizedBox(height: 8),
                        _RetryCard(
                          messageKey: 'avatar_store.error.refresh_models',
                          onRetry: _store.refreshFreeModels,
                        ),
                      ],
                    ],
                  ),
                ),
                SliverPadding(
                  padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
                  sliver: SliverLayoutBuilder(
                    builder: (context, constraints) {
                      final columns =
                          widget.ownedOnly ||
                              constraints.crossAxisExtent < 328 ||
                              MediaQuery.textScalerOf(context).scale(15) > 18
                          ? 1
                          : 2;
                      return SliverList.separated(
                        key: ValueKey<String>(
                          widget.ownedOnly
                              ? 'model-workshop-list'
                              : 'model-store-gallery',
                        ),
                        itemCount: (visibleModels.length / columns).ceil(),
                        separatorBuilder: (_, _) => const SizedBox(height: 12),
                        itemBuilder: (context, rowIndex) {
                          final first = rowIndex * columns;
                          Widget card(int index) {
                            final option = visibleModels[index];
                            return _ModelSkinCard(
                              option: option,
                              isCurrent: option.id == current.id,
                              isSwitching: switching,
                              remoteModelSelectionAvailable:
                                  selectableById[option.id] ?? false,
                              onTap: () => _showModelDetail(option),
                              managementRow: widget.ownedOnly,
                            );
                          }

                          if (columns == 1) return card(first);
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: card(first)),
                              const SizedBox(width: 12),
                              Expanded(
                                child: first + 1 < visibleModels.length
                                    ? card(first + 1)
                                    : const SizedBox.shrink(),
                              ),
                            ],
                          );
                        },
                      );
                    },
                  ),
                ),
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    horizontalPadding,
                    24,
                    horizontalPadding,
                    28,
                  ),
                  sliver: SliverList.list(
                    children: [
                      if (visibleModels.isEmpty)
                        widget.ownedOnly
                            ? Text(
                                'asset_store.empty'.tr,
                                style: Theme.of(context).textTheme.bodyMedium,
                              )
                            : _ModelSearchEmpty(
                                onClear: query.isEmpty
                                    ? null
                                    : () => setState(_search.clear),
                              ),
                      if (widget.ownedOnly) ...[
                        _StoreSectionHeader(
                          titleKey: 'avatar_store.section.uploads',
                          subtitleKey: 'avatar_store.section.uploads_subtitle',
                          icon: Icons.inventory_2_outlined,
                          trailing: _store.isUploadsLoading.value
                              ? const _CompactProgress()
                              : AppGlassIconButton(
                                  tooltip: 'avatar_store.refresh.uploads'.tr,
                                  onPressed: _store.refreshMyUploads,
                                  icon: Icons.refresh_rounded,
                                  size: 48,
                                ),
                        ),
                        const SizedBox(height: 12),
                        if (_store.uploadsError.value != null) ...[
                          _RetryCard(
                            messageKey: 'avatar_store.error.refresh_uploads',
                            onRetry: _store.refreshMyUploads,
                          ),
                          const SizedBox(height: 12),
                        ],
                        if (uploads.isEmpty && !_store.isUploadsLoading.value)
                          const _EmptyUploadsCard(),
                        for (final upload in uploads) ...[
                          _UploadCard(upload: upload),
                          const SizedBox(height: 12),
                        ],
                        const SizedBox(height: 12),
                        Text(
                          'avatar_store.cover.guidance'.tr,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 8),
                        AppGlassButton(
                          key: const ValueKey<String>('model-workshop-upload'),
                          label: _store.isUploading.value
                              ? 'avatar_store.uploading'.tr
                              : 'avatar_store.upload'.tr,
                          icon: Icons.upload_rounded,
                          fullWidth: true,
                          onPressed: _store.isUploading.value
                              ? null
                              : _pickAndUpload,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            );
          },
        );
      }),
    );
  }
}

class _ModelDetailSheet extends StatefulWidget {
  const _ModelDetailSheet({
    required this.option,
    required this.avatars,
    required this.invalidated,
    required this.authority,
    required this.onSelect,
  });
  final AvatarOption option;
  final AvatarConfigService avatars;
  final Future<void>? invalidated;
  final bool Function() authority;
  final Future<bool> Function() onSelect;

  @override
  State<_ModelDetailSheet> createState() => _ModelDetailSheetState();
}

class _ModelDetailSheetState extends State<_ModelDetailSheet> {
  bool _invalidated = false;
  bool _busy = false;
  bool get _current => mounted && !_invalidated && widget.authority();

  @override
  void initState() {
    super.initState();
    widget.invalidated?.then((_) {
      if (mounted) setState(() => _invalidated = true);
    });
  }

  Future<void> _confirmSelection() async {
    if (!_current || _busy || widget.avatars.isSwitching.value) return;
    setState(() => _busy = true);
    try {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(bundledAvatarStoreName(widget.option)),
          content: Text('asset_store.confirm_select'.tr),
          actions: [
            TextButton(
              key: const ValueKey<String>('model-confirm-cancel'),
              onPressed: () => Navigator.pop(dialog, false),
              child: Text('common.cancel'.tr),
            ),
            FilledButton(
              key: const ValueKey<String>('model-confirm-select'),
              onPressed: () => Navigator.pop(dialog, true),
              child: Text('common.confirm'.tr),
            ),
          ],
        ),
      );
      if (accepted != true ||
          !_current ||
          !widget.avatars.canSelectOption(widget.option)) {
        return;
      }
      final selected = await widget.onSelect();
      if (!mounted) return;
      if (selected && _current) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => FractionallySizedBox(
    heightFactor: .9,
    child: AppGlassSheet(
      key: const ValueKey<String>('model-detail-sheet'),
      child: SizedBox(
        height: double.infinity,
        child: SingleChildScrollView(
          child: AppReactiveBuilder(() {
            final option = widget.option;
            final glass = MaasoGlassTheme.of(context);
            final current = widget.avatars.selectedId.value == option.id;
            final selectable =
                _current &&
                !option.capabilityProfile.hasBlockers &&
                widget.avatars.canSelectOption(option);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        bundledAvatarStoreName(option),
                        style: TextStyle(
                          color: glass.foregroundPrimary,
                          fontSize: 28,
                          height: 36 / 28,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    AppGlassIconButton(
                      tooltip: 'common.close'.tr,
                      onPressed: () => Navigator.pop(context),
                      icon: Icons.close_rounded,
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                AppGlassSurface(
                  key: const ValueKey<String>('model-detail-art'),
                  role: AppGlassSurfaceRole.staticSurface,
                  padding: const EdgeInsets.all(16),
                  child: SizedBox(
                    height: 320,
                    child: _ModelPreview(option: option),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  _modelSource(option),
                  style: TextStyle(
                    color: glass.foregroundSecondary,
                    fontSize: 13,
                    height: 20 / 13,
                  ),
                ),
                if (current) ...[
                  const SizedBox(height: 12),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: _CurrentModelBadge(),
                  ),
                ],
                const SizedBox(height: 16),
                Text(
                  option.id == 'agent'
                      ? 'avatar_store.bundled_female_summary'.tr
                      : _avatarCapabilityDetail(option.capabilityProfile),
                  style: TextStyle(
                    color: glass.foregroundSecondary,
                    fontSize: 15,
                    height: 24 / 15,
                  ),
                ),
                if (!selectable) ...[
                  const SizedBox(height: 12),
                  Text(
                    'common.action_unavailable'.tr,
                    key: const ValueKey<String>('model-detail-unavailable'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 13,
                      height: 20 / 13,
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                AppGlassButton(
                  key: const ValueKey<String>('model-detail-select'),
                  label:
                      (_busy
                              ? 'asset_store.working'
                              : current
                              ? 'avatar_store.equipped'
                              : 'asset_store.select')
                          .tr,
                  primary: !current,
                  foregroundColor: current ? glass.accentText : null,
                  fullWidth: true,
                  onPressed:
                      !selectable ||
                          _busy ||
                          current ||
                          widget.avatars.isSwitching.value
                      ? null
                      : _confirmSelection,
                ),
              ],
            );
          }),
        ),
      ),
    ),
  );
}

class _CompactProgress extends StatelessWidget {
  const _CompactProgress();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(15),
    child: SizedBox(
      height: 18,
      width: 18,
      child: CircularProgressIndicator(
        strokeWidth: 2,
        color: MaasoGlassTheme.of(context).accent,
      ),
    ),
  );
}

class _StoreSectionHeader extends StatelessWidget {
  const _StoreSectionHeader({
    required this.titleKey,
    required this.icon,
    this.subtitleKey,
    this.trailing,
  });

  final String titleKey;
  final IconData icon;
  final String? subtitleKey;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return Row(
      children: [
        Icon(icon, color: glass.accent, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                titleKey.tr,
                style: TextStyle(
                  color: glass.foregroundPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                ),
              ),
              if (subtitleKey != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitleKey!.tr,
                  style: TextStyle(
                    color: glass.foregroundSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
        ?trailing,
      ],
    );
  }
}

class _EquippedModelShowcase extends StatelessWidget {
  const _EquippedModelShowcase({
    required this.option,
    required this.isSwitching,
  });

  final AvatarOption option;
  final bool isSwitching;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return AppSecondaryCard(
      key: const ValueKey<String>('model-current-summary'),
      tone: AppSecondaryCardTone.selected,
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(
              width: 72,
              height: 80,
              child: _ModelPreview(option: option),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  bundledAvatarStoreName(option),
                  style: TextStyle(
                    color: glass.foregroundPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  isSwitching
                      ? 'avatar_store.status.switching'.tr
                      : _modelSource(option),
                  style: TextStyle(
                    color: glass.foregroundSecondary,
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (isSwitching)
            const _CompactProgress()
          else
            Icon(Icons.check_circle_rounded, color: glass.accent, size: 24),
        ],
      ),
    );
  }
}

class _ModelSkinCard extends StatelessWidget {
  const _ModelSkinCard({
    required this.option,
    required this.isCurrent,
    required this.isSwitching,
    required this.remoteModelSelectionAvailable,
    required this.onTap,
    required this.managementRow,
  });

  final AvatarOption option;
  final bool isCurrent;
  final bool isSwitching;
  final bool remoteModelSelectionAvailable;
  final VoidCallback onTap;
  final bool managementRow;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final profile = option.capabilityProfile;
    final unavailable =
        option.remoteModelId != null && !remoteModelSelectionAvailable;
    final canSelect =
        !isCurrent && !isSwitching && !profile.hasBlockers && !unavailable;
    final detail = _avatarCapabilityDetail(profile);
    final source = _modelSource(option);
    return Semantics(
      label: 'avatar_store.model.semantics'.trParams({
        'name': bundledAvatarStoreName(option),
        'source': source,
      }),
      selected: isCurrent,
      value: unavailable
          ? 'common.action_unavailable'.tr
          : 'avatar_store.capability.state.${profile.state.wireName}'.tr,
      hint: unavailable
          ? 'common.action_unavailable'.tr
          : profile.hasBlockers
          ? '${'avatar_store.capability.selection_blocked'.tr}. $detail'
          : detail,
      enabled: canSelect || isCurrent,
      button: true,
      child: !managementRow
          ? _PublicModelSkinCard(
              option: option,
              isCurrent: isCurrent,
              isSwitching: isSwitching,
              unavailable: unavailable,
              onTap: canSelect || isCurrent ? onTap : null,
            )
          : AppSecondaryCard(
              key: ValueKey<String>('model-card-${option.id}'),
              tone: isCurrent
                  ? AppSecondaryCardTone.selected
                  : AppSecondaryCardTone.normal,
              onTap: canSelect || isCurrent ? onTap : null,
              padding: const EdgeInsets.all(12),
              cornerRadius: 20,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: SizedBox(
                          width: 72,
                          height: 80,
                          child: _ModelPreview(option: option),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              bundledAvatarStoreName(option),
                              style: TextStyle(
                                color: glass.foregroundPrimary,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              source,
                              style: TextStyle(
                                color: glass.foregroundSecondary,
                                fontSize: 13,
                                height: 1.35,
                              ),
                            ),
                            if (profile.isDeclared) ...[
                              const SizedBox(height: 8),
                              _AvatarCapabilityChip(
                                key: ValueKey<String>(
                                  'model-capability-${option.id}',
                                ),
                                profile: profile,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (unavailable) ...[
                    const SizedBox(height: 8),
                    Text(
                      'common.action_unavailable'.tr,
                      key: ValueKey<String>(
                        'model-capability-unavailable-${option.id}',
                      ),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                  ] else if (profile.isDeclared) ...[
                    const SizedBox(height: 8),
                    Text(
                      profile.hasBlockers
                          ? '${'avatar_store.capability.selection_blocked'.tr} · $detail'
                          : detail,
                      style: TextStyle(
                        color: profile.hasBlockers
                            ? Theme.of(context).colorScheme.error
                            : glass.foregroundSecondary,
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  if (isCurrent)
                    Row(
                      children: [
                        Icon(
                          Icons.check_circle_rounded,
                          color: glass.accent,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            isSwitching
                                ? 'avatar_store.status.switching'.tr
                                : 'avatar_store.equipped'.tr,
                            style: TextStyle(
                              color: glass.accentText,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    )
                  else
                    Align(
                      alignment: Alignment.centerRight,
                      child: AppGlassButton(
                        key: ValueKey<String>('model-select-${option.id}'),
                        label: 'asset_store.select'.tr,
                        minHeight: 48,
                        onPressed: canSelect ? onTap : null,
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

class _PublicModelSkinCard extends StatelessWidget {
  const _PublicModelSkinCard({
    required this.option,
    required this.isCurrent,
    required this.isSwitching,
    required this.unavailable,
    required this.onTap,
  });

  final AvatarOption option;
  final bool isCurrent;
  final bool isSwitching;
  final bool unavailable;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final profile = option.capabilityProfile;
    final detail = _avatarCapabilityDetail(profile);
    return AppSecondaryCard(
      key: ValueKey<String>('model-card-${option.id}'),
      onTap: onTap,
      padding: EdgeInsets.zero,
      cornerRadius: MaasoGlassTheme.surfaceRadius,
      child: Ink(
        key: ValueKey<String>('model-frost-fill-${option.id}'),
        color: glass.muted,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (isCurrent)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _CurrentModelBadge(
                    key: ValueKey<String>('model-current-${option.id}'),
                    isSwitching: isSwitching,
                  ),
                ),
              )
            else
              const SizedBox(height: 48),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: LayoutBuilder(
                builder: (context, constraints) => SizedBox(
                  height: (constraints.maxWidth / .68).clamp(220, 340),
                  child: _ModelPreview(option: option),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    bundledAvatarStoreName(option),
                    style: TextStyle(
                      color: glass.foregroundPrimary,
                      fontSize: 22,
                      height: 28 / 22,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _modelSource(option),
                    style: TextStyle(
                      color: glass.foregroundSecondary,
                      fontSize: 13,
                      height: 20 / 13,
                    ),
                  ),
                  if (profile.isDeclared) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: _AvatarCapabilityChip(
                        key: ValueKey<String>('model-capability-${option.id}'),
                        profile: profile,
                      ),
                    ),
                  ],
                  if (unavailable) ...[
                    const SizedBox(height: 8),
                    Text(
                      'common.action_unavailable'.tr,
                      key: ValueKey<String>(
                        'model-capability-unavailable-${option.id}',
                      ),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 13,
                        height: 20 / 13,
                      ),
                    ),
                  ] else if (profile.isDeclared) ...[
                    const SizedBox(height: 8),
                    Text(
                      profile.hasBlockers
                          ? '${'avatar_store.capability.selection_blocked'.tr} · $detail'
                          : detail,
                      style: TextStyle(
                        color: profile.hasBlockers
                            ? Theme.of(context).colorScheme.error
                            : glass.foregroundSecondary,
                        fontSize: 13,
                        height: 20 / 13,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  AppGlassButton(
                    key: ValueKey<String>('model-select-${option.id}'),
                    label: 'skill_store.view_details'.tr,
                    primary: !isCurrent,
                    foregroundColor: isCurrent ? glass.accentText : null,
                    minHeight: 48,
                    fullWidth: true,
                    onPressed: onTap,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CurrentModelBadge extends StatelessWidget {
  const _CurrentModelBadge({super.key, this.isSwitching = false});

  final bool isSwitching;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: glass.surface.withValues(
          alpha: MaasoFrostTokens.overlayFillAlpha,
        ),
        borderRadius: BorderRadius.circular(MaasoGlassTheme.capsuleRadius),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_rounded, color: glass.accentText, size: 14),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                (isSwitching
                        ? 'avatar_store.status.switching'
                        : 'avatar_store.section.equipped')
                    .tr,
                style: TextStyle(
                  color: glass.accentText,
                  fontSize: 12,
                  height: 20 / 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModelSearchEmpty extends StatelessWidget {
  const _ModelSearchEmpty({required this.onClear});

  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return AppGlassSurface(
      key: const ValueKey<String>('model-store-empty'),
      role: AppGlassSurfaceRole.staticSurface,
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          Icon(Icons.search_rounded, color: glass.foregroundSecondary),
          const SizedBox(height: 12),
          Text(
            'asset_store.empty'.tr,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: glass.foregroundPrimary,
              fontSize: 15,
              height: 24 / 15,
            ),
          ),
          if (onClear != null) ...[
            const SizedBox(height: 16),
            AppGlassButton(
              key: const ValueKey<String>('model-empty-clear'),
              label: 'skill_store.clear_search'.tr,
              primary: false,
              foregroundColor: glass.accentText,
              onPressed: onClear,
            ),
          ],
        ],
      ),
    );
  }
}

String _modelSource(AvatarOption option) {
  final reviewedSource = _titleCase(option.modelSource);
  return option.remoteModelId == null
      ? 'avatar_store.source.maaso_original'.tr
      : reviewedSource.isEmpty
      ? 'avatar_store.source.reviewed'.tr
      : 'avatar_store.source.reviewed_named'.trParams({
          'source': reviewedSource,
        });
}

class _ModelPreview extends StatelessWidget {
  const _ModelPreview({required this.option});

  final AvatarOption option;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final assetPath = _previewAssetPath(option);
    final imageUrl = _approvedPreviewUrl(option.previewImageUrl);
    return ClipRect(
      child: DecoratedBox(
        decoration: BoxDecoration(color: glass.muted),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (assetPath != null)
              Image.asset(
                assetPath,
                key: ValueKey<String>('model-preview-${option.id}'),
                fit: BoxFit.contain,
                alignment: Alignment.center,
                errorBuilder: (_, _, _) =>
                    _PreviewFallback(name: bundledAvatarStoreName(option)),
              )
            else if (imageUrl != null)
              Image.network(
                imageUrl,
                key: ValueKey<String>('model-preview-${option.id}'),
                fit: BoxFit.contain,
                alignment: Alignment.center,
                frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                  if (frame != null || wasSynchronouslyLoaded) return child;
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      _PreviewFallback(
                        name: bundledAvatarStoreName(option),
                        loading: true,
                      ),
                      const Center(
                        child: SizedBox(
                          height: 22,
                          width: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    ],
                  );
                },
                errorBuilder: (_, _, _) =>
                    _PreviewFallback(name: bundledAvatarStoreName(option)),
              )
            else
              _PreviewFallback(name: bundledAvatarStoreName(option)),
          ],
        ),
      ),
    );
  }
}

class _PreviewFallback extends StatelessWidget {
  const _PreviewFallback({required this.name, this.loading = false});

  final String name;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            loading
                ? Icons.hourglass_top_rounded
                : Icons.accessibility_new_rounded,
            size: 32,
            color: glass.foregroundSecondary,
          ),
          const SizedBox(height: 7),
          Text(
            loading ? 'avatar_store.preview.loading'.tr : name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: glass.foregroundPrimary,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _AvatarCapabilityChip extends StatelessWidget {
  const _AvatarCapabilityChip({super.key, required this.profile});

  final AvatarCapabilityProfile profile;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final foreground = switch (profile.state) {
      AvatarCapabilityState.incompatible => Theme.of(context).colorScheme.error,
      AvatarCapabilityState.unknown => glass.foregroundSecondary,
      _ => glass.accentText,
    };
    final background = foreground.withValues(alpha: 0.10);
    final tooltip = _avatarCapabilityDetail(profile);
    return Tooltip(
      message: tooltip,
      child: ExcludeSemantics(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            child: Text(
              'avatar_store.capability.state.${profile.state.wireName}'.tr,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: foreground,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                height: 1.25,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _avatarCapabilityDetail(AvatarCapabilityProfile profile) {
  final issue = profile.primaryIssue;
  return issue == null
      ? 'avatar_store.capability.detail.${profile.state.wireName}'.tr
      : 'avatar_store.capability.issue.${issue.code.wireName}'.tr;
}

String? _previewAssetPath(AvatarOption option) {
  if (option.previewAssetPath?.trim().isNotEmpty == true) {
    return option.previewAssetPath!.trim();
  }
  return null;
}

String? _approvedPreviewUrl(String? value) {
  final uri = Uri.tryParse(value?.trim() ?? '');
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
  return uri.toString();
}

String _titleCase(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty) return '';
  return '${normalized[0].toUpperCase()}${normalized.substring(1)}';
}

class _UploadCard extends StatelessWidget {
  const _UploadCard({required this.upload});

  final OwnAvatarUpload upload;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final status = _UploadStatusPresentation.forStatus(upload.status, context);
    final statusReason = _localizedUploadStatusReason(upload);
    return AppSecondaryCard(
      key: ValueKey<String>('model-upload-${upload.id}'),
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_approvedPreviewUrl(upload.previewImageUrl) != null)
            SizedBox(
              width: 88,
              height: 132,
              child: Image.network(
                upload.previewImageUrl!,
                cacheWidth: 176,
                key: ValueKey<String>('model-upload-cover-${upload.id}'),
                fit: BoxFit.contain,
                alignment: Alignment.center,
                semanticLabel: upload.displayName,
                errorBuilder: (_, _, _) => Icon(
                  Icons.image_not_supported_outlined,
                  color: glass.foregroundSecondary,
                ),
              ),
            )
          else
            Icon(Icons.view_in_ar_outlined, color: glass.accent, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  upload.displayName,
                  style: TextStyle(
                    color: glass.foregroundPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  upload.fileName,
                  style: TextStyle(
                    color: glass.foregroundSecondary,
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 8),
                _StatusChip(labelKey: status.labelKey, color: status.color),
                if (statusReason != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    statusReason,
                    style: TextStyle(
                      color: glass.foregroundSecondary,
                      fontSize: 13,
                      height: 1.35,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyUploadsCard extends StatelessWidget {
  const _EmptyUploadsCard();

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return AppSecondaryCard(
      padding: const EdgeInsets.all(14),
      child: Text(
        'avatar_store.upload.empty'.tr,
        style: TextStyle(
          color: glass.foregroundSecondary,
          fontSize: 12,
          height: 1.4,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _RetryCard extends StatelessWidget {
  const _RetryCard({required this.messageKey, required this.onRetry});

  final String messageKey;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return AppSecondaryCard(
      tone: AppSecondaryCardTone.danger,
      padding: const EdgeInsets.fromLTRB(14, 9, 8, 9),
      child: Row(
        children: [
          Icon(
            Icons.cloud_off_outlined,
            color: Theme.of(context).colorScheme.error,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              messageKey.tr,
              style: TextStyle(
                color: glass.foregroundSecondary,
                fontSize: 11,
                height: 1.35,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton(onPressed: onRetry, child: Text('common.retry'.tr)),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.labelKey, required this.color});

  final String labelKey;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        child: Text(
          labelKey.tr,
          style: TextStyle(
            color: color,
            fontSize: 10,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }
}

class _UploadStatusPresentation {
  const _UploadStatusPresentation(this.labelKey, this.color);

  final String labelKey;
  final Color color;

  factory _UploadStatusPresentation.forStatus(
    AvatarUploadStatus status,
    BuildContext context,
  ) {
    final glass = MaasoGlassTheme.of(context);
    final color = switch (status) {
      AvatarUploadStatus.scanFailed ||
      AvatarUploadStatus.rejected => Theme.of(context).colorScheme.error,
      AvatarUploadStatus.approved =>
        glass.brightness == Brightness.dark
            ? MaasoFrostTokens.darkSuccess
            : MaasoFrostTokens.lightSuccess,
      _ => glass.accentText,
    };
    final labelKey = switch (status) {
      AvatarUploadStatus.pendingUpload =>
        'avatar_store.upload.status.uploading',
      AvatarUploadStatus.pendingScan => 'avatar_store.upload.status.scanning',
      AvatarUploadStatus.scanFailed =>
        'avatar_store.upload.status.needs_changes',
      AvatarUploadStatus.pendingReview =>
        'avatar_store.upload.status.awaiting_review',
      AvatarUploadStatus.approved => 'avatar_store.upload.status.available',
      AvatarUploadStatus.rejected => 'avatar_store.upload.status.not_approved',
    };
    return _UploadStatusPresentation(labelKey, color);
  }
}

String? _localizedUploadStatusReason(OwnAvatarUpload upload) {
  final statusMessage = upload.statusMessage?.trim();
  if (statusMessage == null || statusMessage.isEmpty) return null;
  return switch (upload.status) {
    AvatarUploadStatus.scanFailed =>
      'avatar_store.upload.reason.scan_failed'.tr,
    AvatarUploadStatus.rejected => 'avatar_store.upload.reason.rejected'.tr,
    _ => 'avatar_store.upload.reason.generic'.tr,
  };
}

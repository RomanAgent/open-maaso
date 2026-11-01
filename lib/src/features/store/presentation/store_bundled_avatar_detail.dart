import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/avatar_config_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/features/store/presentation/store_asset_detail.dart';

/// Joy is the real default model bound in the packaged Companion scene. The
/// persisted Agent identity stays stable; this is not a server-reviewed asset.
String bundledAvatarStoreName(AvatarOption option) =>
    option.id == 'agent' ? 'Joy' : option.name;

Future<void> showBundledAvatarStoreDetail(
  BuildContext context,
  AvatarOption option,
  AvatarConfigService avatars, {
  required bool Function() canContinue,
}) async {
  if (!canContinue()) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _BundledAvatarDetail(
      option: option,
      avatars: avatars,
      canContinue: canContinue,
    ),
  );
}

class _BundledAvatarDetail extends StatefulWidget {
  const _BundledAvatarDetail({
    required this.option,
    required this.avatars,
    required this.canContinue,
  });
  final AvatarOption option;
  final AvatarConfigService avatars;
  final bool Function() canContinue;

  @override
  State<_BundledAvatarDetail> createState() => _BundledAvatarDetailState();
}

class _BundledAvatarDetailState extends State<_BundledAvatarDetail> {
  bool _busy = false;
  bool _invalidated = false;
  Object? _error;
  bool get _current => mounted && !_invalidated && widget.canContinue();

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
              _invalidated = true;
              _error = StateError('bundled_avatar_scope_changed');
            });
          }
        });
  }

  Future<void> _select() async {
    if (!_current || _busy || widget.avatars.isSwitching.value) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(bundledAvatarStoreName(widget.option)),
          content: Text('asset_store.confirm_select'.tr),
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
      if (!widget.avatars.canSelectOption(widget.option)) {
        throw StateError('bundled_avatar_unavailable');
      }
      // The existing service owns the reviewed-selection clear, renderer
      // switch, voice assignment, persistence, and rollback on any failure.
      await widget.avatars.select(widget.option.id);
    } catch (error) {
      if (_current) setState(() => _error = error);
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => FractionallySizedBox(
    heightFactor: .9,
    child: AppGlassSheet(
      child: SizedBox(
        height: double.infinity,
        child: SingleChildScrollView(
          child: AppReactiveBuilder(() {
            final glass = MaasoGlassTheme.of(context);
            final selected =
                widget.avatars.selectedId.value == widget.option.id;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        bundledAvatarStoreName(widget.option),
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
                const SizedBox(height: 16),
                if (widget.option.previewAssetPath case final artwork?)
                  Container(
                    key: const ValueKey('bundled-detail-frost-artwork'),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: glass.muted,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Image.asset(
                      artwork,
                      height: 300,
                      fit: BoxFit.contain,
                    ),
                  ),
                const SizedBox(height: 24),
                Text(
                  (widget.option.id == 'agent'
                          ? 'avatar_store.bundled_female_summary'
                          : 'avatar_store.source.maaso_original')
                      .tr,
                  style: TextStyle(
                    color: glass.foregroundSecondary,
                    fontSize: 15,
                    height: 24 / 15,
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(storeAssetError(_error!)),
                ],
                const SizedBox(height: 16),
                AppGlassButton(
                  key: const ValueKey('asset-execute'),
                  fullWidth: true,
                  label:
                      (_busy
                              ? 'asset_store.working'
                              : selected
                              ? 'asset_store.selected'
                              : 'asset_store.select')
                          .tr,
                  onPressed:
                      !_current ||
                          _busy ||
                          selected ||
                          widget.avatars.isSwitching.value
                      ? null
                      : _select,
                ),
              ],
            );
          }),
        ),
      ),
    ),
  );
}

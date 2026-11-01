import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_localization.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_glass_theme.dart';
import 'package:maaso/src/desktop/application/companion_menu_catalog.dart';

class CompanionFunctionMenu extends StatefulWidget {
  CompanionFunctionMenu({
    required this.onSelected,
    List<CompanionMenuEntry>? entries,
    AppPlatformCapabilities? capabilities,
    super.key,
  }) : entries = entries ?? CompanionMenuCatalog.entries,
       capabilities = capabilities ?? AppPlatformCapabilities.current();

  static const Key searchFieldKey = ValueKey<String>(
    'companion-function-menu-search',
  );
  static const Key emptyStateKey = ValueKey<String>(
    'companion-function-menu-empty',
  );

  static Key entryKey(String destinationId) =>
      ValueKey<String>('companion-function-menu-entry-$destinationId');
  static Key limitationKey(String destinationId) =>
      ValueKey<String>('companion-function-menu-limitation-$destinationId');

  final List<CompanionMenuEntry> entries;
  final AppPlatformCapabilities capabilities;
  final ValueChanged<CompanionMenuEntry> onSelected;

  @override
  State<CompanionFunctionMenu> createState() => _CompanionFunctionMenuState();
}

class _CompanionFunctionMenuState extends State<CompanionFunctionMenu> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final visibleEntries = _filteredEntries();
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : 360.0;
        final availableHeight = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : 520.0;
        final width = math.min(360.0, availableWidth);
        final height = math.min(520.0, availableHeight);
        return SizedBox(
          width: width,
          height: height,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                child: TextField(
                  key: CompanionFunctionMenu.searchFieldKey,
                  controller: _searchController,
                  onChanged: (value) => setState(() {
                    _query = value.trim().toLowerCase();
                  }),
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    labelText: _text(
                      'companion.menu.search',
                      zh: '搜索功能',
                      en: 'Search functions',
                    ),
                    prefixIcon: const ExcludeSemantics(
                      child: Icon(Icons.search_rounded),
                    ),
                    isDense: true,
                  ),
                ),
              ),
              Expanded(
                child: visibleEntries.isEmpty
                    ? Center(
                        key: CompanionFunctionMenu.emptyStateKey,
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            _text(
                              'companion.menu.empty',
                              zh: '没有匹配的功能',
                              en: 'No matching functions',
                            ),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: glass.foregroundSecondary,
                              fontSize: 14,
                              height: 1.4,
                            ),
                          ),
                        ),
                      )
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                        children: _buildGroups(context, visibleEntries),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  List<CompanionMenuEntry> _filteredEntries() {
    if (_query.isEmpty) return widget.entries;
    return widget.entries
        .where(
          (entry) => entry.searchTerms.any(
            (term) => term.toLowerCase().contains(_query),
          ),
        )
        .toList(growable: false);
  }

  List<Widget> _buildGroups(
    BuildContext context,
    List<CompanionMenuEntry> visibleEntries,
  ) {
    final widgets = <Widget>[];
    for (final group in CompanionMenuGroup.values) {
      final entries = visibleEntries
          .where((entry) => entry.group == group)
          .toList(growable: false);
      if (entries.isEmpty) continue;
      if (widgets.isNotEmpty) widgets.add(const SizedBox(height: 8));
      widgets.add(
        Semantics(
          header: true,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Text(
              _groupLabel(group),
              style: TextStyle(
                color: MaasoGlassTheme.of(context).foregroundSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ),
      );
      widgets.addAll(
        entries.map((entry) {
          final status = widget.capabilities.destinationStatus(
            entry.destination.id,
          );
          return _CompanionMenuTile(
            key: CompanionFunctionMenu.entryKey(entry.destination.id),
            entry: entry,
            label: _entryLabel(entry),
            limitationLabel: status.isLimited ? _limitedLabel() : null,
            limitationMessage: status.isLimited
                ? _limitationMessage(status)
                : null,
            onTap: () => widget.onSelected(entry),
          );
        }),
      );
    }
    return widgets;
  }

  String _entryLabel(CompanionMenuEntry entry) {
    final translated = entry.labelKey.tr;
    return translated == entry.labelKey ? entry.destination.title : translated;
  }

  String _groupLabel(CompanionMenuGroup group) {
    final translated = group.labelKey.tr;
    if (translated != group.labelKey) return translated;
    final zh = switch (group) {
      CompanionMenuGroup.conversation => '交流',
      CompanionMenuGroup.explore => '探索',
      CompanionMenuGroup.create => '创作',
      CompanionMenuGroup.tools => '工具与娱乐',
      CompanionMenuGroup.devices => '设备',
      CompanionMenuGroup.system => '系统',
    };
    final en = switch (group) {
      CompanionMenuGroup.conversation => 'Connect',
      CompanionMenuGroup.explore => 'Explore',
      CompanionMenuGroup.create => 'Create',
      CompanionMenuGroup.tools => 'Tools & Play',
      CompanionMenuGroup.devices => 'Devices',
      CompanionMenuGroup.system => 'System',
    };
    return AppLocalization.locale.languageCode == 'zh' ? zh : en;
  }

  String _text(String key, {required String zh, required String en}) {
    final translated = key.tr;
    if (translated != key) return translated;
    return AppLocalization.locale.languageCode == 'zh' ? zh : en;
  }

  String _limitedLabel() =>
      AppLocalization.locale.languageCode == 'zh' ? '部分受限' : 'Limited';

  String _limitationMessage(AppRouteCapabilityStatus status) {
    final labels = status.unavailableActions
        .map(_capabilityLabel)
        .toList(growable: false);
    if (AppLocalization.locale.languageCode == 'zh') {
      return '当前平台暂不支持：${labels.join('、')}。页面仍可打开。';
    }
    return 'Unavailable on this platform: ${labels.join(', ')}. '
        'The page can still be opened.';
  }

  String _capabilityLabel(AppActionCapability capability) {
    final isZh = AppLocalization.locale.languageCode == 'zh';
    return switch (capability) {
      AppActionCapability.advancedAiSettings =>
        isZh ? '高级 AI 设置' : 'advanced AI settings',
      AppActionCapability.onDeviceLlm =>
        isZh ? '本地大模型' : 'on-device language model',
      AppActionCapability.onDeviceSpeechModels =>
        isZh ? '本地语音模型' : 'on-device speech models',
      AppActionCapability.unityAvatar => isZh ? '3D 头像' : '3D avatar',
      AppActionCapability.remoteUnityAvatarAssets =>
        isZh ? '远程 3D 头像资源' : 'remote 3D avatar assets',
      AppActionCapability.remoteUnityWorldAssets =>
        isZh ? '远程 3D 世界资源' : 'remote 3D world assets',
      AppActionCapability.localUnityMediaCapture =>
        isZh ? '本地 3D 媒体采集' : 'local 3D media capture',
      AppActionCapability.realtimeRtc => isZh ? '实时音视频' : 'live audio/video',
      AppActionCapability.onDeviceFaceDetection =>
        isZh ? '本机人脸检测' : 'on-device face detection',
      AppActionCapability.bluetooth => isZh ? '蓝牙设备' : 'Bluetooth devices',
      AppActionCapability.embeddedSurface =>
        isZh ? '交互式小程序' : 'interactive Applets',
      AppActionCapability.localSpeechRecognition =>
        isZh ? '本地语音识别' : 'on-device speech recognition',
    };
  }
}

class _CompanionMenuTile extends StatelessWidget {
  const _CompanionMenuTile({
    required this.entry,
    required this.label,
    required this.limitationLabel,
    required this.limitationMessage,
    required this.onTap,
    super.key,
  });

  final CompanionMenuEntry entry;
  final String label;
  final String? limitationLabel;
  final String? limitationMessage;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return Semantics(
      button: true,
      label: label,
      hint: limitationMessage,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          focusColor: glass.accent.withValues(alpha: 0.16),
          hoverColor: glass.accent.withValues(alpha: 0.1),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: <Widget>[
                  ExcludeSemantics(
                    child: Icon(
                      _iconData(entry.icon),
                      size: 22,
                      color: glass.foregroundPrimary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: glass.foregroundPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (limitationLabel != null) ...<Widget>[
                    Tooltip(
                      message: limitationMessage!,
                      child: Container(
                        key: CompanionFunctionMenu.limitationKey(
                          entry.destination.id,
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: glass.accentSoft,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          limitationLabel!,
                          style: TextStyle(
                            color: glass.accentText,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  ExcludeSemantics(
                    child: Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: glass.foregroundSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  IconData _iconData(CompanionMenuIcon icon) => switch (icon) {
    CompanionMenuIcon.home => Icons.home_rounded,
    CompanionMenuIcon.chat => Icons.chat_bubble_rounded,
    CompanionMenuIcon.moments => Icons.auto_awesome_rounded,
    CompanionMenuIcon.memory => Icons.favorite_rounded,
    CompanionMenuIcon.settings => Icons.settings_rounded,
    CompanionMenuIcon.advanced => Icons.tune_rounded,
    CompanionMenuIcon.skills => Icons.psychology_alt_rounded,
    CompanionMenuIcon.store => Icons.storefront_rounded,
    CompanionMenuIcon.dashboard => Icons.dashboard_rounded,
    CompanionMenuIcon.game => Icons.sports_esports_rounded,
    CompanionMenuIcon.applets => Icons.widgets_rounded,
    CompanionMenuIcon.qr => Icons.qr_code_scanner_rounded,
    CompanionMenuIcon.avatar => Icons.face_rounded,
    CompanionMenuIcon.world => Icons.public_rounded,
    CompanionMenuIcon.feed => Icons.smart_display_rounded,
    CompanionMenuIcon.creator => Icons.edit_note_rounded,
    CompanionMenuIcon.highlights => Icons.auto_awesome_motion_rounded,
    CompanionMenuIcon.projector => Icons.cast_rounded,
    CompanionMenuIcon.unknown => Icons.apps_rounded,
  };
}

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/notifications/notification_consent_service.dart';
import 'package:maaso/src/core/notifications/notification_preferences_service.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/desktop_local_asr_model_catalog.dart';
import 'package:maaso/src/core/services/desktop_local_asr_pack_runtime.dart';
import 'package:maaso/src/core/services/desktop_local_asr_service.dart';
import 'package:maaso/src/core/services/emotion_sensor_service.dart';
import 'package:maaso/src/core/services/home_presentation_preference_service.dart';
import 'package:maaso/src/core/services/ble/ble_transport_service.dart';
import 'package:maaso/src/features/settings/presentation/settings_frost_components.dart';
import 'package:maaso/src/features/settings/presentation/settings_context_panel.dart';
import 'package:maaso/src/features/agent/application/maaso_tts_plugin.dart';
import 'package:maaso/src/features/agent/presentation/companion/embedded_avatar_presentation_policy.dart';
import 'package:maaso/src/features/agent/application/sherpa_tts_engine.dart';
import 'package:maaso/src/features/agent/data/bridge/tts_engine.dart';
import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:maaso/src/features/settings/application/agent_settings_controller.dart';
import 'package:maaso/src/features/settings/presentation/location_settings_row.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/services/cloud_llm_health_service.dart';
import 'package:maaso/src/core/services/local_llm_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/maaso_agent_mode_service.dart';
import 'package:maaso/src/core/services/sherpa_model_download_service.dart';
import 'package:maaso/src/core/services/sherpa_neural_tts.dart';
import 'package:maaso/src/core/services/sherpa_bindings.dart';
import 'package:maaso/src/core/services/theme_service.dart';
import 'package:maaso/src/core/services/vad_service.dart';
import 'package:maaso/src/core/services/voice_prosody_preference_service.dart';
import 'package:maaso/src/core/utils/byte_format.dart';
import 'package:maaso/src/desktop/application/desktop_companion_preferences_service.dart';

class AgentSettingsPage extends AppView<AgentSettingsController> {
  const AgentSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final inset = MediaQuery.sizeOf(context).width < 360 ? 16.0 : 20.0;
    return AppSecondaryScaffold(
      header: const _SettingsHeader(),
      contentMaxWidth: 640,
      body: ListView(
        key: const ValueKey('settings-list'),
        padding: EdgeInsets.fromLTRB(inset, 12, inset, 24),
        children: [
          Text(
            'settings.title'.tr,
            style: TextStyle(
              fontSize: 28,
              height: 36 / 28,
              fontWeight: FontWeight.w600,
              color: glass.foregroundPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'settings.page_subtitle'.tr,
            style: TextStyle(
              fontSize: 13,
              height: 20 / 13,
              color: glass.foregroundSecondary,
            ),
          ),
          const SizedBox(height: 24),
          const HomePresentationSettingsSection(),
          const SizedBox(height: 16),
          const SettingsContextPanel(),
          const SizedBox(height: 24),
          const AgentPerceptionSettingsSection(),
          const SizedBox(height: 24),
          const _NotificationSection(),
          const SizedBox(height: 24),
          SettingsFrostGroup(
            title: 'settings.devices_preferences'.tr,
            child: const Column(
              children: [
                _LanguageSection(),
                SettingsFrostDivider(),
                _BluetoothSettingsRow(),
                SettingsFrostDivider(),
                _MicrophoneSettingsRow(),
                SettingsFrostDivider(),
                LocationSettingsRow(),
              ],
            ),
          ),
          const SizedBox(height: 24),
          SettingsFrostGroup(
            title: 'settings.privacy_account'.tr,
            child: Column(
              children: [
                SettingsFrostRow(
                  key: const ValueKey('settings-privacy'),
                  icon: Icons.privacy_tip_outlined,
                  title: 'settings.privacy_policy'.tr,
                  onTap: () => appNavigation.push(AppRouteCatalog.privacy),
                ),
                const SettingsFrostDivider(),
                SettingsFrostRow(
                  key: const ValueKey('settings-account-deletion'),
                  icon: Icons.manage_accounts_outlined,
                  title: 'account_deletion.title'.tr,
                  onTap: () =>
                      appNavigation.push(AppRouteCatalog.accountDeletion),
                ),
              ],
            ),
          ),
          if (appServices
              .isRegistered<DesktopCompanionPreferencesService>()) ...[
            const SizedBox(height: 24),
            const DesktopCompanionPresentationSettingsSection(),
          ],
          const _CapabilityAdvancedFeaturesEntry(),
          const SizedBox(height: 24),
          const _AccountSection(),
          const SizedBox(height: 20),
          Text(
            'Maaso · 1.0.0',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: glass.foregroundSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsHeader extends StatelessWidget {
  const _SettingsHeader();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
    child: Row(
      children: [
        AppGlassIconButton(
          icon: Icons.arrow_back_rounded,
          tooltip: 'common.back'.tr,
          size: 48,
          onPressed: () =>
              appNavigation.pop(fallbackRoute: AppRouteCatalog.home),
        ),
        Expanded(
          child: Text(
            'Maaso',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: MaasoGlassTheme.of(context).foregroundPrimary,
            ),
          ),
        ),
        const _AppearanceModeButton(),
      ],
    ),
  );
}

class _BluetoothSettingsRow extends StatelessWidget {
  const _BluetoothSettingsRow();

  @override
  Widget build(BuildContext context) {
    final transport = appServices.maybeFind<BleTransportService>();
    return AppReactiveBuilder(() {
      final connected = transport?.isConnected.value ?? false;
      final scanning = transport?.isScanning.value ?? false;
      final name = transport?.connected.value?.platformName.trim();
      return SettingsFrostRow(
        key: const ValueKey('settings-bluetooth'),
        icon: Icons.bluetooth_rounded,
        title: 'settings.bluetooth'.tr,
        subtitle: 'settings.projector_connection'.tr,
        value: connected
            ? (name?.isNotEmpty == true ? name : 'settings.device_connected'.tr)
            : (scanning
                      ? 'settings.device_scanning'
                      : 'settings.device_disconnected')
                  .tr,
        onTap: () => appNavigation.push(AppRouteCatalog.bleProjector),
      );
    });
  }
}

class _MicrophoneSettingsRow extends StatelessWidget {
  const _MicrophoneSettingsRow();

  @override
  Widget build(BuildContext context) => SettingsFrostRow(
    icon: Icons.mic_none_rounded,
    title: 'settings.microphone'.tr,
    subtitle: 'settings.system_permission_hint'.tr,
  );
}

class HomePresentationSettingsSection extends StatefulWidget {
  const HomePresentationSettingsSection({super.key});

  @override
  State<HomePresentationSettingsSection> createState() =>
      _HomePresentationSettingsSectionState();
}

class _HomePresentationSettingsSectionState
    extends State<HomePresentationSettingsSection> {
  bool _saving = false;
  String? _error;

  Future<void> _select(
    HomePresentationPreferenceService service,
    HomePresentationMode next,
  ) async {
    if (_saving || next == service.mode.value) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await service.setMode(next);
    } catch (_) {
      _error = 'settings.home_view_error'.tr;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = appServices.maybeFind<HomePresentationPreferenceService>();
    if (service == null) return const SizedBox.shrink();
    final capabilities =
        appServices.maybeFind<AppPlatformCapabilities>() ??
        AppPlatformCapabilities.current();
    final avatarAvailable =
        EmbeddedAvatarPresentationPolicy.shouldEmbed() &&
        capabilities.actionStatus(AppActionCapability.unityAvatar).available;
    return AppReactiveBuilder(() {
      final preference = service.mode.value;
      final glass = MaasoGlassTheme.of(context);
      final selected = avatarAvailable ? preference : HomePresentationMode.chat;
      return SettingsFrostPanel(
        key: const ValueKey('settings-home-view'),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'settings.home_view'.tr,
                style: TextStyle(
                  fontSize: 15,
                  height: 24 / 15,
                  fontWeight: FontWeight.w600,
                  color: glass.foregroundPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                (avatarAvailable
                        ? 'settings.home_view_hint'
                        : 'settings.home_view_unavailable')
                    .tr,
                style: TextStyle(
                  fontSize: 13,
                  height: 20 / 13,
                  color: glass.foregroundSecondary,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final mode in [
                    HomePresentationMode.avatar,
                    HomePresentationMode.chat,
                  ]) ...[
                    if (mode == HomePresentationMode.chat)
                      const SizedBox(width: 12),
                    Expanded(
                      child: _HomeViewChoice(
                        key: ValueKey('settings-home-view-${mode.name}'),
                        selected: selected == mode,
                        icon: mode == HomePresentationMode.avatar
                            ? Icons.accessibility_new_rounded
                            : Icons.chat_bubble_outline_rounded,
                        label:
                            (mode == HomePresentationMode.avatar
                                    ? 'settings.home_view_avatar'
                                    : 'settings.home_view_chat')
                                .tr,
                        onTap: _saving || !avatarAvailable
                            ? null
                            : () => _select(service, mode),
                      ),
                    ),
                  ],
                ],
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    });
  }
}

class _HomeViewChoice extends StatelessWidget {
  const _HomeViewChoice({
    super.key,
    required this.selected,
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final bool selected;
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return Semantics(
      selected: selected,
      button: true,
      enabled: onTap != null,
      child: Material(
        color: selected ? glass.surface : Colors.transparent,
        elevation: selected ? 2 : 0,
        shadowColor: glass.staticShadow,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: 28,
                  child: Stack(
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Icon(
                          icon,
                          size: 24,
                          color: selected
                              ? glass.accentText
                              : glass.foregroundSecondary,
                        ),
                      ),
                      if (selected)
                        Align(
                          alignment: Alignment.topRight,
                          child: Icon(
                            Icons.check_circle_rounded,
                            size: 16,
                            color: glass.accentText,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  label,
                  textAlign: TextAlign.start,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.5,
                    fontWeight: FontWeight.w500,
                    color: selected
                        ? glass.accentText
                        : glass.foregroundSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Uses the already-mounted sensor and shared speech queue, even when settings
/// is opened directly without a HomeController.
class AgentPerceptionSettingsSection extends StatefulWidget {
  const AgentPerceptionSettingsSection({super.key});

  @override
  State<AgentPerceptionSettingsSection> createState() =>
      _AgentPerceptionSettingsSectionState();
}

class _AgentPerceptionSettingsSectionState
    extends State<AgentPerceptionSettingsSection> {
  bool _savingVision = false;
  bool _savingSound = false;
  String? _error;

  Future<void> _changeVision(EmotionSensorService sensor, bool enabled) async {
    if (_savingVision ||
        !identical(appServices.maybeFind<EmotionSensorService>(), sensor)) {
      return;
    }
    setState(() {
      _savingVision = true;
      _error = null;
    });
    try {
      if (enabled) {
        await sensor.start();
      } else {
        await sensor.stop(userInitiated: true);
      }
    } catch (_) {
      _error = 'settings.agent_controls_error'.tr;
    } finally {
      if (mounted) setState(() => _savingVision = false);
    }
  }

  Future<void> _changeSound(bool enabled) async {
    if (_savingSound) return;
    setState(() {
      _savingSound = true;
      _error = null;
    });
    try {
      await MaasoTtsPlugin.setSoundEnabled(enabled);
    } catch (_) {
      _error = 'settings.agent_controls_error'.tr;
    } finally {
      if (mounted) setState(() => _savingSound = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sensor = appServices.maybeFind<EmotionSensorService>();
    return AppReactiveBuilder(() {
      final visionEnabled = sensor?.userEnabled.value ?? false;
      final visionAvailable = sensor?.sensingAvailable ?? false;
      final visionStarting = sensor?.isStarting.value ?? false;
      final soundEnabled = MaasoTtsPlugin.soundEnabled.value;
      return SettingsFrostGroup(
        title: 'settings.agent_controls'.tr,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SettingsFrostSwitch(
              tileKey: const ValueKey('settings-agent-sound'),
              icon: Icons.volume_up_outlined,
              title: 'settings.agent_sound'.tr,
              subtitle: Text('settings.agent_sound_hint'.tr),
              value: soundEnabled,
              onChanged: _savingSound ? null : _changeSound,
            ),
            const SettingsFrostDivider(),
            SettingsFrostSwitch(
              tileKey: const ValueKey('settings-agent-vision'),
              icon: Icons.visibility_outlined,
              title: 'settings.agent_vision'.tr,
              subtitle: Text(
                (visionAvailable
                        ? 'settings.agent_vision_hint'
                        : 'settings.agent_vision_unavailable')
                    .tr,
              ),
              value: visionEnabled,
              onChanged:
                  sensor == null ||
                      (!visionAvailable && !visionEnabled) ||
                      _savingVision ||
                      visionStarting
                  ? null
                  : (enabled) => _changeVision(sensor, enabled),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      );
    });
  }
}

class DesktopCompanionPresentationSettingsSection extends StatelessWidget {
  const DesktopCompanionPresentationSettingsSection({
    this.preferences,
    super.key,
  });

  final DesktopCompanionPreferencesService? preferences;

  @override
  Widget build(BuildContext context) {
    final service =
        preferences ?? appServices.find<DesktopCompanionPreferencesService>();
    return StreamBuilder<DesktopCompanionPresentationConfigV1>(
      initialData: service.config,
      stream: service.changes,
      builder: (context, snapshot) {
        final config = snapshot.data ?? service.config;
        return _Section(
          title: 'settings.desktop_companion'.tr,
          subtitle: 'settings.desktop_companion_subtitle'.tr,
          child: Column(
            children: [
              Semantics(
                container: true,
                label: 'settings.desktop_companion_quality'.tr,
                value: _desktopCompanionQualityLabel(config.quality),
                child: _DropdownTile<DesktopCompanionRenderQuality>(
                  icon: Icons.hd_rounded,
                  iconColor: ColorConstant.primaryColor,
                  label: 'settings.desktop_companion_quality'.tr,
                  value: config.quality,
                  items: DesktopCompanionRenderQuality.values
                      .map(
                        (quality) => DropdownMenuItem(
                          value: quality,
                          child: Text(_desktopCompanionQualityLabel(quality)),
                        ),
                      )
                      .toList(growable: false),
                  onChanged: (quality) {
                    if (quality != null) {
                      unawaited(service.setQuality(quality));
                    }
                  },
                ),
              ),
              const Divider(height: 1),
              Semantics(
                container: true,
                label: 'settings.desktop_companion_fps'.tr,
                value: '${config.targetFps}',
                child: _DropdownTile<int>(
                  icon: Icons.speed_rounded,
                  iconColor: ColorConstant.secondaryColor,
                  label: 'settings.desktop_companion_fps'.tr,
                  value: config.targetFps,
                  items: DesktopCompanionPresentationConfigV1.supportedTargetFps
                      .map(
                        (fps) => DropdownMenuItem(
                          value: fps,
                          child: Text('$fps FPS'),
                        ),
                      )
                      .toList(growable: false),
                  onChanged: (fps) {
                    if (fps != null) unawaited(service.setTargetFps(fps));
                  },
                ),
              ),
              const Divider(height: 1),
              _DesktopCompanionScaleSlider(
                value: config.visualScale,
                onChangeEnd: (scale) =>
                    unawaited(service.setVisualScale(scale)),
              ),
              const Divider(height: 1),
              _SettingRow(
                icon: Icons.vertical_align_top_rounded,
                color: ColorConstant.primaryColor,
                title: 'settings.desktop_companion_always_on_top'.tr,
                trailing: Semantics(
                  label: 'settings.desktop_companion_always_on_top'.tr,
                  toggled: config.alwaysOnTop,
                  child: Switch.adaptive(
                    value: config.alwaysOnTop,
                    onChanged: (value) =>
                        unawaited(service.setAlwaysOnTop(value)),
                  ),
                ),
              ),
              const Divider(height: 1),
              _SettingRow(
                icon: Icons.align_vertical_bottom_rounded,
                color: ColorConstant.secondaryColor,
                title: 'settings.desktop_companion_snap'.tr,
                trailing: Semantics(
                  label: 'settings.desktop_companion_snap'.tr,
                  toggled: config.snapEnabled,
                  child: Switch.adaptive(
                    value: config.snapEnabled,
                    onChanged: (value) =>
                        unawaited(service.setSnapEnabled(value)),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _DesktopCompanionScaleSlider extends StatefulWidget {
  const _DesktopCompanionScaleSlider({
    required this.value,
    required this.onChangeEnd,
  });

  final double value;
  final ValueChanged<double> onChangeEnd;

  @override
  State<_DesktopCompanionScaleSlider> createState() =>
      _DesktopCompanionScaleSliderState();
}

class _DesktopCompanionScaleSliderState
    extends State<_DesktopCompanionScaleSlider> {
  late double _displayValue;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _displayValue = _quantizeScale(widget.value);
  }

  @override
  void didUpdateWidget(covariant _DesktopCompanionScaleSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_dragging && oldWidget.value != widget.value) {
      _displayValue = _quantizeScale(widget.value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = 'settings.desktop_companion_scale'.tr;
    final valueLabel = _scaleLabel(_displayValue);
    final scales = DesktopCompanionPresentationConfigV1.supportedVisualScales;
    final selectedIndex = scales.indexOf(_quantizeScale(_displayValue));
    final increased =
        scales[selectedIndex < scales.length - 1
            ? selectedIndex + 1
            : selectedIndex];
    final decreased = scales[selectedIndex > 0 ? selectedIndex - 1 : 0];
    return Semantics(
      container: true,
      excludeSemantics: true,
      slider: true,
      label: label,
      value: valueLabel,
      increasedValue: _scaleLabel(increased),
      decreasedValue: _scaleLabel(decreased),
      onIncrease: selectedIndex < scales.length - 1
          ? () => _commit(increased)
          : null,
      onDecrease: selectedIndex > 0 ? () => _commit(decreased) : null,
      child: Column(
        children: [
          _SettingRow(
            icon: Icons.aspect_ratio_rounded,
            color: ColorConstant.accentColor,
            title: label,
            trailing: Text(
              valueLabel,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: MaasoGlassTheme.of(context).foregroundPrimary,
              ),
            ),
          ),
          SizedBox(
            height: 48,
            child: Slider(
              min: 0,
              max: (scales.length - 1).toDouble(),
              divisions: scales.length - 1,
              value: selectedIndex.toDouble(),
              label: valueLabel,
              onChanged: (value) {
                setState(() {
                  _dragging = true;
                  _displayValue = scales[value.round()];
                });
              },
              onChangeEnd: (value) => _commit(scales[value.round()]),
            ),
          ),
        ],
      ),
    );
  }

  void _commit(double value) {
    final next = _quantizeScale(value);
    setState(() {
      _dragging = false;
      _displayValue = next;
    });
    if (next != widget.value) widget.onChangeEnd(next);
  }
}

double _quantizeScale(double value) =>
    DesktopCompanionPresentationConfigV1.nearestVisualScale(value);

String _scaleLabel(double value) {
  final scale = _quantizeScale(value);
  final key = switch (scale) {
    1.2 => 'settings.desktop_companion_scale_small',
    1.8 => 'settings.desktop_companion_scale_normal',
    2.4 => 'settings.desktop_companion_scale_large',
    _ => 'settings.desktop_companion_scale_extra_large',
  };
  return '${key.tr}（${(scale * 100).round()}%）';
}

String _desktopCompanionQualityLabel(DesktopCompanionRenderQuality quality) =>
    switch (quality) {
      DesktopCompanionRenderQuality.eco =>
        'settings.desktop_companion_quality_eco'.tr,
      DesktopCompanionRenderQuality.balanced =>
        'settings.desktop_companion_quality_balanced'.tr,
      DesktopCompanionRenderQuality.crisp =>
        'settings.desktop_companion_quality_crisp'.tr,
    };

class _Section extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget child;
  const _Section({required this.title, this.subtitle, required this.child});

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return AppSecondarySection(
      title: title,
      subtitle: subtitle,
      child: Material(
        key: ValueKey<String>('settings-group-$title'),
        color: glass.muted,
        borderRadius: BorderRadius.circular(MaasoGlassTheme.surfaceRadius),
        clipBehavior: Clip.antiAlias,
        child: Padding(padding: const EdgeInsets.all(16), child: child),
      ),
    );
  }
}

class _AppearanceModeButton extends StatefulWidget {
  const _AppearanceModeButton();

  @override
  State<_AppearanceModeButton> createState() => _AppearanceModeButtonState();
}

class _AppearanceModeButtonState extends State<_AppearanceModeButton> {
  bool _saving = false;

  Future<void> _choose(AgentSettingsController controller) async {
    if (_saving) return;
    final next = await showSettingsChoiceSheet<ThemeModePreference>(
      context: context,
      sheetKey: const ValueKey('settings-appearance-sheet'),
      title: 'settings.appearance'.tr,
      selected: controller.selectedThemeMode.value,
      values: ThemeModePreference.values,
      label: _themeModeLabel,
      keyName: (mode) => 'settings-appearance-${mode.name}',
      icon: (mode) => switch (mode) {
        ThemeModePreference.system => Icons.brightness_auto_outlined,
        ThemeModePreference.light => Icons.light_mode_outlined,
        ThemeModePreference.dark => Icons.dark_mode_outlined,
      },
    );
    if (!mounted ||
        next == null ||
        next == controller.selectedThemeMode.value ||
        !identical(
          appServices.maybeFind<AgentSettingsController>(),
          controller,
        )) {
      return;
    }
    setState(() => _saving = true);
    try {
      await controller.setThemeMode(next);
      if (!mounted ||
          !identical(
            appServices.maybeFind<AgentSettingsController>(),
            controller,
          )) {
        return;
      }
      appNavigation.showSnackBar(
        snackPosition: AppSnackPosition.top,
        message: 'settings.theme_mode_changed'.trParams({
          'mode': _themeModeLabel(next),
        }),
      );
    } catch (_) {
      if (!mounted ||
          !identical(
            appServices.maybeFind<AgentSettingsController>(),
            controller,
          )) {
        return;
      }
      appNavigation.showSnackBar(
        snackPosition: AppSnackPosition.top,
        message: 'settings.theme_mode_save_failed'.tr,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = appServices.find<AgentSettingsController>();
    final theme = appServices.maybeFind<ThemeService>();
    return AppReactiveBuilder(() {
      final mode = controller.selectedThemeMode.value;
      final brightness =
          theme?.brightness.value ??
          switch (mode) {
            ThemeModePreference.system => Theme.of(context).brightness,
            ThemeModePreference.light => Brightness.light,
            ThemeModePreference.dark => Brightness.dark,
          };
      return AppGlassIconButton(
        key: const ValueKey('settings-appearance-toggle'),
        icon: brightness == Brightness.dark
            ? Icons.dark_mode_rounded
            : Icons.light_mode_rounded,
        size: 48,
        tooltip: 'settings.appearance_current'.trParams({
          'mode': _themeModeLabel(mode),
        }),
        onPressed: _saving ? null : () => _choose(controller),
      );
    });
  }

  String _themeModeLabel(ThemeModePreference mode) {
    switch (mode) {
      case ThemeModePreference.system:
        return 'settings.theme_mode_system'.tr;
      case ThemeModePreference.light:
        return 'settings.theme_mode_light'.tr;
      case ThemeModePreference.dark:
        return 'settings.theme_mode_dark'.tr;
    }
  }
}

class _AccountSection extends StatefulWidget {
  const _AccountSection();
  @override
  State<_AccountSection> createState() => _AccountSectionState();
}

class _AccountSectionState extends State<_AccountSection> {
  bool _working = false;

  Future<void> _logout() async {
    if (_working) return;
    final controller = appServices.find<AgentSettingsController>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('settings.logout'.tr),
        content: Text('settings.logout_confirm_hint'.tr),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('common.cancel'.tr),
          ),
          TextButton(
            key: const ValueKey('settings-logout-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('settings.logout'.tr),
          ),
        ],
      ),
    );
    if (!mounted ||
        confirmed != true ||
        !identical(
          appServices.maybeFind<AgentSettingsController>(),
          controller,
        )) {
      return;
    }
    setState(() => _working = true);
    try {
      await controller.logout();
    } catch (_) {
      if (mounted &&
          identical(
            appServices.maybeFind<AgentSettingsController>(),
            controller,
          )) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          appGlassSnackBar(content: Text('common.request_failed'.tr)),
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return TextButton(
      key: const ValueKey('settings-logout'),
      onPressed: _working ? null : _logout,
      style: TextButton.styleFrom(
        foregroundColor: glass.foregroundPrimary,
        backgroundColor: glass.muted,
        minimumSize: const Size.fromHeight(56),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      child: Text('settings.logout'.tr),
    );
  }
}

class _NotificationSection extends StatelessWidget {
  const _NotificationSection();

  @override
  Widget build(BuildContext context) {
    final notifications = appServices
        .maybeFind<NotificationPreferencesService>();
    final consent = appServices.maybeFind<NotificationConsentService>();
    return SettingsFrostGroup(
      title: 'settings.notifications_title'.tr,
      child: AppReactiveBuilder(() {
        final preferences =
            notifications?.state.value ?? const NotificationPreferences();
        return Column(
          children: [
            SettingsFrostSwitch(
              icon: Icons.notifications_active_outlined,
              title: 'settings.notifications_allow'.tr,
              tileKey: const ValueKey('settings-notifications-allow'),
              subtitle: Text('settings.notifications_allow_hint'.tr),
              value: preferences.canNotify,
              onChanged: consent == null || consent.isUpdating.value
                  ? null
                  : (enabled) async {
                      try {
                        final granted = await consent.setEnabled(enabled);
                        if (enabled && !granted && context.mounted) {
                          appNavigation.showSnackBar(
                            message:
                                'settings.notifications_permission_denied'.tr,
                          );
                        }
                      } on Object {
                        if (context.mounted) {
                          appNavigation.showSnackBar(
                            message:
                                'settings.notifications_permission_denied'.tr,
                          );
                        }
                      }
                    },
            ),
            const SettingsFrostDivider(),
            SettingsFrostSwitch(
              icon: Icons.schedule_rounded,
              title: 'settings.notifications_scheduled_tasks'.tr,
              tileKey: const ValueKey('settings-notifications-scheduled'),
              subtitle: Text('settings.notifications_scheduled_hint'.tr),
              value: preferences.scheduledTasksEnabled,
              onChanged: preferences.canNotify && notifications != null
                  ? notifications.setScheduledTasksEnabled
                  : null,
            ),
          ],
        );
      }),
    );
  }
}

class _LanguageSection extends StatefulWidget {
  const _LanguageSection();
  @override
  State<_LanguageSection> createState() => _LanguageSectionState();
}

class _LanguageSectionState extends State<_LanguageSection> {
  bool _saving = false;

  Future<void> _choose(AgentSettingsController controller) async {
    if (_saving) return;
    final next = await showSettingsChoiceSheet<AppLocale>(
      context: context,
      sheetKey: const ValueKey('settings-language-sheet'),
      title: 'settings.language'.tr,
      selected: controller.selectedLocale.value,
      values: AppLocale.values,
      label: (locale) => locale.displayName,
      keyName: (locale) => 'settings-language-${locale.code}',
      icon: (locale) => locale == AppLocale.system
          ? Icons.phone_iphone_rounded
          : Icons.translate_rounded,
    );
    if (!mounted ||
        next == null ||
        next == controller.selectedLocale.value ||
        !identical(
          appServices.maybeFind<AgentSettingsController>(),
          controller,
        )) {
      return;
    }
    setState(() => _saving = true);
    try {
      await controller.setLocale(next);
    } catch (_) {
      if (mounted &&
          identical(
            appServices.maybeFind<AgentSettingsController>(),
            controller,
          )) {
        appNavigation.showSnackBar(message: 'common.request_failed'.tr);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = appServices.find<AgentSettingsController>();
    return AppReactiveBuilder(
      () => SettingsFrostRow(
        key: const ValueKey('settings-language'),
        icon: Icons.language_rounded,
        title: 'settings.language'.tr,
        value: controller.selectedLocale.value.displayName,
        onTap: _saving ? null : () => _choose(controller),
      ),
    );
  }
}

class _AdvancedFeaturesSection extends StatelessWidget {
  const _AdvancedFeaturesSection();

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return _Section(
      title: 'settings.advanced_features'.tr,
      subtitle: 'settings.advanced_features_subtitle'.tr,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SettingRow(
            icon: Icons.tune_rounded,
            color: ColorConstant.primaryColor,
            title: 'settings.advanced_features_open'.tr,
            trailing: AppGlassIconButton(
              icon: Icons.chevron_right_rounded,
              tooltip: 'settings.advanced_features'.tr,
              onPressed: () =>
                  appNavigation.push(AppRouteCatalog.advancedFeatures),
              size: 44,
              iconSize: 22,
              foregroundColor: glass.foregroundSecondary,
            ),
          ),
          Text(
            'settings.advanced_features_note'.tr,
            style: TextStyle(fontSize: 11, color: glass.foregroundSecondary),
          ),
        ],
      ),
    );
  }
}

class _CapabilityAdvancedFeaturesEntry extends StatelessWidget {
  const _CapabilityAdvancedFeaturesEntry();

  @override
  Widget build(BuildContext context) {
    AppCapabilitySnapshotService? service;
    try {
      service = appServices.maybeFind<AppCapabilitySnapshotService>();
    } catch (_) {
      service = null;
    }
    if (service == null) {
      return AppPlatformCapabilities.current().supportsAdvancedAiSettings
          ? const Column(
              children: <Widget>[
                SizedBox(height: 16),
                _AdvancedFeaturesSection(),
              ],
            )
          : const SizedBox.shrink();
    }
    return ValueListenableBuilder<AppCapabilitySnapshot>(
      valueListenable: service,
      builder: (context, snapshot, _) {
        final available =
            snapshot.allows(
              AppCapabilityKey.route('advanced_features'),
              requireVisible: true,
            ) &&
            snapshot.allows(
              AppCapabilityKey.platformAction(
                AppActionCapability.advancedAiSettings,
              ),
              requireVisible: true,
            );
        return available
            ? const Column(
                children: <Widget>[
                  SizedBox(height: 16),
                  _AdvancedFeaturesSection(),
                ],
              )
            : const SizedBox.shrink();
      },
    );
  }
}

class AgentAdvancedFeaturesPage extends StatefulWidget {
  const AgentAdvancedFeaturesPage({super.key});

  @override
  State<AgentAdvancedFeaturesPage> createState() =>
      _AgentAdvancedFeaturesPageState();
}

class _AgentAdvancedFeaturesPageState extends State<AgentAdvancedFeaturesPage> {
  late final AppPlatformCapabilities _platformCapabilities =
      AppPlatformCapabilities.current();
  late final Future<void> _prepare =
      _platformCapabilities.supportsAdvancedAiSettings
      ? _prepareAdvancedBaseServices()
      : Future<void>.value();

  Future<void> _prepareAdvancedBaseServices() async {
    if (!_platformCapabilities.supportsAdvancedAiSettings) return;
    if (!appServices.isRegistered<SherpaModelDownloadService>()) {
      appServices.put(SherpaModelDownloadService());
    }
    if (!appServices.isRegistered<VadService>()) {
      appServices.put(VadService());
    }
  }

  @override
  Widget build(BuildContext context) {
    AppCapabilitySnapshotService? service;
    try {
      service = appServices.maybeFind<AppCapabilitySnapshotService>();
    } catch (_) {
      service = null;
    }
    if (service == null) {
      return _buildForAvailability(
        _platformCapabilities.supportsAdvancedAiSettings,
      );
    }
    return ValueListenableBuilder<AppCapabilitySnapshot>(
      valueListenable: service,
      builder: (context, snapshot, _) => _buildForAvailability(
        snapshot.allows(
              AppCapabilityKey.route('advanced_features'),
              requireVisible: true,
            ) &&
            snapshot.allows(
              AppCapabilityKey.platformAction(
                AppActionCapability.advancedAiSettings,
              ),
              requireVisible: true,
            ),
      ),
    );
  }

  Widget _buildForAvailability(bool available) {
    if (!available) return const AgentSettingsPage();
    return FutureBuilder<void>(
      future: _prepare,
      builder: (context, snapshot) {
        return _AdvancedFeaturesPage(
          preparingModels: snapshot.connectionState != ConnectionState.done,
        );
      },
    );
  }
}

Future<LocalLLMService> _ensureLocalLlmService() async {
  final platformCapabilities = AppPlatformCapabilities.current();
  if (!platformCapabilities.supportsOnDeviceLlm) {
    throw UnsupportedError('On-device LLM is available only on desktop.');
  }
  if (appServices.isRegistered<LocalLLMService>()) {
    return appServices.find<LocalLLMService>();
  }
  return appServices.putAsync(
    () => LocalLLMService(
      platformCapabilities: platformCapabilities,
    ).init(autoLoad: false),
  );
}

Future<SherpaNeuralTts> _ensureLocalTtsService() async {
  final platformCapabilities = AppPlatformCapabilities.current();
  if (!platformCapabilities.supportsOnDeviceSpeechModels) {
    throw UnsupportedError(
      'On-device neural TTS is available only on desktop.',
    );
  }
  initializeSherpaBindings();
  if (!appServices.isRegistered<SherpaModelDownloadService>()) {
    appServices.put(SherpaModelDownloadService());
  }
  if (appServices.isRegistered<SherpaNeuralTts>()) {
    return appServices.find<SherpaNeuralTts>();
  }
  return appServices.putAsync(
    () => SherpaNeuralTts(platformCapabilities: platformCapabilities).init(),
  );
}

class _AdvancedFeaturesPage extends StatelessWidget {
  const _AdvancedFeaturesPage({required this.preparingModels});

  final bool preparingModels;

  @override
  Widget build(BuildContext context) {
    final controller = appServices.find<AgentSettingsController>();
    return AppSecondaryScaffold(
      header: AppSecondaryHeader(
        title: 'settings.advanced_features_page_title'.tr,
        onBack: () => appNavigation.pop(),
      ),
      body: AppReactiveBuilder(() {
        final mode = controller.pipelineMode.value;
        final showModeScopedSections =
            mode == AgentPipelineMode.localFull ||
            mode == AgentPipelineMode.directCloud;
        return ListView(
          padding: EdgeInsets.fromLTRB(
            16,
            10,
            16,
            MediaQuery.paddingOf(context).bottom + 24,
          ),
          children: [
            if (preparingModels) ...[
              const _AdvancedPreparingBanner(),
              const SizedBox(height: 16),
            ],
            const _RealtimeExperimentSection(),
            const SizedBox(height: 16),
            const _VoiceProsodySection(),
            const SizedBox(height: 16),
            const _DesktopLocalAsrSection(),
            const SizedBox(height: 16),
            if (showModeScopedSections) ...[
              const _ModelConfigSection(),
              const SizedBox(height: 16),
              const _LocalVoicePresetSection(),
              const SizedBox(height: 16),
              const _VoiceSection(),
              const SizedBox(height: 16),
              const _OnDeviceBrainSection(),
              const SizedBox(height: 16),
            ],
          ],
        );
      }),
    );
  }
}

class _VoiceProsodySection extends StatelessWidget {
  const _VoiceProsodySection();

  @override
  Widget build(BuildContext context) {
    final preferences = appServices.maybeFind<VoiceProsodyPreferenceService>();
    final glass = MaasoGlassTheme.of(context);
    return _Section(
      title: 'settings.voice_prosody'.tr,
      subtitle: 'settings.voice_prosody_subtitle'.tr,
      child: preferences == null
          ? Text(
              'settings.voice_prosody_unavailable'.tr,
              style: TextStyle(fontSize: 12, color: glass.foregroundSecondary),
            )
          : AppReactiveBuilder(
              () => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SettingRow(
                    icon: Icons.graphic_eq_rounded,
                    color: ColorConstant.secondaryColor,
                    title: preferences.effectiveEnabled
                        ? 'settings.voice_prosody_enabled'.tr
                        : 'settings.voice_prosody_disabled'.tr,
                    trailing: AppGlassToggle(
                      value: preferences.effectiveEnabled,
                      semanticLabel: 'settings.voice_prosody'.tr,
                      onChanged: (value) async {
                        try {
                          await preferences.setEnabled(value);
                        } catch (_) {
                          if (!context.mounted) return;
                          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                            appGlassSnackBar(
                              content: Text('common.request_failed'.tr),
                            ),
                          );
                        }
                      },
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'settings.voice_prosody_privacy_note'.tr,
                    style: TextStyle(
                      fontSize: 11,
                      color: glass.foregroundSecondary,
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _DesktopLocalAsrSection extends StatefulWidget {
  const _DesktopLocalAsrSection();

  @override
  State<_DesktopLocalAsrSection> createState() =>
      _DesktopLocalAsrSectionState();
}

class _DesktopLocalAsrSectionState extends State<_DesktopLocalAsrSection> {
  DesktopLocalAsrService? _observedService;
  String? _busyModelId;
  String? _messageKey;
  bool _messageIsError = false;
  int _operationGeneration = 0;

  DesktopLocalAsrService? get _service =>
      appServices.maybeFind<DesktopLocalAsrService>();

  DesktopLocalAsrPackRuntime? get _packRuntime =>
      appServices.maybeFind<DesktopLocalAsrPackRuntime>();

  bool get _operationBusy => _busyModelId != null;

  Future<void> _importModel(DesktopLocalAsrModelDescriptor descriptor) async {
    if (descriptor.requiresLegalApproval) {
      _showMessage('settings.local_asr_legal_gate', isError: true);
      return;
    }
    final runtime = _packRuntime;
    final service = _service;
    if (runtime == null || service == null || !runtime.supported) {
      _showMessage('settings.local_asr_unavailable', isError: true);
      return;
    }
    final sourceDirectory = await FilePicker.getDirectoryPath(
      dialogTitle: 'settings.local_asr_choose_directory'.tr,
      lockParentWindow: true,
    );
    if (sourceDirectory == null ||
        !mounted ||
        !identical(_service, service) ||
        !identical(_packRuntime, runtime)) {
      return;
    }
    final operationGeneration = _beginOperation(descriptor.id);
    try {
      await runtime.importUserDirectory(
        modelId: descriptor.id,
        sourceDirectoryPath: sourceDirectory,
      );
      await service.selectModel(descriptor.id);
      if (!_operationStillOwned(service, runtime, operationGeneration)) return;
      setState(() {
        _messageKey = 'settings.local_asr_import_success';
        _messageIsError = false;
      });
    } on DesktopLocalAsrPackException catch (error) {
      if (!_operationStillOwned(service, runtime, operationGeneration)) return;
      _showMessage(_localAsrPackIssueMessage(error.issue), isError: true);
    } on Object {
      if (!_operationStillOwned(service, runtime, operationGeneration)) return;
      _showMessage('settings.local_asr_import_failed', isError: true);
    } finally {
      _endOperation(descriptor.id, operationGeneration);
    }
  }

  Future<void> _verifyInstalled(
    DesktopLocalAsrModelDescriptor descriptor,
  ) async {
    if (descriptor.requiresLegalApproval) {
      _showMessage('settings.local_asr_legal_gate', isError: true);
      return;
    }
    final runtime = _packRuntime;
    final service = _service;
    if (runtime == null || service == null || !runtime.supported) {
      _showMessage('settings.local_asr_unavailable', isError: true);
      return;
    }
    final operationGeneration = _beginOperation(descriptor.id);
    try {
      final verified = await runtime.resolve(descriptor.coreModelPack);
      if (verified == null) {
        if (_operationStillOwned(service, runtime, operationGeneration)) {
          _showMessage('settings.local_asr_not_installed', isError: true);
        }
        return;
      }
      await service.selectModel(descriptor.id);
      if (!_operationStillOwned(service, runtime, operationGeneration)) return;
      setState(() {
        _messageKey = 'settings.local_asr_verify_success';
        _messageIsError = false;
      });
    } on DesktopLocalAsrPackException catch (error) {
      if (!_operationStillOwned(service, runtime, operationGeneration)) return;
      _showMessage(_localAsrPackIssueMessage(error.issue), isError: true);
    } on Object {
      if (!_operationStillOwned(service, runtime, operationGeneration)) return;
      _showMessage('settings.local_asr_verify_failed', isError: true);
    } finally {
      _endOperation(descriptor.id, operationGeneration);
    }
  }

  Future<void> _setEnabled(bool enabled) async {
    final service = _service;
    if (service == null) {
      _showMessage('settings.local_asr_unavailable', isError: true);
      return;
    }
    final operationModelId =
        service.state.value.selectedModelId ?? '_preference';
    final operationGeneration = _beginOperation(operationModelId);
    try {
      await service.setEnabled(enabled);
      if (!mounted ||
          !identical(_service, service) ||
          operationGeneration != _operationGeneration) {
        return;
      }
      _showMessage(
        enabled
            ? 'settings.local_asr_enable_success'
            : 'settings.local_asr_disable_success',
      );
    } on Object {
      if (!mounted ||
          !identical(_service, service) ||
          operationGeneration != _operationGeneration) {
        return;
      }
      _showMessage('settings.local_asr_preference_failed', isError: true);
    } finally {
      _endOperation(operationModelId, operationGeneration);
    }
  }

  int _beginOperation(String modelId) {
    final operationGeneration = ++_operationGeneration;
    if (!mounted) return operationGeneration;
    setState(() {
      _busyModelId = modelId;
      _messageKey = null;
    });
    return operationGeneration;
  }

  void _endOperation(String? modelId, int operationGeneration) {
    if (!mounted ||
        modelId == null ||
        _busyModelId != modelId ||
        _operationGeneration != operationGeneration) {
      return;
    }
    setState(() => _busyModelId = null);
  }

  bool _operationStillOwned(
    DesktopLocalAsrService service,
    DesktopLocalAsrPackRuntime runtime,
    int operationGeneration,
  ) =>
      mounted &&
      identical(_service, service) &&
      identical(_packRuntime, runtime) &&
      _operationGeneration == operationGeneration;

  void _showMessage(String key, {bool isError = false}) {
    if (!mounted) return;
    setState(() {
      _messageKey = key;
      _messageIsError = isError;
    });
  }

  @override
  Widget build(BuildContext context) {
    final service = _service;
    final runtime = _packRuntime;
    final glass = MaasoGlassTheme.of(context);
    if (!identical(_observedService, service)) {
      _observedService = service;
      _operationGeneration++;
      _busyModelId = null;
      _messageKey = null;
      _messageIsError = false;
    }
    if (service == null || runtime == null || !runtime.supported) {
      return _Section(
        title: 'settings.local_asr'.tr,
        subtitle: 'settings.local_asr_subtitle'.tr,
        child: Text(
          'settings.local_asr_unavailable'.tr,
          style: TextStyle(fontSize: 12, color: glass.foregroundSecondary),
        ),
      );
    }
    return _Section(
      title: 'settings.local_asr'.tr,
      subtitle: 'settings.local_asr_subtitle'.tr,
      child: AppReactiveBuilder(() {
        final state = service.state.value;
        final selectedReady =
            state.selectedModelId != null && state.selectedModelAvailable;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SettingRow(
              icon: Icons.mic_none_rounded,
              color: ColorConstant.secondaryColor,
              title: state.effectiveEnabled
                  ? 'settings.local_asr_enabled'.tr
                  : 'settings.local_asr_disabled'.tr,
              trailing: AppGlassToggle(
                value: state.preferenceEnabled,
                semanticLabel: 'settings.local_asr_toggle'.tr,
                onChanged:
                    !_operationBusy &&
                        !state.decodeActive &&
                        (state.preferenceEnabled || selectedReady)
                    ? _setEnabled
                    : null,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'settings.local_asr_privacy_note'.tr,
              style: TextStyle(
                fontSize: 11,
                height: 1.4,
                color: glass.foregroundSecondary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'settings.local_asr_realtime_note'.tr,
              style: TextStyle(
                fontSize: 11,
                height: 1.4,
                color: glass.foregroundSecondary,
              ),
            ),
            const SizedBox(height: 14),
            for (
              var index = 0;
              index < runtime.descriptors.length;
              index++
            ) ...[
              _DesktopLocalAsrModelCard(
                descriptor: runtime.descriptors[index],
                selected:
                    state.selectedModelId == runtime.descriptors[index].id,
                verified:
                    state.selectedModelId == runtime.descriptors[index].id &&
                    state.selectedModelAvailable,
                enabled:
                    state.effectiveEnabled &&
                    state.selectedModelId == runtime.descriptors[index].id,
                busy: _busyModelId == runtime.descriptors[index].id,
                operationBlocked: _operationBusy || state.decodeActive,
                onImport: () => _importModel(runtime.descriptors[index]),
                onVerify: () => _verifyInstalled(runtime.descriptors[index]),
              ),
              if (index != runtime.descriptors.length - 1)
                const Divider(height: 24),
            ],
            if (_messageKey != null) ...[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Text(
                  _messageKey!.tr,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.35,
                    color: _messageIsError
                        ? ColorConstant.errorColor
                        : ColorConstant.successColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ],
        );
      }),
    );
  }
}

class _DesktopLocalAsrModelCard extends StatelessWidget {
  const _DesktopLocalAsrModelCard({
    required this.descriptor,
    required this.selected,
    required this.verified,
    required this.enabled,
    required this.busy,
    required this.operationBlocked,
    required this.onImport,
    required this.onVerify,
  });

  final DesktopLocalAsrModelDescriptor descriptor;
  final bool selected;
  final bool verified;
  final bool enabled;
  final bool busy;
  final bool operationBlocked;
  final VoidCallback onImport;
  final VoidCallback onVerify;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final legallyBlocked = descriptor.requiresLegalApproval;
    final byteLength = descriptor.files.fold<int>(
      0,
      (total, file) => total + file.byteLength,
    );
    final statusKey = legallyBlocked
        ? 'settings.local_asr_status_legal_gate'
        : enabled
        ? 'settings.local_asr_status_active'
        : selected && verified
        ? 'settings.local_asr_status_selected'
        : verified
        ? 'settings.local_asr_status_verified'
        : selected
        ? 'settings.local_asr_status_unverified'
        : 'settings.local_asr_status_not_imported';
    final statusColor = enabled || verified
        ? ColorConstant.successColor
        : legallyBlocked
        ? ColorConstant.errorColor
        : glass.foregroundSecondary;
    return Semantics(
      container: true,
      label: descriptor.displayName,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      descriptor.displayName,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.3,
                        fontWeight: FontWeight.w700,
                        color: glass.foregroundPrimary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'settings.local_asr_model_metadata'.trParams({
                        'locales': descriptor.locales.join(' / '),
                        'size': formatBytes(byteLength),
                        'license': descriptor.licenseId,
                      }),
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.4,
                        color: glass.foregroundSecondary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    SelectableText(
                      'settings.local_asr_model_provenance'.trParams({
                        'revision': descriptor.sourceRevision,
                        'source': descriptor.sourceRepository,
                        'licenseReference': descriptor.licenseReference,
                      }),
                      style: TextStyle(
                        fontSize: 10,
                        height: 1.45,
                        color: glass.foregroundSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text(
                statusKey.tr,
                textAlign: TextAlign.end,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.3,
                  fontWeight: FontWeight.w700,
                  color: statusColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            legallyBlocked
                ? 'settings.local_asr_model_legal_note'.tr
                : descriptor.engine == DesktopLocalAsrEngine.moonshineV1
                ? 'settings.local_asr_model_moonshine_note'.tr
                : 'settings.local_asr_model_multilingual_note'.tr,
            style: TextStyle(
              fontSize: 11,
              height: 1.4,
              color: glass.foregroundSecondary,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              AppGlassButton(
                label: busy
                    ? 'settings.local_asr_importing'.tr
                    : legallyBlocked
                    ? 'settings.local_asr_legal_locked'.tr
                    : 'settings.local_asr_import'.tr,
                semanticLabel: 'settings.local_asr_import_semantics'.trParams({
                  'model': descriptor.displayName,
                }),
                icon: busy
                    ? Icons.hourglass_top_rounded
                    : legallyBlocked
                    ? Icons.lock_outline_rounded
                    : Icons.folder_open_rounded,
                primary: false,
                minHeight: 44,
                onPressed: operationBlocked || legallyBlocked ? null : onImport,
              ),
              AppGlassButton(
                label: 'settings.local_asr_verify_installed'.tr,
                semanticLabel:
                    '${'settings.local_asr_verify_installed'.tr} ${descriptor.displayName}',
                icon: Icons.verified_outlined,
                primary: false,
                minHeight: 44,
                onPressed: operationBlocked || legallyBlocked ? null : onVerify,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

String _localAsrPackIssueMessage(DesktopLocalAsrPackIssue issue) =>
    switch (issue) {
      DesktopLocalAsrPackIssue.licenseAcknowledgementRequired ||
      DesktopLocalAsrPackIssue.legalApprovalRequired =>
        'settings.local_asr_legal_gate',
      DesktopLocalAsrPackIssue.missingFile ||
      DesktopLocalAsrPackIssue.extraFile ||
      DesktopLocalAsrPackIssue.wrongFileSize ||
      DesktopLocalAsrPackIssue.wrongFileDigest ||
      DesktopLocalAsrPackIssue.unsafeSourcePath ||
      DesktopLocalAsrPackIssue.unsafeFilesystemEntry ||
      DesktopLocalAsrPackIssue.installedPackInvalid =>
        'settings.local_asr_import_invalid',
      DesktopLocalAsrPackIssue.unsupportedHost ||
      DesktopLocalAsrPackIssue.runtimeRetired ||
      DesktopLocalAsrPackIssue.staleMount => 'settings.local_asr_unavailable',
      DesktopLocalAsrPackIssue.unknownModel ||
      DesktopLocalAsrPackIssue.ioFailure => 'settings.local_asr_import_failed',
    };

class _AdvancedPreparingBanner extends StatelessWidget {
  const _AdvancedPreparingBanner();

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return AppSecondaryCard(
      cornerRadius: 16,
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'settings.advanced_features_preparing'.tr,
              style: TextStyle(fontSize: 13, color: glass.foregroundPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

class _ModelConfigSection extends StatelessWidget {
  const _ModelConfigSection();

  @override
  Widget build(BuildContext context) {
    final controller = appServices.find<AgentSettingsController>();
    final glass = MaasoGlassTheme.of(context);
    return _Section(
      title: 'settings.section_model'.tr,
      subtitle: 'settings.section_model_subtitle'.tr,
      child: Column(
        children: [
          AppReactiveBuilder(
            () => Row(
              children: [
                Expanded(
                  child: Text(
                    controller.cloudEnabled.value
                        ? 'settings.cloud_brain_on'.tr
                        : 'settings.cloud_brain_off'.tr,
                    style: TextStyle(
                      fontSize: 13,
                      color: glass.foregroundPrimary,
                    ),
                  ),
                ),
                AppGlassToggle(
                  value: controller.cloudEnabled.value,
                  semanticLabel: controller.cloudEnabled.value
                      ? 'settings.cloud_brain_on'.tr
                      : 'settings.cloud_brain_off'.tr,
                  onChanged: controller.setCloudEnabled,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          AppReactiveBuilder(() {
            final names = [
              for (final p in controller.providers) p.name,
              if (controller.selectedProviderName.value ==
                  AgentSettingsController.customProviderName)
                AgentSettingsController.customProviderName,
            ];
            return _LabeledDropdown<String>(
              icon: Icons.cloud_outlined,
              label: 'settings.provider'.tr,
              value: controller.selectedProviderName.value,
              items: names
                  .map(
                    (n) => DropdownMenuItem(
                      value: n,
                      child: Text(
                        n == AgentSettingsController.customProviderName
                            ? 'settings.provider_custom'.tr
                            : n,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (v) {
                if (v != null) controller.applyProvider(v);
              },
            );
          }),
          const SizedBox(height: 12),
          AppGlassField(
            controller: controller.apiKey,
            obscureText: true,
            labelText: 'settings.api_key'.tr,
            prefixIcon: Icons.vpn_key_rounded,
            decoration: InputDecoration(
              helperText: 'settings.api_key_helper'.tr,
              helperStyle: const TextStyle(fontSize: 11),
            ),
          ),
          const SizedBox(height: 10),
          AppGlassField(
            controller: controller.baseUrl,
            labelText: 'settings.base_url'.tr,
            prefixIcon: Icons.link,
            decoration: InputDecoration(
              helperText: 'settings.base_url_helper'.tr,
              helperStyle: const TextStyle(fontSize: 11),
            ),
          ),
          const SizedBox(height: 10),
          AppReactiveBuilder(() {
            final models = controller.currentModels;
            if (models.isEmpty) {
              return AppGlassField(
                controller: controller.model,
                labelText: 'settings.model'.tr,
                prefixIcon: Icons.auto_awesome,
              );
            }
            final cur = controller.selectedModelId.value;
            final items = [
              if (cur.isNotEmpty && !models.contains(cur)) cur,
              ...models,
            ];
            return _LabeledDropdown<String>(
              icon: Icons.auto_awesome,
              label: 'settings.model'.tr,
              value: cur.isEmpty ? items.first : cur,
              items: items
                  .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                  .toList(),
              onChanged: (v) {
                if (v != null) controller.selectModel(v);
              },
            );
          }),
          const SizedBox(height: 10),
          AppReactiveBuilder(() {
            if (!controller.cloudSaveFailed.value) {
              return const SizedBox.shrink();
            }
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: ColorConstant.errorColor.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.error_outline_rounded,
                    size: 16,
                    color: ColorConstant.errorColor,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'settings.cloud_save_failed'.tr,
                      style: TextStyle(
                        fontSize: 12,
                        color: glass.foregroundPrimary,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: controller.retryCloudSave,
                    child: Text('settings.cloud_save_retry'.tr),
                  ),
                ],
              ),
            );
          }),
          const SizedBox(height: 10),
          const _CloudHealthRow(),
          const SizedBox(height: 10),
          Text(
            'settings.local_key_note'.tr,
            style: TextStyle(fontSize: 11, color: glass.foregroundSecondary),
          ),
        ],
      ),
    );
  }
}

class _LocalVoicePresetSection extends StatelessWidget {
  const _LocalVoicePresetSection();

  @override
  Widget build(BuildContext context) {
    final controller = appServices.find<AgentSettingsController>();
    final glass = MaasoGlassTheme.of(context);
    return _Section(
      title: 'settings.section_language_voice'.tr,
      subtitle: 'settings.section_language_voice_subtitle'.tr,
      child: Column(
        children: [
          AppReactiveBuilder(
            () => _DropdownTile<String>(
              icon: Icons.record_voice_over_rounded,
              iconColor: ColorConstant.primaryColor,
              label: 'settings.tts_voice'.tr,
              value: controller.selectedVoice.value,
              items: AgentSettingsController.voiceOptions
                  .map(
                    (v) =>
                        DropdownMenuItem(value: v.id, child: Text(v.display)),
                  )
                  .toList(),
              onChanged: (v) {
                if (v != null) controller.setVoice(v);
              },
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'settings.language_voice_note'.tr,
            style: TextStyle(fontSize: 11, color: glass.foregroundSecondary),
          ),
        ],
      ),
    );
  }
}

class _RealtimeExperimentSection extends StatelessWidget {
  const _RealtimeExperimentSection();

  @override
  Widget build(BuildContext context) {
    final controller = appServices.find<AgentSettingsController>();
    final glass = MaasoGlassTheme.of(context);
    final capabilities = AppPlatformCapabilities.current();
    return _Section(
      title: 'settings.section_pipeline_mode'.tr,
      subtitle: 'settings.section_pipeline_mode_subtitle'.tr,
      child: AppReactiveBuilder(() {
        final selectedMode = controller.pipelineMode.value;
        final availableModes = AgentPipelineMode.values
            .where((mode) => mode.isAvailableFor(capabilities))
            .toList(growable: false);
        return Column(
          children: [
            for (final mode in availableModes) ...[
              ListTile(
                onTap: () => controller.setPipelineMode(mode),
                contentPadding: const EdgeInsets.symmetric(vertical: 4),
                minLeadingWidth: 28,
                leading: Icon(
                  selectedMode == mode
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  color: selectedMode == mode
                      ? ColorConstant.primaryColor
                      : ColorConstant.textSecondary,
                ),
                title: Text(
                  _pipelineModeTitle(mode),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: glass.foregroundPrimary,
                  ),
                ),
                subtitle: Text(
                  _pipelineModeSubtitle(mode),
                  style: TextStyle(
                    fontSize: 11,
                    color: glass.foregroundSecondary,
                  ),
                ),
                trailing: selectedMode == mode
                    ? const Icon(
                        Icons.check_circle_rounded,
                        color: ColorConstant.primaryColor,
                        size: 18,
                      )
                    : null,
              ),
              if (mode != availableModes.last) const Divider(height: 1),
            ],
          ],
        );
      }),
    );
  }

  String _pipelineModeTitle(AgentPipelineMode mode) {
    switch (mode) {
      case AgentPipelineMode.localFull:
        return 'settings.pipeline_local_full'.tr;
      case AgentPipelineMode.directCloud:
        return 'settings.pipeline_direct_cloud'.tr;
      case AgentPipelineMode.proxyDefault:
        return 'settings.pipeline_proxy_default'.tr;
      case AgentPipelineMode.volcRealtimeAudio:
        return 'settings.pipeline_volc_realtime_audio'.tr;
    }
  }

  String _pipelineModeSubtitle(AgentPipelineMode mode) {
    switch (mode) {
      case AgentPipelineMode.localFull:
        return 'settings.pipeline_local_full_note'.tr;
      case AgentPipelineMode.directCloud:
        return 'settings.pipeline_direct_cloud_note'.tr;
      case AgentPipelineMode.proxyDefault:
        return 'settings.pipeline_proxy_default_note'.tr;
      case AgentPipelineMode.volcRealtimeAudio:
        return 'settings.pipeline_volc_realtime_audio_note'.tr;
    }
  }
}

class _SettingRow extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final Widget trailing;
  const _SettingRow({
    required this.icon,
    required this.color,
    required this.title,
    required this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, size: 17, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.25,
                  color: glass.foregroundPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Flexible(fit: FlexFit.loose, child: trailing),
          ],
        ),
      ),
    );
  }
}

/// Reusable settings row with a left icon + label + right dropdown.
class _DropdownTile<T> extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  const _DropdownTile({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, size: 17, color: iconColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.25,
                  color: glass.foregroundPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Flexible(
              fit: FlexFit.loose,
              child: DropdownButtonHideUnderline(
                child: DropdownButton<T>(
                  isExpanded: true,
                  value: value,
                  items: items,
                  onChanged: onChanged,
                  borderRadius: BorderRadius.circular(12),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontSize: 13,
                    color: glass.foregroundPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Full-width labelled dropdown styled to match [AppTextField] — used for the
/// provider + model selectors, whose values (e.g. long Doubao model ids) need
/// the whole row width and ellipsis rather than a right-aligned chip.
class _LabeledDropdown<T> extends StatelessWidget {
  final IconData icon;
  final String label;
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  const _LabeledDropdown({
    required this.icon,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 4),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: glass.foregroundSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        AppGlassSurface(
          role: AppGlassSurfaceRole.staticSurface,
          behavior: AppGlassSurfaceBehavior.staticSurface,
          cornerRadius: 16,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              Icon(icon, size: 18, color: glass.foregroundSecondary),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<T>(
                    isExpanded: true,
                    value: value,
                    items: items,
                    onChanged: onChanged,
                    borderRadius: BorderRadius.circular(12),
                    icon: Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: glass.foregroundSecondary,
                    ),
                    style: TextStyle(
                      fontSize: 15,
                      color: glass.foregroundPrimary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ─────────────────── Cloud connectivity status ───────────────────

/// Compact cloud-health banner + manual "recheck", bound to
/// [CloudLLMHealthService].  Mirrors the unknown→checking→available|unavailable
/// lifecycle and surfaces the failure reason inline so the user can self-fix.
class _CloudHealthRow extends StatelessWidget {
  const _CloudHealthRow();

  @override
  Widget build(BuildContext context) {
    if (!appServices.isRegistered<CloudLLMHealthService>()) {
      return const SizedBox.shrink();
    }
    final svc = appServices.find<CloudLLMHealthService>();
    final controller = appServices.find<AgentSettingsController>();
    final glass = MaasoGlassTheme.of(context);
    return AppReactiveBuilder(() {
      final h = svc.health.value;
      final (color, icon, text) = _present(h);
      final busy = h.status == CloudLLMStatus.checking;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            busy
                ? SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(color),
                    ),
                  )
                : Icon(icon, size: 16, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: TextStyle(fontSize: 12, color: glass.foregroundPrimary),
              ),
            ),
            // Nothing to verify when the user has turned cloud off.
            if (h.status != CloudLLMStatus.disabled)
              TextButton(
                onPressed: busy ? null : controller.recheckCloudHealth,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(44, 44),
                  tapTargetSize: MaterialTapTargetSize.padded,
                ),
                child: Text('settings.cloud_health_recheck'.tr),
              ),
          ],
        ),
      );
    });
  }

  (Color, IconData, String) _present(CloudLLMHealth h) {
    switch (h.status) {
      case CloudLLMStatus.disabled:
        return (
          ColorConstant.textSecondary,
          Icons.cloud_off_rounded,
          'settings.cloud_health_disabled'.tr,
        );
      case CloudLLMStatus.unknown:
        return (
          ColorConstant.textSecondary,
          Icons.help_outline_rounded,
          'settings.cloud_health_unknown'.tr,
        );
      case CloudLLMStatus.checking:
        return (
          ColorConstant.primaryColor,
          Icons.sync_rounded,
          'settings.cloud_health_checking'.tr,
        );
      case CloudLLMStatus.available:
        if (h.reason == 'degraded') {
          return (
            const Color(0xFFFF8A65),
            Icons.warning_amber_rounded,
            'settings.cloud_health_degraded'.tr,
          );
        }
        final latency = h.latencyMs;
        final text = latency != null
            ? 'settings.cloud_health_available_latency'.trParams({
                'ms': '$latency',
              })
            : 'settings.cloud_health_available'.tr;
        return (const Color(0xFF43A047), Icons.cloud_done_rounded, text);
      case CloudLLMStatus.unavailable:
        return (
          ColorConstant.errorColor,
          Icons.cloud_off_rounded,
          'settings.cloud_health_unavailable'.trParams({
            'reason': _reasonText(h.reason),
          }),
        );
    }
  }

  String _reasonText(String? reason) {
    final key = switch (reason) {
      'unauthorized' => 'settings.cloud_health_reason_unauthorized',
      'model_not_found' => 'settings.cloud_health_reason_model_not_found',
      'not_found' => 'settings.cloud_health_reason_not_found',
      'bad_request' => 'settings.cloud_health_reason_bad_request',
      'rate_limited' => 'settings.cloud_health_reason_rate_limited',
      'timeout' => 'settings.cloud_health_reason_timeout',
      'network' => 'settings.cloud_health_reason_network',
      'server_error' => 'settings.cloud_health_reason_server_error',
      _ => 'settings.cloud_health_reason_unknown',
    };
    return key.tr;
  }
}

/// Settings panel for the P2.5 on-device routing LLM (llamadart).
///
/// Pure observer of [LocalLLMService] — toggle calls enable/disable,
/// progress bar reads .progress, banner reflects .error.  No local state.
class _OnDeviceBrainSection extends StatefulWidget {
  const _OnDeviceBrainSection();

  @override
  State<_OnDeviceBrainSection> createState() => _OnDeviceBrainSectionState();
}

class _OnDeviceBrainSectionState extends State<_OnDeviceBrainSection> {
  bool _starting = false;

  Future<void> _enableLocalBrain() async {
    if (_starting) return;
    setState(() => _starting = true);
    try {
      final svc = await _ensureLocalLlmService();
      await svc.setEnabled(true);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    if (!appServices.isRegistered<LocalLLMService>()) {
      return _Section(
        title: 'settings.on_device_brain'.tr,
        subtitle: 'settings.on_device_brain_subtitle'.tr,
        child: Row(
          children: [
            Expanded(
              child: Text(
                'settings.local_brain_off'.tr,
                style: TextStyle(fontSize: 13, color: glass.foregroundPrimary),
              ),
            ),
            TextButton.icon(
              onPressed: _starting ? null : _enableLocalBrain,
              icon: _starting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download_rounded, size: 16),
              label: Text('settings.local_brain_enable'.tr),
            ),
          ],
        ),
      );
    }
    final svc = appServices.find<LocalLLMService>();
    return _Section(
      title: 'settings.on_device_brain'.tr,
      subtitle: 'settings.on_device_brain_subtitle'.tr,
      child: AppReactiveBuilder(() {
        final enabled = svc.isEnabled.value;
        final loading = svc.isLoading.value;
        final available = svc.isAvailable.value;
        final suppressed = svc.suppressedByCloud.value;
        final err = svc.error.value;
        final received = svc.receivedBytes.value;
        final total = svc.totalBytes.value;
        final eta = svc.etaSeconds.value;
        final hasByteInfo = total > 0 && loading;

        String loadingHint() {
          if (hasByteInfo) {
            final etaStr = eta == null
                ? ''
                : '  ·  ${'common.left_duration'.trParams({'duration': formatDuration(eta)})}';
            final remaining = total - received;
            return 'settings.local_brain_loading_bytes'.trParams({
              'received': formatBytes(received),
              'total': formatBytes(total),
              'remaining': formatBytes(remaining > 0 ? remaining : 0),
              'eta': etaStr,
            });
          }
          if (svc.progress.value > 0) {
            return 'settings.local_brain_loading_progress'.trParams({
              'percent': (svc.progress.value * 100).toStringAsFixed(0),
            });
          }
          return 'settings.local_brain_loading'.tr;
        }

        final downloadedKeys = svc.downloadedKeys;
        final downloadingKey = svc.downloadingKey.value;
        final busy = loading || downloadingKey != null;
        final activeKey = svc.selectedModel.value.key;
        final switchable = LlmModelOption.all
            .where((m) => downloadedKeys.contains(m.key))
            .toList();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    enabled
                        ? 'settings.local_brain_disable'.tr
                        : 'settings.local_brain_enable'.tr,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: glass.foregroundPrimary,
                    ),
                  ),
                ),
                Switch.adaptive(
                  value: enabled,
                  onChanged: busy ? null : (v) => svc.setEnabled(v),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // ── Per-model download rows: each model has its own download /
            //    retry button + progress.  A green check marks the model that
            //    is currently active and successfully started.
            for (final m in LlmModelOption.all) ...[
              _BrainModelRow(
                option: m,
                downloaded: downloadedKeys.contains(m.key),
                isActive: m.key == activeKey,
                isActiveAvailable: enabled && m.key == activeKey && available,
                isDownloading: downloadingKey == m.key,
                progress: svc.downloadProgress[m.key] ?? 0,
                error: svc.downloadError[m.key],
                onDownload: downloadingKey != null
                    ? null
                    : () => svc.downloadModel(m),
              ),
              const SizedBox(height: 8),
            ],
            // ── Switch dropdown: pick which downloaded model is active.
            if (switchable.isNotEmpty) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Text(
                    'settings.local_brain_active_model'.tr,
                    style: TextStyle(
                      fontSize: 13,
                      color: glass.foregroundSecondary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: downloadedKeys.contains(activeKey)
                          ? activeKey
                          : switchable.first.key,
                      underline: const SizedBox.shrink(),
                      onChanged: loading
                          ? null
                          : (key) {
                              if (key == null) return;
                              final m = LlmModelOption.fromKey(key);
                              svc.selectModel(m, enable: enabled);
                            },
                      items: [
                        for (final m in switchable)
                          DropdownMenuItem<String>(
                            value: m.key,
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    m.label.tr,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                                if (m.key == activeKey && available) ...[
                                  const SizedBox(width: 6),
                                  const Icon(
                                    Icons.check_circle_rounded,
                                    size: 16,
                                    color: Color(0xFF2E7D32),
                                  ),
                                ],
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            // Status line — opt-in first, then the current runtime state.
            Text(
              !enabled
                  ? 'settings.local_brain_off'.tr
                  : suppressed
                  ? 'settings.local_brain_standby_cloud'.tr
                  : available
                  ? 'settings.local_brain_active'.tr
                  : loading
                  ? loadingHint()
                  : 'settings.local_brain_enabled_not_loaded'.tr,
              style: TextStyle(fontSize: 13, color: glass.foregroundPrimary),
            ),
            if (loading) ...[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: svc.progress.value > 0 ? svc.progress.value : null,
                  minHeight: 6,
                  backgroundColor: ColorConstant.divider,
                  valueColor: const AlwaysStoppedAnimation<Color>(
                    ColorConstant.primaryColor,
                  ),
                ),
              ),
            ],
            if (err != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: ColorConstant.errorColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.error_outline_rounded,
                          size: 14,
                          color: Color(0xFFB71C1C),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'settings.local_brain_load_failed'.tr,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: glass.foregroundPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'common.request_failed'.tr,
                      maxLines: 5,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: glass.foregroundSecondary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: loading
                            ? null
                            : () => svc.selectModel(
                                svc.selectedModel.value,
                                enable: true,
                              ),
                        icon: const Icon(Icons.refresh_rounded, size: 16),
                        label: Text('common.retry'.tr),
                        style: TextButton.styleFrom(
                          foregroundColor: glass.foregroundPrimary,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: const Size(44, 44),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        );
      }),
    );
  }
}

/// One row of the on-device brain model picker: model name + size on the left,
/// and a context-dependent trailing control — a green check when the model is
/// the active, successfully-started brain; a "downloaded" tag once cached; a
/// download button when missing; a progress bar while fetching; or a retry
/// button after a failed download.
class _BrainModelRow extends StatelessWidget {
  const _BrainModelRow({
    required this.option,
    required this.downloaded,
    required this.isActive,
    required this.isActiveAvailable,
    required this.isDownloading,
    required this.progress,
    required this.error,
    required this.onDownload,
  });

  final LlmModelOption option;
  final bool downloaded;
  final bool isActive;
  final bool isActiveAvailable;
  final bool isDownloading;
  final double progress;
  final String? error;
  final VoidCallback? onDownload;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final pct = (progress * 100).clamp(0, 100);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isActive ? glass.accentSoft : glass.muted,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      option.label.tr,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: glass.foregroundPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      option.approxLabel,
                      style: TextStyle(
                        fontSize: 12,
                        color: glass.foregroundSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _trailing(context, pct),
            ],
          ),
          if (isDownloading) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress > 0 ? progress : null,
                minHeight: 5,
                backgroundColor: ColorConstant.divider,
                valueColor: const AlwaysStoppedAnimation<Color>(
                  ColorConstant.primaryColor,
                ),
              ),
            ),
          ],
          if (error != null && !isDownloading) ...[
            const SizedBox(height: 6),
            Text(
              error!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: glass.foregroundSecondary),
            ),
          ],
        ],
      ),
    );
  }

  Widget _trailing(BuildContext context, num pct) {
    final glass = MaasoGlassTheme.of(context);
    // Active + loaded → the success green check.
    if (isActiveAvailable) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.check_circle_rounded,
            size: 18,
            color: Color(0xFF2E7D32),
          ),
          const SizedBox(width: 4),
          Text(
            'settings.local_brain_started'.tr,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: glass.foregroundPrimary,
            ),
          ),
        ],
      );
    }
    if (isDownloading) {
      return Text(
        '${pct.toStringAsFixed(0)}%',
        style: TextStyle(fontSize: 12, color: glass.foregroundSecondary),
      );
    }
    // Download failed → retry button.
    if (error != null) {
      return TextButton.icon(
        onPressed: onDownload,
        icon: const Icon(Icons.refresh_rounded, size: 16),
        label: Text('common.retry'.tr),
        style: TextButton.styleFrom(
          foregroundColor: glass.foregroundPrimary,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: const Size(44, 44),
        ),
      );
    }
    // Already on disk → downloaded tag.
    if (downloaded) {
      return Text(
        'settings.local_brain_downloaded'.tr,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: glass.foregroundSecondary,
        ),
      );
    }
    // Missing → download button.
    return TextButton.icon(
      onPressed: onDownload,
      icon: const Icon(Icons.download_rounded, size: 16),
      label: Text('settings.local_brain_download'.tr),
      style: TextButton.styleFrom(
        foregroundColor: glass.foregroundPrimary,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(44, 44),
      ),
    );
  }
}

/// Voice (neural TTS) status. Supertonic 3 is initialized only after the user
/// explicitly loads the optional local voice.
class _VoiceSection extends StatefulWidget {
  const _VoiceSection();

  @override
  State<_VoiceSection> createState() => _VoiceSectionState();
}

class _VoiceSectionState extends State<_VoiceSection> {
  bool _starting = false;

  Future<void> _enableLocalVoice() async {
    if (_starting) return;
    setState(() => _starting = true);
    try {
      final tts = await _ensureLocalTtsService();
      await tts.select(TtsEngine.supertonic, enable: true);
      TTSEngineRegistry.current = SherpaTtsEngine();
      await tts.ensureReady().catchError((_) {});
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    if (!appServices.isRegistered<SherpaNeuralTts>()) {
      return _Section(
        title: 'settings.voice'.tr,
        subtitle: 'settings.voice_subtitle'.tr,
        child: Row(
          children: [
            Expanded(
              child: Text(
                'settings.voice_off'.tr,
                style: TextStyle(fontSize: 13, color: glass.foregroundPrimary),
              ),
            ),
            TextButton(
              onPressed: _starting ? null : _enableLocalVoice,
              child: Text(
                _starting
                    ? 'settings.voice_enabled_not_loaded'.tr
                    : 'settings.local_model_load'.tr,
              ),
            ),
          ],
        ),
      );
    }
    final tts = appServices.find<SherpaNeuralTts>();

    return _Section(
      title: 'settings.voice'.tr,
      subtitle: 'settings.voice_subtitle'.tr,
      child: AppReactiveBuilder(() {
        final ready = tts.isReady.value;
        final loading = tts.isLoading.value;
        final enabled = tts.enabled.value;
        final pct = (tts.downloadProgress.value * 100).clamp(0, 100);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    !enabled
                        ? 'settings.voice_off'.tr
                        : ready
                        ? 'settings.voice_ready'.tr
                        : loading
                        ? 'settings.voice_downloading'.trParams({
                            'percent': pct.toStringAsFixed(0),
                          })
                        : 'settings.voice_enabled_not_loaded'.tr,
                    style: TextStyle(
                      fontSize: 13,
                      color: glass.foregroundPrimary,
                    ),
                  ),
                ),
                if (ready)
                  const Icon(
                    Icons.check_circle_rounded,
                    size: 20,
                    color: Color(0xFF43A047),
                  )
                else
                  TextButton(
                    onPressed: loading ? null : _enableLocalVoice,
                    child: Text('settings.local_model_load'.tr),
                  ),
              ],
            ),
            if (loading) ...[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: tts.downloadProgress.value > 0
                      ? tts.downloadProgress.value
                      : null,
                  minHeight: 6,
                  backgroundColor: ColorConstant.divider,
                  valueColor: const AlwaysStoppedAnimation<Color>(
                    ColorConstant.primaryColor,
                  ),
                ),
              ),
            ],
          ],
        );
      }),
    );
  }
}

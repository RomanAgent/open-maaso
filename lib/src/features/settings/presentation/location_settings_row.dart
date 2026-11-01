import 'dart:async';

import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/location_service.dart';
import 'package:maaso/src/features/settings/presentation/settings_frost_components.dart';

/// The existing hardware-permission row. Permission requests are made only
/// from a user's tap; mounting and returning from Settings only inspect status.
class LocationSettingsRow extends StatefulWidget {
  const LocationSettingsRow({this.service, super.key});

  final LocationService? service;

  @override
  State<LocationSettingsRow> createState() => _LocationSettingsRowState();
}

class _LocationSettingsRowState extends State<LocationSettingsRow>
    with WidgetsBindingObserver {
  bool _working = false;
  bool _checking = false;
  String? _error;

  LocationService? get _service =>
      widget.service ?? appServices.maybeFind<LocationService>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refreshPermission());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshPermission());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _refreshPermission() async {
    final service = _service;
    if (service == null || service.isClosed || _working || _checking) return;
    setState(() => _checking = true);
    try {
      await service.refreshPermission();
    } catch (_) {
      if (mounted && identical(_service, service)) {
        setState(() => _error = 'settings.location_action_failed'.tr);
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _run(
    LocationService service,
    Future<void> Function() operation, {
    required String errorKey,
  }) async {
    if (_working || service.isClosed || !identical(_service, service)) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await operation();
    } catch (_) {
      if (identical(_service, service)) _error = errorKey.tr;
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _setEnabled(LocationService service, bool enabled) =>
      _run(service, () async {
        await service.setEnabled(enabled);
        if (enabled && identical(_service, service)) {
          try {
            await service.locate(requestPermission: true);
          } catch (_) {
            if (identical(_service, service)) {
              _error = 'settings.location_action_failed'.tr;
            }
          }
        }
      }, errorKey: 'settings.location_save_failed');

  Future<void> _act(LocationService service, LocationStatus status) => _run(
    service,
    () async {
      if (status == LocationStatus.deniedForever) {
        if (!await service.openAppSettings() && identical(_service, service)) {
          _error = 'settings.location_settings_failed'.tr;
        }
      } else if (status == LocationStatus.servicesDisabled) {
        if (!await service.openLocationSettings() &&
            identical(_service, service)) {
          _error = 'settings.location_settings_failed'.tr;
        }
      } else {
        await service.locate(requestPermission: true);
      }
    },
    errorKey: 'settings.location_action_failed',
  );

  @override
  Widget build(BuildContext context) {
    final service = _service;
    return AppReactiveBuilder(() {
      final snapshot = service?.state.value;
      final status = snapshot?.status ?? LocationStatus.unavailable;
      final enabled = service?.enabled.value ?? false;
      final retired = status == LocationStatus.retired;
      final busy = _working || _checking || status == LocationStatus.locating;
      final usable = service != null && !service.isClosed && !retired;
      final subtitle = _checking
          ? 'settings.location_checking'.tr
          : status == LocationStatus.unavailable && service?.isSupported == true
          ? 'settings.location_action_failed'.tr
          : _statusText(status, snapshot?.cityQuery);
      final actionVisible =
          usable &&
          service.isSupported &&
          enabled &&
          status != LocationStatus.disabled;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsFrostSwitch(
            tileKey: const ValueKey('settings-location-enabled'),
            icon: Icons.location_on_outlined,
            title: 'settings.location'.tr,
            subtitle: Semantics(
              liveRegion: true,
              child: Text(
                subtitle,
                key: const ValueKey('settings-location-status'),
              ),
            ),
            value: enabled && !retired,
            onChanged: usable && !busy
                ? (value) => _setEnabled(service, value)
                : null,
          ),
          if (actionVisible)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 34),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton(
                  key: const ValueKey('settings-location-action'),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    padding: EdgeInsets.zero,
                    alignment: AlignmentDirectional.centerStart,
                  ),
                  onPressed: busy ? null : () => _act(service, status),
                  child: Text(_actionLabel(status).tr),
                ),
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 34, top: 8),
              child: Text(
                _error!,
                key: const ValueKey('settings-location-error'),
                style: TextStyle(
                  fontSize: 13,
                  height: 20 / 13,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
        ],
      );
    });
  }

  String _statusText(LocationStatus status, String? city) => switch (status) {
    LocationStatus.available when city != null && city.trim().isNotEmpty =>
      'settings.location_current_city'.trParams({'city': city}),
    LocationStatus.available => 'settings.location_allowed'.tr,
    LocationStatus.idle => 'settings.location_allowed'.tr,
    LocationStatus.permissionRequired =>
      '${'settings.location_not_authorized'.tr}. ${'settings.location_hint'.tr}',
    LocationStatus.locating => 'settings.location_loading'.tr,
    LocationStatus.disabled => 'settings.location_disabled'.tr,
    LocationStatus.denied => 'settings.location_denied'.tr,
    LocationStatus.deniedForever => 'settings.location_denied_forever'.tr,
    LocationStatus.servicesDisabled => 'settings.location_system_disabled'.tr,
    LocationStatus.cityUnavailable => 'settings.location_city_unavailable'.tr,
    LocationStatus.timeout ||
    LocationStatus.cancelled => 'settings.location_action_failed'.tr,
    LocationStatus.unavailable ||
    LocationStatus.retired => 'settings.location_unavailable'.tr,
  };

  String _actionLabel(LocationStatus status) => switch (status) {
    LocationStatus.deniedForever ||
    LocationStatus.servicesDisabled => 'settings.location_open_settings',
    LocationStatus.available => 'settings.location_refresh',
    LocationStatus.unavailable => 'common.retry',
    _ => 'settings.location_allow',
  };
}

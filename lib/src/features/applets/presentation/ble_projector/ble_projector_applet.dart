import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:maaso/src/features/widgets_hub/presentation/applet_player_like_button.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:image_picker/image_picker.dart';

import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary.dart';
import 'package:maaso/src/core/services/ble/ble_transport_service.dart'
    show BleScanEntry;
import 'package:maaso/src/core/services/ble/yoturetoys/yoturetoys_device.dart';

/// Official applet: control panel for the **Yoturetoys AI Drawing Projector**.
///
/// On open it auto-scans, auto-connects when a single projector is found, and
/// then renders the device panel. It drives the SAME [YoturetoysDevice] facade
/// the dialogue skill uses — no duplicate BLE logic.
class BleProjectorApplet extends StatefulWidget {
  const BleProjectorApplet({super.key});

  @override
  State<BleProjectorApplet> createState() => _BleProjectorAppletState();
}

class _BleProjectorAppletState extends State<BleProjectorApplet> {
  YoturetoysDevice get _device => appServices.find<YoturetoysDevice>();

  final _urlCtrl = TextEditingController();
  final _dio = Dio();
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoStart());
  }

  Future<void> _autoStart() async {
    if (!_device.bluetoothAvailable) return;
    if (_device.isConnected.value) return;
    setState(() => _error = null);
    try {
      await _device.scanAndAutoConnect(seconds: 8);
    } catch (error) {
      debugPrint('[BleProjector] automatic scan failed: $error');
      if (mounted) setState(() => _error = 'applet.projector.scan_failed'.tr);
    }
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshots = appServices.maybeFind<AppCapabilitySnapshotService>();
    if (snapshots == null) return _buildScaffold(bluetoothAvailable: true);
    return ListenableBuilder(
      listenable: snapshots,
      builder: (context, _) =>
          _buildScaffold(bluetoothAvailable: _device.bluetoothAvailable),
    );
  }

  Widget _buildScaffold({required bool bluetoothAvailable}) {
    return AppSecondaryScaffold(
      header: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            AppGlassIconButton(
              key: const ValueKey('applet-player-back'),
              size: 48,
              icon: Icons.arrow_back_rounded,
              tooltip: 'common.back'.tr,
              onPressed: appNavigation.pop,
            ),
            const AppletPlayerLikeButton(
              appletId: 'ble_yoturetoys_projector',
              official: true,
            ),
          ],
        ),
      ),
      body: !bluetoothAvailable
          ? AppSecondaryStateView(
              key: const Key('projector-capability-unavailable'),
              kind: AppSecondaryStateKind.error,
              title: 'common.action_unavailable'.tr,
              icon: Icons.bluetooth_disabled_rounded,
            )
          : AppReactiveBuilder(() {
              if (_device.isConnected.value) return _connectedPanel();
              return _discoveryPanel();
            }),
    );
  }

  // —————————————————— discovery (scan / pick) ——————————————————

  Widget _discoveryPanel() {
    final glass = MaasoGlassTheme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
      children: [
        const SizedBox(height: 24),
        AppSecondaryCard(
          child: Center(
            child: AppReactiveBuilder(() {
              final scanning = _device.isScanning.value;
              return Column(
                children: [
                  Icon(
                    scanning
                        ? Icons.bluetooth_searching_rounded
                        : Icons.bluetooth_rounded,
                    size: 64,
                    color: ColorConstant.secondaryColor,
                  ),
                  const SizedBox(height: 14),
                  Text(
                    scanning
                        ? 'applet.projector.scanning'.tr
                        : 'applet.projector.scan_hint'.tr,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: glass.foregroundSecondary,
                      fontSize: 13,
                    ),
                  ),
                ],
              );
            }),
          ),
        ),
        const SizedBox(height: 20),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: AppSecondaryCard(
              tone: AppSecondaryCardTone.danger,
              padding: const EdgeInsets.all(12),
              child: Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: glass.foregroundPrimary, fontSize: 12),
              ),
            ),
          ),
        AppReactiveBuilder(() {
          final entries = _device.found.values.toList();
          if (entries.isEmpty) return const SizedBox.shrink();
          return Column(children: [for (final e in entries) _foundTile(e)]);
        }),
        const SizedBox(height: 16),
        Center(
          child: AppGlassButton(
            label: 'applet.projector.rescan'.tr,
            icon: Icons.refresh_rounded,
            onPressed: _autoStart,
            fullWidth: false,
            color: ColorConstant.accentColor.withValues(alpha: 0.62),
          ),
        ),
      ],
    );
  }

  Widget _foundTile(BleScanEntry e) {
    final glass = MaasoGlassTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppSecondaryCard(
        padding: EdgeInsets.zero,
        child: ListTile(
          leading: const Icon(
            Icons.cast_rounded,
            color: ColorConstant.secondaryColor,
          ),
          title: Text(e.label ?? YoturetoysDevice.productName),
          subtitle: e.sn != null ? Text('SN ${e.sn}') : null,
          trailing: Text(
            '${e.rssi} dBm',
            style: TextStyle(fontSize: 11, color: glass.foregroundSecondary),
          ),
          onTap: () => _connect(e.device),
        ),
      ),
    );
  }

  Future<void> _connect(BluetoothDevice device) async {
    if (!_device.bluetoothAvailable) return;
    setState(() => _error = null);
    try {
      await _device.connect(device);
    } catch (error) {
      debugPrint('[BleProjector] connection failed: $error');
      if (mounted) {
        setState(() => _error = 'applet.projector.connect_failed'.tr);
      }
    }
  }

  // —————————————————— connected panel ——————————————————

  Widget _connectedPanel() {
    final glass = MaasoGlassTheme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
      children: [
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: TextButton(
            onPressed: () => _device.disconnect(),
            child: Text('applet.projector.disconnect'.tr),
          ),
        ),

        AppReactiveBuilder(() {
          final info = _device.info.value;
          return _card(
            child: Row(
              children: [
                const Icon(
                  Icons.check_circle_rounded,
                  color: ColorConstant.secondaryColor,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        YoturetoysDevice.productName,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: glass.foregroundPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        info == null
                            ? 'applet.projector.connected'.tr
                            : 'SN ${info.sn}  ·  v${info.firmwareVersion}',
                        style: TextStyle(
                          fontSize: 12,
                          color: glass.foregroundSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }),
        const SizedBox(height: 16),
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'applet.projector.project_title'.tr,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: glass.foregroundPrimary,
                ),
              ),
              const SizedBox(height: 10),
              AppReactiveBuilder(() {
                final busy = _device.isTransferring.value;
                return SizedBox(
                  width: double.infinity,
                  child: AppGlassButton(
                    label: 'applet.projector.pick_gallery'.tr,
                    icon: Icons.photo_library_rounded,
                    onPressed: busy ? null : _pickFromGallery,
                    fullWidth: true,
                    color: ColorConstant.primaryColor.withValues(alpha: 0.62),
                  ),
                );
              }),
              const SizedBox(height: 14),
              Row(
                children: [
                  const Expanded(child: Divider(color: ColorConstant.divider)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      'applet.projector.or_url'.tr,
                      style: TextStyle(
                        fontSize: 11,
                        color: glass.foregroundSecondary,
                      ),
                    ),
                  ),
                  const Expanded(child: Divider(color: ColorConstant.divider)),
                ],
              ),
              const SizedBox(height: 10),
              AppGlassField(
                controller: _urlCtrl,
                hintText: 'applet.projector.url_hint'.tr,
                keyboardType: TextInputType.url,
              ),
              const SizedBox(height: 12),
              AppReactiveBuilder(() {
                final busy = _device.isTransferring.value;
                return Column(
                  children: [
                    if (busy)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: LinearProgressIndicator(
                          value: _device.transferProgress.value,
                          color: ColorConstant.primaryColor,
                          backgroundColor: ColorConstant.divider,
                        ),
                      ),
                    SizedBox(
                      width: double.infinity,
                      child: AppGlassButton(
                        label: busy
                            ? 'applet.projector.sending'.tr
                            : 'applet.projector.project'.tr,
                        icon: Icons.send_rounded,
                        onPressed: busy ? null : _projectUrl,
                        fullWidth: true,
                        color: ColorConstant.secondaryColor.withValues(
                          alpha: 0.62,
                        ),
                      ),
                    ),
                  ],
                );
              }),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(
                    color: glass.foregroundPrimary,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _pickFromGallery() async {
    setState(() => _error = null);
    try {
      await _device.runAccountOperation(() async {
        final picked = await ImagePicker().pickImage(
          source: ImageSource.gallery,
        );
        if (picked == null) return; // user cancelled
        final bytes = await picked.readAsBytes();
        await _project(bytes);
      });
    } catch (error) {
      debugPrint('[BleProjector] gallery projection failed: $error');
      if (mounted) {
        setState(() => _error = 'applet.projector.project_failed'.tr);
      }
    }
  }

  Future<void> _projectUrl() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) return;
    setState(() => _error = null);
    try {
      await _device.runAccountOperation(() async {
        final res = await _dio.get<List<int>>(
          url,
          options: Options(responseType: ResponseType.bytes),
        );
        final bytes = res.data;
        if (bytes == null || bytes.isEmpty) {
          if (mounted) {
            setState(() => _error = 'applet.projector.load_failed'.tr);
          }
          return;
        }
        await _project(bytes);
      });
    } catch (error) {
      debugPrint('[BleProjector] URL projection failed: $error');
      if (mounted) {
        setState(() => _error = 'applet.projector.project_failed'.tr);
      }
    }
  }

  Future<void> _project(List<int> bytes) async {
    await _device.projectImage(bytes);
    if (mounted) {
      showAppGlassNotice(
        title: 'applet.projector.name'.tr,
        message: 'applet.projector.done'.tr,
        icon: Icons.check_circle_rounded,
      );
    }
  }

  Widget _card({required Widget child}) {
    return AppSecondaryCard(padding: const EdgeInsets.all(16), child: child);
  }
}

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../core/foundation/app_framework.dart';
import '../core/services/ble/ble_transport_service.dart';
import '../core/services/ble/yoturetoys/yoturetoys_device.dart';

/// Lazily uses the app's single existing radio stack; never scans at bootstrap.
class OfflineHardwareController extends ChangeNotifier {
  OfflineHardwareController({BleTransportService Function()? transportFactory})
    : _transportFactory = transportFactory ?? BleTransportService.new;
  final BleTransportService Function() _transportFactory;
  BleTransportService? _transport;
  YoturetoysDevice? _device;
  final List<Worker> _workers = [];
  bool busy = false;
  String? error;
  bool get initialized => _device != null;
  bool get connected => _device?.isConnected.value ?? false;
  bool get scanning => _device?.isScanning.value ?? false;
  List<BleScanEntry> get devices => _device?.found.values.toList() ?? [];
  double get progress => _device?.transferProgress.value ?? 0;
  void _install() {
    if (_device != null) {
      _device!.activateAccount(accountScopeKey: 'open-maaso:offline:test');
      return;
    }
    _transport =
        appServices.peek<BleTransportService>() ??
        appServices.put(_transportFactory());
    _device =
        appServices.peek<YoturetoysDevice>() ??
        appServices.put(YoturetoysDevice(_transport!));
    _device!.activateAccount(accountScopeKey: 'open-maaso:offline:test');
    _workers.addAll([
      ever(_device!.isConnected, (_) => notifyListeners()),
      ever(_device!.isScanning, (_) => notifyListeners()),
      ever(_device!.found, (_) => notifyListeners()),
      ever(_device!.transferProgress, (_) => notifyListeners()),
    ]);
  }

  Future<void> scan() async {
    if (busy) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      _install();
      await _device!.scan(seconds: 10);
    } catch (_) {
      error = '无法扫描，请检查设备蓝牙和系统权限。';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> connect(BleScanEntry entry) async {
    if (busy) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      _install();
      await _device!.connect(entry.device);
    } catch (_) {
      error = '连接未完成，请靠近设备后重试。';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    try {
      await _device?.disconnect();
    } catch (_) {
      error = '设备尚未断开，请重试。';
    }
    notifyListeners();
  }

  Future<void> project(Uint8List bytes) async {
    if (busy || !connected) throw StateError('Device not ready');
    if (bytes.length > 8 * 1024 * 1024) {
      throw const FormatException('Image too large');
    }
    busy = true;
    error = null;
    notifyListeners();
    try {
      await _device!.projectImage(bytes);
    } catch (_) {
      error = '图片未发送成功，请检查设备连接。';
      rethrow;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> stopScan() async {
    await _device?.stopScan();
  }

  Future<void> retire() async {
    await _device?.deactivateAccountAndDrain();
  }

  @override
  void dispose() {
    for (final w in _workers) {
      w.dispose();
    }
    unawaited(retire());
    super.dispose();
  }
}

class OfflineHardwarePage extends StatefulWidget {
  const OfflineHardwarePage({
    super.key,
    required this.controller,
    required this.pickImage,
  });
  final OfflineHardwareController controller;
  final Future<Uint8List?> Function() pickImage;
  @override
  State<OfflineHardwarePage> createState() => _OfflineHardwarePageState();
}

class _OfflineHardwarePageState extends State<OfflineHardwarePage> {
  @override
  void dispose() {
    unawaited(widget.controller.stopScan());
    super.dispose();
  }

  Future<void> sendImage() async {
    try {
      final bytes = await widget.pickImage();
      if (bytes == null || !mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('发送到已连接的投影仪？'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.memory(
                bytes,
                height: 180,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const Text('图片无法预览'),
              ),
              const SizedBox(height: 12),
              const Text('图片仅通过蓝牙发送，不上传服务器。'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认发送'),
            ),
          ],
        ),
      );
      if (confirmed == true) await widget.controller.project(bytes);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未发送图片，请选择有效的 PNG/JPEG 并检查蓝牙连接。')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return ListenableBuilder(
      listenable: c,
      builder: (_, _) => Scaffold(
        appBar: AppBar(title: const Text('本地蓝牙投影仪')),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text('使用现有 Yoturetoys 协议直接连接附近设备。只有点击扫描才请求蓝牙权限。'),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: c.busy ? null : c.scan,
              icon: const Icon(Icons.bluetooth_searching),
              label: Text(c.scanning ? '正在扫描…' : '扫描附近设备'),
            ),
            if (c.error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(c.error!),
              ),
            for (final entry in c.devices)
              ListTile(
                title: Text(entry.label ?? 'Yoturetoys 投影仪'),
                subtitle: Text(entry.id),
                onTap: c.busy ? null : () => c.connect(entry),
              ),
            if (c.connected) ...[
              const ListTile(
                leading: Icon(Icons.bluetooth_connected),
                title: Text('设备已连接'),
              ),
              FilledButton.icon(
                onPressed: c.busy ? null : sendImage,
                icon: const Icon(Icons.photo_outlined),
                label: const Text('选择本地图片投影'),
              ),
              TextButton(onPressed: c.disconnect, child: const Text('断开连接')),
            ],
            if (c.busy)
              LinearProgressIndicator(
                value: c.progress > 0 ? c.progress : null,
              ),
          ],
        ),
      ),
    );
  }
}

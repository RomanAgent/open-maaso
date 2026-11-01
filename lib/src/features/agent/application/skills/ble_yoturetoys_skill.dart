import 'dart:convert';
import 'dart:io';

import 'package:image_picker/image_picker.dart';
import 'package:dio/dio.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/core/services/ble/yoturetoys/yoturetoys_device.dart';

/// Secondary ("二级") skill for the **Yoturetoys AI Drawing Projector**.
///
/// Implements that device's protocol verbs on top of [YoturetoysDevice]. It
/// assumes the parent [BluetoothSkill] already connected the radio — if not,
/// each method returns a clear error so the agent knows to connect first.
class BleYoturetoysSkill extends AgentSkill {
  BleYoturetoysSkill({this.agentId});
  final String? agentId;

  /// Injectable for tests: returns chosen image bytes, or null if cancelled.
  /// Defaults to the native gallery picker (same call the Hub applet uses).
  Future<List<int>?> Function() galleryPicker = _defaultGalleryPicker;

  static Future<List<int>?> _defaultGalleryPicker() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return null;
    return picked.readAsBytes();
  }

  static const _maxBytes = 8 * 1024 * 1024; // refuse absurd inputs
  static final _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 20),
      responseType: ResponseType.bytes,
    ),
  );

  @override
  String get skillName => 'BleYoturetoys';

  @override
  String get description =>
      'Control the Yoturetoys AI Drawing Projector over Bluetooth: project a '
      'picture onto it, switch to a stored artwork, or toggle its voice. '
      'To project a picture: first call bluetoothConnect (it auto-scans), then '
      'ask the user whether to use a gallery photo or a web image. For gallery '
      'use projectorSendGallery; for web, either project a URL the user gives '
      'with projectorTransferImage {"image": url} or find one with imageSearch '
      'and project results[0].url. If the user '
      'answers that question with a bare subject like "cat" or "silly cat", '
      'treat it as the web image query and do not drift into chatting about it.';

  YoturetoysDevice get _device => appServices.find<YoturetoysDevice>();

  /// How long to wait for an in-flight connection before giving up. The
  /// connection action can still be settling when a send arrives on the next
  /// turn, so briefly wait for it instead of failing immediately.
  Duration connectWait = const Duration(seconds: 12);

  Future<bool> _ensureConnected() async {
    if (!appServices.isRegistered<YoturetoysDevice>()) return false;
    if (_device.isConnected.value) return true;
    final deadline = DateTime.now().add(connectWait);
    while (!_device.isConnected.value && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    return _device.isConnected.value;
  }

  @override
  Map<String, dynamic Function(List<dynamic>)> get methods => {
    'projectorTransferImage': _transferImage,
    'projectorSendGallery': (_) => _sendGallery(),
    'projectorSetVoice': _setVoice,
    'projectorStatus': (_) => _status(),
  };

  @override
  Map<String, Map<String, dynamic>>? get nativeToolSchemas => {
    'projectorTransferImage': {
      'type': 'object',
      'properties': {
        'image': {
          'type': 'string',
          'description':
              'Image to project: https URL, local file path, data: URI, or base64.',
        },
        'quality': {
          'type': 'integer',
          'description': 'JPEG quality 1-100 (default 80).',
        },
      },
      'required': ['image'],
    },
    'projectorSendGallery': {'type': 'object', 'properties': {}},
    'projectorSetVoice': {
      'type': 'object',
      'properties': {
        'enable': {'type': 'boolean'},
      },
      'required': ['enable'],
    },
    'projectorStatus': {'type': 'object', 'properties': {}},
  };

  @override
  Map<String, String> get nativeMethodDescriptions => const {
    'projectorTransferImage':
        'Project an image onto the connected Yoturetoys projector.',
    'projectorSendGallery':
        'Open the photo gallery, let the user pick a photo, and project it.',
    'projectorSetVoice': 'Turn the projector\'s voice on or off.',
    'projectorStatus': 'Report the projector connection + transfer progress.',
  };

  // ─────────────────────────── implementation ───────────────────────────

  Future<String> _transferImage(List<dynamic> args) =>
      _device.runAccountOperation(() => _transferImageActive(args));

  Future<String> _transferImageActive(List<dynamic> args) async {
    try {
      if (!await _ensureConnected()) {
        return jsonEncode({'error': 'projector_not_connected'});
      }
      final map = _decode(args);
      final src = map['image']?.toString() ?? '';
      if (src.isEmpty) return jsonEncode({'error': 'missing_image'});
      final quality = (map['quality'] as num?)?.toInt() ?? 80;

      final bytes = await _resolveBytes(src);
      if (bytes == null || bytes.isEmpty) {
        return jsonEncode({'error': 'image_load_failed'});
      }
      if (bytes.length > _maxBytes) {
        return jsonEncode({'error': 'image_too_large'});
      }

      await _device.projectImage(bytes, quality: quality.clamp(1, 100));
      return jsonEncode({'ok': true});
    } catch (error) {
      Log.w('[BleYoturetoys] transfer failed: $error');
      return jsonEncode({'error': 'execution_failed'});
    }
  }

  /// Open the gallery, let the user pick a photo, and project it. One call =
  /// pick + send, so the agent invokes this right after the user says "gallery".
  Future<String> _sendGallery() =>
      _device.runAccountOperation(_sendGalleryActive);

  Future<String> _sendGalleryActive() async {
    try {
      if (!await _ensureConnected()) {
        return jsonEncode({'error': 'projector_not_connected'});
      }
      final bytes = await galleryPicker();
      if (bytes == null) {
        return jsonEncode({'cancelled': true});
      }
      if (bytes.isEmpty) {
        return jsonEncode({'error': 'empty_image'});
      }
      if (bytes.length > _maxBytes) {
        return jsonEncode({'error': 'image_too_large'});
      }
      await _device.projectImage(bytes);
      return jsonEncode({'ok': true});
    } catch (error) {
      Log.w('[BleYoturetoys] gallery send failed: $error');
      return jsonEncode({'error': 'execution_failed'});
    }
  }

  Future<String> _setVoice(List<dynamic> args) =>
      _device.runAccountOperation(() => _setVoiceActive(args));

  Future<String> _setVoiceActive(List<dynamic> args) async {
    try {
      if (!_device.isConnected.value) {
        return jsonEncode({'error': 'projector_not_connected'});
      }
      final map = _decode(args);
      await _device.setVoice(map['enable'] == true);
      return jsonEncode({'ok': true});
    } catch (error) {
      Log.w('[BleYoturetoys] voice update failed: $error');
      return jsonEncode({'error': 'execution_failed'});
    }
  }

  Future<String> _status() => _device.runAccountOperation(_statusActive);

  Future<String> _statusActive() async {
    final i = _device.info.value;
    return jsonEncode({
      'connected': _device.isConnected.value,
      'transferring': _device.isTransferring.value,
      'progress': _device.transferProgress.value,
      if (i != null)
        'device': {
          'product': YoturetoysDevice.productName,
          'sn': i.sn,
          'firmware': i.firmwareVersion,
        },
    });
  }

  Map _decode(List<dynamic> args) {
    if (args.isEmpty) return const {};
    final raw = args[0];
    final d = raw is String ? jsonDecode(raw) : raw;
    return d is Map ? d : const {};
  }

  /// Resolve an image reference to raw bytes. Supports https URLs, data: URIs,
  /// local file paths (incl. file://), and bare base64.
  Future<List<int>?> _resolveBytes(String src) async {
    final s = src.trim();
    if (s.startsWith('data:')) {
      final comma = s.indexOf(',');
      if (comma < 0) return null;
      return base64Decode(s.substring(comma + 1));
    }
    if (s.startsWith('http://') || s.startsWith('https://')) {
      final res = await _dio.get<List<int>>(s);
      return res.data;
    }
    final path = s.startsWith('file://') ? Uri.parse(s).toFilePath() : s;
    final file = File(path);
    if (await file.exists()) return file.readAsBytes();
    // last resort: maybe it's bare base64
    try {
      return base64Decode(s);
    } catch (_) {
      return null;
    }
  }
}

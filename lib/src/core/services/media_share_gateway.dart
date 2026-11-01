import 'dart:io';

import 'package:flutter/services.dart';
import 'package:maaso/src/core/foundation/app_localization.dart';

abstract interface class MediaShareGateway {
  Future<bool> share({required String text, String? filePath, Rect? origin});
}

class PlatformMediaShareGateway implements MediaShareGateway {
  const PlatformMediaShareGateway({
    MethodChannel channel = const MethodChannel('maaso/share'),
  }) : _channel = channel;

  final MethodChannel _channel;

  @override
  Future<bool> share({
    required String text,
    String? filePath,
    Rect? origin,
  }) async {
    final normalizedPath = filePath?.trim();
    final hasFile =
        normalizedPath != null &&
        normalizedPath.isNotEmpty &&
        await File(normalizedPath).exists();
    try {
      final launched = await _channel.invokeMethod<bool>(
        'share',
        <String, Object?>{
          'title': 'common.share'.tr,
          'text': text,
          if (hasFile) 'filePath': normalizedPath,
          if (origin != null)
            'origin': <String, double>{
              'left': origin.left,
              'top': origin.top,
              'width': origin.width,
              'height': origin.height,
            },
        },
      );
      return launched == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}

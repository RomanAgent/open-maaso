import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:maaso/src/core/services/avatar_model_upload_cover.dart';

Uint8List avatarCoverPngBytes({int width = 96, int height = 144}) =>
    img.encodePng(img.Image(width: width, height: height));

Future<AvatarModelUploadCover> avatarUploadCoverFixture() =>
    AvatarModelUploadCover.fromBytes(
      fileName: 'lumen-cover.png',
      bytes: avatarCoverPngBytes(),
    );

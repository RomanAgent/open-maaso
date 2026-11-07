import 'dart:async';
import 'dart:math' as math;
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_execution_contract.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:maaso/src/core/network/backend_client.dart';
import 'package:image/image.dart' as image;
import 'package:sembast/sembast.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/chat_attachment.dart';
import 'package:maaso/src/features/agent/application/project_build/project_reference_input.dart';

final class PreparedChatMedia {
  const PreparedChatMedia(this.attachment, this.bytes, this.mime);
  final ChatAttachment attachment;
  final Uint8List bytes;
  final String mime;
}

/// Re-encodes images to remove EXIF and bounds decoded pixels before resizing.
PreparedChatMedia normalizeChatImage(Uint8List bytes) {
  if (bytes.length < 12 || bytes.length > 20 * 1024 * 1024) {
    throw const FormatException('image_size');
  }
  final decoder = image.findDecoderForData(bytes);
  final info = decoder?.startDecode(bytes);
  if (info == null ||
      info.width <= 0 ||
      info.height <= 0 ||
      info.width * info.height > 40000000) {
    throw const FormatException('image_dimensions');
  }
  var decoded = decoder!.decodeFrame(0);
  if (decoded == null) throw const FormatException('image_decode');
  decoded = image.bakeOrientation(decoded);
  if (decoded.width > 1600 || decoded.height > 1600) {
    decoded = image.copyResize(
      decoded,
      width: decoded.width >= decoded.height ? 1600 : null,
      height: decoded.height > decoded.width ? 1600 : null,
    );
  }
  final clean = image.Image(
    width: decoded.width,
    height: decoded.height,
    numChannels: 3,
  );
  image.compositeImage(clean, decoded);
  final data = Uint8List.fromList(image.encodeJpg(clean, quality: 82));
  final thumb = image.copyResize(
    clean,
    width: clean.width >= clean.height ? 240 : null,
    height: clean.height > clean.width ? 240 : null,
  );
  final thumbnail = base64Encode(image.encodeJpg(thumb, quality: 65));
  return PreparedChatMedia(
    ChatAttachment(
      id: sha256.convert(data).toString(),
      kind: 'image',
      byteLength: data.length,
      thumbnailJpeg: thumbnail,
    ),
    data,
    'image/jpeg',
  );
}

/// Validates original generated images without normalizing their encoding/alpha.
/// Decode limits are checked before allocating the full pixel buffer.
PreparedChatMedia prepareInvocationImage(AppInvocationProducedImage output) {
  final bytes = output.bytes;
  final png =
      bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47 &&
      bytes[4] == 13 &&
      bytes[5] == 10 &&
      bytes[6] == 26 &&
      bytes[7] == 10;
  final jpeg =
      bytes.length >= 4 &&
      bytes[0] == 0xff &&
      bytes[1] == 0xd8 &&
      bytes[bytes.length - 2] == 0xff &&
      bytes.last == 0xd9;
  if (bytes.isEmpty ||
      bytes.length > appInvocationMaximumImageBytes ||
      (output.mime == 'image/png'
          ? !png
          : output.mime == 'image/jpeg'
          ? !jpeg
          : true)) {
    throw const FormatException('invocation_image_signature');
  }
  final decoder = output.mime == 'image/png'
      ? image.PngDecoder()
      : image.JpegDecoder();
  final info = decoder.startDecode(bytes);
  if (info == null ||
      info.width <= 0 ||
      info.height <= 0 ||
      info.width > 4096 ||
      info.height > 4096 ||
      info.width * info.height > 12000000 ||
      decoder.numFrames() != 1) {
    throw const FormatException('invocation_image_dimensions');
  }
  final decoded = decoder.decodeFrame(0);
  if (decoded == null) throw const FormatException('invocation_image_decode');
  final thumbnail = image.copyResize(
    decoded,
    width: decoded.width >= decoded.height
        ? math.min(240, decoded.width)
        : null,
    height: decoded.height > decoded.width
        ? math.min(240, decoded.height)
        : null,
  );
  final preview = image.Image(
    width: thumbnail.width,
    height: thumbnail.height,
    numChannels: 3,
  );
  image.fill(preview, color: image.ColorRgb8(255, 255, 255));
  image.compositeImage(preview, thumbnail);
  return PreparedChatMedia(
    ChatAttachment(
      id: output.sha256Digest,
      kind: 'image',
      byteLength: bytes.length,
      thumbnailJpeg: base64Encode(image.encodeJpg(preview, quality: 80)),
    ),
    Uint8List.fromList(bytes).asUnmodifiableView(),
    output.mime,
  );
}

final class ChatMediaService extends AppService {
  ChatMediaService({
    required Database database,
    required bool Function() isCurrent,
    required Uri baseUri,
    required Future<String> Function() accessToken,
    http.Client? client,
    Future<void> Function()? authorize,
  }) : _db = database,
       _current = isCurrent,
       _baseUri = baseUri,
       _token = accessToken,
       _authorize = authorize,
       _client = client ?? createMaasoBackendClient();
  final Database _db;
  final bool Function() _current;
  final Uri _baseUri;
  final Future<String> Function() _token;
  final Future<void> Function()? _authorize;
  final http.Client _client;
  final _store = stringMapStoreFactory.store('chat_media.v1');
  final _referenceInputs = stringMapStoreFactory.store(
    'project_reference_inputs.v1',
  );
  bool _retired = false;

  /// UI previews must release decoded media synchronously when this account retires.
  final retired = false.obs;
  final Set<Future<void>> _writes = {};
  bool get isCurrent => !_retired && _current();
  void _check() {
    if (!isCurrent) throw StateError('chat_media_account_changed');
  }

  Future<PreparedChatMedia> prepareImage(Uint8List bytes) async {
    _check();
    final value = await compute(normalizeChatImage, bytes);
    _check();
    return value;
  }

  bool usesDatabase(Database database) => identical(_db, database);

  Future<PreparedChatMedia> prepareInvocationOutput(
    AppInvocationProducedImage output,
  ) async {
    _check();
    final prepared = await compute(prepareInvocationImage, output);
    _check();
    return prepared;
  }

  /// Called only from the owning publication transaction. No independent append.
  Future<void> persistInvocationOutputs(
    Transaction transaction,
    List<PreparedChatMedia> outputs,
  ) async {
    _check();
    if (outputs.length > appInvocationMaximumImages) {
      throw const FormatException('invocation_output_count');
    }
    for (final item in outputs) {
      if (item.attachment.kind != 'image' ||
          !const {'image/png', 'image/jpeg'}.contains(item.mime) ||
          item.bytes.length != item.attachment.byteLength ||
          sha256.convert(item.bytes).toString() != item.attachment.id) {
        throw const FormatException('invocation_output_bytes_changed');
      }
      final record = _store.record(item.attachment.id);
      final existing = await record.get(transaction);
      _check();
      final data = base64Encode(item.bytes);
      if (existing != null &&
          (existing['mime'] != item.mime || existing['data'] != data)) {
        throw const FormatException('invocation_output_conflict');
      }
      if (existing == null)
        await record.put(transaction, {'mime': item.mime, 'data': data});
      _check();
    }
  }

  /// Reads an immutable committed output for the account-owned invocation
  /// journal. The caller's transaction must belong to this service's Database;
  /// ResultStore and the journal provider verify that binding before injection.
  Future<Uint8List?> readInvocationOutput(
    DatabaseClient transaction, {
    required String id,
    required String mime,
    required int byteLength,
  }) async {
    _check();
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(id) ||
        !const {'image/png', 'image/jpeg'}.contains(mime) ||
        byteLength < 1 ||
        byteLength > appInvocationMaximumImageBytes) {
      throw const FormatException('invocation_output_descriptor');
    }
    final row = await _store.record(id).get(transaction);
    _check();
    if (row == null) return null;
    final data = row['data'];
    if (row['mime'] != mime ||
        data is! String ||
        data.length != ((byteLength + 2) ~/ 3) * 4) {
      throw const FormatException('invocation_output_corrupt');
    }
    final bytes = base64Decode(data);
    if (bytes.length != byteLength || sha256.convert(bytes).toString() != id) {
      throw const FormatException('invocation_output_corrupt');
    }
    _check();
    return bytes.asUnmodifiableView();
  }

  Future<void> persist(PreparedChatMedia media) async {
    _check();
    final task = _db.transaction((tx) async {
      _check();
      await _store.record(media.attachment.id).put(tx, {
        'mime': media.mime,
        'data': base64Encode(media.bytes),
      });
      _check();
    });
    _writes.add(task);
    try {
      await task;
      _check();
    } finally {
      _writes.remove(task);
    }
  }

  Future<PreparedChatMedia?> read(ChatAttachment attachment) async {
    _check();
    final row = await _store.record(attachment.id).get(_db);
    _check();
    if (row == null) return null;
    final bytes = base64Decode(row['data'] as String);
    if (bytes.length != attachment.byteLength ||
        sha256.convert(bytes).toString() != attachment.id) {
      throw const FormatException('chat_media_corrupt');
    }
    return PreparedChatMedia(attachment, bytes, row['mime'] as String);
  }

  /// Pins the exact, ordered local image inputs and their prior visual summary.
  /// No network request is issued and no upload/model-read status is inferred.
  Future<ProjectReferenceInputSnapshot> persistProjectReferenceInput(
    List<PreparedChatMedia> media, {
    required String scopeKey,
    required String visualSummary,
    List<ProjectReferencePurpose>? purposes,
    int inputRevision = 1,
  }) async {
    _check();
    if (media.isEmpty ||
        media.length > 4 ||
        (purposes != null && purposes.length != media.length)) {
      throw const FormatException('project_reference_invalid_images');
    }
    // Detach before the first await so later caller mutations cannot change
    // the durable bytes without also changing their content-addressed identity.
    final frozen = <PreparedChatMedia>[];
    for (final item in media) {
      if (item.attachment.kind != 'image' ||
          item.mime != 'image/jpeg' ||
          item.bytes.length != item.attachment.byteLength ||
          sha256.convert(item.bytes).toString() != item.attachment.id) {
        throw const FormatException('project_reference_invalid_bytes');
      }
      frozen.add(
        PreparedChatMedia(
          item.attachment,
          Uint8List.fromList(item.bytes),
          item.mime,
        ),
      );
    }
    final snapshot = ProjectReferenceInputSnapshot(
      scopeKey: scopeKey,
      visualSummary: visualSummary,
      inputRevision: inputRevision,
      references: [
        for (var index = 0; index < frozen.length; index++)
          ProjectReferenceImage(
            sha256: frozen[index].attachment.id,
            byteLength: frozen[index].bytes.length,
            mime: frozen[index].mime,
            purpose: purposes?[index] ?? ProjectReferencePurpose.reference,
          ),
      ],
    );
    final writing = _db.transaction((tx) async {
      _check();
      for (final item in frozen) {
        await _store.record(item.attachment.id).put(tx, {
          'mime': item.mime,
          'data': base64Encode(item.bytes),
        });
        _check();
      }
      await _referenceInputs.record(snapshot.digest).put(tx, snapshot.toJson());
      _check();
    });
    _writes.add(writing);
    try {
      await writing;
      _check();
      return snapshot;
    } finally {
      _writes.remove(writing);
    }
  }

  /// Restores existing local media into a durable reference snapshot. Remote
  /// attachment metadata alone is insufficient: each byte record must exist.
  Future<ProjectReferenceInputSnapshot> captureProjectReferenceInput(
    List<ChatAttachment> attachments, {
    required String scopeKey,
    required String visualSummary,
  }) async {
    _check();
    if (attachments.isEmpty ||
        attachments.length > 4 ||
        attachments.any((item) => item.kind != 'image')) {
      throw const FormatException('project_reference_invalid_images');
    }
    final media = <PreparedChatMedia>[];
    for (final attachment in attachments) {
      final item = await read(attachment);
      if (item == null) {
        throw StateError('project_reference_local_media_missing');
      }
      media.add(item);
    }
    return persistProjectReferenceInput(
      media,
      scopeKey: scopeKey,
      visualSummary: visualSummary,
    );
  }

  Future<List<PreparedChatMedia>> loadProjectReferenceInput(
    ProjectReferenceInputSnapshot expected,
  ) async {
    _check();
    final raw = await _referenceInputs.record(expected.digest).get(_db);
    _check();
    if (raw == null) throw StateError('project_reference_snapshot_missing');
    final stored = ProjectReferenceInputSnapshot.fromJson(raw);
    if (stored.digest != expected.digest) {
      throw const FormatException('project_reference_digest_mismatch');
    }
    final media = <PreparedChatMedia>[];
    for (final reference in stored.references) {
      final item = await read(
        ChatAttachment(
          id: reference.sha256,
          kind: 'image',
          byteLength: reference.byteLength,
        ),
      );
      if (item == null) {
        throw StateError('project_reference_local_media_missing');
      }
      if (item.mime != reference.mime) {
        throw const FormatException('project_reference_mime_mismatch');
      }
      media.add(item);
    }
    _check();
    return List.unmodifiable(media);
  }

  Future<String> analyze(
    List<PreparedChatMedia> media, {
    required String question,
    required String locale,
    required String requestId,
  }) async {
    _check();
    if (media.isEmpty ||
        media.length > 4 ||
        media.fold<int>(0, (n, m) => n + m.bytes.length) > 12 * 1024 * 1024) {
      throw const FormatException('chat_media_size');
    }
    await _authorize?.call();
    _check();
    final token = await _token();
    _check();
    final response = await _client
        .post(
          _baseUri.resolve('v1/proxy/media/analyze'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'requestId': requestId,
            'question': question,
            'locale': locale,
            'media': media
                .map(
                  (m) => {
                    'id': m.attachment.id,
                    'mime': m.mime,
                    'durationMs': m.attachment.durationMs,
                    'data': base64Encode(m.bytes),
                  },
                )
                .toList(),
          }),
        )
        .timeout(const Duration(seconds: 70));
    _check();
    if (response.statusCode != 200 || response.bodyBytes.length > 32768) {
      throw StateError('chat_media_analysis_unavailable');
    }
    final raw = jsonDecode(utf8.decode(response.bodyBytes));
    if (raw is! Map || raw['code'] != 'OK' || raw['data'] is! Map) {
      throw const FormatException('chat_media_response');
    }
    final data = raw['data'] as Map;
    final description = data['description'];
    final ids = data['sourceMediaIds'];
    if (description is! String ||
        description.trim().isEmpty ||
        description.length > 12000 ||
        ids is! List ||
        !listEquals(ids, media.map((m) => m.attachment.id).toList())) {
      throw const FormatException('chat_media_response');
    }
    return description.trim();
  }

  Future<void> shutdown() async {
    _retired = true;
    retired.value = true;
    _client.close();
    await Future.wait(_writes.toList());
  }

  @override
  void onClose() {
    _retired = true;
    retired.value = true;
    _client.close();
    super.onClose();
  }
}

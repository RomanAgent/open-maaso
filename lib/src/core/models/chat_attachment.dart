import 'dart:convert';

/// Metadata only. Original media is stored separately in the account database.
/// IDs are portable; filesystem paths and provider URLs never enter history.
final class ChatAttachment {
  ChatAttachment({
    required this.id,
    required this.kind,
    required this.byteLength,
    this.thumbnailJpeg = '',
    this.durationMs = 0,
  }) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(id) ||
        !{'image', 'video'}.contains(kind) ||
        byteLength <= 0 ||
        byteLength > 12 * 1024 * 1024 ||
        durationMs < 0 ||
        durationMs > 60000 ||
        thumbnailJpeg.length > 96 * 1024) {
      throw const FormatException('invalid_chat_attachment');
    }
    if (thumbnailJpeg.isNotEmpty) {
      final bytes = base64Decode(thumbnailJpeg);
      if (bytes.length < 4 ||
          bytes[0] != 0xff ||
          bytes[1] != 0xd8 ||
          bytes[bytes.length - 2] != 0xff ||
          bytes.last != 0xd9) {
        throw const FormatException('invalid_attachment_thumbnail');
      }
    }
  }
  final String id;
  final String kind;
  final int byteLength;
  final String thumbnailJpeg;
  final int durationMs;
  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind,
    'byteLength': byteLength,
    'thumbnailJpeg': thumbnailJpeg,
    'durationMs': durationMs,
  };
  factory ChatAttachment.fromJson(Map<String, Object?> value) => ChatAttachment(
    id: value['id'] as String,
    kind: value['kind'] as String,
    byteLength: value['byteLength'] as int,
    thumbnailJpeg: value['thumbnailJpeg'] as String? ?? '',
    durationMs: value['durationMs'] as int? ?? 0,
  );
  static List<ChatAttachment> decode(Object? raw) {
    if (raw == null) return const [];
    if (raw is! List || raw.length > 4) {
      throw const FormatException('invalid_attachments');
    }
    return List.unmodifiable(
      raw.map(
        (x) => ChatAttachment.fromJson(Map<String, Object?>.from(x as Map)),
      ),
    );
  }
}

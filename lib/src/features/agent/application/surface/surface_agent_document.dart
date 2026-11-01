import 'dart:convert';

const surfaceAgentDocumentMaxUtf8Bytes = 64 * 1024;

/// Document capacity is a technical byte boundary, never a shortening rule.
/// Whitespace and Markdown are retained verbatim for persistence/signatures.
String readSurfaceAgentDocument(
  Object? raw, {
  bool requireNonBlank = false,
  String errorCode = 'invalid_skill_instructions',
}) {
  if (raw == null && !requireNonBlank) return '';
  if (raw is! String || (requireNonBlank && raw.trim().isEmpty)) {
    throw FormatException(errorCode);
  }
  final bytes = utf8.encode(raw);
  if (bytes.length > surfaceAgentDocumentMaxUtf8Bytes ||
      utf8.decode(bytes) != raw ||
      RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]').hasMatch(raw)) {
    throw FormatException(errorCode);
  }
  return raw;
}

bool runtimeChatContentHash(Object? value) =>
    value is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(value);

String runtimeChatIdentifier(String value, {int maximum = 64}) {
  if (value.length < 8 ||
      value.length > maximum ||
      !RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(value)) {
    throw const FormatException('invalid_runtime_chat_id');
  }
  return value;
}

DateTime runtimeChatUtc(Object? value) {
  final parsed = value is String ? DateTime.tryParse(value) : null;
  if (parsed == null || !parsed.isUtc) {
    throw const FormatException('invalid_runtime_chat_timestamp');
  }
  return parsed;
}

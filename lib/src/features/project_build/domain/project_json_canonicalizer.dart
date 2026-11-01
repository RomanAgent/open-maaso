import 'dart:convert';
import 'dart:typed_data';

/// RFC 8785 JSON canonicalization for the versioned project package contract.
/// Strings are preserved (never normalized), object keys use UTF-16 ordering,
/// and JSON numeric tokens are parsed as IEEE 754 binary64 like ECMAScript.
/// See https://www.rfc-editor.org/rfc/rfc8785.html.
final class ProjectJsonCanonicalizer {
  const ProjectJsonCanonicalizer({
    this.maxBytes = 1024 * 1024,
    this.maxDepth = 64,
    this.maxNodes = 65536,
  });

  final int maxBytes;
  final int maxDepth;
  final int maxNodes;

  Object? parse(String source) {
    _validateLimits();
    _validUnicode(source);
    if (source.length > maxBytes || utf8.encode(source).length > maxBytes) {
      throw const FormatException('project_json_size_limit');
    }
    return _ProjectJsonReader(source, maxDepth, maxNodes).read();
  }

  Object? parseBytes(List<int> source) {
    _validateLimits();
    if (source.length > maxBytes) {
      throw const FormatException('project_json_size_limit');
    }
    return parse(utf8.decode(source, allowMalformed: false));
  }

  String canonicalize(Object? value) {
    _validateLimits();
    final writer = _ProjectJcsWriter(maxBytes, maxDepth, maxNodes);
    writer.write(value, 0);
    return writer.output.toString();
  }

  Uint8List canonicalBytes(Object? value) =>
      Uint8List.fromList(utf8.encode(canonicalize(value)));

  void _validateLimits() {
    if (maxBytes < 1 || maxDepth < 1 || maxNodes < 1) {
      throw ArgumentError('invalid_project_json_limits');
    }
  }
}

void _validUnicode(String value) {
  for (var index = 0; index < value.length; index++) {
    final unit = value.codeUnitAt(index);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      index++;
      if (index >= value.length ||
          value.codeUnitAt(index) < 0xdc00 ||
          value.codeUnitAt(index) > 0xdfff) {
        throw const FormatException('project_json_lone_surrogate');
      }
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      throw const FormatException('project_json_lone_surrogate');
    }
  }
}

final class _ProjectJcsWriter {
  _ProjectJcsWriter(this.maxBytes, this.maxDepth, this.maxNodes);
  final int maxBytes;
  final int maxDepth;
  final int maxNodes;
  final output = StringBuffer();
  final _active = Set<Object>.identity();
  var _bytes = 0;
  var _nodes = 0;

  void _append(String value) {
    if (value.length > maxBytes - _bytes) {
      throw const FormatException('project_json_size_limit');
    }
    _bytes += utf8.encode(value).length;
    if (_bytes > maxBytes) {
      throw const FormatException('project_json_size_limit');
    }
    output.write(value);
  }

  void write(Object? value, int depth) {
    if (depth > maxDepth || ++_nodes > maxNodes) {
      throw const FormatException('project_json_structure_limit');
    }
    if (value == null) {
      _append('null');
      return;
    }
    if (value is bool) {
      _append(value ? 'true' : 'false');
      return;
    }
    if (value is String) {
      _string(value);
      return;
    }
    if (value is num) {
      _append(_number(value));
      return;
    }
    if (value is List) {
      if (!_active.add(value)) {
        throw const FormatException('project_json_cycle');
      }
      try {
        _append('[');
        for (var index = 0; index < value.length; index++) {
          if (index != 0) _append(',');
          write(value[index], depth + 1);
        }
        _append(']');
      } finally {
        _active.remove(value);
      }
      return;
    }
    if (value is Map) {
      if (!_active.add(value)) {
        throw const FormatException('project_json_cycle');
      }
      try {
        if (value.keys.any((key) => key is! String)) {
          throw const FormatException('project_json_non_string_key');
        }
        final keys = value.keys.cast<String>().toList()..sort(_compareUtf16);
        _append('{');
        for (var index = 0; index < keys.length; index++) {
          if (index != 0) _append(',');
          _string(keys[index]);
          _append(':');
          write(value[keys[index]], depth + 1);
        }
        _append('}');
      } finally {
        _active.remove(value);
      }
      return;
    }
    throw const FormatException('project_json_unsupported_value');
  }

  void _string(String value) {
    if (value.length > maxBytes) {
      throw const FormatException('project_json_size_limit');
    }
    _validUnicode(value);
    final escaped = StringBuffer('"');
    for (final rune in value.runes) {
      switch (rune) {
        case 0x22:
          escaped.write(r'\"');
        case 0x5c:
          escaped.write(r'\\');
        case 8:
          escaped.write(r'\b');
        case 9:
          escaped.write(r'\t');
        case 10:
          escaped.write(r'\n');
        case 12:
          escaped.write(r'\f');
        case 13:
          escaped.write(r'\r');
        default:
          if (rune < 32) {
            escaped.write('\\u${rune.toRadixString(16).padLeft(4, '0')}');
          } else {
            escaped.writeCharCode(rune);
          }
      }
      if (escaped.length > maxBytes) {
        throw const FormatException('project_json_size_limit');
      }
    }
    escaped.write('"');
    _append(escaped.toString());
  }

  static int _compareUtf16(String left, String right) {
    final end = left.length < right.length ? left.length : right.length;
    for (var index = 0; index < end; index++) {
      final comparison = left
          .codeUnitAt(index)
          .compareTo(right.codeUnitAt(index));
      if (comparison != 0) return comparison;
    }
    return left.length.compareTo(right.length);
  }

  static String _number(num value) {
    final number = value.toDouble();
    if (!number.isFinite) {
      throw const FormatException('project_json_non_finite');
    }
    // Native int callers must not silently lose precision. Parsed JSON tokens
    // already use binary64. Contract IDs above safe integer range use strings.
    if (value is int && BigInt.from(number) != BigInt.from(value)) {
      throw const FormatException('project_json_integer_precision');
    }
    if (number == 0) return '0';
    final negative = number.isNegative;
    final raw = number.abs().toString().toLowerCase();
    final parts = raw.split('e');
    final coefficient = parts.first;
    final exponent = parts.length == 2 ? int.parse(parts.last) : 0;
    final dot = coefficient.indexOf('.');
    var decimalPosition = (dot == -1 ? coefficient.length : dot) + exponent;
    var digits = coefficient.replaceAll('.', '');
    while (digits.length > 1 && digits.startsWith('0')) {
      digits = digits.substring(1);
      decimalPosition--;
    }
    while (digits.length > 1 && digits.endsWith('0')) {
      digits = digits.substring(0, digits.length - 1);
    }
    final String body;
    if (decimalPosition > 0 && decimalPosition <= 21) {
      body = digits.length <= decimalPosition
          ? digits.padRight(decimalPosition, '0')
          : '${digits.substring(0, decimalPosition)}.${digits.substring(decimalPosition)}';
    } else if (decimalPosition <= 0 && decimalPosition > -6) {
      body = '0.${'0' * -decimalPosition}$digits';
    } else {
      final exp = decimalPosition - 1;
      body =
          '${digits[0]}${digits.length > 1 ? '.${digits.substring(1)}' : ''}e${exp >= 0 ? '+' : ''}$exp';
    }
    return negative ? '-$body' : body;
  }
}

final class _ProjectJsonReader {
  _ProjectJsonReader(this.source, this.maxDepth, this.maxNodes);
  final String source;
  final int maxDepth;
  final int maxNodes;
  var offset = 0;
  var nodes = 0;

  Object? read() {
    final value = _value(0);
    _space();
    if (offset != source.length) {
      throw const FormatException('project_json_invalid');
    }
    return value;
  }

  void _space() {
    while (offset < source.length &&
        const [9, 10, 13, 32].contains(source.codeUnitAt(offset))) {
      offset++;
    }
  }

  bool _take(String value) {
    _space();
    if (offset < source.length && source[offset] == value) {
      offset++;
      return true;
    }
    return false;
  }

  void _expect(String value) {
    if (!_take(value)) throw const FormatException('project_json_invalid');
  }

  Object? _value(int depth) {
    if (depth > maxDepth || ++nodes > maxNodes) {
      throw const FormatException('project_json_structure_limit');
    }
    _space();
    if (offset >= source.length) {
      throw const FormatException('project_json_invalid');
    }
    if (source[offset] == '"') return _string();
    if (_take('{')) {
      final values = <String, Object?>{};
      if (_take('}')) return Map<String, Object?>.unmodifiable(values);
      do {
        _space();
        final key = _string();
        if (values.containsKey(key)) {
          throw const FormatException('project_json_duplicate_key');
        }
        _expect(':');
        values[key] = _value(depth + 1);
        if (_take('}')) return Map<String, Object?>.unmodifiable(values);
        _expect(',');
      } while (true);
    }
    if (_take('[')) {
      final values = <Object?>[];
      if (_take(']')) return List<Object?>.unmodifiable(values);
      do {
        values.add(_value(depth + 1));
        if (_take(']')) return List<Object?>.unmodifiable(values);
        _expect(',');
      } while (true);
    }
    for (final literal in const ['null', 'true', 'false']) {
      if (source.startsWith(literal, offset)) {
        offset += literal.length;
        return switch (literal) {
          'null' => null,
          'true' => true,
          _ => false,
        };
      }
    }
    final token = RegExp(
      r'-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?',
    ).matchAsPrefix(source, offset);
    if (token == null) throw const FormatException('project_json_invalid');
    offset = token.end;
    final number = double.tryParse(token.group(0)!);
    if (number == null || !number.isFinite) {
      throw const FormatException('project_json_non_finite');
    }
    final integer = int.tryParse(token.group(0)!);
    if (integer != null && integer.abs() <= 9007199254740991) return integer;
    return number;
  }

  String _string() {
    if (offset >= source.length || source[offset] != '"') {
      throw const FormatException('project_json_invalid');
    }
    final start = offset++;
    while (offset < source.length) {
      final character = source[offset++];
      if (character == r'\') {
        offset++;
      } else if (character == '"') {
        final value = jsonDecode(source.substring(start, offset)) as String;
        _validUnicode(value);
        return value;
      }
    }
    throw const FormatException('project_json_invalid');
  }
}

/// Reads transient text only from a literal first root member `"reply"`.
///
/// It never scans for keys inside arbitrary text, actions or nested objects.
/// A returned delta is presentation data: the complete JSON envelope must still
/// be validated separately before persistence or creation-intent admission.
final class JsonReplyPrefix {
  _ReplyPrefixPhase _phase = _ReplyPrefixPhase.root;
  var _keyOffset = 0;
  var _unicodeValue = 0;
  var _unicodeDigits = 0;
  int? _highSurrogate;

  static const _key = '"reply"';

  /// The first reply string is closed. This says nothing about its envelope.
  bool get isComplete => _phase == _ReplyPrefixPhase.closed;

  String add(String fragment) {
    final output = StringBuffer();
    for (final code in fragment.codeUnits) {
      switch (_phase) {
        case _ReplyPrefixPhase.root:
          if (_isWhitespace(code)) continue;
          _phase = code == 0x7b
              ? _ReplyPrefixPhase.firstMember
              : _ReplyPrefixPhase.disabled;
        case _ReplyPrefixPhase.firstMember:
          if (_isWhitespace(code)) continue;
          if (code != _key.codeUnitAt(0)) {
            _phase = _ReplyPrefixPhase.disabled;
          } else {
            _keyOffset = 1;
            _phase = _ReplyPrefixPhase.key;
          }
        case _ReplyPrefixPhase.key:
          if (code != _key.codeUnitAt(_keyOffset)) {
            _phase = _ReplyPrefixPhase.disabled;
          } else if (++_keyOffset == _key.length) {
            _phase = _ReplyPrefixPhase.colon;
          }
        case _ReplyPrefixPhase.colon:
          if (_isWhitespace(code)) continue;
          _phase = code == 0x3a
              ? _ReplyPrefixPhase.value
              : _ReplyPrefixPhase.disabled;
        case _ReplyPrefixPhase.value:
          if (_isWhitespace(code)) continue;
          _phase = code == 0x22
              ? _ReplyPrefixPhase.text
              : _ReplyPrefixPhase.disabled;
        case _ReplyPrefixPhase.text:
          if (code == 0x22) {
            if (_highSurrogate != null) _fail();
            _phase = _ReplyPrefixPhase.closed;
          } else if (code == 0x5c) {
            _phase = _ReplyPrefixPhase.escape;
          } else {
            if (code < 0x20) _fail();
            _emit(code, output);
          }
        case _ReplyPrefixPhase.escape:
          if (code == 0x75) {
            _unicodeValue = 0;
            _unicodeDigits = 0;
            _phase = _ReplyPrefixPhase.unicode;
          } else {
            final decoded = switch (code) {
              0x22 || 0x5c || 0x2f => code,
              0x62 => 0x08,
              0x66 => 0x0c,
              0x6e => 0x0a,
              0x72 => 0x0d,
              0x74 => 0x09,
              _ => null,
            };
            if (decoded == null) _fail();
            _emit(decoded, output);
            _phase = _ReplyPrefixPhase.text;
          }
        case _ReplyPrefixPhase.unicode:
          final digit = switch (code) {
            >= 0x30 && <= 0x39 => code - 0x30,
            >= 0x61 && <= 0x66 => code - 0x61 + 10,
            >= 0x41 && <= 0x46 => code - 0x41 + 10,
            _ => null,
          };
          if (digit == null) _fail();
          _unicodeValue = (_unicodeValue << 4) | digit;
          if (++_unicodeDigits == 4) {
            _emit(_unicodeValue, output);
            _phase = _ReplyPrefixPhase.text;
          }
        case _ReplyPrefixPhase.closed:
        case _ReplyPrefixPhase.disabled:
          // A later key or root can never reopen the presentation channel.
          return output.toString();
      }
    }
    return output.toString();
  }

  void _emit(int code, StringBuffer output) {
    final high = _highSurrogate;
    if (high != null) {
      if (code < 0xdc00 || code > 0xdfff) _fail();
      output.writeCharCode(high);
      output.writeCharCode(code);
      _highSurrogate = null;
    } else if (code >= 0xd800 && code <= 0xdbff) {
      _highSurrogate = code;
    } else if (code >= 0xdc00 && code <= 0xdfff) {
      _fail();
    } else {
      output.writeCharCode(code);
    }
  }

  static bool _isWhitespace(int code) =>
      code == 0x20 || code == 0x09 || code == 0x0a || code == 0x0d;

  static Never _fail() =>
      throw const FormatException('invalid_json_reply_prefix');
}

enum _ReplyPrefixPhase {
  root,
  firstMember,
  key,
  colon,
  value,
  text,
  escape,
  unicode,
  closed,
  disabled,
}

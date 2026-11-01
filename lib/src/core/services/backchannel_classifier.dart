// lib/src/core/services/backchannel_classifier.dart

/// Whether a barge-in utterance is a passive backchannel ("uh-huh", keep going)
/// or a real interruption that should start a new turn.
enum BackchannelVerdict { backchannel, interruption }

/// Pure, locale-agnostic classifier. A barge-in counts as a backchannel only
/// when the whole utterance (normalized) is empty or a known affirmation —
/// anything substantive is treated as an interruption. Kept deliberately
/// conservative: when in doubt, interrupt (the user gets a real answer rather
/// than being ignored).
class BackchannelClassifier {
  const BackchannelClassifier();

  /// Affirmations in EN + ZH. Compared against the normalized utterance
  /// (lowercased, surrounding punctuation/space stripped).
  static const Set<String> _affirmations = {
    // English
    'ok', 'okay', 'k', 'yeah', 'yep', 'yes', 'yup', 'mhm', 'mm', 'mmhmm',
    'uh-huh', 'uhhuh', 'uh huh', 'right', 'sure', 'sure thing', 'go on',
    'continue', 'i see', 'got it', 'gotcha', 'cool', 'nice', 'aha',
    // Chinese
    '嗯', '嗯嗯', '嗯哼', '对', '对对', '对啊', '对的', '是', '是的', '好',
    '好的', '好吧', '行', '哦', '噢', '嗯呢', '继续', '说', '你说',
  };

  // Matches leading/trailing whitespace and common punctuation (ASCII + CJK).
  // Note: \p{P} unicode property escapes are not supported in Dart's RegExp
  // implementation (as of Dart SDK 3.x), so we use an explicit char class
  // covering ASCII punctuation and common CJK punctuation characters.
  // The double-quote character is handled by its Unicode code point \x22 to
  // avoid raw-string quoting issues.
  static final _leadingTrailingPunct = RegExp(
    r'^[\s'
    r"!#$%&'()*+,\-./:;<=>?@\[\\\]^_`{|}~"
    '\x22'
    r'。，！？、…—～·]+|'
    r'[\s'
    r"!#$%&'()*+,\-./:;<=>?@\[\\\]^_`{|}~"
    '\x22'
    r'。，！？、…—～·]+$',
  );

  BackchannelVerdict classify(String utterance) {
    final normalized = _normalize(utterance);
    if (normalized.isEmpty) return BackchannelVerdict.backchannel;
    if (_affirmations.contains(normalized)) {
      return BackchannelVerdict.backchannel;
    }
    return BackchannelVerdict.interruption;
  }

  String _normalize(String s) {
    final lowered = s.toLowerCase().trim();
    final stripped = lowered.replaceAll(_leadingTrailingPunct, '');
    return stripped.replaceAll(RegExp(r'\s+'), ' ');
  }
}

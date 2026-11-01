enum LookupIntentMode { search, clarify }

/// A model's semantic lookup decision, never permission to call a tool.
///
/// Only the owning human turn may consume this after the complete response is
/// validated. The host still checks enabled Skills, account ownership and
/// cancellation before admitting a search.
final class LookupIntent {
  const LookupIntent._({
    required this.mode,
    this.query = '',
    this.question = '',
    this.useCurrentLocation = false,
  });

  static const maxQueryCharacters = 2048;
  static const maxQuestionCharacters = 400;

  final LookupIntentMode mode;
  final String query;
  final String question;
  final bool useCurrentLocation;

  factory LookupIntent.fromJson(Map<String, Object?> data) {
    if (data['type'] != 'lookup.intent') {
      throw const FormatException('invalid_lookup_intent');
    }
    final mode = switch (data['mode']) {
      'search' => LookupIntentMode.search,
      'clarify' => LookupIntentMode.clarify,
      _ => throw const FormatException('invalid_lookup_mode'),
    };
    final field = mode == LookupIntentMode.search ? 'query' : 'question';
    final allowed = {'type', 'mode', field};
    if (mode == LookupIntentMode.search) allowed.add('useCurrentLocation');
    if (data.keys.any((key) => !allowed.contains(key))) {
      throw const FormatException('unknown_lookup_field');
    }
    final useCurrentLocation = data.containsKey('useCurrentLocation')
        ? data['useCurrentLocation']
        : false;
    if (useCurrentLocation is! bool) {
      throw const FormatException('invalid_lookup_location_request');
    }
    final value = data[field];
    final maximum = mode == LookupIntentMode.search
        ? maxQueryCharacters
        : maxQuestionCharacters;
    if (value is! String ||
        value.trim().isEmpty ||
        value.length > maximum ||
        RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]').hasMatch(value)) {
      throw FormatException('invalid_lookup_$field');
    }
    return LookupIntent._(
      mode: mode,
      query: mode == LookupIntentMode.search ? value.trim() : '',
      question: mode == LookupIntentMode.clarify ? value.trim() : '',
      useCurrentLocation: useCurrentLocation,
    );
  }

  Map<String, Object?> toJson() => {
    'type': 'lookup.intent',
    'mode': mode.name,
    if (mode == LookupIntentMode.search) 'query': query,
    if (mode == LookupIntentMode.clarify) 'question': question,
    if (useCurrentLocation) 'useCurrentLocation': true,
  };
}

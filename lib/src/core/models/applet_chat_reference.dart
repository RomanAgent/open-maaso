import 'dart:convert';

/// A reusable public applet and validated configuration attached to a message.
final class AppletChatReference {
  const AppletChatReference({
    required this.id,
    required this.title,
    required this.scopeKey,
    required this.revision,
    required this.sourceSha256,
    this.actions = const [],
  });
  final String id;
  final String title;
  final String scopeKey;
  final int revision;
  final String sourceSha256;
  final List<Map<String, Object?>> actions;

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'scopeKey': scopeKey,
    'revision': revision,
    'sourceSha256': sourceSha256,
    'actions': actions,
  };

  static AppletChatReference? tryParse(Object? value) {
    if (value is! Map) return null;
    try {
      final encoded = jsonEncode(value);
      if (encoded.length > 65536) return null;
      final data = jsonDecode(encoded) as Map<String, dynamic>;
      final id = data['id'];
      final title = data['title'];
      final scope = data['scopeKey'];
      final revision = data['revision'];
      final hash = data['sourceSha256'];
      final actions = data['actions'] ?? const [];
      if (id is! String ||
          !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,39}$').hasMatch(id) ||
          title is! String ||
          title.length > 160 ||
          scope is! String ||
          scope.length > 512 ||
          revision is! int ||
          revision < 1 ||
          hash is! String ||
          hash.length > 128 ||
          actions is! List ||
          actions.length > 8) {
        return null;
      }
      final parsed = <Map<String, Object?>>[];
      for (final action in actions) {
        if (action is! Map ||
            action['name'] is! String ||
            (action['name'] as String).length > 64 ||
            action['arguments'] is! Map) {
          return null;
        }
        parsed.add(
          Map<String, Object?>.unmodifiable({
            'name': action['name'],
            'arguments': action['arguments'],
          }),
        );
      }
      return AppletChatReference(
        id: id,
        title: title,
        scopeKey: scope,
        revision: revision,
        sourceSha256: hash,
        actions: List.unmodifiable(parsed),
      );
    } catch (_) {
      return null;
    }
  }
}

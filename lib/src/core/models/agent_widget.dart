/// A piece of UI the AI has generated for the user — a "mini-program".
/// The actual layout is described declaratively in [spec] (see
/// `DynamicWidget` for the schema).  Persisted in the Widget Hub.
class AgentWidget {
  int? id;

  /// Which agent built this (currently always "self").
  String agentId;

  /// Display name shown in the Hub list.
  String title;

  /// Optional short blurb shown under the title.
  String? subtitle;

  /// Optional emoji / icon hint ("📈", "📊", "🌤️" ...).
  String? icon;

  /// What this hub item is, and therefore how to render/open it.
  ///   * 'surface' — a freeform generated SurfaceRuntime project
  ///                 (payload: spec['surfaceId'], spec['surfaceKind'],
  ///                 spec['html'], spec['css'], spec['js'], spec['manifest'],
  ///                 spec['backend'], spec['revisions']).
  /// Other historical values may still exist in local storage, but new
  /// generated UI is saved and opened only as 'surface'.
  String kind;

  /// Generic payload, interpreted by [kind]:
  ///   surface → {surfaceId, surfaceKind, html, css, js, manifest, backend};
  Map<String, Object?> spec;

  DateTime createdAt;

  /// "Seen" flag — lets the home screen "new item notification" dismiss.
  bool seen;

  AgentWidget({
    this.id,
    required this.agentId,
    required this.title,
    this.subtitle,
    this.icon,
    this.kind = 'widget',
    required this.spec,
    required this.createdAt,
    this.seen = false,
  });

  bool get isSurface => kind == 'surface';

  Map<String, Object?> toJson() => {
    'agentId': agentId,
    'title': title,
    if (subtitle != null) 'subtitle': subtitle,
    if (icon != null) 'icon': icon,
    'kind': kind,
    'spec': spec,
    'createdAt': createdAt.toIso8601String(),
    'seen': seen,
  };

  factory AgentWidget.fromJson(Map<String, Object?> json, {int? id}) =>
      AgentWidget(
        id: id,
        agentId: json['agentId'] as String? ?? 'self',
        title: json['title'] as String? ?? 'Mini App',
        subtitle: json['subtitle'] as String?,
        icon: json['icon'] as String?,
        kind: json['kind'] as String? ?? 'widget',
        spec: json['spec'] is Map
            ? Map<String, Object?>.from(json['spec'] as Map)
            : <String, Object?>{},
        createdAt:
            DateTime.tryParse(json['createdAt'] as String? ?? '') ??
            DateTime.now(),
        seen: json['seen'] as bool? ?? false,
      );
}

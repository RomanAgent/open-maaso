import 'dart:convert';

enum OfflineWorkKind { game, applet }

enum OfflineTaskStatus { queued, running, completed, failed, cancelled }

/// A local creation receipt, never a server job or an automatic retry command.
class OfflineCreationTask {
  const OfflineCreationTask({
    required this.id,
    required this.kind,
    required this.request,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.resultWorkIds = const [],
    this.errorCode = '',
  });

  static const errorCodes = {
    '',
    'interrupted',
    'cancelled',
    'request_failed',
    'invalid_response',
    'storage_failed',
  };
  final String id;
  final OfflineWorkKind kind;
  final String request;
  final OfflineTaskStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<String> resultWorkIds;
  final String errorCode;

  OfflineCreationTask copyWith({
    OfflineTaskStatus? status,
    DateTime? updatedAt,
    List<String>? resultWorkIds,
    String? errorCode,
  }) => OfflineCreationTask(
    id: id,
    kind: kind,
    request: request,
    status: status ?? this.status,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    resultWorkIds: resultWorkIds ?? this.resultWorkIds,
    errorCode: errorCode ?? this.errorCode,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'request': request,
    'status': status.name,
    'createdAt': createdAt.toUtc().millisecondsSinceEpoch,
    'updatedAt': updatedAt.toUtc().millisecondsSinceEpoch,
    'resultWorkIds': resultWorkIds.toList(),
    'errorCode': errorCode,
  };

  factory OfflineCreationTask.fromJson(Map<String, Object?> json) {
    _onlyKeys(json, const {
      'id',
      'kind',
      'request',
      'status',
      'createdAt',
      'updatedAt',
      'resultWorkIds',
      'errorCode',
    });
    final kindName = _string(json, 'kind', 16);
    final kinds = OfflineWorkKind.values.where((v) => v.name == kindName);
    final statusName = _string(json, 'status', 16);
    final statuses = OfflineTaskStatus.values.where(
      (v) => v.name == statusName,
    );
    if (kinds.isEmpty || statuses.isEmpty) {
      throw const FormatException(
        'Invalid local creation task kind or status.',
      );
    }
    final status = statuses.single;
    final error = _string(json, 'errorCode', 40, allowEmpty: true);
    final results = json['resultWorkIds'];
    if (!errorCodes.contains(error) || results is! List || results.length > 8) {
      throw const FormatException('Invalid local creation task outcome.');
    }
    final ids = <String>[];
    for (final value in results) {
      ids.add(_id({'id': value}));
    }
    if (ids.toSet().length != ids.length ||
        status == OfflineTaskStatus.completed &&
            (ids.isEmpty || error.isNotEmpty) ||
        status != OfflineTaskStatus.completed && ids.isNotEmpty ||
        status == OfflineTaskStatus.failed &&
            (error.isEmpty || error == 'cancelled') ||
        status == OfflineTaskStatus.cancelled && error != 'cancelled' ||
        const {
              OfflineTaskStatus.queued,
              OfflineTaskStatus.running,
            }.contains(status) &&
            error.isNotEmpty) {
      throw const FormatException('Inconsistent local creation task outcome.');
    }
    final createdAt = _date(json, 'createdAt');
    final updatedAt = _date(json, 'updatedAt');
    if (updatedAt.isBefore(createdAt)) {
      throw const FormatException('Task dates are inconsistent.');
    }
    return OfflineCreationTask(
      id: _id(json),
      kind: kinds.single,
      request: _string(json, 'request', 16000),
      status: status,
      createdAt: createdAt,
      updatedAt: updatedAt,
      resultWorkIds: List.unmodifiable(ids),
      errorCode: error,
    );
  }
}

/// Local-edition records contain no backend identifiers or credentials.
class OfflineMessage {
  const OfflineMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.createdAt,
  });

  final String id;
  final String role;
  final String text;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'role': role,
    'text': text,
    'createdAt': createdAt.toUtc().millisecondsSinceEpoch,
  };

  factory OfflineMessage.fromJson(Map<String, Object?> json) {
    _onlyKeys(json, const {'id', 'role', 'text', 'createdAt'});
    final role = _string(json, 'role', 16);
    if (!const {'user', 'assistant', 'system'}.contains(role)) {
      throw const FormatException('Unsupported message role.');
    }
    return OfflineMessage(
      id: _id(json),
      role: role,
      text: _string(json, 'text', 65536),
      createdAt: _date(json, 'createdAt'),
    );
  }
}

class OfflineWork {
  const OfflineWork({
    required this.id,
    required this.title,
    required this.kind,
    required this.html,
    required this.createdAt,
    required this.updatedAt,
  });

  static const maxHtmlBytes = 1024 * 1024;
  final String id;
  final String title;
  final OfflineWorkKind kind;
  final String html;
  final DateTime createdAt;
  final DateTime updatedAt;

  OfflineWork copyWith({String? title, String? html, DateTime? updatedAt}) =>
      OfflineWork(
        id: id,
        title: title ?? this.title,
        kind: kind,
        html: html ?? this.html,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'kind': kind.name,
    'html': html,
    'createdAt': createdAt.toUtc().millisecondsSinceEpoch,
    'updatedAt': updatedAt.toUtc().millisecondsSinceEpoch,
  };

  factory OfflineWork.fromJson(Map<String, Object?> json) {
    _onlyKeys(json, const {
      'id',
      'title',
      'kind',
      'html',
      'createdAt',
      'updatedAt',
    });
    final kind = _string(json, 'kind', 16);
    final parsedKind = OfflineWorkKind.values.where((v) => v.name == kind);
    if (parsedKind.isEmpty) throw const FormatException('Invalid work kind.');
    final html = _string(json, 'html', maxHtmlBytes);
    if (utf8.encode(html).length > maxHtmlBytes) {
      throw const FormatException('Work HTML exceeds the local storage limit.');
    }
    final createdAt = _date(json, 'createdAt');
    final updatedAt = _date(json, 'updatedAt');
    if (updatedAt.isBefore(createdAt)) {
      throw const FormatException('Work dates are inconsistent.');
    }
    return OfflineWork(
      id: _id(json),
      title: _string(json, 'title', 160),
      kind: parsedKind.single,
      html: html,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }
}

class OfflineProfile {
  const OfflineProfile({
    this.name = 'Test User',
    this.agentName = 'Maaso',
    this.persona = 'A thoughtful, friendly companion.',
  });

  final String name;
  final String agentName;
  final String persona;

  OfflineProfile copyWith({String? name, String? agentName, String? persona}) =>
      OfflineProfile(
        name: name ?? this.name,
        agentName: agentName ?? this.agentName,
        persona: persona ?? this.persona,
      );

  Map<String, Object?> toJson() => {
    'name': name,
    'agentName': agentName,
    'persona': persona,
  };

  factory OfflineProfile.fromJson(Map<String, Object?> json) {
    _onlyKeys(json, const {'name', 'agentName', 'persona'});
    return OfflineProfile(
      name: _string(json, 'name', 80),
      agentName: _string(json, 'agentName', 80),
      persona: _string(json, 'persona', 8000, allowEmpty: true),
    );
  }
}

/// API keys belong in the platform credential store, never in this record.
class OfflineSettings {
  const OfflineSettings({
    this.ttsEnabled = true,
    this.providerEnabled = false,
    this.providerId = 'openai',
    this.baseUrl = '',
    this.model = '',
    this.companionEnabled = false,
  });

  final bool ttsEnabled;
  final bool providerEnabled;
  final String providerId;
  final String baseUrl;
  final String model;
  final bool companionEnabled;

  OfflineSettings copyWith({
    bool? ttsEnabled,
    bool? providerEnabled,
    String? providerId,
    String? baseUrl,
    String? model,
    bool? companionEnabled,
  }) => OfflineSettings(
    ttsEnabled: ttsEnabled ?? this.ttsEnabled,
    providerEnabled: providerEnabled ?? this.providerEnabled,
    providerId: providerId ?? this.providerId,
    baseUrl: baseUrl ?? this.baseUrl,
    model: model ?? this.model,
    companionEnabled: companionEnabled ?? this.companionEnabled,
  );

  Map<String, Object?> toJson() => {
    'ttsEnabled': ttsEnabled,
    'providerEnabled': providerEnabled,
    'providerId': providerId,
    'baseUrl': baseUrl,
    'model': model,
    'companionEnabled': companionEnabled,
  };

  factory OfflineSettings.fromJson(Map<String, Object?> json) {
    _onlyKeys(json, const {
      'ttsEnabled',
      'providerEnabled',
      'providerId',
      'baseUrl',
      'model',
      'companionEnabled',
    });
    final baseUrl = _string(json, 'baseUrl', 2048, allowEmpty: true);
    if (baseUrl.isNotEmpty) {
      final uri = Uri.tryParse(baseUrl);
      if (uri == null ||
          !uri.hasAuthority ||
          !const {'https', 'http'}.contains(uri.scheme) ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment) {
        throw const FormatException(
          'Provider URL must not contain credentials or query parameters.',
        );
      }
    }
    return OfflineSettings(
      ttsEnabled: _bool(json, 'ttsEnabled'),
      providerEnabled: _bool(json, 'providerEnabled'),
      providerId: _string(json, 'providerId', 80),
      baseUrl: baseUrl,
      model: _string(json, 'model', 160, allowEmpty: true),
      companionEnabled: json.containsKey('companionEnabled')
          ? _bool(json, 'companionEnabled')
          : false,
    );
  }
}

String _string(
  Map<String, Object?> json,
  String key,
  int maxLength, {
  bool allowEmpty = false,
}) {
  final value = json[key];
  if (value is! String ||
      value.length > maxLength ||
      (!allowEmpty && value.trim().isEmpty)) {
    throw FormatException('Invalid local record field: $key.');
  }
  return value;
}

String _id(Map<String, Object?> json) {
  final id = _string(json, 'id', 160);
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$').hasMatch(id)) {
    throw const FormatException('Invalid local record identifier.');
  }
  return id;
}

bool _bool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! bool) {
    throw FormatException('Invalid local record field: $key.');
  }
  return value;
}

DateTime _date(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! int || value < 0 || value > 253402300799999) {
    throw FormatException('Invalid local timestamp: $key.');
  }
  return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
}

void _onlyKeys(Map<String, Object?> json, Set<String> keys) {
  if (json.keys.any((key) => !keys.contains(key))) {
    throw const FormatException('Unexpected local record field.');
  }
}

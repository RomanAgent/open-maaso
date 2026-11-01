class RealtimeAgentConfig {
  RealtimeAgentConfig({
    required this.enabled,
    required this.baseUri,
    this.disabledReason,
  });

  static const _envBaseUrl = String.fromEnvironment('MAASO_AGENT_BASE_URL');

  bool enabled;
  Uri? baseUri;
  String? disabledReason;

  bool get isReady => enabled && baseUri != null;

  factory RealtimeAgentConfig.fromEnvironment({String? environmentBaseUrl}) {
    return RealtimeAgentConfig.fromValues(
      enabled: true,
      baseUrl: _envBaseUrl,
      environmentBaseUrl: environmentBaseUrl,
    );
  }

  factory RealtimeAgentConfig.fromValues({
    required bool enabled,
    required String baseUrl,
    String? environmentBaseUrl,
  }) {
    if (!enabled) {
      return RealtimeAgentConfig(
        enabled: false,
        baseUri: null,
        disabledReason: 'disabled',
      );
    }

    final trimmed = baseUrl.trim().isNotEmpty
        ? baseUrl.trim()
        : (environmentBaseUrl ?? '').trim();
    if (trimmed.isEmpty) {
      return RealtimeAgentConfig(
        enabled: true,
        baseUri: null,
        disabledReason: 'missing MAASO_AGENT_BASE_URL or app environment',
      );
    }

    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        !uri.isAbsolute ||
        uri.host.trim().isEmpty ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      return RealtimeAgentConfig(
        enabled: true,
        baseUri: null,
        disabledReason: 'MAASO_AGENT_BASE_URL must be a root HTTPS origin',
      );
    }

    return RealtimeAgentConfig(enabled: true, baseUri: _normalizeBase(uri));
  }

  void updateBaseUrl(String baseUrl) {
    final next = RealtimeAgentConfig.fromValues(
      enabled: enabled,
      baseUrl: baseUrl,
    );
    enabled = next.enabled;
    baseUri = next.baseUri;
    disabledReason = next.disabledReason;
  }

  static Uri _normalizeBase(Uri uri) {
    return uri.replace(
      scheme: 'https',
      host: uri.host.toLowerCase(),
      path: '/',
      query: null,
      fragment: null,
    );
  }
}

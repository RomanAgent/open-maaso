class AgentConfig {
  static final AgentConfig _instance = AgentConfig._internal();

  factory AgentConfig() => _instance;

  AgentConfig._internal();

  final Map<String, String> _apiKeys = {};

  void setApiKey(String serviceName, String key) {
    _apiKeys[serviceName] = key;
  }

  String? getApiKey(String serviceName) {
    return _apiKeys[serviceName];
  }

  void clearApiKey(String serviceName) {
    _apiKeys.remove(serviceName);
  }
}

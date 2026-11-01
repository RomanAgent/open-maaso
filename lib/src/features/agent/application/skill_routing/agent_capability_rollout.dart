/// Ordered capability gates for progressively enabling agent skill features.
///
/// The order is intentional: a later capability is effective only when every
/// earlier capability was explicitly requested. This prevents a partially
/// populated remote config from enabling page control or public writes ahead
/// of their safety foundations.
enum AgentCapabilityGate {
  lazyHostActivation,
  pageSkillDefaults,
  pageAgentControl,
  publicDrafts,
  publicWrites,
}

/// Account- and locale-neutral rollout configuration.
///
/// Segmentation belongs in the host's configuration service. After it resolves
/// a cohort, it should construct one of these process-local capability sets.
/// This object deliberately stores no account, locale, or experiment labels.
class AgentCapabilityRollout {
  const AgentCapabilityRollout({
    bool requestLazyHostActivation = false,
    bool requestPageSkillDefaults = false,
    bool requestPageAgentControl = false,
    bool requestPublicDrafts = false,
    bool requestPublicWrites = false,
  }) : _requestLazyHostActivation = requestLazyHostActivation,
       _requestPageSkillDefaults = requestPageSkillDefaults,
       _requestPageAgentControl = requestPageAgentControl,
       _requestPublicDrafts = requestPublicDrafts,
       _requestPublicWrites = requestPublicWrites;

  /// Fail-closed defaults for an unavailable or malformed remote config.
  static const safeDefaults = AgentCapabilityRollout();

  /// A staged preset that enables only metadata routing and lazy activation.
  static const lazyActivationOnly = AgentCapabilityRollout(
    requestLazyHostActivation: true,
  );

  final bool _requestLazyHostActivation;
  final bool _requestPageSkillDefaults;
  final bool _requestPageAgentControl;
  final bool _requestPublicDrafts;

  /// Public writes are always opt-in and remain false in every default preset.
  final bool _requestPublicWrites;

  bool isEnabled(AgentCapabilityGate gate) {
    var enabled = true;
    for (var index = 0; index <= gate.index; index++) {
      enabled = enabled && _requested(AgentCapabilityGate.values[index]);
    }
    return enabled;
  }

  bool get lazyHostActivationEnabled =>
      isEnabled(AgentCapabilityGate.lazyHostActivation);

  bool get pageSkillDefaultsEnabled =>
      isEnabled(AgentCapabilityGate.pageSkillDefaults);

  bool get pageAgentControlEnabled =>
      isEnabled(AgentCapabilityGate.pageAgentControl);

  bool get publicDraftsEnabled => isEnabled(AgentCapabilityGate.publicDrafts);

  bool get publicWritesEnabled => isEnabled(AgentCapabilityGate.publicWrites);

  /// Returns requested and effective bits for configuration diagnostics.
  ///
  /// The export has fixed cardinality and contains no cohort identifiers.
  Map<String, Object> toJson() => <String, Object>{
    'schema_version': 1,
    'requested': <String, bool>{
      for (final gate in AgentCapabilityGate.values)
        gate.name: _requested(gate),
    },
    'effective': <String, bool>{
      for (final gate in AgentCapabilityGate.values) gate.name: isEnabled(gate),
    },
  };

  bool _requested(AgentCapabilityGate gate) => switch (gate) {
    AgentCapabilityGate.lazyHostActivation => _requestLazyHostActivation,
    AgentCapabilityGate.pageSkillDefaults => _requestPageSkillDefaults,
    AgentCapabilityGate.pageAgentControl => _requestPageAgentControl,
    AgentCapabilityGate.publicDrafts => _requestPublicDrafts,
    AgentCapabilityGate.publicWrites => _requestPublicWrites,
  };
}

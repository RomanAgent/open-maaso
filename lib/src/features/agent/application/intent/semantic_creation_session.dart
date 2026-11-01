import 'package:uuid/uuid.dart';

import 'creation_intent.dart';

final class CreationProposal {
  const CreationProposal({
    required this.id,
    required this.scopeKey,
    required this.kind,
    required this.requirements,
    required this.sourceTurnId,
    required this.expiresAt,
  });

  final String id, scopeKey, requirements, sourceTurnId;
  final CreationIntentKind kind;
  final DateTime expiresAt;

  Map<String, Object?> toPromptData() => {
    'id': id,
    'kind': kind.name,
    'requirements': requirements,
  };
}

/// Typed, host-owned proposal state. No natural-language matching occurs here.
/// The model interprets the current human's response; the host checks identity,
/// current scope, expiry and single consumption of the referenced proposal.
final class SemanticCreationSession {
  SemanticCreationSession({
    this.ttl = const Duration(minutes: 5),
    DateTime Function()? now,
    String Function()? newId,
  }) : _now = now ?? DateTime.now,
       _newId = newId ?? const Uuid().v4;

  final Duration ttl;
  final DateTime Function() _now;
  final String Function() _newId;
  CreationProposal? _proposal;

  CreationProposal? current(String scopeKey) {
    final value = _proposal;
    if (value != null &&
        (value.scopeKey != scopeKey || !_now().isBefore(value.expiresAt))) {
      clear();
    }
    return _proposal;
  }

  CreationProposal propose(
    CreationIntent decision, {
    required String scopeKey,
    required String sourceTurnId,
  }) {
    if (decision.mode != CreationIntentMode.propose ||
        scopeKey.isEmpty ||
        sourceTurnId.isEmpty) {
      throw const FormatException('invalid_creation_proposal');
    }
    return _proposal = CreationProposal(
      id: _newId(),
      scopeKey: scopeKey,
      kind: decision.kind!,
      requirements: decision.requirements,
      sourceTurnId: sourceTurnId,
      expiresAt: _now().add(ttl),
    );
  }

  CreationProposal? consume(CreationIntent decision, String scopeKey) {
    if (decision.mode != CreationIntentMode.confirm) return null;
    final value = current(scopeKey);
    if (value == null || value.id != decision.proposalId) return null;
    clear();
    return value;
  }

  void clear() => _proposal = null;
}

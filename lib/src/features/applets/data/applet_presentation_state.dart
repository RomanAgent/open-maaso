import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';

/// Host-owned marker for a generated Applet that is persisted but has not yet
/// committed a successful presentation receipt.
const String appletPresentationPendingKey = 'presentationPending';

final String _appletPresentationProcessOwner =
    'process_${DateTime.now().microsecondsSinceEpoch}_'
    '${identityHashCode(Object())}';

bool isAppletPresentationPending(AgentWidget widget) {
  final marker = widget.spec[appletPresentationPendingKey];
  return marker == true || marker is Map;
}

/// True only for a presentation left by a previous process. Legacy boolean
/// markers predate process ownership and are therefore recovered as orphans.
bool isOrphanedAppletPresentation(AgentWidget widget) {
  final marker = widget.spec[appletPresentationPendingKey];
  if (marker == true) return true;
  if (marker is! Map) return false;
  final owner = marker['owner']?.toString().trim() ?? '';
  return owner.isEmpty || owner != _appletPresentationProcessOwner;
}

/// Whether a persisted Applet is safe to expose to user- or Agent-initiated
/// list, open, edit, and reopen paths.
bool isAppletPresentationDiscoverable(
  AgentWidget widget, {
  required String scopeKey,
}) =>
    AppletLocalOwnership.isVisible(widget, scopeKey: scopeKey) &&
    !isAppletPresentationPending(widget) &&
    widget.spec['cloudDelete'] == null;

void markAppletPresentationPending(AgentWidget widget) {
  widget.spec = <String, Object?>{
    ...widget.spec,
    appletPresentationPendingKey: <String, Object?>{
      'schemaVersion': 1,
      'owner': _appletPresentationProcessOwner,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    },
  };
}

Map<String, Object?> committedAppletPresentationSpec(AgentWidget widget) {
  final spec = Map<String, Object?>.from(widget.spec);
  spec.remove(appletPresentationPendingKey);
  return spec;
}

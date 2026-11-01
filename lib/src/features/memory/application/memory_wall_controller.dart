import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/core/models/milestone.dart';
import 'package:maaso/src/core/models/relationship_state.dart';
import 'package:maaso/src/core/services/relationship_service.dart';

/// Thin view-model over [RelationshipService] — the wall just renders the
/// service's already-reactive state + milestone timeline.
class MemoryWallController extends AppController {
  RelationshipService get _rel => appServices.find<RelationshipService>();

  RxList<Milestone> get milestones => _rel.milestones;
  Rxn<RelationshipState> get state => _rel.state;
}

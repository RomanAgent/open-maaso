import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/core/models/agent_moment.dart';
import 'package:maaso/src/core/services/db_service.dart';

class MomentFeedItem {
  const MomentFeedItem._({required this.moment});

  final AgentMoment moment;

  DateTime get createdAt => moment.timestamp;

  static MomentFeedItem forMoment(AgentMoment moment) =>
      MomentFeedItem._(moment: moment);
}

class MomentsController extends AppController {
  final DBService _db = appServices.find<DBService>();

  final moments = <AgentMoment>[].obs;
  final feedItems = <MomentFeedItem>[].obs;

  @override
  void onInit() {
    super.onInit();
    reload();
  }

  Future<void> reload() async {
    final loadedMoments = await _db.getAllMoments();
    moments.assignAll(loadedMoments);
    final mixed = loadedMoments.map(MomentFeedItem.forMoment).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    feedItems.assignAll(mixed);
  }

  Future<void> simulatePost() async {
    final self = await _db.getSelfProfile();
    if (self == null) return;

    final moment = AgentMoment(
      authorId: 'self',
      authorNickname: self.nickname,
      authorAvatar: self.avatar,
      content:
          "I'm having a great time in the parallel universe! ${self.catchphrase}",
      timestamp: DateTime.now(),
    );
    await _db.saveAgentMoment(moment);
    await reload();
  }
}

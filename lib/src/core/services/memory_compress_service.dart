import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/llm_proxy_service.dart';

class MemoryCompressService extends AppService {
  final DBService _db = appServices.find<DBService>();
  final LLMProxyService _llm = appServices.find<LLMProxyService>();

  static const int _maxChars = 2000;

  Future<bool> maybeCompress(String agentId) async {
    final profile = await _db.getSelfProfile();
    if (profile == null) return false;

    final mem = profile.longTermMemory;
    if (mem == null || mem.length <= _maxChars) return false;

    final compressed = await _summarize(mem);
    if (compressed == null || compressed.isEmpty) return false;

    profile.longTermMemory = compressed;
    await _db.saveAgentProfile(profile);

    final core = appServices.find<AgentCoreController>();
    core.profile.value = profile;
    core.profile.refresh();

    return true;
  }

  Future<String?> _summarize(String raw) async {
    final prompt = AgentPromptCatalog.text(
      'app.memory.compress.long',
      params: <String, Object?>{'memory': raw},
    );
    try {
      return await _llm.chat(prompt);
    } catch (_) {
      return null;
    }
  }
}

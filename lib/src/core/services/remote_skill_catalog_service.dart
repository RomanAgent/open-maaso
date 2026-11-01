import 'dart:convert';
import 'dart:io';

import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

class RemoteSkillSpec {
  final String id;
  final String name;
  final String description;
  final String version;
  final String? jsBundleUrl;
  final Map<String, Object?> metadata;

  RemoteSkillSpec({
    required this.id,
    required this.name,
    required this.description,
    this.version = '1.0.0',
    this.jsBundleUrl,
    this.metadata = const {},
  });

  factory RemoteSkillSpec.fromJson(Map<String, Object?> j) => RemoteSkillSpec(
    id: (j['id'] as String?) ?? '',
    name: (j['name'] as String?) ?? '',
    description: (j['description'] as String?) ?? '',
    version: (j['version'] as String?) ?? '1.0.0',
    jsBundleUrl: j['js_bundle_url'] as String?,
    metadata: (j['metadata'] as Map<String, Object?>?) ?? {},
  );
}

class RemoteSkillCatalogService extends AppService {
  static const _catalogUrl = 'https://api.maaso.ai/v1/skills/catalog';

  final RxList<RemoteSkillSpec> availableSkills = <RemoteSkillSpec>[].obs;
  final RxBool isLoading = false.obs;

  Future<RemoteSkillCatalogService> init() async => this;

  Future<List<RemoteSkillSpec>> fetchCatalog() async {
    isLoading.value = true;
    try {
      final client = HttpClient();
      final request = await client.getUrl(Uri.parse(_catalogUrl));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      client.close();

      final data = jsonDecode(body) as List;
      final specs = data
          .map((e) => RemoteSkillSpec.fromJson(e as Map<String, Object?>))
          .toList();
      availableSkills.assignAll(specs);
      Log.i('📦 [RemoteSkillCatalog] fetched ${specs.length} skills');
      return specs;
    } catch (e) {
      Log.w('📦 [RemoteSkillCatalog] fetch failed: $e');
      return [];
    } finally {
      isLoading.value = false;
    }
  }

  Future<bool> installSkill(String skillId) async {
    final spec = availableSkills.firstWhereOrNull((s) => s.id == skillId);
    if (spec == null) {
      Log.w('📦 [RemoteSkillCatalog] skill not found in catalog: $skillId');
      return false;
    }

    Log.i(
      '📦 [RemoteSkillCatalog] install not yet implemented for: ${spec.name}',
    );
    return false;
  }
}

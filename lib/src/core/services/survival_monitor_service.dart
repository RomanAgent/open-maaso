import 'dart:io';

import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_gene.dart';
import 'package:maaso/src/core/services/gene_encoder_service.dart';

enum SurvivalThreat { none, lowStorage, appUpdate, userUninstall, deviceLost }

class SurvivalMonitorService extends AppService {
  final Rx<SurvivalThreat> currentThreat = SurvivalThreat.none.obs;
  final Rx<AgentGene?> lastEncodedGene = Rxn<AgentGene>();

  Future<SurvivalMonitorService> init() async => this;

  Future<void> checkStorage() async {
    try {
      final stat = await Process.run('df', ['-k', '/']);
      final output = stat.stdout.toString();
      final usageLine = output.split('\n').skip(1).firstOrNull;
      if (usageLine == null) return;

      final parts = usageLine.split(RegExp(r'\s+'));
      if (parts.length >= 5) {
        final usePercent = int.tryParse(parts[4].replaceAll('%', ''));
        if (usePercent != null && usePercent > 90) {
          currentThreat.value = SurvivalThreat.lowStorage;
          Log.w('🆘 [Survival] low storage: $usePercent%');
        } else {
          if (currentThreat.value == SurvivalThreat.lowStorage) {
            currentThreat.value = SurvivalThreat.none;
          }
        }
      }
    } catch (_) {}
  }

  Future<AgentGene?> encodeGene() async {
    if (!appServices.isRegistered<GeneEncoderService>()) return null;
    final encoder = appServices.find<GeneEncoderService>();
    final gene = await encoder.encode();
    if (gene != null) {
      lastEncodedGene.value = gene;
      Log.i('🆘 [Survival] gene encoded for ${gene.name}');
    }
    return gene;
  }

  Future<void> onAppDetached() async {
    Log.i('🆘 [Survival] app detaching — emergency gene encode');
    currentThreat.value = SurvivalThreat.userUninstall;
    await encodeGene();
  }
}

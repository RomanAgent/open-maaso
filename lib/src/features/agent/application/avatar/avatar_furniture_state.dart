/// Semantic, renderer-reported personal-space posture. Coordinates and bones
/// never enter the model protocol. Observations are admitted by the renderer's
/// existing command authority before consumers can use them.
enum AvatarFurniturePhase {
  approaching,
  aligning,
  seated,
  working,
  lying,
  rising,
  standing,
}

class AvatarFurnitureState {
  const AvatarFurnitureState({
    required this.phase,
    required this.furnitureId,
    required this.sceneId,
    required this.sequence,
    this.workSessionId,
  });
  final AvatarFurniturePhase phase;
  final String furnitureId;
  final String sceneId;
  final int sequence;

  /// Host-only task ownership, admitted with the account/renderer observation.
  final String? workSessionId;
  bool get sleeping => phase == AvatarFurniturePhase.lying;
  bool get transitioning => const {
    AvatarFurniturePhase.approaching,
    AvatarFurniturePhase.aligning,
    AvatarFurniturePhase.rising,
  }.contains(phase);

  static const gestures = {
    'sit_sofa',
    'sit_chair',
    'work_desk',
    'lie_bed',
    'sit_bed',
    'stand_up',
  };
  static String? gestureForPosture(String value) =>
      gestures.contains(value) ? value : null;

  static AvatarFurnitureState? parse(Map<String, dynamic> json) {
    final phase = AvatarFurniturePhase.values
        .where((p) => p.name == json['phase'])
        .firstOrNull;
    final furniture = json['furnitureId'];
    final scene = json['sceneId'];
    final sequence = json['sequence'];
    final workSessionId = json['workSessionId'];
    if (phase == null ||
        sequence is! int ||
        sequence <= 0 ||
        sequence > 9007199254740991 ||
        furniture is! String ||
        !const {'', 'sofa', 'chair', 'desk', 'bed'}.contains(furniture) ||
        scene is! String ||
        scene.isEmpty ||
        scene.length > 128 ||
        (phase != AvatarFurniturePhase.standing && furniture.isEmpty) ||
        (workSessionId != null &&
            workSessionId != '' &&
            (workSessionId is! String ||
                !RegExp(r'^[a-f0-9]{64}$').hasMatch(workSessionId) ||
                furniture != 'desk' ||
                !const {
                  AvatarFurniturePhase.approaching,
                  AvatarFurniturePhase.aligning,
                  AvatarFurniturePhase.working,
                }.contains(phase)))) {
      return null;
    }
    return AvatarFurnitureState(
      phase: phase,
      furnitureId: furniture,
      sceneId: scene,
      sequence: sequence,
      workSessionId: workSessionId is String && workSessionId.isNotEmpty
          ? workSessionId
          : null,
    );
  }
}

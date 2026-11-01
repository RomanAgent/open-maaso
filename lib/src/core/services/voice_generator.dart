import 'dart:math';

class VoiceGenerator {
  static const _maleVoices = [1, 5, 12, 18, 23, 30, 35, 42, 48];
  static const _femaleVoices = [0, 3, 7, 15, 20, 27, 33, 40, 45, 50];

  String generateForGender(String gender) {
    final pool = gender == 'male' ? _maleVoices : _femaleVoices;
    final idx = Random.secure().nextInt(pool.length);
    return pool[idx].toString();
  }
}

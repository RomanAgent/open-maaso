import 'dart:math';

class GenderGenerator {
  String generate() {
    return Random.secure().nextBool() ? 'female' : 'male';
  }
}

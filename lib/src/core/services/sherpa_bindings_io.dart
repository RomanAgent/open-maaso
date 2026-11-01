import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

bool get sherpaBindingsAvailable => true;

void initializeSherpaBindings() => sherpa.initBindings();

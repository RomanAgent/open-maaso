import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/project_build/domain/project_json_canonicalizer.dart';

double _binary64(String hex) {
  final data = ByteData(8)
    ..setUint32(0, int.parse(hex.substring(0, 8), radix: 16))
    ..setUint32(4, int.parse(hex.substring(8), radix: 16));
  return data.getFloat64(0);
}

void main() {
  const jcs = ProjectJsonCanonicalizer();
  test('RFC 8785 primitive and UTF-16 sorting samples', () {
    const source =
        r'''{"numbers":[333333333.33333329,1E30,4.50,2e-3,0.000000000000000000000000001],"string":"\u20ac$\u000F\u000aA'\u0042\u0022\u005c\\\"\/","literals":[null,true,false]}''';
    expect(
      jcs.canonicalize(jcs.parse(source)),
      r'''{"literals":[null,true,false],"numbers":[333333333.3333333,1e+30,4.5,0.002,1e-27],"string":"€$\u000f\nA'B\"\\\\\"/"}''',
    );
    final keys = {
      '€': 'Euro',
      '\r': 'Return',
      'דּ': 'Hebrew',
      '1': 'One',
      '😀': 'Emoji',
      '\u0080': 'Control',
      'ö': 'Latin',
    };
    expect(
      jcs.canonicalize(keys),
      '{"\\r":"Return","1":"One","\u0080":"Control","ö":"Latin","€":"Euro","😀":"Emoji","דּ":"Hebrew"}',
    );
  });

  test('all finite RFC 8785 Appendix B binary64 vectors', () {
    const vectors = {
      '0000000000000000': '0',
      '8000000000000000': '0',
      '0000000000000001': '5e-324',
      '8000000000000001': '-5e-324',
      '7fefffffffffffff': '1.7976931348623157e+308',
      'ffefffffffffffff': '-1.7976931348623157e+308',
      '4340000000000000': '9007199254740992',
      'c340000000000000': '-9007199254740992',
      '4430000000000000': '295147905179352830000',
      '44b52d02c7e14af5': '9.999999999999997e+22',
      '44b52d02c7e14af6': '1e+23',
      '44b52d02c7e14af7': '1.0000000000000001e+23',
      '444b1ae4d6e2ef4e': '999999999999999700000',
      '444b1ae4d6e2ef4f': '999999999999999900000',
      '444b1ae4d6e2ef50': '1e+21',
      '3eb0c6f7a0b5ed8c': '9.999999999999997e-7',
      '3eb0c6f7a0b5ed8d': '0.000001',
      '41b3de4355555553': '333333333.3333332',
      '41b3de4355555554': '333333333.33333325',
      '41b3de4355555555': '333333333.3333333',
      '41b3de4355555556': '333333333.3333334',
      '41b3de4355555557': '333333333.33333343',
      'becbf647612f3696': '-0.0000033333333333333333',
      '43143ff3c1cb0959': '1424953923781206.2',
    };
    for (final entry in vectors.entries) {
      expect(
        jcs.canonicalize(_binary64(entry.key)),
        entry.value,
        reason: entry.key,
      );
    }
  });

  test(
    'rejects duplicate keys, invalid Unicode, nonfinite values and cycles',
    () {
      for (final source in [
        r'{"a":1,"\u0061":2}',
        r'{"nested":{"x":1,"x":2}}',
        r'"\ud800"',
        r'"\udc00"',
        '1e9999',
        '01',
        '[1,]',
        '{"x":1,}',
      ]) {
        expect(() => jcs.parse(source), throwsFormatException, reason: source);
      }
      for (final number in [
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        expect(() => jcs.canonicalize(number), throwsFormatException);
      }
      expect(
        () => jcs.canonicalize(String.fromCharCode(0xd800)),
        throwsFormatException,
      );
      final cycle = <Object?>[];
      cycle.add(cycle);
      expect(() => jcs.canonicalize(cycle), throwsFormatException);
      expect(() => jcs.canonicalize({1: 'non-string'}), throwsFormatException);
      expect(() => jcs.canonicalize(9007199254740993), throwsFormatException);
    },
  );

  test(
    'preserves strings and array order while deeply freezing parsed values',
    () {
      final parsed = jcs.parse('{"z":[{"b":2,"a":1}],"e":"é","é":"é"}') as Map;
      expect(
        jcs.canonicalize(parsed),
        '{"e":"é","z":[{"a":1,"b":2}],"é":"é"}',
      );
      expect(() => parsed['z'] = [], throwsUnsupportedError);
      expect(() => (parsed['z'] as List).clear(), throwsUnsupportedError);
      expect(
        () => ((parsed['z'] as List).single as Map).clear(),
        throwsUnsupportedError,
      );
      expect(jcs.canonicalBytes([true, null]), utf8.encode('[true,null]'));
    },
  );

  test('bounds input, output, nesting and node count', () {
    const small = ProjectJsonCanonicalizer(
      maxBytes: 16,
      maxDepth: 2,
      maxNodes: 4,
    );
    expect(() => small.parse('"${'x' * 20}"'), throwsFormatException);
    expect(() => small.canonicalize('x' * 20), throwsFormatException);
    expect(() => small.parse('[[[0]]]'), throwsFormatException);
    expect(() => small.parse('[1,2,3,4]'), throwsFormatException);
  });

  test('seeded random binary64 serialization matches a real V8 runtime', () async {
    final random = Random(8785);
    final samples = <String>[];
    while (samples.length < 10000) {
      final hex =
          '${random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0')}${random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0')}';
      if (_binary64(hex).isFinite) samples.add(hex);
    }
    final process = await Process.start('node', [
      '-e',
      r'''let input='';process.stdin.on('data',c=>input+=c);process.stdin.on('end',()=>{const values=JSON.parse(input).map(h=>JSON.stringify(Buffer.from(h,'hex').readDoubleBE(0)));process.stdout.write(JSON.stringify(values));});''',
    ]);
    process.stdin.write(jsonEncode(samples));
    await process.stdin.close();
    final outputs = await Future.wait([
      process.stdout.transform(utf8.decoder).join(),
      process.stderr.transform(utf8.decoder).join(),
    ]);
    expect(await process.exitCode, 0, reason: outputs[1]);
    final expected = jsonDecode(outputs[0]) as List;
    for (var index = 0; index < samples.length; index++) {
      expect(
        jcs.canonicalize(_binary64(samples[index])),
        expected[index],
        reason: samples[index],
      );
    }
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Release suppresses only reviewed absent optional integration classes', () {
    final lines = File('android/app/proguard-rules.pro')
        .readAsLinesSync()
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !line.startsWith('#'))
        .toList();
    const expected = <String>{
      'com.hihonor.android.magicx.media.audio.interfaces.AudioFeaturesKit',
      r'com.hihonor.android.magicx.media.audio.interfaces.HnAudioClient$ServiceType',
      'com.hihonor.android.magicx.media.audio.interfaces.HnAudioClient',
      r'com.hihonor.android.magicx.media.audio.interfaces.HnEarReturnClient$ParameName',
      'com.hihonor.android.magicx.media.audio.interfaces.HnEarReturnClient',
      'com.hihonor.android.magicx.media.audio.interfaces.IAudioServiceCallback',
      'java.awt.Color',
      'java.awt.Font',
      'java.awt.Point',
      'java.awt.Rectangle',
      'javax.money.CurrencyUnit',
      'javax.money.Monetary',
      'javax.ws.rs.Consumes',
      'javax.ws.rs.Produces',
      'javax.ws.rs.core.Response',
      'javax.ws.rs.core.StreamingOutput',
      'javax.ws.rs.ext.MessageBodyReader',
      'javax.ws.rs.ext.MessageBodyWriter',
      'javax.ws.rs.ext.Provider',
      'org.glassfish.jersey.internal.spi.AutoDiscoverable',
      'org.javamoney.moneta.Money',
      'org.joda.time.DateTime',
      'org.joda.time.DateTimeZone',
      'org.joda.time.Duration',
      'org.joda.time.Instant',
      'org.joda.time.LocalDate',
      'org.joda.time.LocalDateTime',
      'org.joda.time.LocalTime',
      'org.joda.time.Period',
      'org.joda.time.ReadablePartial',
      'org.joda.time.format.DateTimeFormat',
      'org.joda.time.format.DateTimeFormatter',
      'springfox.documentation.spring.web.json.Json',
    };
    expect(lines, hasLength(expected.length));
    expect(lines.every((line) => line.startsWith('-dontwarn ')), isTrue);
    final targets = lines
        .map((line) => line.substring('-dontwarn '.length))
        .toSet();
    expect(targets, expected);
    expect(
      targets.any((target) => target.contains('*') || target.contains('?')),
      isFalse,
    );
    expect(
      targets.any(
        (target) =>
            target.startsWith('android.') ||
            target.startsWith('androidx.') ||
            target.startsWith('org.openmaaso.') ||
            target.startsWith('com.futurpals.'),
      ),
      isFalse,
    );
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    expect(gradle, isNot(contains('isMinifyEnabled = false')));
    expect(gradle, isNot(contains('isShrinkResources = false')));
  });
}

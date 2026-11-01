import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/conversation/json_reply_prefix.dart';

void main() {
  test('Chinese and English text arrive before the reply string closes', () {
    for (final text in ['理解了。我按这个想法来做。', 'Okay. I will follow that idea.']) {
      final parser = JsonReplyPrefix();
      expect(parser.add(' \n{ \t"reply" \r: "'), isEmpty);
      final first = text.substring(
        0,
        text.contains('.') ? text.indexOf('.') + 1 : text.indexOf('。') + 1,
      );
      expect(parser.add(first), first);
      expect(
        parser.add(text.substring(first.length)),
        text.substring(first.length),
      );
      expect(
        parser.add('","actions":[{"type":"creation.intent","mode":"none"}]}'),
        isEmpty,
      );
    }
  });

  test('every fragment boundary preserves ordinary JSON escapes', () {
    const text = '你好。\nHe said "okay". C:\\game\tReady / now.';
    final raw = jsonEncode({'reply': text, 'actions': <Object?>[]});
    for (var boundary = 0; boundary <= raw.length; boundary++) {
      final parser = JsonReplyPrefix();
      expect(
        parser.add(raw.substring(0, boundary)) +
            parser.add(raw.substring(boundary)),
        text,
        reason: 'boundary $boundary',
      );
    }
  });

  test('Unicode escapes and surrogate pairs are buffered until complete', () {
    final parser = JsonReplyPrefix();
    expect(parser.add(r'{"reply":"\u4'), isEmpty);
    expect(parser.add('f60'), '你');
    expect(parser.add(r'\u597'), isEmpty);
    expect(parser.add('d'), '好');
    expect(parser.add(r'\uD83D'), isEmpty);
    expect(parser.add(r'\uDE'), isEmpty);
    expect(parser.add('42'), '🙂');
    expect(parser.add('","actions":[]}'), isEmpty);
  });

  test('literal supplementary characters do not leak a high surrogate', () {
    final parser = JsonReplyPrefix();
    final codeUnits = '🙂'.codeUnits;
    expect(parser.add('{"reply":"'), isEmpty);
    expect(parser.add(String.fromCharCode(codeUnits.first)), isEmpty);
    expect(parser.add(String.fromCharCode(codeUnits.last)), '🙂');
  });

  test(
    'an escaped backslash never turns following text into a Unicode escape',
    () {
      final parser = JsonReplyPrefix();
      expect(parser.add(r'{"reply":"\\'), r'\');
      expect(parser.add(r'u4f60'), 'u4f60');
      expect(parser.add(r'\\n'), r'\n');
      expect(parser.add('","actions":[]}'), isEmpty);
    },
  );

  test(
    'partial escapes remain private until their escaped character arrives',
    () {
      final parser = JsonReplyPrefix();
      expect(parser.add('{"reply":"Hello.'), 'Hello.');
      expect(parser.add('\\'), isEmpty);
      expect(parser.add('n'), '\n');
      expect(parser.add('\\'), isEmpty);
      expect(parser.add('"'), '"');
      expect(parser.add(' End."'), ' End.');
    },
  );

  test('only a literal first root reply string can supply text', () {
    for (final raw in [
      '{"actions":[{"text":"fake"}],"reply":"late"}',
      '{"other":{"reply":"nested"},"reply":"late"}',
      '{"reply":{"reply":"nested"},"actions":[]}',
      r'{"re\u0070ly":"escaped key","actions":[]}',
      '{"Reply":"wrong case","actions":[]}',
      '"{\\"reply\\":\\"quoted fake\\"}"',
      'ordinary text {"reply":"embedded"}',
      '[{"reply":"array fake"}]',
    ]) {
      final parser = JsonReplyPrefix();
      final output = StringBuffer();
      for (final code in raw.codeUnits) {
        output.write(parser.add(String.fromCharCode(code)));
      }
      expect(output.toString(), isEmpty, reason: raw);
    }
  });

  test(
    'nested-looking literals and action metadata never reopen the channel',
    () {
      final parser = JsonReplyPrefix();
      const text = '他说 {"reply":"只是引用"}。';
      final reply = jsonEncode(text);
      expect(parser.add('{"reply":$reply'), text);
      expect(
        parser.add(
          ',"actions":[{"type":"creation.intent","mode":"create",'
          '"requirements":"secret metadata","kind":"game"}]}',
        ),
        isEmpty,
      );
      expect(parser.add('{"reply":"a second root"}'), isEmpty);
    },
  );

  test(
    'invalid escapes and incomplete surrogate pairs cannot leak raw syntax',
    () {
      for (final suffix in [
        r'\x',
        r'\uZZZZ',
        r'\uD800x',
        r'\uDC00',
        r'\uD800"',
      ]) {
        final parser = JsonReplyPrefix();
        expect(parser.add('{"reply":"'), isEmpty);
        expect(() => parser.add(suffix), throwsFormatException, reason: suffix);
      }
    },
  );
}

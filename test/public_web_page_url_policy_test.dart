import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/skills/public_web_page_url_policy.dart';

void main() {
  for (final url in [
    'https://example.com/article?q=weather',
    'https://news.example.com:443/path',
    'https://xn--fiqs8s.example.com/',
  ]) {
    test('allows public HTTPS hostname syntax $url', () {
      expect(isPublicWebPageUrl(url), true);
    });
  }
  for (final url in [
    '',
    'http://example.com/',
    'file:///etc/passwd',
    'https://localhost/',
    'https://host.localhost/',
    'https://router.local/',
    'https://router.home.arpa/',
    'https://host.internal/',
    'https://host.test/',
    'https://127.0.0.1/',
    'https://[::1]/',
    'https://[64:ff9b::808:808]/',
    'https://2130706433/',
    'https://0x7f000001/',
    'https://0177.0.0.1/',
    'https://username:password@example.com/',
    'https://@example.com/',
    'https://example.com:444/',
    'https://example.com./',
    'https://example.com/\nprivate',
    r'https://example.com\@localhost/',
  ]) {
    test('rejects unsafe or ambiguous URL $url', () {
      expect(isPublicWebPageUrl(url), false);
    });
  }

  test('removes fragment from the request URL', () {
    expect(
      validatePublicWebPageUrl('https://example.com/#private').fragment,
      '',
    );
  });

  for (final address in [
    '1.1.1.1',
    '8.8.8.8',
    '93.184.216.34',
    '2606:4700:4700::1111',
    '2001:4860:4860::8888',
    '64:ff9b::1.1.1.1',
    '64:ff9b::808:808',
  ]) {
    test('accepts global DNS answer $address', () {
      expect(
        isPublicWebPageAddressBytes(InternetAddress(address).rawAddress),
        true,
      );
    });
  }

  for (final address in [
    '0.0.0.0',
    '10.1.2.3',
    '127.0.0.1',
    '100.64.0.1',
    '100.127.255.255',
    '169.254.169.254',
    '172.16.0.1',
    '172.31.255.255',
    '192.0.0.1',
    '192.0.2.1',
    '192.88.99.1',
    '192.168.1.1',
    '198.18.0.1',
    '198.19.255.255',
    '198.51.100.1',
    '203.0.113.1',
    '224.0.0.1',
    '255.255.255.255',
    '::',
    '::1',
    'fc00::1',
    'fe80::1',
    'ff02::1',
    '::ffff:127.0.0.1',
    '64:ff9b::a00:1',
    '64:ff9b::7f00:1',
    '64:ff9b::c000:201',
    '64:ff9b::c0a8:101',
    '64:ff9b::c612:1',
    '64:ff9b::ffff:ffff',
    '64:ff9b:1::808:808',
    '64:ff9b:1:ffff:ffff:ffff:808:808',
    '64:ff9b:0:0:1::808:808',
    '2001:db8::1',
    '2001::1',
    '2001:2::1',
    '2001:10::1',
    '2001:20::1',
    '2002:7f00:1::1',
    '3fff::1',
  ]) {
    test('rejects special-use DNS answer $address', () {
      expect(
        isPublicWebPageAddressBytes(InternetAddress(address).rawAddress),
        false,
      );
    });
  }
}

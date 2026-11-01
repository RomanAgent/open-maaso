/// A bounded, machine-readable rejection from the public page transport.
class PublicWebPageRequestException implements Exception {
  const PublicWebPageRequestException(this.code, {required this.failureStage});

  final String code;
  final String failureStage;
}

/// Syntax validation is deliberately independent from DNS validation. The
/// native transport also checks every resolved address before opening a socket.
Uri validatePublicWebPageUrl(String rawUrl) {
  final raw = rawUrl.trim();
  final uri = Uri.tryParse(raw);
  if (raw.isEmpty ||
      raw.length > 8192 ||
      RegExp(r'[\x00-\x20\x7f\\]').hasMatch(raw) ||
      uri == null ||
      !uri.hasAuthority) {
    throw const PublicWebPageRequestException(
      'invalid_url',
      failureStage: 'url',
    );
  }
  if (uri.scheme.toLowerCase() != 'https') {
    throw const PublicWebPageRequestException(
      'https_required',
      failureStage: 'url',
    );
  }
  final rawAuthority = RegExp(
    r'^https://([^/?#]*)',
    caseSensitive: false,
  ).firstMatch(raw)?.group(1);
  if (rawAuthority == null ||
      rawAuthority.contains('@') ||
      uri.authority.contains('@') ||
      uri.userInfo.isNotEmpty ||
      uri.port != 443) {
    throw const PublicWebPageRequestException(
      'unsafe_url',
      failureStage: 'url',
    );
  }
  final host = uri.host.toLowerCase();
  final labels = host.split('.');
  const localSuffixes = {
    'localhost',
    'local',
    'localdomain',
    'internal',
    'intranet',
    'lan',
    'home',
    'home.arpa',
    'test',
    'invalid',
    'onion',
  };
  final local = localSuffixes.any(
    (suffix) => host == suffix || host.endsWith('.$suffix'),
  );
  if (host.length > 253 ||
      labels.length < 2 ||
      local ||
      !RegExp(r'^[a-z]{2,63}$|^xn--[a-z0-9-]{2,59}$').hasMatch(labels.last) ||
      labels.any(
        (label) =>
            label.isEmpty ||
            label.length > 63 ||
            !RegExp(r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$').hasMatch(label),
      )) {
    throw const PublicWebPageRequestException(
      'public_hostname_required',
      failureStage: 'url',
    );
  }
  return uri.removeFragment();
}

bool isPublicWebPageUrl(String rawUrl) {
  try {
    validatePublicWebPageUrl(rawUrl);
    return true;
  } on PublicWebPageRequestException {
    return false;
  }
}

/// Excludes private, loopback, link-local, multicast, documentation, benchmark,
/// unsafe translation, and other special-use addresses. A DNS answer containing even
/// one disallowed address is rejected by the native transport.
bool isPublicWebPageAddressBytes(List<int> bytes) {
  if (bytes.any((byte) => byte < 0 || byte > 255)) return false;
  if (bytes.length == 4) {
    final a = bytes[0];
    final b = bytes[1];
    final c = bytes[2];
    return !(a == 0 ||
        a == 10 ||
        a == 127 ||
        a >= 224 ||
        (a == 100 && b >= 64 && b <= 127) ||
        (a == 169 && b == 254) ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 0 && (c == 0 || c == 2)) ||
        (a == 192 && b == 88 && c == 99) ||
        (a == 192 && b == 168) ||
        (a == 198 && (b == 18 || b == 19)) ||
        (a == 198 && b == 51 && c == 100) ||
        (a == 203 && b == 0 && c == 113));
  }
  if (bytes.length != 16) return false;
  // RFC 6052's well-known /96 prefix supports DNS64/NAT64 on IPv6-only
  // networks. Its last 32 bits must still pass the public IPv4 policy.
  // Do not extend this exception to RFC 8215's local-use 64:ff9b:1::/48.
  if (bytes[0] == 0 &&
      bytes[1] == 0x64 &&
      bytes[2] == 0xff &&
      bytes[3] == 0x9b &&
      bytes.sublist(4, 12).every((byte) => byte == 0)) {
    return isPublicWebPageAddressBytes(bytes.sublist(12));
  }
  if ((bytes[0] & 0xe0) != 0x20) return false;
  // Only global unicast 2000::/3 is eligible; reject its special-use ranges.
  if (bytes[0] == 0x20 && bytes[1] == 0x02) return false; // 6to4.
  if (bytes[0] == 0x20 && bytes[1] == 0x01) {
    if ((bytes[2] == 0 && bytes[3] <= 2) || // Teredo / benchmark.
        (bytes[2] == 0x0d && bytes[3] == 0xb8) || // Documentation.
        (bytes[2] == 0 && (bytes[3] & 0xf0) == 0x10) || // ORCHID.
        (bytes[2] == 0 && (bytes[3] & 0xf0) == 0x20)) {
      return false;
    }
  }
  if (bytes[0] == 0x3f && bytes[1] == 0xff && (bytes[2] & 0xf0) == 0) {
    return false; // 3fff::/20 documentation.
  }
  return true;
}

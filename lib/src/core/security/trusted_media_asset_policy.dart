import 'package:maaso/src/core/services/app_environment_service.dart';

/// Exact-host policy for media URLs that Flutter fetches automatically.
///
/// The deployed CDN hosts are build-time trust configuration. Feed payloads
/// can select paths on those hosts, but can never expand the host allowlist.
class TrustedMediaAssetPolicy {
  const TrustedMediaAssetPolicy({required this.allowedHosts});

  static const String _testHostConfiguration = String.fromEnvironment(
    'MAASO_TEST_MEDIA_CDN_HOSTS',
    defaultValue: '',
  );
  static const String _productionHostConfiguration = String.fromEnvironment(
    'MAASO_PRODUCTION_MEDIA_CDN_HOSTS',
    defaultValue: '',
  );

  final Set<String> allowedHosts;

  factory TrustedMediaAssetPolicy.forEnvironment(MaasoEnvironment environment) {
    return TrustedMediaAssetPolicy.fromConfigurations(
      environment: environment,
      testHosts: _testHostConfiguration,
      productionHosts: _productionHostConfiguration,
    );
  }

  factory TrustedMediaAssetPolicy.fromConfigurations({
    required MaasoEnvironment environment,
    required String testHosts,
    required String productionHosts,
  }) {
    final configured = environment == MaasoEnvironment.test
        ? testHosts
        : productionHosts;
    return TrustedMediaAssetPolicy(
      allowedHosts: Set<String>.unmodifiable(
        configured
            .split(',')
            .map((host) => host.trim().toLowerCase())
            .where(_isValidConfiguredHost),
      ),
    );
  }

  bool allows(Uri uri) {
    final host = uri.host.toLowerCase();
    return uri.scheme == 'https' &&
        uri.userInfo.isEmpty &&
        !uri.hasFragment &&
        (!uri.hasPort || uri.port == 443) &&
        _isValidConfiguredHost(host) &&
        allowedHosts.any((allowed) => allowed.toLowerCase() == host);
  }

  static bool _isValidConfiguredHost(String value) {
    final host = value.trim().toLowerCase();
    if (host.isEmpty ||
        host == 'localhost' ||
        host.endsWith('.localhost') ||
        host.endsWith('.local') ||
        host.endsWith('.internal') ||
        host.endsWith('.lan') ||
        host.endsWith('.home.arpa') ||
        host.endsWith('.test') ||
        host.contains(':') ||
        RegExp(r'^\d{1,3}(?:\.\d{1,3}){3}$').hasMatch(host)) {
      return false;
    }
    final labels = host.split('.');
    if (labels.length < 2) return false;
    final pattern = RegExp(r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$');
    return labels.every(
      (label) =>
          label.isNotEmpty && label.length <= 63 && pattern.hasMatch(label),
    );
  }
}

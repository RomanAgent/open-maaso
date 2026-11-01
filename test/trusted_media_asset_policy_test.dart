import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/security/trusted_media_asset_policy.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';

void main() {
  test('selects an exact trusted CDN host for each app environment', () {
    final testPolicy = TrustedMediaAssetPolicy.fromConfigurations(
      environment: MaasoEnvironment.test,
      testHosts: 'assets-test.example.com, live-test.example.com',
      productionHosts: 'assets.example.com',
    );
    final productionPolicy = TrustedMediaAssetPolicy.fromConfigurations(
      environment: MaasoEnvironment.production,
      testHosts: 'assets-test.example.com',
      productionHosts: 'assets.example.com,live.example.com',
    );

    expect(
      testPolicy.allows(Uri.parse('https://assets-test.example.com/a.jpg')),
      isTrue,
    );
    expect(
      testPolicy.allows(Uri.parse('https://assets.example.com/a.jpg')),
      isFalse,
    );
    expect(
      productionPolicy.allows(Uri.parse('https://live.example.com/a.jpg')),
      isTrue,
    );
    expect(
      productionPolicy.allows(
        Uri.parse('https://assets.example.com.attacker.test/a.jpg'),
      ),
      isFalse,
    );
  });

  test('rejects unsafe or malformed configured and response hosts', () {
    final policy = TrustedMediaAssetPolicy.fromConfigurations(
      environment: MaasoEnvironment.test,
      testHosts: 'localhost,127.0.0.1,10.0.0.1,assets.example.com',
      productionHosts: 'assets.example.com',
    );

    expect(policy.allowedHosts, <String>{'assets.example.com'});
    expect(
      policy.allows(Uri.parse('https://user@assets.example.com/a.jpg')),
      isFalse,
    );
    expect(
      policy.allows(Uri.parse('https://assets.example.com:444/a.jpg')),
      isFalse,
    );
    expect(
      policy.allows(Uri.parse('https://assets.example.com/a.jpg#fragment')),
      isFalse,
    );
    expect(policy.allows(Uri.parse('https://10.0.0.1/a.jpg')), isFalse);
  });
}

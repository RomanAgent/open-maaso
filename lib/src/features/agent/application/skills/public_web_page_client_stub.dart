import 'package:http/http.dart' as http;

import 'public_web_page_url_policy.dart';

/// Browsers cannot inspect DNS answers or pin a socket to the checked address.
/// Fail closed rather than relying on CORS or accidentally sending cookies.
http.Client createPublicWebPageClient() => PublicWebPageUnavailableClient();

class PublicWebPageUnavailableClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    validatePublicWebPageUrl(request.url.toString());
    throw const PublicWebPageRequestException(
      'public_dns_validation_unavailable',
      failureStage: 'dns',
    );
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The publisher's push relay (it holds the APNs key and the Firebase service account). A fork with its own
/// keys points `PUSH_RELAY_URL` elsewhere.
final Uri defaultRelay = Uri.parse('https://iemvfkcpmgdkupwnnewg.supabase.co/functions/v1/relay');

/// Posts pushes to the relay, which sees only a token and ciphertext.
class Relay {
  Relay(this.url, {this.log});

  final Uri url;
  final void Function(String)? log;
  final HttpClient _client = HttpClient()..connectionTimeout = const Duration(seconds: 10);

  /// The relay's status for one push (410: the phone is gone), or null when it couldn't be reached.
  Future<int?> post(Map<String, dynamic> body) async {
    try {
      final req = await _client.postUrl(url);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
      final res = await req.close().timeout(const Duration(seconds: 20));
      final text = await utf8.decodeStream(res);
      if (res.statusCode >= 300 && res.statusCode != 410) log?.call('relay ${res.statusCode} $text');
      return res.statusCode;
    } on Object catch (e) {
      log?.call('relay unreachable: $e');
      return null;
    }
  }

  void close() => _client.close(force: true);
}

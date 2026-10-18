import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocketterm_desktop/update_check.dart';

void main() {
  group('compareVersions', () {
    test('orders major, minor and patch as numbers, not text', () {
      expect(UpdateCheck.compareVersions('0.10.0', '0.9.9'), greaterThan(0));
      expect(UpdateCheck.compareVersions('1.0.0', '0.99.99'), greaterThan(0));
      expect(UpdateCheck.compareVersions('0.5.2', '0.5.10'), lessThan(0));
      expect(UpdateCheck.compareVersions('0.5.0', '0.5.0'), 0);
    });

    test('ignores build metadata; a pre-release comes before its release', () {
      expect(UpdateCheck.compareVersions('0.5.0+9', '0.5.0+5'), 0);
      expect(UpdateCheck.compareVersions('0.6.0-beta.1', '0.6.0'), lessThan(0));
      expect(UpdateCheck.compareVersions('0.6.0-beta.2', '0.6.0-beta.10'), lessThan(0));
      expect(UpdateCheck.compareVersions('0.6.0-beta', '0.6.0-alpha'), greaterThan(0));
      expect(UpdateCheck.compareVersions('0.6.0-rc.1', '0.5.0'), greaterThan(0));
    });

    test('is null for anything that is not a version', () {
      expect(UpdateCheck.compareVersions('latest', '0.5.0'), isNull);
      expect(UpdateCheck.compareVersions('0.6', '0.5.0'), isNull);
      expect(UpdateCheck.compareVersions('0.6.0', ''), isNull);
    });
  });

  group('newer', () {
    const page = 'https://github.com/danyzmaj-apps/pocketterm/releases/tag/v0.6.0';

    test('a higher tag, with or without its v, is the update', () {
      expect(
        UpdateCheck.newer({'tag_name': 'v0.6.0', 'html_url': page}, '0.5.0'),
        UpdateInfo('0.6.0', Uri.parse(page)),
      );
      expect(UpdateCheck.newer({'tag_name': '0.6.0', 'html_url': page}, '0.5.0')?.version, '0.6.0');
    });

    test('the same, an older or an unreadable release is none', () {
      expect(UpdateCheck.newer({'tag_name': 'v0.5.0', 'html_url': page}, '0.5.0'), isNull);
      expect(UpdateCheck.newer({'tag_name': 'v0.4.9', 'html_url': page}, '0.5.0'), isNull);
      expect(UpdateCheck.newer({'tag_name': 'nightly', 'html_url': page}, '0.5.0'), isNull);
      expect(UpdateCheck.newer({'tag_name': 'v0.6.0'}, '0.5.0'), isNull);
      expect(UpdateCheck.newer({'tag_name': 'v0.6.0', 'html_url': 'http://example.com/x'}, '0.5.0'), isNull);
      expect(UpdateCheck.newer(['v0.6.0'], '0.5.0'), isNull);
    });
  });

  group('check', () {
    UpdateCheck checker(Future<http.Response> Function(http.Request) answer) =>
        UpdateCheck(client: MockClient(answer), version: () async => '0.5.0');

    test("asks GitHub's latest release and tells listeners about a newer one", () async {
      Uri? asked;
      final check = checker((req) async {
        asked = req.url;
        return http.Response(
          jsonEncode({
            'tag_name': 'v0.6.0',
            'html_url': 'https://github.com/danyzmaj-apps/pocketterm/releases/tag/v0.6.0',
          }),
          200,
        );
      });
      addTearDown(check.dispose);
      var told = 0;
      check.addListener(() => told++);
      await check.check();
      expect(asked, Uri.parse('https://api.github.com/repos/danyzmaj-apps/pocketterm/releases/latest'));
      expect(check.update?.version, '0.6.0');
      expect(told, 1);
      // The same answer again changes nothing.
      await check.check();
      expect(told, 1);
    });

    test('a failed check shows nothing, also after one that found an update', () async {
      var fail = false;
      final check = checker((_) async {
        if (fail) throw http.ClientException('offline');
        return http.Response(jsonEncode({'tag_name': 'v0.6.0', 'html_url': 'https://github.com/x'}), 200);
      });
      addTearDown(check.dispose);
      await check.check();
      expect(check.update, isNotNull);
      fail = true;
      await check.check();
      expect(check.update, isNull);
    });

    test('an error status or a body that is not JSON shows nothing', () async {
      for (final r in [http.Response('{"message":"API rate limit exceeded"}', 403), http.Response('<html>', 200)]) {
        final check = checker((_) async => r);
        addTearDown(check.dispose);
        await check.check();
        expect(check.update, isNull);
      }
    });
  });
}

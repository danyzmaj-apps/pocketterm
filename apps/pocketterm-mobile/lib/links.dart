import 'dart:async';

import 'package:url_launcher/url_launcher.dart';

/// PocketTerm's home: the source, the docs and the desktop downloads.
const repoUrl = 'https://github.com/danyzmaj-apps/pocketterm';

/// The desktop app's latest release (Mac DMG, Windows installer).
const desktopDownloadsUrl = '$repoUrl/releases/latest';

/// Opens [url] in the browser, outside the app.
void openExternal(String url) => unawaited(launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication));

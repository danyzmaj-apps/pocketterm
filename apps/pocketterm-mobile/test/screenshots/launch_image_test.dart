// The iPhone's launch icons (ios/Runner/Assets.xcassets/LaunchIcon<Theme>.imageset): the intro's first frame in each
// theme, drawn by the intro's own painter, so the intro takes over from the launch screen without a visible change.
// LaunchScreen.storyboard shows Catppuccin Mocha's (a storyboard can't follow the picked theme); SceneDelegate.swift
// shows the picked theme's until Flutter's first frame. Both put it 42% of the screen's short side across, at most
// 360 pt, centred on the theme's background, as the intro draws it.
// Run from apps/pocketterm-mobile after changing the logo, a theme or the intro's start:
//   fvm flutter test test/screenshots/launch_image_test.dart --tags screenshots --run-skipped
@Tags(['screenshots'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/intro.dart';
import 'package:pocketterm_core/logo.dart';
import 'package:pocketterm_core/theme.dart';

void main() {
  test('each theme\u2019s launch icon at 360 pt, @1x to @3x', () async {
    const side = 360.0;
    for (final (name, theme) in [
      ('Mocha', PtTheme.mocha),
      ('Dawn', PtTheme.dawn),
      ('TokyoNight', PtTheme.tokyoNight),
      ('Gruvbox', PtTheme.gruvbox),
    ]) {
      final dir = Directory('ios/Runner/Assets.xcassets/LaunchIcon$name.imageset')..createSync();
      final images = <Map<String, String>>[];
      for (final scale in [1, 2, 3]) {
        final file = 'LaunchIcon$name${scale == 1 ? '' : '@${scale}x'}.png';
        final recorder = ui.PictureRecorder();
        paintLaunchIcon(ui.Canvas(recorder)..scale(scale.toDouble()), LogoStyle.of(theme), side);
        final px = (side * scale).round();
        final image = await recorder.endRecording().toImage(px, px);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        File('${dir.path}/$file').writeAsBytesSync(png!.buffer.asUint8List());
        image.dispose();
        images.add({'idiom': 'universal', 'filename': file, 'scale': '${scale}x'});
      }
      File('${dir.path}/Contents.json').writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert({
          'images': images,
          'info': {'version': 1, 'author': 'xcode'},
        })}\n',
      );
    }
  });
}

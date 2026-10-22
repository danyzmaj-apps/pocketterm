import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocketterm_desktop/prompt_files.dart';

void main() {
  late Directory dir;
  late PromptFiles files;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('pocketterm_prompt_files');
    files = PromptFiles(Directory(p.join(dir.path, 'pocketterm-files')));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  ({String name, String mime, Uint8List bytes}) file(String name, String text, {String mime = ''}) =>
      (name: name, mime: mime, bytes: Uint8List.fromList(text.codeUnits));

  test('files land under their own names, in a folder of their own per prompt, nothing overwritten', () async {
    final first = await files.save([file('notes.txt', 'one'), file('notes.txt', 'two'), file('notes.txt', 'three')]);
    expect(first.map(p.basename), ['notes.txt', 'notes (2).txt', 'notes (3).txt']);
    expect(first.map((f) => File(f).readAsStringSync()), ['one', 'two', 'three']);
    expect(first.map(p.dirname).toSet(), hasLength(1));
    expect(p.isWithin(files.dir.path, first.first), isTrue);

    final second = await files.save([file('notes.txt', 'later')]);
    expect(p.basename(second.single), 'notes.txt');
    expect(p.dirname(second.single), isNot(p.dirname(first.first)), reason: "another prompt's folder");
    expect(File(first.first).readAsStringSync(), 'one');
  });

  test('a name that tries to leave its folder stays in it', () async {
    final saved = await files.save([
      file('../../.ssh/authorized_keys', 'a'),
      file(r'..\..\Windows\evil.bat', 'b'),
      file('..', 'c'),
      file('/etc/passwd', 'd'),
      file('a\u0000b\nc.txt', 'e'),
    ]);
    for (final path in saved) {
      expect(p.isWithin(files.dir.path, path), isTrue, reason: path);
      expect(p.split(p.relative(path, from: files.dir.path)), hasLength(2), reason: path);
    }
    expect(saved.map(p.basename), ['authorized_keys', 'evil.bat', 'file', 'passwd', 'abc.txt']);
  });

  test('safe names: no characters Windows refuses, no device names, ends without dots or spaces, length capped', () {
    expect(safeFileName('re: "plan" <v2>?.md'), 're plan v2.md');
    expect(safeFileName('CON.txt'), '_CON.txt');
    expect(safeFileName('report. . '), 'report');
    expect(safeFileName('...'), 'file');
    expect(safeFileName('.env'), '.env', reason: 'a hidden file keeps its name');
    expect(safeFileName('scan', mime: 'application/pdf'), 'scan.pdf');
    expect(safeFileName('scan', mime: 'application/x-unknown'), 'scan');
    final long = safeFileName('${'a' * 300}.pdf');
    expect(long, hasLength(120));
    expect(long, endsWith('.pdf'));
  });

  test('every name Windows opens as a device gets a prefix, however it is written', () {
    for (final name in [r'conin$', r'CONOUT$.txt', 'COM¹.log', 'lpt³', 'CON .txt', 'nul.tar.gz', 'Aux']) {
      expect(safeFileName(name), '_$name', reason: name);
    }
    for (final name in ['console.txt', 'com10.txt', 'conin.txt', 'lpt.md']) {
      expect(safeFileName(name), name, reason: name);
    }
  });

  test('a prompt names its files as omp and Claude Code take them at the computer', () {
    expect(
      withMentions('look at these', ['/tmp/pt/a1/notes.txt', '/tmp/pt/a1/my notes.txt']),
      'look at these\n\n@/tmp/pt/a1/notes.txt @"/tmp/pt/a1/my notes.txt"',
    );
    expect(withMentions('  ', ['/tmp/pt/a1/x.pdf']), '@/tmp/pt/a1/x.pdf');
    expect(withMentions('just words', const []), 'just words');
    // A trailing dot or comma would be taken for punctuation; Windows paths have : and \.
    expect(fileMention('/tmp/pt/a1/v1.'), '@"/tmp/pt/a1/v1."');
    expect(
      fileMention(r'C:\Users\me\AppData\Local\Temp\pocketterm-files\a1\x.pdf'),
      r'@"C:\Users\me\AppData\Local\Temp\pocketterm-files\a1\x.pdf"',
    );
    expect(fileMention("/tmp/pt/a1/it's.txt"), '@"/tmp/pt/a1/it\'s.txt"');
  });

  test('folders older than a day go; newer ones stay', () async {
    final old = p.dirname((await files.save([file('old.txt', 'x')])).single);
    final fresh = p.dirname((await files.save([file('new.txt', 'y')])).single);
    final twoDaysAgo = DateTime.now().subtract(const Duration(days: 2));
    final stamp = [
      twoDaysAgo.year,
      for (final n in [twoDaysAgo.month, twoDaysAgo.day, twoDaysAgo.hour, twoDaysAgo.minute]) '$n'.padLeft(2, '0'),
    ].join();
    expect((await Process.run('touch', ['-t', stamp, old])).exitCode, 0);

    await files.prune();
    expect(Directory(old).existsSync(), isFalse);
    expect(Directory(fresh).existsSync(), isTrue);
  }, testOn: '!windows');
}

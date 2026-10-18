@TestOn('vm')
library;

import 'dart:io';

import 'package:kugelaudio/kugelaudio.dart';
import 'package:test/test.dart';

void main() {
  test('packageVersion matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match =
        RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(pubspec);
    expect(packageVersion, match![1]);
  });

  test('CHANGELOG.md has an entry for this version', () {
    expect(File('CHANGELOG.md').readAsStringSync(),
        contains('## $packageVersion'));
  });
}

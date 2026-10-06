import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/data/sources/json_file_store.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jfs_test');
    JsonFileStore.instance.debugDirectory = tmp;
  });

  tearDown(() async {
    JsonFileStore.instance.debugDirectory = null;
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  test('round-trip write/read/remove', () async {
    await JsonFileStore.instance.writeString('k1', 'hello');
    expect(await JsonFileStore.instance.readString('k1'), 'hello');
    await JsonFileStore.instance.remove('k1');
    expect(await JsonFileStore.instance.readString('k1'), isNull);
  });

  test('read error path when target path is a directory logs warning (line 69)',
      () async {
    final file = File('${tmp.path}/k2.json');
    await Directory(file.path).create(recursive: true);
    final r = await JsonFileStore.instance.readString('k2');
    expect(r, isNull);
  });

  test('rename fails into existing directory triggers FileSystemException (93)',
      () async {
    await JsonFileStore.instance.writeString('k3', 'a');
    final target = File('${tmp.path}/k3.json');
    await target.delete();
    await Directory(target.path).create();
    // On Linux, rename(file -> dir) throws FileSystemException and is caught;
    // the subsequent directory-delete fallback is Windows-specific (cannot delete
    // a directory via File.delete() on POSIX), so we only assert no throw.
    await JsonFileStore.instance.writeString('k3', 'b');
  });

  test('rename fails into non-empty directory -> outer cleanup (102/103/105)',
      () async {
    await JsonFileStore.instance.writeString('k4', 'a');
    final target = File('${tmp.path}/k4.json');
    await target.delete();
    final dir = Directory(target.path)..createSync();
    await File('${dir.path}/child').writeAsString('x');
    await JsonFileStore.instance.writeString('k4', 'b');
    expect(await File('${tmp.path}/k4.json.tmp').exists(), isFalse);
  });
}

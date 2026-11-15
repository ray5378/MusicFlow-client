import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/services/apk_cache_janitor.dart';
import 'package:musicflow_client/core/services/apk_cache_paths.dart';

/// 安装包清理（时机二：每次启动一次）的行为钉子。
///
/// 判据**只**来自旁车 meta，绝不解析文件名 —— 文件名里的版本是紧凑 tag
/// （`v5.14.1` → `5141`），紧凑化有损（`5.14.1` 与 `51.4.1` 都会变成 `5141`）。
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('apk_janitor_test');
  });

  tearDown(() async {
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  });

  /// 造一个 apk 文件（内容无关，清理只看 meta）。
  Future<File> makeApk(String name) async {
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(<int>[0x50, 0x4B, 0x03, 0x04, 0x00]);
    return file;
  }

  Future<void> writeMeta(File apk, String version, DateTime at) => writeApkMeta(
    apk.path,
    ApkMeta(version: version, downloadedAt: at.toUtc()),
  );

  test('meta.version <= 当前运行版本 → 已装成功，包和 meta 都删掉', () async {
    final apk = await makeApk('MusicFlow-v5141-android.apk');
    await writeMeta(apk, '5.14.1', DateTime.utc(2026, 1, 1));

    await cleanupInstalledApks(
      pkgInfo: () async => '5.14.1',
      dirs: <Directory>[dir],
      now: () => DateTime.utc(2026, 1, 2),
    );

    expect(await apk.exists(), isFalse, reason: '同版本 ⇒ 更新已经装上了，包没用');
    expect(
      await File(apkMetaPathFor(apk.path)).exists(),
      isFalse,
      reason: 'meta 必须跟着包一起删，否则下次会把残留 meta 当孤儿',
    );
  });

  test('meta.version 更高且下载超过 24 小时 → 装了但失败，删掉', () async {
    final apk = await makeApk('MusicFlow-v5150-android.apk');
    final now = DateTime.utc(2026, 5, 10, 12);
    await writeMeta(apk, '5.15.0', now.subtract(const Duration(hours: 25)));

    await cleanupInstalledApks(
      pkgInfo: () async => '5.14.1',
      dirs: <Directory>[dir],
      now: () => now,
    );

    expect(await apk.exists(), isFalse, reason: '超 24h 的更版本包当垃圾清掉');
  });

  test('meta.version 更高但刚下完（1 小时前）→ 留着让用户重试', () async {
    final apk = await makeApk('MusicFlow-v5150-android.apk');
    final now = DateTime.utc(2026, 5, 10, 12);
    await writeMeta(apk, '5.15.0', now.subtract(const Duration(hours: 1)));

    await cleanupInstalledApks(
      pkgInfo: () async => '5.14.1',
      dirs: <Directory>[dir],
      now: () => now,
    );

    expect(
      await apk.exists(),
      isTrue,
      reason: '用户可能在安装器上点了取消，留 24h 让他直接重试，不必重下几十 MB',
    );
    expect(await File(apkMetaPathFor(apk.path)).exists(), isTrue);
  });

  test('没有 meta 的孤儿 apk → 无法判定版本，删掉', () async {
    final orphan = await makeApk('unknown-build.apk');
    final kept = await makeApk('MusicFlow-v5150-android.apk');
    final now = DateTime.utc(2026, 5, 10, 12);
    await writeMeta(kept, '5.15.0', now.subtract(const Duration(minutes: 5)));

    await cleanupInstalledApks(
      pkgInfo: () async => '5.14.1',
      dirs: <Directory>[dir],
      now: () => now,
    );

    expect(await orphan.exists(), isFalse, reason: '历史遗留的孤儿包必须清掉');
    expect(await kept.exists(), isTrue, reason: '有 meta 且未超期的不许误删');
  });

  test('meta 损坏 → 当孤儿处理（删包），全程不抛', () async {
    final apk = await makeApk('MusicFlow-v5150-android.apk');
    await File(apkMetaPathFor(apk.path)).writeAsString('{ not json');

    await expectLater(
      cleanupInstalledApks(
        pkgInfo: () async => '5.14.1',
        dirs: <Directory>[dir],
        now: () => DateTime.utc(2026, 5, 10),
      ),
      completes,
      reason: 'meta 损坏绝不能把启动流程搞崩',
    );
    expect(await apk.exists(), isFalse);
  });

  test('目录不存在 / PackageInfo 读不到版本 → 静默跳过', () async {
    final missing = Directory('${dir.path}${Platform.pathSeparator}nope');

    await expectLater(
      cleanupInstalledApks(
        pkgInfo: () async => '5.14.1',
        dirs: <Directory>[missing],
        now: () => DateTime.utc(2026, 5, 10),
      ),
      completes,
      reason: '目录不存在必须静默（首装根本还没有这个目录）',
    );

    final apk = await makeApk('MusicFlow-v5150-android.apk');
    await cleanupInstalledApks(
      pkgInfo: () async => '',
      dirs: <Directory>[dir],
      now: () => DateTime.utc(2026, 5, 10),
    );
    expect(await apk.exists(), isTrue, reason: '拿不到当前版本就无从判定，宁可留着也不许瞎删');
  });

  test('下载前清旧包：只删 meta 版本更低的，同版本与更高版本都留', () async {
    final older = await makeApk('old.apk');
    final same = await makeApk('same.apk');
    final newer = await makeApk('new.apk');
    final orphan = await makeApk('orphan.apk');
    final stamp = DateTime.utc(2026, 5, 10);
    await writeMeta(older, '5.13.0', stamp);
    await writeMeta(same, '5.14.1', stamp);
    await writeMeta(newer, '5.15.0', stamp);

    await purgeStaleApks(targetVersion: '5.14.1', dir: dir);

    expect(await older.exists(), isFalse, reason: '旧版本包留着没意义');
    expect(await orphan.exists(), isFalse, reason: '孤儿包无法判定，一并清掉');
    expect(await same.exists(), isTrue, reason: '同版本交给下载服务自己删同名文件');
    expect(await newer.exists(), isTrue, reason: '更高版本不许抢着删');
  });

  test('compareAppVersions 口径：缺位补 0，非数字按 0', () {
    expect(compareAppVersions('5.14.1', '5.14.1'), 0);
    expect(compareAppVersions('5.14.1', '5.14.2'), lessThan(0));
    expect(compareAppVersions('5.15.0', '5.14.9'), greaterThan(0));
    expect(compareAppVersions('5.14', '5.14.0'), 0, reason: '缺位补 0');
    expect(compareAppVersions('5.14.1', '5.14.1.1'), lessThan(0));
    expect(compareAppVersions('x.y.z', '0.0.0'), 0, reason: '非数字按 0');
  });

  test('旁车 meta 是 JSON，往返一致（版本 + 下载时刻）', () async {
    final apk = await makeApk('roundtrip.apk');
    final at = DateTime.utc(2026, 5, 10, 8, 30);
    await writeApkMeta(apk.path, ApkMeta(version: '5.15.0', downloadedAt: at));

    final raw = await File(apkMetaPathFor(apk.path)).readAsString();
    expect(raw.contains('"version"'), isTrue);
    final meta = await readApkMeta(apk.path);
    expect(meta, isNotNull);
    expect(meta!.version, '5.15.0');
    expect(meta.downloadedAt.toUtc(), at);
    expect(jsonDecode(raw), isA<Map<String, dynamic>>());
  });
}

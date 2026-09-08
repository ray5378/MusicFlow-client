import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'package:musicflow_client/core/utils/logger.dart';

/// 文件 KV 存储（每键一个 JSON 文件，tmp+rename 原子写）。
///
/// 为什么大数据不能用 SharedPreferences：Windows 的 shared_preferences 实现
/// 每次写入**任何一个键**都会把整个 prefs map 全量 jsonEncode + 同步重写整个
/// 文件——任一键的写入成本等于全部键的总大小。历史教训：一条 metadata 缓存
/// 键膨胀到 87MB，导致每 5 秒一次的播放会话落盘都要全量重写 93MB 文件，平台
/// 线程（Windows 上 Dart UI 与平台消息泵同线程）被持续烧满，滚动假死。
/// 这里改为每键独立文件：写入成本只与本键大小相关，tmp+rename 原子替换，
/// 崩溃/强杀不会留下半写文件。
class JsonFileStore {
  JsonFileStore._();

  static final JsonFileStore instance = JsonFileStore._();

  static const String _logTag = 'FILE_STORE';

  Directory? _dir;
  Directory? _testDir;
  final Map<String, Future<void>> _writeQueues = <String, Future<void>>{};

  /// 测试注入临时目录（生产代码不要调用）。
  set debugDirectory(Directory? dir) => _testDir = dir;

  Future<Directory> _resolveDir() async {
    final test = _testDir;
    if (test != null) {
      if (!test.existsSync()) test.createSync(recursive: true);
      return test;
    }
    final cached = _dir;
    if (cached != null) return cached;
    // widget 测试(FakeAsync)中未 mock 的平台通道永不返回——测试环境退化为
    // 一次性临时目录，避免无注入的测试路径卡死；确定性测试应注入 debugDirectory。
    if (Platform.environment['FLUTTER_TEST'] != null) {
      return _dir = Directory.systemTemp.createTempSync('mf_file_store_test');
    }
    final support = await getApplicationSupportDirectory();
    final dir = Directory(
      '${support.path}${Platform.pathSeparator}storage_v2',
    );
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return _dir = dir;
  }

  /// 键 → 文件名：仅保留安全字符，其余替换为下划线。
  String _fileName(String key) {
    final safe = key.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return '$safe.json';
  }

  File _fileFor(Directory dir, String key) =>
      File('${dir.path}${Platform.pathSeparator}${_fileName(key)}');

  /// 读取键内容（原始字符串）。文件不存在或读取失败返回 null（容错不抛）。
  Future<String?> readString(String key) async {
    try {
      final dir = await _resolveDir();
      final file = _fileFor(dir, key);
      if (!file.existsSync()) return null;
      return await file.readAsString();
    } catch (e) {
      Logger.warnWithTag(_logTag, 'read failed key=$key', e);
      return null;
    }
  }

  /// 原子写入键内容。同键写入串行化（避免并发乱序导致旧值覆盖新值）。
  /// 失败只记日志不抛出——缓存/会话类数据宁可下次重写，不能反噬播放链路。
  Future<void> writeString(String key, String content) async {
    final prev = _writeQueues[key] ?? Future<void>.value();
    final task = prev.then((_) => _doWrite(key, content));
    _writeQueues[key] = task.whenComplete(() {
      if (identical(_writeQueues[key], task)) _writeQueues.remove(key);
    });
    return task;
  }

  Future<void> _doWrite(String key, String content) async {
    try {
      final dir = await _resolveDir();
      final file = _fileFor(dir, key);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(content, flush: true);
      try {
        await tmp.rename(file.path);
      } on FileSystemException {
        // 个别 Windows 文件系统/杀软占用下 rename 可能失败：删旧再换名。
        if (file.existsSync()) await file.delete();
        await tmp.rename(file.path);
      }
    } catch (e) {
      Logger.warnWithTag(_logTag, 'write failed key=$key', e);
      try {
        final dir = await _resolveDir();
        final tmp = File(
          '${dir.path}${Platform.pathSeparator}${_fileName(key)}.tmp',
        );
        if (tmp.existsSync()) await tmp.delete();
      } catch (_) {}
    }
  }

  /// 删除键（不存在时静默）。
  Future<void> remove(String key) async {
    try {
      final dir = await _resolveDir();
      final file = _fileFor(dir, key);
      if (file.existsSync()) await file.delete();
    } catch (e) {
      Logger.warnWithTag(_logTag, 'remove failed key=$key', e);
    }
  }
}

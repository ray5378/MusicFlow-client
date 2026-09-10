// 接续搬移端到端模拟的**元守卫**：钉死 handoff_e2e_test.dart 自身的有效性。
//
// 为什么需要这一层：E2E 测试起的是**本地假服务端**，它一旦写错（例如忘记设
// JSON content-type、忘记实现 /status），测试会静默变成假红/假绿。2026-09-10
// 真实踩过：假服务端没设 content-type → 客户端 postRaw 拿到的不是 Map →
// `resp is! Map` 判定失败 → 4/5 用例假红，而根因在测试脚手架而非生产代码。
//
// 本扫描钉死 E2E 脚手架的三个「必须有」，保证它一直测的是真东西：
//   1. 假服务端必须设置 JSON content-type（否则响应被当成 String）；
//   2. 必须实现 /rest/api/v1/play、/queue/play、/status、/queue 四个端点；
//   3. 必须用**真** SubsonicApiClient + **真** ProviderContainer（不是 mocktail），
//      且断言里必须包含「body 不含 items」这条主通道核心约束。
//
// 用法：dart run tool/handoff_e2e_scan.dart   （退出码 0=通过，1=回归）
import 'dart:io';

const String _testPath = 'test/providers/handoff_e2e_test.dart';

void main() {
  final file = File(_testPath);
  if (!file.existsSync()) {
    stderr.writeln('::error::找不到 E2E 测试文件 $_testPath');
    exit(2);
  }
  final src = file.readAsStringSync();
  final failures = <String>[];

  void require(bool ok, String message) {
    if (!ok) failures.add(message);
  }

  // 1) 假服务端必须设置 JSON content-type。
  require(
    src.contains('headers.contentType = ContentType.json') ||
        src.contains('contentType = ContentType.json'),
    '假服务端未设置 JSON content-type：客户端 postRaw/getRaw 只在 JSON '
        'content-type 下把 body 解析成 Map，否则返回 String，会让 '
        '`resp is! Map` 判定失败 —— E2E 会变成假红（2026-09-10 真实踩过）。',
  );

  // 2) 必须实现搬移链路用到的四个端点。
  for (final endpoint in <String>[
    "'/rest/api/v1/play'",
    "'/queue/play'",
    "'/status'",
  ]) {
    require(src.contains(endpoint),
        '假服务端缺少端点 $endpoint：E2E 覆盖不完整');
  }

  // 3) 必须是真客户端 + 真容器（不是全面 mocktail）。
  require(src.contains('SubsonicApiClient('),
      'E2E 必须使用真 SubsonicApiClient 走真 HTTP，不能用 mock 替身');
  require(src.contains('ProviderContainer('),
      'E2E 必须用真 ProviderContainer，否则测不到真实 provider 接线');
  require(!src.contains('MockClient') || src.contains('SubsonicApiClient('),
      'E2E 不可退化为纯 mock 客户端');

  // 4) 必须保留「主通道 body 不含整队」这条核心断言。
  require(src.contains('"items"') || src.contains("'items'"),
      'E2E 丢失了「主通道 body 不含整队 items」的核心断言：'
          '这条是防大歌单回退到 MB 级整队推送的关键');

  // 5) 必须覆盖回落场景（主通道失败 / 404）。
  require(src.contains('mainChannelNotFound') || src.contains('mainChannelFails'),
      'E2E 丢失了主通道失败回落场景的构造开关');

  if (failures.isEmpty) {
    stdout.writeln('OK: 接续搬移 E2E 脚手架契约在位（content-type/端点/真客户端/核心断言）');
    exit(0);
  }
  for (final f in failures) {
    stderr.writeln('::error::$f');
  }
  exit(1);
}

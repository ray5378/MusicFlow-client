import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/dlna/cast_http.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/server_address.dart';

ServerAddress _addr(
  String id,
  String url, {
  int priority = 0,
  ServerAddressStatus status = ServerAddressStatus.ok,
  bool isLocked = false,
}) {
  return ServerAddress(
    id: id,
    libraryId: 'lib',
    label: id,
    url: url,
    priority: priority,
    isLocked: isLocked,
    status: status,
  );
}

MusicLibrary _library(List<ServerAddress> addresses) {
  final now = DateTime(2024, 1, 1);
  return MusicLibrary(
    id: 'lib',
    name: '测试库',
    addresses: addresses,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  group('pickDlnaCastHttpBase', () {
    test('活跃地址是 http → 直接用（优先级最高，不要求 ok 状态）', () {
      final base = pickDlnaCastHttpBase(
        addresses: [
          _addr('a', 'https://music.example.com', status: ServerAddressStatus.ok),
        ],
        activeAddress: _addr('b', 'http://192.168.1.5:4533'),
      );
      expect(base, 'http://192.168.1.5:4533');
    });

    test('活跃是 https → 取健康检查 ok 的 http 地址（按优先级）', () {
      final base = pickDlnaCastHttpBase(
        addresses: [
          _addr('https-lan', 'https://lan.example.com', priority: 0),
          _addr('http-failed', 'http://10.0.0.2:4533',
              priority: 1, status: ServerAddressStatus.failed),
          _addr('http-ok', 'http://ddns.example.com:4533', priority: 2),
        ],
        activeAddress: _addr('https-lan', 'https://lan.example.com'),
      );
      expect(base, 'http://ddns.example.com:4533');
    });

    test('手动锁定 https 不影响投流：仍返回 ok 的 http 地址', () {
      final base = pickDlnaCastHttpBase(
        addresses: [
          _addr('https-lock', 'https://lock.example.com', isLocked: true),
          _addr('http-ok', 'http://192.168.1.5:4533'),
        ],
        activeAddress: _addr('https-lock', 'https://lock.example.com',
            isLocked: true),
      );
      expect(base, 'http://192.168.1.5:4533');
    });

    test('只有 https 地址 → null（禁止直投）', () {
      final base = pickDlnaCastHttpBase(
        addresses: [_addr('a', 'https://music.example.com')],
        activeAddress: _addr('a', 'https://music.example.com'),
      );
      expect(base, isNull);
    });

    test('http 地址存在但探测失败 → null（沿用探测结果，不额外探测）', () {
      final base = pickDlnaCastHttpBase(
        addresses: [
          _addr('http-failed', 'http://10.0.0.2:4533',
              status: ServerAddressStatus.failed),
        ],
        activeAddress: null,
      );
      expect(base, isNull);
    });

    test('空地址列表 → null', () {
      expect(
        pickDlnaCastHttpBase(addresses: const [], activeAddress: null),
        isNull,
      );
    });

    test('normalize：http 基地址去尾斜杠', () {
      final base = pickDlnaCastHttpBase(
        addresses: [_addr('a', 'http://192.168.1.5:4533/')],
        activeAddress: null,
      );
      expect(base, 'http://192.168.1.5:4533');
    });
  });

  group('resolveDlnaCastHttpBase', () {
    test('库为空或无地址 → null；有 http ok 地址 → 返回', () {
      expect(
        resolveDlnaCastHttpBase(library: null, activeAddress: null),
        isNull,
      );
      expect(
        resolveDlnaCastHttpBase(
          library: _library([]),
          activeAddress: null,
        ),
        isNull,
      );
      expect(
        resolveDlnaCastHttpBase(
          library: _library([_addr('a', 'http://192.168.1.5:4533')]),
          activeAddress: null,
        ),
        'http://192.168.1.5:4533',
      );
    });
  });

  group('rewriteUrlToBase', () {
    test('token 流地址：https 主机 → http 基地址，路径不变', () {
      final rewritten = rewriteUrlToBase(
        'https://music.example.com/rest/dlna/stream/abc123',
        'http://ddns.example.com:4533',
      );
      expect(rewritten, 'http://ddns.example.com:4533/rest/dlna/stream/abc123');
    });

    test('带鉴权 query 的回退流地址：origin 换掉，query 原样保留', () {
      final rewritten = rewriteUrlToBase(
        'https://music.example.com/rest/stream?u=ray&t=abc&s=def&id=s1',
        'http://192.168.1.5:4533',
      );
      expect(
        rewritten,
        'http://192.168.1.5:4533/rest/stream?u=ray&t=abc&s=def&id=s1',
      );
    });

    test('baseUrl 带尾斜杠不会拼出双斜杠', () {
      final rewritten = rewriteUrlToBase(
        'https://music.example.com/rest/dlna/stream/tok',
        'http://192.168.1.5:4533/',
      );
      expect(
        rewritten,
        'http://192.168.1.5:4533/rest/dlna/stream/tok',
      );
    });

    test('非法输入原样返回（不抛异常）', () {
      expect(rewriteUrlToBase('', 'http://h:1'), '');
      expect(rewriteUrlToBase('https://h/x', ''), 'https://h/x');
      expect(rewriteUrlToBase('not a url', 'http://h:1'), 'not a url');
    });
  });

  test('提示文案与 ray 指定措辞一致', () {
    expect(kDlnaCastHttpRequiredHint, '直投功能必须在媒体库中先添加http连接');
  });
}

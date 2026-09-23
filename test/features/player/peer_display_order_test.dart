import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/features/player/peer_display_order.dart';

/// 播放端展示序的**行为锁**（用户定稿 2026-09-24）：
///   在播优先 → 类别（客户端本机 > 群组 > 独立播放器） → 名称。
///
/// 本文件是这条口径唯一的自动化验收点，由**阻塞** workflow
/// `.github/workflows/peer-order-guard.yml` 执行（`Test Suite` 是
/// `continue-on-error` 的观察流水线，锁不住东西，所以单开一道）。
///
/// ⚠️ 第 1 组用例是**判别性用例**：把「在播优先」换成「类别优先」（曾被否掉的
/// 中间态）时，只有它们会红 —— 其余用例两种口径下都通过。
void main() {
  /// 造一个播放端。默认造「闲置的独立播放器（DLNA）」。
  PeerInfo peer(
    String name, {
    String kind = 'dlna',
    bool self = false,
    bool playing = false,
  }) =>
      PeerInfo(
        peerId: '$kind:$name',
        name: name,
        kind: kind,
        available: true,
        self: self,
        queueActive: playing,
      );

  /// 本机（客户端自己那条）—— `kind == 'local'` 即 [PeerInfo.isLocal]。
  PeerInfo local(String name, {bool playing = false}) =>
      peer(name, kind: 'local', self: true, playing: playing);

  /// 群组（容器型播放端）。
  PeerInfo groupPeer(String name, {bool playing = false}) =>
      peer(name, kind: 'group', playing: playing);

  /// 按展示序排一遍，返回名称序列（顺带验证可作 `List.sort` 的比较器使用）。
  List<String> order(List<PeerInfo> list) =>
      (list.toList()..sort(comparePeerDisplayOrder)).map((p) => p.name).toList();

  group('在播优先（第一维度，压过类别）', () {
    // 判别性用例 ①：在播的**独立播放器**要排在闲置的**群组**之前。
    // 「类别优先」会把群组提到前面 ⇒ 这条必红。
    test('a playing device outranks an idle group', () {
      final playingDevice = peer('DLNA-A', playing: true);
      final idleGroup = groupPeer('Group-B');
      expect(comparePeerDisplayOrder(playingDevice, idleGroup), lessThan(0));
      expect(order([idleGroup, playingDevice]), ['DLNA-A', 'Group-B']);
    });

    // 判别性用例 ②：在播的**群组**要排在闲置的**本机**之前。
    // 本机虽是最高的类别，但优先级在「类别」之下 ⇒ 同样被在播压过。
    test('a playing group outranks an idle local client', () {
      final playingGroup = groupPeer('Group-A', playing: true);
      final idleLocal = local('Me');
      expect(comparePeerDisplayOrder(playingGroup, idleLocal), lessThan(0));
      expect(order([idleLocal, playingGroup]), ['Group-A', 'Me']);
    });

    test('a playing local client outranks everything else', () {
      final me = local('Me', playing: true);
      final playingGroup = groupPeer('Group-A', playing: true);
      final playingDevice = peer('DLNA-A', playing: true);
      expect(order([playingDevice, playingGroup, me]), ['Me', 'Group-A', 'DLNA-A']);
    });
  });

  group('同播态下按类别（本机 > 群组 > 独立播放器）', () {
    test('idle: local > group > standalone', () {
      final me = local('Me');
      final g = groupPeer('Group-A');
      final device = peer('DLNA-A');
      expect(order([device, g, me]), ['Me', 'Group-A', 'DLNA-A']);
    });

    test('playing: local > group > standalone', () {
      final me = local('Me', playing: true);
      final g = groupPeer('Group-A', playing: true);
      final device = peer('DLNA-A', playing: true);
      expect(order([device, g, me]), ['Me', 'Group-A', 'DLNA-A']);
    });

    test('all standalone kinds share the same weight (dlna/sendspin/airplay)', () {
      // 独立播放器之间只比「在播」和名称，不按传输协议细分。
      final sendspin = peer('S', kind: 'sendspin', playing: true);
      final airplay = peer('P', kind: 'airplay');
      final dlna = peer('D', kind: 'dlna', playing: true);
      expect(order([airplay, sendspin, dlna]), ['D', 'S', 'P']);
    });
  });

  group('兜底:同类同播态按名称稳定排序', () {
    test('falls back to name', () {
      final b = peer('B');
      final a = peer('A');
      expect(order([b, a]), ['A', 'B']);
    });

    test('is a valid total order (no comparator contract violation)', () {
      final list = [
        local('Me'),
        groupPeer('Group-A'),
        peer('DLNA-A', playing: true),
        peer('DLNA-B'),
        groupPeer('Group-B', playing: true),
        local('Other', playing: true),
      ];
      final once = order(list);
      final twice = order(list.toList()..shuffle());
      expect(twice, once, reason: '比较器必须给出稳定全序，与输入顺序无关');
    });
  });

  group('peerKindRank 权重', () {
    test('local=0, group=1, everything else=2', () {
      expect(peerKindRank(local('Me')), 0);
      expect(peerKindRank(peer('Other', kind: 'local')), 0); // 同账号别的本机端
      expect(peerKindRank(groupPeer('G')), 1);
      expect(peerKindRank(peer('D')), 2);
      expect(peerKindRank(peer('S', kind: 'sendspin')), 2);
      expect(peerKindRank(peer('P', kind: 'airplay')), 2);
    });
  });
}

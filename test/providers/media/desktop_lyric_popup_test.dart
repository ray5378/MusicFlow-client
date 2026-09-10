import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/providers/media/desktop_lyric_popup.dart';

void main() {
  group('desktopLyricSongRow', () {
    test('有歌手拼「歌名 — 歌手」,无歌手只有歌名', () {
      expect(desktopLyricSongRow(Song(id: 'a', title: '晴天', artist: '周杰伦')),
          '晴天 — 周杰伦');
      expect(desktopLyricSongRow(Song(id: 'b', title: '未知曲目')), '未知曲目');
      expect(desktopLyricSongRow(Song(id: 'c', title: '空白', artist: '  ')),
          '空白');
    });
  });

  group('composeDesktopLyricQueue', () {
    final localQueue = <Song>[
      Song(id: 'a', title: '晴天', artist: '周杰伦'),
      Song(id: 'b', title: '夜曲', artist: '周杰伦'),
      Song(id: 'c', title: '稻香'),
    ];

    test('本机:playerProvider 队列 + localIndex', () {
      final data = composeDesktopLyricQueue(
        castActive: false,
        castQueue: const [],
        castIndex: -1,
        localQueue: localQueue,
        localIndex: 1,
        dlnaCasting: false,
        dlnaIndex: -1,
      );
      expect(data.items, ['晴天 — 周杰伦', '夜曲 — 周杰伦', '稻香']);
      expect(data.index, 1);
    });

    test('DLNA 直投:playerProvider 队列 + dlnaIndex', () {
      final data = composeDesktopLyricQueue(
        castActive: false,
        castQueue: const [],
        castIndex: -1,
        localQueue: localQueue,
        localIndex: 0,
        dlnaCasting: true,
        dlnaIndex: 2,
      );
      expect(data.items.length, 3);
      expect(data.index, 2);
    });

    test('后端投屏:castQueue/castIndex 权威,忽略本机队列', () {
      final data = composeDesktopLyricQueue(
        castActive: true,
        castQueue: const [
          <String, dynamic>{'songId': 'x', 'title': '远端歌', 'artist': '某人'},
          <String, dynamic>{'songId': 'y'},
        ],
        castIndex: 1,
        localQueue: localQueue,
        localIndex: 0,
        dlnaCasting: false,
        dlnaIndex: -1,
      );
      expect(data.items.first, '远端歌 — 某人');
      // 无 title 的条目走 l10nNowCurrent().peer_unknown 兜底文案。
      expect(data.items.last, isNotEmpty);
      expect(data.index, 1);
    });
  });

  // 桌面歌词「切换播放器」弹窗(歌词窗上方自弹,内容与 MINI 小弹窗一致)。
  // 行号是原生层与 Dart 之间的唯一契约(switch_pick:N),顺序错位会导致
  // 「点 A 设备切到 B」,必须用单测锁死。
  group('composeDesktopLyricSwitchList', () {
    test('本机为当前目标:只有本机一行,且标记 current', () {
      final rows = composeDesktopLyricSwitchList(
        localTitle: '本机播放',
        localSubtitle: '在本机播放',
        localIsCurrent: true,
      );
      expect(rows.length, 1);
      expect(rows.single.title, '本机播放');
      expect(rows.single.current, isTrue);
    });

    test('投屏中:本机 + 停止投屏 + 可用设备,本机不再 current', () {
      final rows = composeDesktopLyricSwitchList(
        localTitle: '本机播放',
        localSubtitle: '投屏中',
        localIsCurrent: false,
        stopCastTitle: '停止投屏',
        stopCastSubtitle: '停止向 主卧 投屏',
        remotePeers: const [
          (name: '主卧', subtitle: '', kind: 'dlna', current: true, badge: 'DLNA', canPull: true,
              canPush: false),
          (name: '书房', subtitle: '', kind: 'dlna', current: false, badge: 'DLNA', canPull: false,
              canPush: true),
        ],
      );
      expect(rows.map((r) => r.title).toList(),
          ['本机播放', '停止投屏', '主卧', '书房']);
      // 行号契约:0=本机 1=停止投屏 2=主卧 3=书房。
      expect(rows[0].current, isFalse);
      expect(rows[1].current, isFalse);
      expect(rows[2].current, isTrue);
      expect(rows[3].current, isFalse);
      expect(rows[1].subtitle, '停止向 主卧 投屏');
    });

    test('本机已是当前目标时不插入「停止投屏」行(行号不会整体错位)', () {
      final rows = composeDesktopLyricSwitchList(
        localTitle: '本机播放',
        localSubtitle: '本机',
        localIsCurrent: true,
        // 即使调用方传了停止投屏文案,本机为当前目标时也不该出现该行。
        stopCastTitle: '停止投屏',
        remotePeers: const [
          (name: '主卧', subtitle: '', kind: 'dlna', current: false, badge: 'DLNA', canPull: false,
              canPush: false),
        ],
      );
      expect(rows.map((r) => r.title).toList(), ['本机播放', '主卧']);
    });

    test('toChannelMap 产出 MethodChannel 能编码的基本类型', () {
      final rows = composeDesktopLyricSwitchList(
        localTitle: '本机播放',
        localSubtitle: '本机',
        localIsCurrent: true,
      );
      final map = rows.single.toChannelMap();
      expect(map['title'], isA<String>());
      expect(map['subtitle'], isA<String>());
      expect(map['current'], isA<bool>());
      expect(map['badge'], isA<String>());
      expect(map['canPull'], isA<bool>());
      expect(map['canPush'], isA<bool>());
      expect(map['handoff'], isA<bool>());
      expect(map.keys.toSet(),
          {
            'title', 'subtitle', 'current', 'badge', 'canPull', 'canPush',
            'handoff', 'isRefresh', 'icon',
          });
    });

    test('handoff 恒为 true 的只有远端设备行(箭头与可用性是两件事)', () {
      final rows = composeDesktopLyricSwitchList(
        localTitle: '本机播放',
        localSubtitle: '投屏中',
        localIsCurrent: false,
        stopCastTitle: '停止投屏',
        remotePeers: const [
          // 两支箭头都不可用:仍必须画出来(置灰),不能整块消失。
          (name: '主卧', subtitle: '', kind: 'dlna', current: true, badge: 'DLNA', canPull: false,
              canPush: false),
        ],
      );
      expect(rows[0].handoff, isFalse, reason: '本机行没有接续语义');
      expect(rows[1].handoff, isFalse, reason: '停止投屏行没有接续语义');
      expect(rows[2].handoff, isTrue, reason: '设备行恒有两支接续箭头');
      expect(rows[2].canPull, isFalse);
      expect(rows[2].canPush, isFalse);
    });

    test('设备行带 DLNA 徽章 + 接续可用性(与 MINI 弹窗 PeerCastRow 同款)', () {
      final rows = composeDesktopLyricSwitchList(
        localTitle: '本机播放',
        localSubtitle: '本机',
        localIsCurrent: true,
        remotePeers: const [
          (name: '主卧', subtitle: '', kind: 'dlna', current: false, badge: 'DLNA', canPull: true,
              canPush: false),
        ],
      );
      // 本机行不画徽章。
      expect(rows[0].badge, '');
      expect(rows[0].canPull, isFalse);
      expect(rows[0].canPush, isFalse);
      expect(rows[1].badge, 'DLNA');
      expect(rows[1].canPull, isTrue);
      expect(rows[1].canPush, isFalse);
    });
  });

  group('desktopLyricPeerIndexFromRow', () {
    test('本机为当前目标:行 0 是本机,设备从行 1 起', () {
      expect(desktopLyricPeerIndexFromRow(0, hasStopCastRow: false), -1);
      expect(desktopLyricPeerIndexFromRow(1, hasStopCastRow: false), 0);
      expect(desktopLyricPeerIndexFromRow(2, hasStopCastRow: false), 1);
    });
    test('投屏态多一行「停止投屏」:设备从行 2 起', () {
      expect(desktopLyricPeerIndexFromRow(0, hasStopCastRow: true), -1);
      expect(desktopLyricPeerIndexFromRow(1, hasStopCastRow: true), -1);
      expect(desktopLyricPeerIndexFromRow(2, hasStopCastRow: true), 0);
      expect(desktopLyricPeerIndexFromRow(3, hasStopCastRow: true), 1);
    });
    test('负行号(原生层不该发,但兜住)统一返回 -1', () {
      expect(desktopLyricPeerIndexFromRow(-1, hasStopCastRow: false), -1);
      expect(desktopLyricPeerIndexFromRow(-5, hasStopCastRow: true), -1);
    });
  });
}

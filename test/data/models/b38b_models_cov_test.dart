import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/data/models/album.dart';
import 'package:musicflow_client/data/models/home_section_layout.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/search.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/models/structured_lyrics.dart';

void main() {
  test('Song.fromJson string/num variants (8/15/16/243)', () {
    final s = Song.fromJson({
      'id': '1',
      'title': 't',
      'duration': '120', // line 8: String -> int.tryParse
      'bitRate': '320', // line 8
      'isVideo': 1, // line 15: num -> bool
      'starred': 'true', // line 16: String -> bool
      'previewRequestHeaders': {'a': 'b'}, // line 243 map callback
    });
    expect(s.duration, 120);
    expect(s.isVideo, isTrue);
    expect(s.starred, isTrue);
    expect(s.previewRequestHeaders, {'a': 'b'});
  });

  test('StructuredLyrics.fromJson no line -> empty list (27)', () {
    final ly = StructuredLyrics.fromJson({});
    expect(ly.lines, isEmpty);
  });

  test('Album.fromJson string number (4)', () {
    final a = Album.fromJson({
      'id': '1',
      'name': 'n',
      'songCount': '5',
      'duration': '100',
    });
    expect(a.songCount, 5);
  });

  test('MusicLibrary.fromJson (30/31)', () {
    final now = DateTime.now();
    final m = MusicLibrary.fromJson({
      'id': '1',
      'name': 'n',
      'createdAt': now.toIso8601String(),
      'updatedAt': now.toIso8601String(),
    });
    expect(m.id, '1');
  });

  test('ServerAddress.fromJson (19/20)', () {
    final a = ServerAddress.fromJson({
      'id': '1',
      'libraryId': 'l',
      'label': 'L',
      'url': 'u',
      'priority': 1,
    });
    expect(a.id, '1');
  });

  test('HomeSectionLayout.copyWith (40)', () {
    final h = HomeSectionLayout().copyWith(order: ['a']);
    expect(h.order, ['a']);
  });

  test('Playlist._parseDate num + space variants (103/104/114/116)', () {
    expect(
      Playlist.fromJson({
        'id': '1',
        'name': 'n',
        'created': 1700000000000, // num epoch ms branch
      }).created,
      isNotNull,
    );
    expect(
      Playlist.fromJson({
        'id': '1',
        'name': 'n',
        'created': '2024-01-01 00:00:00', // space -> T replacement
      }).created,
      isNotNull,
    );
  });

  testWidgets('Playlist.durationString hours+minutes (90) + PeerInfo getters (65/89)',
      (tester) async {
    final p = Playlist(
      id: '1',
      name: 'n',
      songCount: 1,
      duration: 3725, // 1h 2m 5s
    );
    expect(p.durationString, isNotEmpty); // line 90

    final peer = PeerInfo(
      peerId: 'p',
      name: 'n',
      kind: 'local',
      available: true,
      self: false,
    );
    expect(peer.isOtherLocal, isTrue); // line 65

    final peer2 = PeerInfo(
      peerId: 'q',
      name: 'n',
      kind: 'local',
      available: true,
      self: true,
      queueTotal: 3,
      queueActive: true,
    );
    expect(peer2.queueLabel, isNotEmpty); // line 89
  });

  test('SearchAlbum.fromRemoteJson + fromLocal (164)', () {
    final a = SearchAlbum.fromRemoteJson({
      'id': '1',
      'name': 'n',
      'artist': 'ar',
      'providerName': 'pn',
    });
    expect(a.providerName, 'pn'); // line 164
    final local = SearchAlbum.fromLocal(
      Album(id: '1', name: 'n', songCount: 2, duration: 100),
    );
    expect(local.isLocal, isTrue);
  });
}

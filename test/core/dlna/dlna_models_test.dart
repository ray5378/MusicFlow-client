import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/dlna/dlna_models.dart';

void main() {
  group('DlnaCastTrack', () {
    test('exposes song identity fields', () {
      const track = DlnaCastTrack(
        songId: 's1',
        title: 'Lights',
        artist: 'Phantom',
        album: 'Night',
      );

      expect(track.songId, 's1');
      expect(track.title, 'Lights');
      expect(track.artist, 'Phantom');
      expect(track.album, 'Night');
    });

    test('artist/album are optional', () {
      const track = DlnaCastTrack(songId: 's2', title: 'Solo');

      expect(track.artist, isNull);
      expect(track.album, isNull);
    });
  });

  group('DlnaDeviceStatus', () {
    test('defaults to stopped/idle', () {
      const status = DlnaDeviceStatus();

      expect(status.state, 'STOPPED');
      expect(status.position, 0);
      expect(status.duration, 0);
      expect(status.volume, 0);
      expect(status.muted, isFalse);
    });

    test('copyWith updates only provided fields', () {
      const base = DlnaDeviceStatus(
        state: 'PLAYING',
        position: 10,
        duration: 200,
        volume: 50,
        muted: false,
      );

      final copy = base.copyWith(muted: true, volume: 80);

      expect(copy.state, 'PLAYING');
      expect(copy.position, 10);
      expect(copy.duration, 200);
      expect(copy.volume, 80);
      expect(copy.muted, isTrue);
    });
  });

  group('DlnaDevice', () {
    final base = DlnaDevice(
      id: 'udn-1',
      name: 'Living Room TV',
      location: 'http://192.168.1.10:8000/desc.xml',
      lastSeen: DateTime(2024, 1, 1),
    );

    test('displayName falls back to name when no alias', () {
      expect(base.displayName, 'Living Room TV');
    });

    test('displayName prefers alias', () {
      final withAlias = base.copyWith(alias: '客厅电视');
      expect(withAlias.displayName, '客厅电视');
    });

    test('copyWith toggles availability and disabled', () {
      final offline = base.copyWith(available: false);
      final disabled = base.copyWith(disabled: true);

      expect(offline.available, isFalse);
      expect(offline.disabled, isFalse);
      expect(disabled.disabled, isTrue);
    });

    test('keeps service URLs on copyWith of unrelated field', () {
      final device = base.copyWith(avTransportUrl: 'http://1/AVTransport/control');
      final copy = device.copyWith(name: 'Renamed');
      expect(copy.avTransportUrl, 'http://1/AVTransport/control');
    });
  });

  group('DlnaCastSession', () {
    test('isExpired reflects expiry window', () {
      final fresh = DlnaCastSession(
        token: 't1',
        deviceId: 'd1',
        songId: 's1',
        createdAt: DateTime.now(),
        expiresAt: DateTime.now().add(const Duration(minutes: 10)),
      );

      final expired = DlnaCastSession(
        token: 't2',
        deviceId: 'd1',
        songId: 's1',
        createdAt: DateTime.now(),
        expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
      );

      expect(fresh.isExpired, isFalse);
      expect(expired.isExpired, isTrue);
    });
  });
}
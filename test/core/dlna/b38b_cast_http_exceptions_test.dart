import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/dlna/cast_http.dart';

void main() {
  test('DlnaCastHttpUnavailableException toString', () {
    const e = DlnaCastHttpUnavailableException();
    expect(e.toString(), contains('no http cast base'));
  });

  test('DlnaSongUnplayableException exposes songId and toString', () {
    final e = DlnaSongUnplayableException('song-1');
    expect(e.songId, 'song-1');
    expect(e.toString(), contains('song-1'));
  });
}

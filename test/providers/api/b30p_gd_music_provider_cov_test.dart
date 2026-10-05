import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/data/sources/remote/gd_music_api_client.dart';
import 'package:musicflow_client/providers/api/gd_music_provider.dart';

void main() {
  test('gdMusicApiClientProvider 提供单例 GdMusicApiClient', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final first = container.read(gdMusicApiClientProvider);
    final second = container.read(gdMusicApiClientProvider);

    expect(first, isA<GdMusicApiClient>());
    expect(second, same(first));
  });
}

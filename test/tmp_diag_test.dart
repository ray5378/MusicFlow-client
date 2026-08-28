import 'package:dio/dio.dart';
import 'package:musicflow_client/core/utils/cover_ref_security.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/providers/api_provider.dart';
import 'package:musicflow_client/providers/library_provider.dart';
import 'package:musicflow_client/widgets/cover_art_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('diag', (tester) async {
    final now = DateTime(2026, 7, 15);
    final library = MusicLibrary(
      id: 'library-cover',
      name: 'Cover Library',
      createdAt: now,
      updatedAt: now,
    );
    final client = SubsonicApiClient(
      dio: Dio(BaseOptions(baseUrl: 'https://music.example.test')),
    )..setLibrary(library);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          activeLibraryProvider.overrideWithValue(library),
          subsonicApiClientProvider.overrideWithValue(client),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: CoverArtImage(
                coverArtId: toTrustedCoverUrlRef(
                  'https://img.example.com/cover.jpg?size=800',
                ),
                size: 48,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    debugPrint('Image=${find.byType(Image).evaluate().length}');
    debugPrint('Skeleton=${find.byType(Image).evaluate().length}');
    // dump what's under the cover
    for (final e in tester.binding.rootElement!.debugGetDiagnosticChain()) {}
    debugPrint(tester.allWidgets.map((w) => w.runtimeType.toString()).where((t) => t.contains('Skeleton') || t.contains('Image') || t.contains('ColoredBox') || t.contains('SizedBox')).take(20).toList().toString());
  });
}
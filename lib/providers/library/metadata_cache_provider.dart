import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/data/repositories/metadata_cache_repository.dart';

final metadataCacheRepositoryProvider = Provider<MetadataCacheRepository>((
  ref,
) {
  return MetadataCacheRepository();
});

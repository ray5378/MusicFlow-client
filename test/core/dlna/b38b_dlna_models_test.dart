import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/dlna/dlna_models.dart';

void main() {
  test('SsdpDeviceRaw constructor', () {
    final now = DateTime.now();
    final raw = SsdpDeviceRaw(
      location: 'http://192.168.1.5:8200/desc.xml',
      lastSeen: now,
    );
    expect(raw.location, 'http://192.168.1.5:8200/desc.xml');
    expect(raw.lastSeen, now);
  });
}

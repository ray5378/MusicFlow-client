import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/utils/logger.dart';

void main() {
  setUp(() {
    Logger.setLoggingEnabled(true);
    Logger.clearBuffer();
  });
  tearDown(() {
    Logger.setLoggingEnabled(false);
    Logger.clearBuffer();
  });

  test('error with error + stackTrace buffers and prints all lines', () {
    Logger.clearBuffer();
    final ex = Exception('boom');
    final st = StackTrace.current;
    Logger.error('something failed', ex, st);
    final logs = Logger.exportLogs();
    expect(logs, contains('something failed'));
    expect(logs, contains('boom'));
    expect(logs, contains('stackTrace='));
    expect(Logger.bufferedLineCount, greaterThan(0));
    // ensure error + stackTrace lines were appended in non-release mode
    expect(logs, contains('error=Exception: boom'));
  });

  test('buffer overflow drops oldest entry (line 157)', () {
    for (var i = 0; i < 5001; i++) {
      Logger.debug('line-$i');
    }
    expect(Logger.bufferedLineCount, 5000);
    final logs = Logger.exportLogs();
    expect(logs, isNot(contains('line-0')));
    expect(logs, contains('line-5000'));
  });
}

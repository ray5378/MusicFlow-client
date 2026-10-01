import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/dlna/dlna_didl.dart';

void main() {
  group('escapeXml', () {
    test('转义 & < > 三种字符', () {
      expect(escapeXml('a & b'), 'a &amp; b');
      expect(escapeXml('<tag>'), '&lt;tag&gt;');
      expect(escapeXml('a<b>c&d'), 'a&lt;b&gt;c&amp;d');
    });

    test('无特殊字符原样返回', () {
      expect(escapeXml('plain'), 'plain');
      expect(escapeXml(''), '');
    });

    test('不转义引号与单引号（DIDL 属性值里已用双引号包裹）', () {
      expect(escapeXml('say "hi"'), 'say "hi"');
      expect(escapeXml("it's"), "it's");
    });
  });

  group('buildDidlLite', () {
    test('最小参数：只有 title/uri/mime', () {
      final xml = buildDidlLite(title: 'T', uri: 'http://h/s.mp3', mime: 'audio/mpeg');
      expect(xml, contains('<dc:title>T</dc:title>'));
      expect(xml, isNot(contains('<dc:creator>')));
      expect(xml, isNot(contains('<upnp:album>')));
      expect(xml, isNot(contains('<upnp:albumArtURI>')));
      expect(xml, contains('object.item.audioItem.musicTrack'));
      expect(xml, contains('audio/mpeg'));
      expect(xml.startsWith('<DIDL-Lite'), isTrue);
      expect(xml.endsWith('</item></DIDL-Lite>'), isTrue);
    });

    test('标题/艺术家/专辑/封面均按 XML 转义', () {
      final xml = buildDidlLite(
        title: 'a & b',
        uri: 'http://h/s.mp3',
        mime: 'audio/flac',
        artist: '<x>',
        album: 'al"bum',
        albumArtUri: 'http://h/a.jpg?a=1&b=2',
      );
      expect(xml, contains('<dc:title>a &amp; b</dc:title>'));
      expect(xml, contains('<dc:creator>&lt;x&gt;</dc:creator>'));
      expect(xml, contains('<upnp:album>al"bum</upnp:album>'));
      expect(
        xml,
        contains('<upnp:albumArtURI>http://h/a.jpg?a=1&amp;b=2</upnp:albumArtURI>'),
      );
      expect(xml, isNot(contains('<dc:creator><x>')));
    });

    test('res 节点带上 DLNA protocolInfo 并转义 uri', () {
      final xml = buildDidlLite(
        title: 't',
        uri: 'http://h/s?a=1&b=2',
        mime: 'audio/flac',
      );
      expect(xml, contains('<res protocolInfo='));
      expect(xml, contains('http://h/s?a=1&amp;b=2</res>'));
      expect(xml, contains('DLNA.ORG_OP=01;DLNA.ORG_CI=0;'));
    });

    test('四个可选字段缺失时都不生成空节点', () {
      final xml = buildDidlLite(title: 't', uri: 'u', mime: 'm');
      expect(xml.split('<upnp:').length, 2); // class + res
      expect(xml, contains('<upnp:class>'));
      expect(xml, contains('<res '));
    });

    test('item 头固定为 id=1 parentID=0 restricted=1', () {
      final xml = buildDidlLite(title: 't', uri: 'u', mime: 'm');
      expect(xml, contains('<item id="1" parentID="0" restricted="1">'));
    });
  });
}

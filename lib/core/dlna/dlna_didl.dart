/// DIDL-Lite 元数据构造与 XML 转义(DLNA SetAVTransportURI 用)。
/// 纯函数,从 dlna_manager 抽离。

String buildDidlLite({
  required String title,
  required String uri,
  required String mime,
  String? artist,
  String? album,
  String? albumArtUri,
}) {
  final protocolInfo =
      'http-get:*:$mime:DLNA.ORG_OP=01;DLNA.ORG_CI=0;'
      'DLNA.ORG_FLAGS=01700000000000000000000000000000';

  final buffer = StringBuffer()
    ..write('<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"')
    ..write(' xmlns:dc="http://purl.org/dc/elements/1.1/"')
    ..write(' xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">')
    ..write('<item id="1" parentID="0" restricted="1">')
    ..write('<dc:title>${escapeXml(title)}</dc:title>');

  if (artist != null) {
    buffer.write('<dc:creator>${escapeXml(artist)}</dc:creator>');
  }
  if (album != null) {
    buffer.write('<upnp:album>${escapeXml(album)}</upnp:album>');
  }
  if (albumArtUri != null) {
    buffer.write('<upnp:albumArtURI>${escapeXml(albumArtUri)}</upnp:albumArtURI>');
  }

  buffer
    ..write('<upnp:class>object.item.audioItem.musicTrack</upnp:class>')
    ..write('<res protocolInfo="$protocolInfo">${escapeXml(uri)}</res>')
    ..write('</item></DIDL-Lite>');

  return buffer.toString();
}

/// XML 转义
String escapeXml(String s) {
  return s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}
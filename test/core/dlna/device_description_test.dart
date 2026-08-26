import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/dlna/device_description.dart';

/// 回归测试：投屏失败「请检查设备是否在线」根因——description.xml 里相对路径的
/// controlURL 解析方向写反（`controlUrl.resolve(location)` 因 location 为绝对地址，
/// 永远解析回 description.xml 本身），导致 SOAP 控制发错路径。
/// 修复后应 `location.resolve(controlUrl)`，得到真正的 AVTransport 控制 URL。
void main() {
  late HttpServer server;
  const descPath = '/device/desc.xml';

  Future<void> serve(String xml) async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      req.response.headers.contentType = ContentType('text', 'xml', charset: 'utf-8');
      req.response.write(xml);
      await req.response.close();
    });
  }

  String descriptionXml({
    required String controlUrl,
    required String renderingControlUrl,
  }) {
    return '''
<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <device>
    <friendlyName>Test TV</friendlyName>
    <UDN>uuid:1234-5678-90ab</UDN>
    <manufacturer>Acme</manufacturer>
    <modelName>MediaRenderer</modelName>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <controlURL>$controlUrl</controlURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
        <controlURL>$renderingControlUrl</controlURL>
      </service>
    </serviceList>
  </device>
</root>
''';
  }

  test('resolves relative controlURL against device description location', () async {
    await serve(descriptionXml(
      controlUrl: '/upnp/control/AVTransport1',
      renderingControlUrl: '/upnp/control/RenderingControl1',
    ));
    final port = server.port;

    final location = 'http://127.0.0.1:$port$descPath';
    final device = await DeviceDescriptionParser.fetch(location);

    expect(device, isNotNull);
    expect(device!.name, 'Test TV');
    // 关键断言：控制 URL 不再是 description.xml 路径，而是解析后的真实控制路径
    expect(device.avTransportUrl, 'http://127.0.0.1:$port/upnp/control/AVTransport1');
    expect(
      device.renderingControlUrl,
      'http://127.0.0.1:$port/upnp/control/RenderingControl1',
    );
  });

  test('keeps absolute controlURL as-is', () async {
    await serve(descriptionXml(
      controlUrl: 'http://127.0.0.1:8088/MediaRenderer/AVTransport/Control',
      renderingControlUrl: 'http://127.0.0.1:8088/MediaRenderer/RenderingControl',
    ));

    final location = 'http://127.0.0.1:${server.port}$descPath';
    final device = await DeviceDescriptionParser.fetch(location);

    expect(device, isNotNull);
    expect(
      device!.avTransportUrl,
      'http://127.0.0.1:8088/MediaRenderer/AVTransport/Control',
    );
    expect(
      device.renderingControlUrl,
      'http://127.0.0.1:8088/MediaRenderer/RenderingControl',
    );
  });

  test('returns null when no AVTransport service', () async {
    await serve('''
<?xml version="1.0"?>
<root>
  <device>
    <friendlyName>Not a renderer</friendlyName>
    <UDN>uuid:abc</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType>
        <controlURL>/upnp/control/ContentDirectory</controlURL>
      </service>
    </serviceList>
  </device>
</root>
''');
    final location = 'http://127.0.0.1:${server.port}$descPath';

    final device = await DeviceDescriptionParser.fetch(location);

    expect(device, isNull);
  });
}
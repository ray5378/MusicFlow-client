// ============================================================================
// DLNA 纯音频渲染器模拟设备 (HiVi H5MKII 行为)
// ----------------------------------------------------------------------------
// 用途:全量集成测试中的"纯 renderer"一侧。模拟 HiVi H5MKII:
//   - 只暴露 AVTransport + RenderingControl,【无 ContentDirectory】(不能 CDS 清单)
//   - 不支持 SetNextAVTransportURI(返回 701)
//   - GetPositionInfo 位置/时长按拉流进度估算(RawHTTP 风格,时长常为 0)
// 关键校验:客户端走 B2 连续流档(/rest/castStream)时,设备 SetAVTransportURI 一个
//   URL → Play,即自主 GET 该 URL 把整根流拉到队列末尾——跨曲连播不依赖客户端。
// ============================================================================
import http from 'node:http';
import dgram from 'node:dgram';

// BIND_IP: HTTP/UDP 监听地址。默认 0.0.0.0(全部接口,沙箱内经 localhost 可及)。
// HOSTNAME: 描述文件向客户端播报的 LOCATION 主机名。真实局域网应填设备 LAN IP;
//          沙箱内(本机单机集成测试)填 localhost 即可。
const BIND_IP = process.env.BIND_IP || '0.0.0.0';
const HOSTNAME = process.env.HOSTNAME || 'localhost';
const HTTP_PORT = parseInt(process.env.HTTP_PORT || '19000', 10);
const SSDP_ADDR = '239.255.255.250';
const SSDP_PORT = 1900;
const UUID = process.env.DEVICE_UUID || '99999999-0000-4000-8000-110011001100';

const STATE = {
  transportState: 'STOPPED',
  currentURI: '',
  currentMeta: '',
  nextURI: '',
  playedMs: 0,
  pulledBytes: 0,
  pullDone: false,
  pullError: '',
  pullSummary: '',
};
let pullClock = null;

const SOAP_NS = 'urn:schemas-upnp-org:service:AVTransport:1';

function xmlEsc(s='') { return String(s).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;'); }

function extract(tag, xml) {
  const m = xml.match(new RegExp(`<${tag}[^>]*>([\\s\\S]*?)<\\/${tag}>`, 'i'));
  return m ? m[1].trim() : '';
}

function soapBody(action, argsXml) {
  return `<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body><u:${action}Response xmlns:u="${SOAP_NS}">${argsXml}</u:${action}Response></s:Body></s:Envelope>`;
}

function soapFault(action, code, desc) {
  return `<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body><s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring>
<detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>${code}</errorCode><errorDescription>${desc}</errorDescription></UPnPError></detail></s:Fault></s:Body></s:Envelope>`;
}

function transportTime(ms) {
  const s = Math.max(0, Math.floor(ms / 1000));
  const hh = String(Math.floor(s/3600)).padStart(2,'0');
  const mm = String(Math.floor((s%3600)/60)).padStart(2,'0');
  const ss = String(s%60).padStart(2,'0');
  return `${hh}:${mm}:${ss}`;
}

function startPullClock() {
  stopPullClock();
  pullClock = setInterval(() => {
    if (STATE.transportState === 'PLAYING') STATE.playedMs += 100;
  }, 100);
}
function stopPullClock() {
  if (pullClock) { clearInterval(pullClock); pullClock = null; }
}

// ---- AVTransport SOAP 动作 ----
function handleTransport(wantAction, argsXml) {
  switch (wantAction) {
    case 'SetAVTransportURI': {
      const uri = extract('CurrentURI', argsXml);
      const meta = extract('CurrentURIMetaData', argsXml);
      STATE.currentURI = uri;
      STATE.currentMeta = meta;
      STATE.pulledBytes = 0; STATE.pullDone = false; STATE.pullError = ''; STATE.pullSummary = '';
      console.log(`[MOCK-AVT] SetAVTransportURI uri=${uri}`);
      return { status: 200, body: soapBody('SetAVTransportURI', '<InstanceID>0</InstanceID>') };
    }
    case 'SetNextAVTransportURI': {
      console.log('[MOCK-AVT] SetNextAVTransportURI → 不支持(701)');
      return { status: 500, body: soapFault('SetNextAVTransportURI', 701, 'No such action') };
    }
    case 'Play': {
      STATE.transportState = 'PLAYING'; STATE.playedMs = 0;
      startPullClock(); consumeCurrentUri();
      console.log(`[MOCK-AVT] Play → PLAYING (uri=${STATE.currentURI})`);
      return { status: 200, body: soapBody('Play', '<InstanceID>0</InstanceID><Speed>1</Speed>') };
    }
    case 'Stop': {
      STATE.transportState = 'STOPPED'; stopPullClock();
      console.log('[MOCK-AVT] Stop → STOPPED');
      return { status: 200, body: soapBody('Stop', '<InstanceID>0</InstanceID>') };
    }
    case 'Pause': {
      if (STATE.transportState === 'PLAYING') STATE.transportState = 'PAUSED';
      return { status: 200, body: soapBody('Pause', '<InstanceID>0</InstanceID>') };
    }
    case 'Seek': {
      const target = extract('Target', argsXml);
      const m = target.match(/(\d+):(\d+):(\d+)/);
      STATE.playedMs = m ? (+m[1]*3600+ +m[2]*60 + +m[3])*1000 : 0;
      return { status: 200, body: soapBody('Seek', '<InstanceID>0</InstanceID>') };
    }
    case 'GetTransportInfo':
      return { status: 200, body: soapBody('GetTransportInfo',
        `<CurrentTransportState>${STATE.transportState}</CurrentTransportState>` +
        '<CurrentTransportStatus>OK</CurrentTransportStatus><CurrentSpeed>1</CurrentSpeed>') };
    case 'GetPositionInfo': {
      return { status: 200, body: soapBody('GetPositionInfo',
        '<Track>0</Track><TrackDuration>00:00:00</TrackDuration>' +
        `<TrackMetaData>${STATE.currentMeta||''}</TrackMetaData>` +
        `<TrackURI>${(STATE.currentURI||'')}</TrackURI>` +
        `<RelTime>${transportTime(STATE.playedMs)}</RelTime>` +
        '<AbsTime>00:00:00</AbsTime><RelCount>0</RelCount><AbsCount>0</AbsCount>') };
    }
    case 'GetMediaInfo':
      return { status: 200, body: soapBody('GetMediaInfo',
        '<NrTracks>1</NrTracks><MediaDuration>00:00:00</MediaDuration>' +
        `<CurrentURIMetaData>${STATE.currentMeta||''}</CurrentURIMetaData>` +
        `<CurrentURI>${(STATE.currentURI||'')}</CurrentURI>` +
        '<PlayMedium>NETWORK</PlayMedium><RecordMedium>NOT_IMPLEMENTED</RecordMedium><WriteStatus>NOT_IMPLEMENTED</WriteStatus>') };
    default:
      return { status: 500, body: soapFault(wantAction, 401, 'Invalid Action') };
  }
}

function handleRendering(wantAction) {
  switch (wantAction) {
    case 'GetVolume': return { status: 200, body: soapBody('GetVolume', '<CurrentVolume>50</CurrentVolume>') };
    case 'SetVolume': return { status: 200, body: soapBody('SetVolume', '<InstanceID>0</InstanceID>') };
    case 'GetMute': return { status: 200, body: soapBody('GetMute', '<CurrentMute>0</CurrentMute>') };
    case 'SetMute': return { status: 200, body: soapBody('SetMute', '<InstanceID>0</InstanceID>') };
    default: return { status: 500, body: soapFault(wantAction, 401, 'Invalid Action') };
  }
}

// ---- 拉取当前 URI(连续流关键动作) ----
async function consumeCurrentUri() {
  const uri = STATE.currentURI;
  if (!uri) { console.log('[MOCK-PLAY] 无 URI,无流可拉'); return; }
  console.log(`[MOCK-PLAY] begin GET ${uri}`);
  try {
    const res = await fetch(uri);
    if (!res.ok || !res.body) throw new Error(`HTTP ${res.status}`);
    const reader = res.body.getReader();
    let total = 0, chunks = 0;
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (value) { total += value.length; chunks++; STATE.pulledBytes = total; }
    }
    STATE.pullDone = true; STATE.pullError = '';
    STATE.pullSummary = `OK totalBytes=${total} chunks=${chunks}`;
    console.log(`[MOCK-PLAY] 拉流完成: ${STATE.pullSummary}`);
    if (STATE.transportState === 'PLAYING') { STATE.transportState = 'STOPPED'; stopPullClock(); }
  } catch (e) {
    STATE.pullDone = true;
    STATE.pullError = String(e && e.message || e);
    STATE.pullSummary = `ERROR ${STATE.pullError}`;
    console.log(`[MOCK-PLAY] 拉流失败: ${STATE.pullSummary}`);
    if (STATE.transportState === 'PLAYING') { STATE.transportState = 'STOPPED'; stopPullClock(); }
  }
}

const DESC_XML = `<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>HiVi H5MKII (Mock)</friendlyName>
    <manufacturer>HiVi</manufacturer>
    <modelName>H5MKII</modelName>
    <modelNumber>1.0</modelNumber>
    <UDN>uuid:${UUID}</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>
        <controlURL>/avt/control</controlURL>
        <eventSubURL>/avt/event</eventSubURL>
        <SCPDURL>/avt/scpd</SCPDURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:RenderingControl</serviceId>
        <controlURL>/rc/control</controlURL>
        <eventSubURL>/rc/event</eventSubURL>
        <SCPDURL>/rc/scpd</SCPDURL>
      </service>
    </serviceList>
  </device>
</root>`;

// ---- HTTP 服务器 ----
const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', c => body += c);
  req.on('end', () => {
    const urlPath = (req.url || '/').split('?')[0];
    if (req.method === 'GET') {
      if (urlPath === '/desc.xml' || urlPath === '/') {
        res.writeHead(200, { 'Content-Type': 'text/xml; charset="utf-8"' });
        res.end(DESC_XML); console.log('[MOCK-HTTP] GET desc.xml'); return;
      }
      if (urlPath === '/status') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ...STATE })); return;
      }
      res.writeHead(404); res.end('404'); return;
    }
    if (req.method === 'POST') {
      const soapAction = req.headers['soapaction'] || '';
      const m = soapAction.match(/(?:urn:schemas-upnp-org:service:([^:]+):\d+#)([A-Za-z]+)/);
      const wantAction = m ? m[2] : '';
      const isRc = /RenderingControl/.test(soapAction);
      const out = isRc ? handleRendering(wantAction) : handleTransport(wantAction, body);
      console.log(`[MOCK-SOAP] ${isRc?'RC ':'AVT'} ${wantAction} → ${out.status}`);
      res.writeHead(out.status, { 'Content-Type': 'text/xml; charset="utf-8"', 'EXT': '' });
      res.end(out.body); return;
    }
    res.writeHead(405); res.end();
  });
});

// ---- SSDP ----
const sock = dgram.createSocket({ type: 'udp4', reuseAddr: true });
function sendSdp(msg, port, addr) {
  try { sock.send(Buffer.from(msg), port, addr); } catch (e) { console.log('[MOCK-SSDP] send fail', e.message); }
}
function ssdpReply(rinfo) {
  const loc = `http://${HOSTNAME}:${HTTP_PORT}/desc.xml`;
  const st = 'urn:schemas-upnp-org:device:MediaRenderer:1';
  const msg =
    'HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nEXT:\r\n' +
    `LOCATION: ${loc}\r\nSERVER: MusicFlow/1.0 UPnP/1.0 MockRenderer/1.0\r\n` +
    `ST: ${st}\r\nUSN: uuid:${UUID}::${st}\r\n\r\n`;
  sendSdp(msg, rinfo.port, rinfo.address);
  console.log(`[MOCK-SSDP] → ${rinfo.address}:${rinfo.port} respond MediaRenderer`);
}
sock.on('message', (msg, rinfo) => {
  const text = msg.toString('utf8');
  if (!/^M-SEARCH/m.test(text)) return;
  const stMatch = text.match(/^ST:\s*(.+)$/m);
  const st = (stMatch ? stMatch[1].trim() : '').toLowerCase();
  console.log(`[MOCK-SSDP] M-SEARCH from ${rinfo.address}:${rinfo.port} ST=${st}`);
  ssdpReply(rinfo);
});
sock.on('listening', () => {
  console.log(`[MOCK-SSDP] UDP 监听 ${BIND_IP}:1900`);
  try { sock.setBroadcast(true); sock.addMembership(SSDP_ADDR); } catch (e) {}
  try { sock.addMembership(SSDP_ADDR, BIND_IP); } catch (e) {}
});
sock.bind(SSDP_PORT, BIND_IP);

function sendAlive() {
  const loc = `http://${HOSTNAME}:${HTTP_PORT}/desc.xml`;
  const st = 'urn:schemas-upnp-org:device:MediaRenderer:1';
  const msg =
    `NOTIFY * HTTP/1.1\r\nHOST: ${SSDP_ADDR}:${SSDP_PORT}\r\nCACHE-CONTROL: max-age=1800\r\n` +
    `LOCATION: ${loc}\r\nNT: ${st}\r\nNTS: ssdp:alive\r\n` +
    'SERVER: MusicFlow/1.0 UPnP/1.0 MockRenderer/1.0\r\n' +
    `USN: uuid:${UUID}::${st}\r\n\r\n`;
  sendSdp(msg, SSDP_PORT, SSDP_ADDR);
  console.log('[MOCK-SSDP] NOTIFY ssdp:alive 已发送');
}
setTimeout(sendAlive, 800);
setInterval(sendAlive, 90000);

server.listen(HTTP_PORT, BIND_IP, () => console.log(`[MOCK] 就绪: http://${HOSTNAME}:${HTTP_PORT}/desc.xml`));
# -*- coding: utf-8 -*-
"""复刻客户端启动会发的请求链，对比「内网 HTTP」与「公网 HTTPS」的总墙钟。

链路：ping(无鉴权) -> login -> register(拿 peerId) -> 首屏 6 接口（并发）

用法（在任意能访问两条路径的机器上）：python probe_full_chain.py
"""
import json
import ssl
import time
import urllib.request

USER = 'xyz5378'
PWD = '@$qQ!J4pNnSoy8'

LAN = 'http://192.168.10.240:46400'
PUB = 'https://music.cmct.fun:35378'

HOME = [
    ('randomSongs', '/rest/getRandomSongs', {'size': 48}),
    ('starred2', '/rest/getStarred2', {}),
    ('playlists', '/rest/getPlaylists', {}),
    ('indexes', '/rest/getIndexes', {}),
    ('recentlyPlayed', '/rest/getRecentlyPlayed', {}),
    ('genres', '/rest/getGenres', {}),
]


def get(url, params=None, token=None, timeout=30):
    q = '&'.join('%s=%s' % (k, v) for k, v in (params or {}).items())
    u = url + params_query(params, q)
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    req = urllib.request.Request(u, headers={'User-Agent': 'boot-probe/1.0'})
    if token:
        req.add_header('Authorization', 'Bearer ' + token)
    t0 = time.perf_counter()
    with urllib.request.urlopen(req, timeout=timeout, context=ctx) as r:
        body = r.read()
    return (time.perf_counter() - t0) * 1000, r.status, body


def params_query(params, q):
    """拼鉴权参数 + 附加参数，返回完整 query 串。"""
    import hashlib
    import secrets
    import urllib.parse

    salt = secrets.token_hex(4)
    raw = PWD + salt
    token = hashlib.md5(raw.encode()).hexdigest()
    p = {'u': USER, 'p': token, 's': salt, 'v': '1.16.1', 'c': 'boot-probe'}
    p.update(params or {})
    return '?' + urllib.parse.urlencode(p)


def chain(base, label):
    print('=== %s  %s ===' % (label, base))
    t_all = time.perf_counter()

    dt, _, _ = get(base, {'f': 'json'})
    print('  ping            %7.1f ms' % dt)

    dt, _, body = get(base, {'f': 'json'})
    print('  login(bad creds)%7.1f ms' % dt)

    # 真实登录（Subsonic 方式：salt + md5 token 走 query，或明文 password）
    import urllib.parse
    p = {'u': USER, 'p': PWD, 'v': '1.16.1', 'c': 'boot-probe', 'f': 'json'}
    u = base + '/rest/login?' + urllib.parse.urlencode(p)
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    t0 = time.perf_counter()
    try:
        with urllib.request.urlopen(urllib.request.Request(u), timeout=30, context=ctx) as r:
            login_body = r.read()
        lg = 'ok'
    except Exception as e:  # noqa: BLE001
        lg = 'fail(%s)' % type(e).__name__
    login_ms = (time.perf_counter() - t0) * 1000
    print('  login           %7.1f ms  %s' % (login_ms, lg))

    t0 = time.perf_counter()
    try:
        with urllib.request.urlopen(urllib.request.Request(base + '/rest/ping?f=json'),
                                    timeout=30, context=ctx) as r:
            register_body = r.read()
        reg_ms = (time.perf_counter() - t0) * 1000
        info = 'ok'
    except Exception as e:  # noqa: BLE001
        reg_ms = (time.perf_counter() - t0) * 1000
        info = 'fail(%s)' % type(e).__name__
    print('  register/ping   %7.1f ms  %s' % (reg_ms, info))

    # 首屏 6 接口并发
    t0 = time.perf_counter()
    results = []
    import concurrent.futures as cf
    with cf.ThreadPoolExecutor(max_workers=6) as ex:
        futs = {ex.submit(get, base, dict(params, f='json')): name
                for name, _, params in HOME}
        for f, name in futs.items():
            try:
                dt, code, _ = f.result()
                results.append((name, dt, code))
            except Exception as e:  # noqa: BLE001
                results.append((name, -1.0, type(e).__name__))
    wall = (time.perf_counter() - t0) * 1000
    for name, dt, code in sorted(results):
        print('  home:%-14s %7.1f ms  %s' % (name, dt, code))
    print('  home wall-clock %7.1f ms (并发 6 条)' % wall)
    print('  TOTAL chain     %7.1f ms' % ((time.perf_counter() - t_all) * 1000))
    print()


if __name__ == '__main__':
    chain(LAN, '内网 HTTP')
    chain(PUB, '公网 HTTPS')

import 'package:flutter/material.dart';

import '../data/api_client.dart';
import '../data/auth_store.dart';

/// 登录页：填服务器地址 + 账号密码 → ping 校验。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.store, this.onLoggedIn});

  final AuthStore store;

  /// 连接成功回调（用于重建 Shell）。
  final void Function(AuthStore store)? onLoggedIn;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _host = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool busy = false;
  String? error;

  @override
  void initState() {
    super.initState();
    _host.text = widget.store.server;
    _user.text = widget.store.user;
    _pass.text = widget.store.password;
  }

  Future<void> _connect() async {
    setState(() {
      busy = true;
      error = null;
    });
    final server = AuthStore.normalize(_host.text);
    if (server.isEmpty || _user.text.trim().isEmpty) {
      setState(() {
        busy = false;
        error = '请填写服务器地址和用户名';
      });
      return;
    }
    // 先临时保存再校验（ping 需要鉴权参数）。
    await widget.store.save(server: server, user: _user.text, password: _pass.text);
    final api = ApiClient(widget.store);
    try {
      await api.ping();
      if (!mounted) return;
      // 父级收到回调后整体重建为 Shell（home 切换），无需自行导航。
      widget.onLoggedIn?.call(widget.store);
    } catch (e) {
      await widget.store.clear();
      setState(() {
        busy = false;
        error = '连接失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('MusicFlow', style: tt.displaySmall, textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Text('连接你的音乐库', style: tt.bodyMedium, textAlign: TextAlign.center),
                const SizedBox(height: 32),
                TextField(
                  controller: _host,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: '服务器地址',
                    hintText: 'http://192.168.1.10:46400',
                    prefixIcon: Icon(Icons.dns_outlined),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _user,
                  decoration: const InputDecoration(
                    labelText: '用户名',
                    prefixIcon: Icon(Icons.person_outline),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _pass,
                  obscureText: true,
                  onSubmitted: (_) => _connect(),
                  decoration: const InputDecoration(
                    labelText: '密码',
                    prefixIcon: Icon(Icons.lock_outline),
                    border: OutlineInputBorder(),
                  ),
                ),
                if (error != null) ...[
                  const SizedBox(height: 12),
                  Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: busy ? null : _connect,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(busy ? '连接中…' : '连接'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

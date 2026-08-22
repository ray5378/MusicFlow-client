import 'package:flutter/material.dart';

import '../data/auth_store.dart';

/// 设置页：服务器信息 / 主题模式 / 退出登录。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.store, required this.onLogout, required this.themeMode, required this.onThemeMode});

  final AuthStore store;
  final VoidCallback onLogout;
  final ThemeMode themeMode;
  final void Function(ThemeMode mode) onThemeMode;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('服务器', style: tt.headlineSmall),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('地址：${store.server}', style: tt.bodyMedium),
                  const SizedBox(height: 4),
                  Text('用户：${store.user}', style: tt.bodyMedium),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text('外观', style: tt.headlineSmall),
          RadioGroup<ThemeMode>(
            groupValue: themeMode,
            onChanged: (v) {
              if (v != null) onThemeMode(v);
            },
            child: const Column(
              children: [
                RadioListTile<ThemeMode>(
                  value: ThemeMode.system,
                  title: Text('跟随系统'),
                ),
                RadioListTile<ThemeMode>(
                  value: ThemeMode.light,
                  title: Text('浅色'),
                ),
                RadioListTile<ThemeMode>(
                  value: ThemeMode.dark,
                  title: Text('深色'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.tonalIcon(
            onPressed: onLogout,
            icon: const Icon(Icons.logout),
            label: const Text('退出登录'),
          ),
          const SizedBox(height: 16),
          Center(child: Text('MusicFlow 客户端 · 对接 MusicFlow 服务端', style: tt.labelSmall)),
        ],
      ),
    );
  }
}

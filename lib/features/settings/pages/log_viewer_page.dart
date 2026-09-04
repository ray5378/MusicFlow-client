import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/design/components/music_flow_app_bar.dart';
import '../../../core/design/music_flow_design.dart';
import '../../../core/utils/logger.dart';
import '../../../l10n/generated/app_localizations.dart';

/// 应用内诊断日志窗口：无需控制台/导出即可直接在客户端查看并复制日志。
///
/// - 实时刷新（1s 轮询 Logger 内存缓冲，默认开启，可关闭）
/// - 关键字筛选（例如输入 `DLNA-AUTO` / `SSDP` 只看续播/扫描日志）
/// - 「复制全部」一键把当前筛选内容写入剪贴板
/// - 「清空」复位缓冲，便于复现前只保留目标片段
class LogViewerPage extends StatefulWidget {
  const LogViewerPage({super.key});

  @override
  State<LogViewerPage> createState() => _LogViewerPageState();
}

class _LogViewerPageState extends State<LogViewerPage> {
  final TextEditingController _filterController = TextEditingController();
  Timer? _pollTimer;
  bool _autoRefresh = true;
  String _lastSnapshot = '';
  bool _isEmpty = true;

  static const int _maxShownLines = 1500;

  @override
  void initState() {
    super.initState();
    _refresh();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _autoRefresh) _refresh();
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _filterController.dispose();
    super.dispose();
  }

  void _refresh() {
    if (!mounted) return;
    final snapshot = Logger.exportLogs();
    if (snapshot == _lastSnapshot) return;
    _lastSnapshot = snapshot;
    setState(() => _isEmpty = snapshot.isEmpty);
  }

  /// 当前生效的日志行（filter 过滤 + 截取最新 N 行）。
  List<String> get _visibleLines {
    final keyword = _filterController.text.trim();
    final lines = _lastSnapshot.split('\n');
    final filtered = keyword.isEmpty
        ? lines
        : lines.where((l) => l.contains(keyword)).toList();
    if (filtered.length <= _maxShownLines) return filtered;
    return filtered.sublist(filtered.length - _maxShownLines);
  }

  void _copyAll() {
    final lines = _visibleLines;
    final loc = AppLocalizations.of(context);
    if (lines.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(loc.settings_log_no_content)));
      return;
    }
    Clipboard.setData(ClipboardData(text: lines.join('\n')));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(loc.settings_log_copied(lines.length))));
  }

  void _clearBuffer() {
    Logger.clearBuffer();
    _lastSnapshot = '';
    setState(() => _isEmpty = true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = _visibleLines;
    final loc = AppLocalizations.of(context);

    return Scaffold(
      appBar: MusicFlowAppBar(
        title: Text(loc.settings_log_diagnostics),
        actions: <Widget>[
          MusicFlowIconButton(
            icon: _autoRefresh ? Icons.pause : Icons.play_arrow,
            label: loc.settings_log_auto_refresh,
            onPressed: () => setState(() => _autoRefresh = !_autoRefresh),
          ),
          MusicFlowIconButton(
            icon: Icons.delete_sweep_outlined,
            label: loc.settings_log_clear_cache,
            onPressed: _clearBuffer,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _filterController,
                      decoration: InputDecoration(
                        isDense: true,
                        border: const OutlineInputBorder(),
                        hintText: loc.settings_log_filter_hint,
                        prefixIcon: const Icon(Icons.search, size: 20),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonal(
                    onPressed: _copyAll,
                    child: Text(loc.settings_log_copy),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: <Widget>[
                  Text(
                    loc.settings_log_summary(
                      Logger.bufferedLineCount,
                      lines.length,
                      _autoRefresh
                          ? loc.settings_log_status_live
                          : loc.settings_log_status_paused,
                    ),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _isEmpty
                  ? Center(child: Text(loc.settings_log_empty))
                  : SelectionArea(
                      child: ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: lines.length,
                        itemBuilder: (context, index) {
                          final line = lines[index];
                          final isDiagnostic =
                              line.contains('DLNA') || line.contains('SSDP');
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 1),
                            child: Text(
                              line,
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11,
                                height: 1.35,
                                color: isDiagnostic
                                    ? theme.colorScheme.tertiary
                                    : theme.textTheme.bodySmall?.color,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
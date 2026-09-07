import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';



class SleepTimerOffSentinel {
  const SleepTimerOffSentinel();
}

/// 用户选定的定时结果：时长。
class SleepTimerStartChoice {
  const SleepTimerStartChoice({required this.duration});

  final Duration duration;
}

/// 「定时停止播放」设置弹窗（图样式）：预设档 + 自定义分钟步进器。
/// 通过 Navigator.pop 返回 `SleepTimerStartChoice` / `SleepTimerOffSentinel` / null。
class SleepTimerSheet extends StatefulWidget {
  const SleepTimerSheet({
    super.key,
    required this.hasExisting,
    this.initialMinutes = 0,
  });

  final bool hasExisting;

  /// 已有定时时回显的实际剩余分钟数（widget 打开前由调用方从 provider 读取）。
  final int initialMinutes;

  @override
  State<SleepTimerSheet> createState() => _SleepTimerSheetState();
}

class _SleepTimerSheetState extends State<SleepTimerSheet> {
  static const _presets = <int>[10, 20, 30, 40, 50, 60];
  static const _maxMinutes = 180;
  late int _customMinutes = widget.initialMinutes;
  late final TextEditingController _minutesController = TextEditingController(
    text: widget.initialMinutes > 0 ? widget.initialMinutes.toString() : '',
  );

  @override
  void dispose() {
    _minutesController.dispose();
    super.dispose();
  }

  /// 把内部分钟值写回输入框（+/- 按钮用），并重建。
  void _applyMinutes(int next) {
    _customMinutes = next;
    _minutesController.text = next.toString();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(loc.player_sleep_timer_dialog_title),
      titleTextStyle: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
      contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // 预设档位：10/20/30/40/50/60 分钟。点一下仅选中（高亮），
          // 再点底部「开始定时」才真正启动。
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _presets.map((mn) => _PresetChip(
              label: loc.player_sleep_timer_minutes(mn),
              selected: _customMinutes == mn,
              onTap: () => setState(() {
                _customMinutes = mn;
                _minutesController.text = mn.toString();
              }),
            )).toList(),
          ),
          const SizedBox(height: 16),
          // 自定义分钟步进器（0 起，+/-，分钟单位）。
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              _StepperButton(
                icon: Icons.remove,
                onTap: () {
                  if (_customMinutes > 0) _applyMinutes(_customMinutes - 1);
                },
              ),
              const SizedBox(width: 14),
              // 手输分钟数：数字键盘，与 +/- 步进器双向同步。
              SizedBox(
                width: 92,
                child: TextField(
                  controller: _minutesController,
                  textAlign: TextAlign.center,
                  keyboardType: TextInputType.number,
                  inputFormatters: <TextInputFormatter>[
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(3),
                  ],
                  style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold),
                  decoration: const InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    counterText: '',
                  ),
                  onChanged: (value) {
                    final n = int.tryParse(value) ?? 0;
                    _customMinutes = n.clamp(0, _maxMinutes);
                  },
                ),
              ),
              const SizedBox(width: 8),
              Text(
                loc.player_sleep_timer_minutes_unit,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(width: 14),
              _StepperButton(
                icon: Icons.add,
                onTap: () {
                  if (_customMinutes < _maxMinutes) _applyMinutes(_customMinutes + 1);
                },
              ),
            ],
          ),
        ],
      ),
      actions: <Widget>[
        if (widget.hasExisting)
          MusicFlowButton.ghost(
            label: loc.player_sleep_timer_off,
            onPressed: () => Navigator.of(context).pop(const SleepTimerOffSentinel()),
          ),
        MusicFlowButton.ghost(
          label: loc.settings_cancel,
          onPressed: () => Navigator.of(context).pop(),
        ),
        MusicFlowButton.primary(
          label: loc.player_sleep_timer_start,
          onPressed: _customMinutes > 0
              ? () => Navigator.of(context).pop(SleepTimerStartChoice(
                    duration: Duration(minutes: _customMinutes),
                  ))
              : null,
        ),
      ],
    );
  }
}

class _PresetChip extends StatelessWidget {
  const _PresetChip({
    required this.label,
    required this.onTap,
    this.selected = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return MusicFlowPressable(
      borderRadius: BorderRadius.circular(12),
      onPressed: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? cs.primaryContainer : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: selected ? cs.primary : cs.outlineVariant),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? cs.onPrimaryContainer : cs.onSurface,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _StepperButton extends StatelessWidget {
  const _StepperButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return IconButton.filledTonal(
      onPressed: onTap,
      icon: Icon(icon),
      style: IconButton.styleFrom(foregroundColor: accent),
    );
  }
}

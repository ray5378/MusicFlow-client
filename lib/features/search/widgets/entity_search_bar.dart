import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/design/echo_design.dart';

/// 统一搜索条(聚合搜索专用):只有关键词输入(debounce),无来源切换。
/// 需求:去掉「聚合 / 本地 / 插件」切换按钮,全部强制聚合搜索。
/// 搜索结果由 [AggregateSearchResults] 分块展示(本地结果 / 全网结果)。
class EntitySearchBar extends StatefulWidget {
  final String query;
  final ValueChanged<String> onQueryChanged;
  final String hintText;

  const EntitySearchBar({
    super.key,
    required this.query,
    required this.onQueryChanged,
    this.hintText = '搜索',
  });

  @override
  State<EntitySearchBar> createState() => _EntitySearchBarState();
}

class _EntitySearchBarState extends State<EntitySearchBar> {
  static const _debounce = Duration(milliseconds: 450);
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _controller.text = widget.query;
  }

  @override
  void didUpdateWidget(covariant EntitySearchBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query && _controller.text != widget.query) {
      _controller.text = widget.query;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _timer?.cancel();
    _timer = Timer(_debounce, () {
      if (!mounted) return;
      widget.onQueryChanged(value.trim());
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: context.echoPageHorizontalPadding,
      ),
      child: TextField(
        controller: _controller,
        focusNode: _focus,
        onChanged: _onQueryChanged,
        decoration: InputDecoration(
          hintText: widget.hintText,
          prefixIcon: const Icon(AppIcons.search, size: 20),
          suffixIcon: _controller.text.isNotEmpty
              ? EchoIconButton(
                  icon: AppIcons.close,
                  label: '清空搜索词',
                  iconSize: 18,
                  onPressed: () {
                    _controller.clear();
                    widget.onQueryChanged('');
                  },
                )
              : null,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 10,
          ),
        ),
      ),
    );
  }
}

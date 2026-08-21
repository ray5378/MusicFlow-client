import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/design/echo_design.dart';
import '../../../data/models/search.dart';
import '../../../providers/search_provider.dart';

/// 搜索来源下拉的取值:聚合 / 本地 / 某个插件(providerId)
typedef SearchSource = ({SearchMode mode, String providerId});

/// 可复用搜索条:顶部「聚合 / 本地 / 插件」来源切换 + 关键词输入(debounce)。
/// 由所在页面持有 mode/providerId/query 状态并向下传递;本组件只负责 UI 与回调。
class EntitySearchBar extends ConsumerStatefulWidget {
  final SearchEntityKind kind;
  final SearchMode mode;
  final String providerId;
  final String query;
  final ValueChanged<SearchSource> onSourceChanged;
  final ValueChanged<String> onQueryChanged;

  const EntitySearchBar({
    super.key,
    required this.kind,
    required this.mode,
    required this.providerId,
    required this.query,
    required this.onSourceChanged,
    required this.onQueryChanged,
  });

  @override
  ConsumerState<EntitySearchBar> createState() => _EntitySearchBarState();
}

class _EntitySearchBarState extends ConsumerState<EntitySearchBar> {
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

  String get _currentValue {
    if (widget.mode == SearchMode.aggregate) return 'aggregate';
    if (widget.mode == SearchMode.local) return 'local';
    return widget.providerId;
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
    final providersAsync = ref.watch(searchProvidersProvider(widget.kind));

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: context.echoPageHorizontalPadding,
      ),
      child: Row(
        children: <Widget>[
          _buildSourceButton(context, providersAsync),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _focus,
              onChanged: _onQueryChanged,
              decoration: InputDecoration(
                hintText: '搜索${_kindLabel(widget.kind)}',
                prefixIcon: const Icon(AppIcons.search, size: 20),
                suffixIcon: _controller.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(AppIcons.close, size: 18),
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
          ),
        ],
      ),
    );
  }

  Widget _buildSourceButton(
    BuildContext context,
    AsyncValue<List<SearchProvider>> providersAsync,
  ) {
    return providersAsync.when(
      data: (providers) => _sourceDropdown(providers),
      loading: () => _sourceDropdown(const []),
      error: (error, stackTrace) => _sourceDropdown(const []),
    );
  }

  DropdownButton<String> _sourceDropdown(List<SearchProvider> providers) {
    final items = <DropdownMenuItem<String>>[
      const DropdownMenuItem(
        value: 'aggregate',
        child: Text('聚合'),
      ),
      const DropdownMenuItem(
        value: 'local',
        child: Text('本地'),
      ),
    ];
    for (final p in providers) {
      items.add(DropdownMenuItem(
        value: p.id,
        child: Text(p.name),
      ));
    }

    return DropdownButton<String>(
      value: items.any((i) => i.value == _currentValue)
          ? _currentValue
          : 'aggregate',
      items: items,
      selectedItemBuilder: (context) => items
          .map((item) => Text(_truncatedLabel(providers)))
          .toList(),
      onChanged: (value) {
        if (value == null) return;
        if (value == 'aggregate') {
          widget.onSourceChanged((mode: SearchMode.aggregate, providerId: ''));
        } else if (value == 'local') {
          widget.onSourceChanged((mode: SearchMode.local, providerId: ''));
        } else {
          widget.onSourceChanged((mode: SearchMode.plugin, providerId: value));
        }
      },
    );
  }

  String _truncatedLabel(List<SearchProvider> providers) {
    if (widget.mode == SearchMode.aggregate) return '聚合';
    if (widget.mode == SearchMode.local) return '本地';
    var name = widget.providerId;
    for (final p in providers) {
      if (p.id == widget.providerId) {
        name = p.name;
        break;
      }
    }
    return name.length > 2 ? name.substring(0, 2) : name;
  }
}

String _kindLabel(SearchEntityKind kind) {
  switch (kind) {
    case SearchEntityKind.song:
      return '歌曲';
    case SearchEntityKind.album:
      return '专辑';
    case SearchEntityKind.artist:
      return '艺术家';
    case SearchEntityKind.playlist:
      return '歌单';
  }
}

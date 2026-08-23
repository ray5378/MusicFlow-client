import 'package:flutter/material.dart';

/// 横向滚动容器：鼠标悬停时浮显左右箭头按钮，点击可左右滑动查看隐藏内容。
/// 对标主项目 web 端横向列表的交互体验。
///
/// 注意：必须用 [builder] 把本组件内部的 [ScrollController] 传给子级的
/// ListView / SingleChildScrollView（`controller: controller`）。否则父级
/// 控制器没有挂载任何滚动视图（`hasClients == false`），滚动边界永远算不出，
/// 左右箭头将永不显示（历史 bug：组件写了但首页箭头一直不出现）。
class HoverableHorizontalScroll extends StatefulWidget {
  const HoverableHorizontalScroll({
    super.key,
    required this.builder,
    this.scrollStep = 240,
  });

  /// 构造子级横向滚动列表，必须把 [controller] 传给子级滚动视图。
  final Widget Function(BuildContext context, ScrollController controller)
      builder;

  /// 每次点击箭头滚动的像素量。
  final double scrollStep;

  @override
  State<HoverableHorizontalScroll> createState() =>
      _HoverableHorizontalScrollState();
}

class _HoverableHorizontalScrollState extends State<HoverableHorizontalScroll>
    with SingleTickerProviderStateMixin {
  late final ScrollController _controller;
  late final AnimationController _fadeCtrl;
  late final Animation<double> _fade;
  bool _canLeft = false;
  bool _canRight = false;

  @override
  void initState() {
    super.initState();
    _controller = ScrollController();
    _controller.addListener(_checkBounds);
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _fade = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkBounds());
  }

  @override
  void dispose() {
    _controller.removeListener(_checkBounds);
    _controller.dispose();
    _fadeCtrl.dispose();
    super.dispose();
  }

  void _checkBounds() {
    if (!_controller.hasClients) return;
    final pos = _controller.position;
    final left = pos.pixels > pos.minScrollExtent + 1;
    final right = pos.pixels < pos.maxScrollExtent - 1;
    if (left != _canLeft || right != _canRight) {
      setState(() {
        _canLeft = left;
        _canRight = right;
      });
    }
  }

  void _scroll(double delta) {
    if (!_controller.hasClients) return;
    _controller.animateTo(
      (_controller.offset + delta).clamp(
        _controller.position.minScrollExtent,
        _controller.position.maxScrollExtent,
      ),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) {
        _fadeCtrl.forward();
        _checkBounds();
      },
      onExit: (_) => _fadeCtrl.reverse(),
      child: NotificationListener<ScrollMetricsNotification>(
        onNotification: (_) {
          // 子级滚动视图尺寸/边界变化（如窗口缩放、数据刷新后）时重算箭头。
          _checkBounds();
          return false;
        },
        child: Stack(
          children: <Widget>[
            widget.builder(context, _controller),
            if (_canLeft)
              Positioned(
                left: 6,
                top: 0,
                bottom: 0,
                width: 44,
                child: FadeTransition(
                  opacity: _fade,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: () => _scroll(-widget.scrollStep),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: _ArrowBtn(icon: Icons.chevron_left),
                    ),
                  ),
                ),
              ),
            if (_canRight)
              Positioned(
                right: 6,
                top: 0,
                bottom: 0,
                width: 44,
                child: FadeTransition(
                  opacity: _fade,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: () => _scroll(widget.scrollStep),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: _ArrowBtn(icon: Icons.chevron_right),
                    ),
                  ),
                ),
              ),
            if (_canLeft)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: 48,
                child: FadeTransition(
                  opacity: _fade,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: <Color>[
                            Theme.of(context).colorScheme.surface,
                            Theme.of(context).colorScheme.surface.withAlpha(0),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (_canRight)
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                width: 48,
                child: FadeTransition(
                  opacity: _fade,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.centerRight,
                          end: Alignment.centerLeft,
                          colors: <Color>[
                            Theme.of(context).colorScheme.surface,
                            Theme.of(context).colorScheme.surface.withAlpha(0),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 箭头按钮：半透明黑色圆形，鼠标悬停时高亮（底色加深、图标变亮）。
class _ArrowBtn extends StatefulWidget {
  const _ArrowBtn({required this.icon});
  final IconData icon;

  @override
  State<_ArrowBtn> createState() => _ArrowBtnState();
}

class _ArrowBtnState extends State<_ArrowBtn> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    // 半透明黑底 + 白色图标；悬停时加深并轻微放大，达到高亮效果。
    final background = _hovered
        ? Colors.black.withAlpha(170)
        : Colors.black.withAlpha(110);
    final iconColor = _hovered
        ? Colors.white
        : Colors.white.withAlpha(235);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 32,
        height: 32,
        transform: Matrix4.diagonal3Values(
          _hovered ? 1.12 : 1.0,
          _hovered ? 1.12 : 1.0,
          1.0,
        ),
        transformAlignment: Alignment.center,
        decoration: BoxDecoration(
          color: background,
          shape: BoxShape.circle,
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withAlpha(50),
              blurRadius: 4,
            ),
          ],
        ),
        child: Icon(widget.icon, size: 20, color: iconColor),
      ),
    );
  }
}

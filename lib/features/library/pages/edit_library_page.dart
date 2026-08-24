import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/design/echo_design.dart';
import '../../../data/models/music_library.dart';
import '../../../data/models/server_address.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/library_provider.dart';
import '../../../providers/player_provider.dart';
import '../widgets/address_dialog.dart';

class EditLibraryPage extends ConsumerStatefulWidget {
  const EditLibraryPage({super.key, required this.libraryId});

  final String libraryId;

  @override
  ConsumerState<EditLibraryPage> createState() => _EditLibraryPageState();
}

class _EditLibraryPageState extends ConsumerState<EditLibraryPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  late final TextEditingController _apiKeyController;

  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _usernameController = TextEditingController();
    _passwordController = TextEditingController();
    _apiKeyController = TextEditingController();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final librariesAsync = ref.watch(librariesProvider);
    return librariesAsync.when(
      data: (libraries) {
        final library = libraries.cast<MusicLibrary?>().firstWhere(
          (item) => item?.id == widget.libraryId,
          orElse: () => null,
        );
        if (library == null) {
          return const _LibraryLoadingPage(
            title: '编辑音乐库',
            message: '正在更新音乐库列表',
          );
        }

        _initializeForm(library);
        return EchoScaffold(
          topBar: EchoTopBar.back(
            context: context,
            title: '编辑音乐库',
            subtitle: library.name,
            actions: <Widget>[
              EchoIconButton(
                icon: AppIcons.save,
                label: '保存音乐库',
                onPressed: () => _saveLibrary(library),
              ),
            ],
          ),
          body: SafeArea(
            top: false,
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 920),
                child: SingleChildScrollView(
                  key: const ValueKey<String>('edit-library-scroll'),
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: EdgeInsets.fromLTRB(
                    context.echoPageHorizontalPadding,
                    context.echoSpacing.sm,
                    context.echoPageHorizontalPadding,
                    MediaQuery.viewInsetsOf(context).bottom +
                        context.echoSpacing.xxl +
                        context.echoShellBottomObstruction,
                  ),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        _buildBasicInfoSection(),
                        SizedBox(height: context.echoSpacing.xl),
                        const EchoDivider(),
                        SizedBox(height: context.echoSpacing.xl),
                        _buildAddressesSection(library),
                        SizedBox(height: context.echoSpacing.xl),
                        const EchoDivider(),
                        SizedBox(height: context.echoSpacing.xl),
                        _buildDeleteSection(library),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
      loading: () =>
          const _LibraryLoadingPage(title: '编辑音乐库', message: '正在读取音乐库配置'),
      error: (error, stackTrace) => EchoScaffold(
        topBar: EchoTopBar.back(context: context, title: '编辑音乐库'),
        body: EchoErrorState(
          title: '无法读取音乐库',
          description: '音乐库配置暂时不可用，请重试。',
          actionLabel: '重试',
          onAction: () => ref.invalidate(librariesProvider),
        ),
      ),
    );
  }

  void _initializeForm(MusicLibrary library) {
    if (_initialized) return;
    _nameController.text = library.name;
    _usernameController.text = library.username ?? '';
    _passwordController.text = library.password ?? '';
    _apiKeyController.text = library.apiKey ?? '';
    _initialized = true;
  }

  Widget _buildBasicInfoSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const EchoSectionHeader(
          title: '基本信息',
          description: '这个名称只用于在 MusicFlow 中区分不同的音乐库。',
        ),
        SizedBox(height: context.echoSpacing.md),
        EchoTextField(
          controller: _nameController,
          label: '库名称',
          hintText: '例如：家庭音乐库',
          leadingIcon: AppIcons.library,
          textInputAction: TextInputAction.done,
          validator: (value) {
            if (value == null || value.trim().isEmpty) return '请输入名称';
            return null;
          },
        ),
      ],
    );
  }

  Widget _buildAddressesSection(MusicLibrary library) {
    final sortedAddresses = List<ServerAddress>.from(library.addresses)
      ..sort((first, second) => first.priority.compareTo(second.priority));

    final actions = <Widget>[
      if (library.isActive)
        EchoIconButton(
          icon: AppIcons.refresh,
          label: '检测全部线路延迟',
          onPressed: () async {
            await ref.read(addressPoolProvider).probeAll();
            if (mounted) ref.invalidate(librariesProvider);
          },
        ),
      EchoIconButton(
        icon: AppIcons.addCircle,
        label: '添加服务器地址',
        onPressed: () => _showAddressSheet(),
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        EchoSectionHeader(
          title: '服务器地址',
          description: '长按拖动手柄调整优先级；排在前面的线路优先使用。',
          trailing: Wrap(
            spacing: context.echoSpacing.xxs,
            runSpacing: context.echoSpacing.xxs,
            children: actions,
          ),
        ),
        SizedBox(height: context.echoSpacing.sm),
        if (sortedAddresses.isEmpty)
          _InlineFormState(
            icon: AppIcons.route,
            title: '还没有服务器地址',
            description: '至少添加一条线路后才能连接这个音乐库。',
            actionLabel: '添加地址',
            onAction: _showAddressSheet,
          )
        else
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: sortedAddresses.length,
            onReorder: (oldIndex, newIndex) =>
                _onReorderAddresses(sortedAddresses, oldIndex, newIndex),
            proxyDecorator: (child, index, animation) {
              return AnimatedBuilder(
                animation: animation,
                builder: (context, _) => EchoSurface(
                  level: EchoSurfaceLevel.floating,
                  borderColor: context.echoColors.controlBoundary,
                  child: child,
                ),
              );
            },
            itemBuilder: (context, index) {
              final address = sortedAddresses[index];
              return _AddressRow(
                key: ValueKey(address.id),
                address: address,
                index: index,
                onEdit: () => _showAddressSheet(address: address),
                onDelete: () => _deleteAddress(address),
              );
            },
          ),
      ],
    );
  }

  Future<void> _onReorderAddresses(
    List<ServerAddress> addresses,
    int oldIndex,
    int newIndex,
  ) async {
    if (oldIndex < newIndex) newIndex -= 1;
    final item = addresses.removeAt(oldIndex);
    addresses.insert(newIndex, item);

    final repository = ref.read(libraryRepositoryProvider);
    for (var index = 0; index < addresses.length; index++) {
      await repository.updateAddress(
        addresses[index].copyWith(priority: index),
      );
    }
    ref.invalidate(librariesProvider);
  }

  Widget _buildDeleteSection(MusicLibrary library) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const EchoSectionHeader(
          title: '危险操作',
          description: '删除音乐库会移除本机保存的连接信息，且无法恢复。',
        ),
        SizedBox(height: context.echoSpacing.md),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: EchoButton.destructive(
            label: '删除此音乐库',
            leadingIcon: AppIcons.delete,
            onPressed: () => _confirmDelete(library),
          ),
        ),
      ],
    );
  }

  Future<void> _showAddressSheet({ServerAddress? address}) async {
    final result = await showEchoBottomSheet<ServerAddress>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (context) =>
          AddressDialog(libraryId: widget.libraryId, initialAddress: address),
    );
    if (result == null) return;

    final libraries = await ref.read(librariesProvider.future);
    if (!mounted) return;
    final library = libraries.firstWhere((item) => item.id == widget.libraryId);

    if (address == null || address.url != result.url) {
      showEchoMessage(
        context,
        '正在验证服务器一致性…',
        duration: const Duration(seconds: 1),
      );
      final isValid = await ref
          .read(authRepositoryProvider)
          .verifyServerIdentity(result, library);
      if (!mounted) return;
      if (!isValid) {
        await _showVerificationFailure();
        return;
      }
    }

    final repository = ref.read(libraryRepositoryProvider);
    if (address != null) {
      await repository.updateAddress(result);
    } else {
      await repository.addAddress(result);
    }

    ref.invalidate(librariesProvider);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    ref.invalidate(activeLibraryProvider);
    ref.read(addressPoolProvider).probeAll();
  }

  Future<void> _showVerificationFailure() async {
    await showEchoBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      builder: (sheetContext) => EchoBottomSheet(
        title: '验证失败',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              '新地址似乎指向了不同的服务器或验证失败。添加的线路必须属于同一个服务器，并提供相同的音乐库内容。',
              style: context.echoTypography.body.copyWith(
                color: context.echoColors.muted,
              ),
            ),
            SizedBox(height: context.echoSpacing.lg),
            EchoButton.primary(
              label: '知道了',
              expand: true,
              onPressed: () => Navigator.of(sheetContext).pop(),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteAddress(ServerAddress address) async {
    final confirmed = await _confirmDestructiveAction(
      title: '删除地址',
      description: '确定要删除地址“${address.label}”吗？',
      confirmLabel: '删除地址',
    );
    if (!confirmed) return;

    final activeAddress = ref.read(activeAddressProvider);
    if (activeAddress?.id == address.id) ref.invalidate(playerProvider);

    final repository = ref.read(libraryRepositoryProvider);
    await repository.deleteAddress(address.id);
    ref.invalidate(librariesProvider);
  }

  Future<void> _saveLibrary(MusicLibrary original) async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final repository = ref.read(libraryRepositoryProvider);
    final extensions = Map<String, dynamic>.from(original.extensions);
    extensions.remove('aria2');
    extensions.remove('embedService');
    final updated = original.copyWith(
      name: _nameController.text,
      extensions: extensions,
      updatedAt: DateTime.now(),
    );
    await repository.updateLibrary(updated);
    if (!mounted) return;
    showEchoMessage(context, '保存成功', kind: EchoMessageKind.success);
    context.pop();
  }

  Future<void> _confirmDelete(MusicLibrary library) async {
    final confirmed = await _confirmDestructiveAction(
      title: '删除音乐库',
      description: '确定要删除音乐库“${library.name}”吗？此操作不可恢复。',
      confirmLabel: '删除音乐库',
    );
    if (!confirmed) return;

    final repository = ref.read(libraryRepositoryProvider);
    if (library.isActive) ref.invalidate(playerProvider);

    final allLibraries = await ref.read(librariesProvider.future);
    final remaining = allLibraries
        .where((item) => item.id != library.id)
        .toList();
    await repository.deleteLibrary(library.id);
    if (!mounted) return;

    if (remaining.isEmpty) {
      await ref.read(authStateProvider.notifier).logout();
      if (mounted) context.go('/login');
      return;
    }

    final next = remaining.first;
    await repository.setActiveLibrary(next.id);
    ref.read(authStateProvider.notifier).switchLibrary(next);
    if (mounted) context.go('/home');
  }

  Future<bool> _confirmDestructiveAction({
    required String title,
    required String description,
    required String confirmLabel,
  }) async {
    final result = await showEchoBottomSheet<bool>(
      context: context,
      useRootNavigator: true,
      builder: (sheetContext) => EchoBottomSheet(
        title: title,
        subtitle: description,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            EchoButton.destructive(
              label: confirmLabel,
              expand: true,
              onPressed: () => Navigator.of(sheetContext).pop(true),
            ),
            SizedBox(height: context.echoSpacing.xs),
            EchoButton.ghost(
              label: '取消',
              expand: true,
              onPressed: () => Navigator.of(sheetContext).pop(false),
            ),
          ],
        ),
      ),
    );
    return result == true;
  }
}

class _AddressRow extends StatelessWidget {
  const _AddressRow({
    super.key,
    required this.address,
    required this.index,
    required this.onEdit,
    required this.onDelete,
  });

  final ServerAddress address;
  final int index;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final status = _AddressStatusPresentation.from(context, address.status);
    final latency = address.lastLatencyMs == null
        ? '延迟未知'
        : '延迟 ${address.lastLatencyMs}ms';
    final scale = MediaQuery.textScalerOf(context).scale(1);
    final stackActions = scale > 1.3 || MediaQuery.sizeOf(context).width < 380;

    final actions = Wrap(
      spacing: context.echoSpacing.xxs,
      runSpacing: context.echoSpacing.xxs,
      children: <Widget>[
        EchoIconButton(
          icon: AppIcons.edit,
          label: '编辑 ${address.label}',
          onPressed: onEdit,
        ),
        EchoIconButton(
          icon: AppIcons.delete,
          label: '删除 ${address.label}',
          foregroundColor: context.echoColors.error,
          onPressed: onDelete,
        ),
        ReorderableDelayedDragStartListener(
          index: index,
          child: Semantics(
            button: true,
            label: '长按拖动 ${address.label} 调整优先级',
            child: SizedBox.square(
              dimension: context.echoInteraction.minimumTouchTarget,
              child: Center(
                child: Icon(
                  AppIcons.dragHandle,
                  size: context.echoInteraction.iconSize,
                  color: context.echoColors.muted,
                ),
              ),
            ),
          ),
        ),
      ],
    );

    return Padding(
      padding: EdgeInsets.only(bottom: context.echoSpacing.xs),
      child: EchoSurface(
        level: EchoSurfaceLevel.surface,
        borderColor: context.echoColors.divider,
        padding: EdgeInsets.all(context.echoSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox.square(
                  dimension: context.echoInteraction.minimumTouchTarget,
                  child: Center(
                    child: Icon(status.icon, size: 22, color: status.color),
                  ),
                ),
                SizedBox(width: context.echoSpacing.xs),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(address.label, style: context.echoTypography.title),
                      SizedBox(height: context.echoSpacing.xxs),
                      SelectableText(
                        address.url,
                        style: context.echoTypography.body.copyWith(
                          color: context.echoColors.muted,
                        ),
                      ),
                      SizedBox(height: context.echoSpacing.xs),
                      Wrap(
                        spacing: context.echoSpacing.xs,
                        runSpacing: context.echoSpacing.xxs,
                        children: <Widget>[
                          Text(
                            status.label,
                            style: context.echoTypography.metadata.copyWith(
                              color: status.color,
                            ),
                          ),
                          Text(
                            latency,
                            style: context.echoTypography.metadata.copyWith(
                              color: context.echoColors.muted,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (!stackActions) ...<Widget>[
                  SizedBox(width: context.echoSpacing.xs),
                  actions,
                ],
              ],
            ),
            if (stackActions) ...<Widget>[
              SizedBox(height: context.echoSpacing.xs),
              Align(alignment: AlignmentDirectional.centerEnd, child: actions),
            ],
          ],
        ),
      ),
    );
  }
}

class _AddressStatusPresentation {
  const _AddressStatusPresentation({
    required this.label,
    required this.icon,
    required this.color,
  });

  final String label;
  final IconData icon;
  final Color color;

  factory _AddressStatusPresentation.from(
    BuildContext context,
    ServerAddressStatus status,
  ) {
    return switch (status) {
      ServerAddressStatus.ok => _AddressStatusPresentation(
        label: '连接正常',
        icon: AppIcons.checkCircle,
        color: context.echoColors.accent,
      ),
      ServerAddressStatus.failed => _AddressStatusPresentation(
        label: '连接失败',
        icon: AppIcons.error,
        color: context.echoColors.error,
      ),
      ServerAddressStatus.unknown => _AddressStatusPresentation(
        label: '尚未检测',
        icon: AppIcons.info,
        color: context.echoColors.muted,
      ),
    };
  }
}

class _InlineFormState extends StatelessWidget {
  const _InlineFormState({
    required this.icon,
    required this.title,
    required this.description,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final String title;
  final String description;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: context.echoSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox.square(
            dimension: context.echoInteraction.minimumTouchTarget,
            child: Center(
              child: Icon(icon, size: 24, color: context.echoColors.muted),
            ),
          ),
          SizedBox(width: context.echoSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: context.echoTypography.title),
                SizedBox(height: context.echoSpacing.xxs),
                Text(
                  description,
                  style: context.echoTypography.body.copyWith(
                    color: context.echoColors.muted,
                  ),
                ),
                SizedBox(height: context.echoSpacing.xs),
                EchoButton.secondary(
                  label: actionLabel,
                  leadingIcon: AppIcons.add,
                  onPressed: onAction,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LibraryLoadingPage extends StatelessWidget {
  const _LibraryLoadingPage({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return EchoScaffold(
      topBar: EchoTopBar.back(context: context, title: title),
      body: Center(
        child: Semantics(
          liveRegion: true,
          label: message,
          child: ExcludeSemantics(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Padding(
                padding: EdgeInsets.all(context.echoSpacing.lg),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const EchoSkeleton.circle(size: 48),
                    SizedBox(height: context.echoSpacing.md),
                    Text(
                      message,
                      textAlign: TextAlign.center,
                      style: context.echoTypography.body.copyWith(
                        color: context.echoColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

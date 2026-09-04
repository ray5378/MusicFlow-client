import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/design/music_flow_design.dart';
import '../core/network/address_pool.dart';
import '../data/models/music_library.dart';
import '../data/models/server_address.dart';
import '../l10n/generated/app_localizations.dart';
import '../providers/api_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/library_provider.dart';

/// 「切换线路」内容区页面。
///
/// 在 Windows 宽屏下由侧栏/抽屉以内容区分支导航器打开（对齐侧栏其他页面），
/// 不再使用居中/底部弹窗。
class RouteSelectionPage extends ConsumerWidget {
  const RouteSelectionPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = AppLocalizations.of(context);
    final authState = ref.watch(authStateProvider);
    final activeLibraryId = authState.currentLibrary?.id;
    final libraries = ref.watch(librariesProvider);
    final activeAddress = ref.watch(activeAddressProvider);
    final addressPool = ref.read(addressPoolProvider);

    return MusicFlowScaffold(
      topBar: MusicFlowTopBar.back(
        context: context,
        title: loc.widgets_route_selection_title,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: EdgeInsets.only(
              left: context.musicFlowSpacing.md,
              right: context.musicFlowSpacing.md,
              bottom: context.musicFlowSpacing.sm,
            ),
            child: MusicFlowButton.ghost(
              label: loc.widgets_route_redetect_latency,
              leadingIcon: AppIcons.refresh,
              expand: true,
              onPressed: () => addressPool.probeAll(),
            ),
          ),
          Expanded(
            child: libraries.when(
              data: (items) => _RouteSelectionList(
                items: items,
                activeLibraryId: activeLibraryId,
                activeAddress: activeAddress,
                addressPool: addressPool,
                onClosed: () => Navigator.of(context).pop(),
              ),
              loading: () => const Center(
                child: CircularProgressIndicator(),
              ),
              error: (error, stackTrace) => SingleChildScrollView(
                child: MusicFlowErrorState(
                  title: loc.widgets_route_error_title,
                  description: loc.widgets_route_error_desc,
                  actionLabel: loc.widgets_retry,
                  onAction: () => ref.invalidate(librariesProvider),
                  padding: const EdgeInsets.all(24),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RouteSelectionList extends StatelessWidget {
  const _RouteSelectionList({
    required this.items,
    required this.activeLibraryId,
    required this.activeAddress,
    required this.addressPool,
    required this.onClosed,
  });

  final List<MusicLibrary> items;
  final String? activeLibraryId;
  final ServerAddress? activeAddress;
  final AddressPool addressPool;
  final VoidCallback onClosed;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final fallbackLibrary =
        items.where((library) => library.id == activeLibraryId).firstOrNull ??
        items.firstOrNull;
    final poolAddresses = addressPool.addresses;
    final addresses =
        List<ServerAddress>.from(
          poolAddresses.isNotEmpty
              ? poolAddresses
              : fallbackLibrary?.addresses ?? const <ServerAddress>[],
        )..sort((first, second) => first.priority.compareTo(second.priority));

    if (addresses.isEmpty) {
      return SingleChildScrollView(
        child: MusicFlowEmptyState(
          title: loc.widgets_route_no_route_title,
          description: loc.widgets_route_no_route_desc,
          icon: AppIcons.route,
          padding: const EdgeInsets.all(24),
        ),
      );
    }

    final isAuto = !addresses.any(
      (address) => address.isLocked && address.id == activeAddress?.id,
    );
    final currentAddress = activeAddress;
    String autoModeLabel = currentAddress == null
        ? loc.widgets_route_auto_enabled
        : loc.widgets_route_auto_enabled_label(currentAddress.label);

    return ListView(
      shrinkWrap: true,
      padding: EdgeInsets.only(bottom: context.musicFlowSpacing.md),
      children: <Widget>[
        MusicFlowActionRow(
          icon: AppIcons.route,
          title: loc.widgets_route_auto_select,
          subtitle: isAuto
              ? autoModeLabel
              : loc.widgets_route_auto_select_desc,
          selected: isAuto,
          trailing: isAuto
              ? Icon(AppIcons.check, color: context.musicFlowColors.accent)
              : null,
          onPressed: () {
            addressPool.setAutoMode();
            onClosed();
          },
        ),
        Padding(
          padding: EdgeInsets.symmetric(vertical: context.musicFlowSpacing.xs),
          child: const MusicFlowDivider(),
        ),
        for (final address in addresses)
          Padding(
            padding: EdgeInsets.only(bottom: context.musicFlowSpacing.xs),
            child: _RouteAddressRow(
              address: address,
              isSelected: activeAddress?.id == address.id && address.isLocked,
              onPressed: () {
                addressPool.setManualMode(address);
                onClosed();
              },
            ),
          ),
      ],
    );
  }
}

class _RouteAddressRow extends StatelessWidget {
  const _RouteAddressRow({
    required this.address,
    required this.isSelected,
    required this.onPressed,
  });

  final ServerAddress address;
  final bool isSelected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final statusLabel = switch (address.status) {
      ServerAddressStatus.ok => loc.widgets_connection_ok,
      ServerAddressStatus.failed => loc.widgets_connection_failed,
      ServerAddressStatus.unknown => loc.widgets_connection_pending,
    };
    final statusIcon = switch (address.status) {
      ServerAddressStatus.ok => AppIcons.checkCircle,
      ServerAddressStatus.failed => AppIcons.error,
      ServerAddressStatus.unknown => AppIcons.help,
    };
    final statusColor = switch (address.status) {
      ServerAddressStatus.ok => context.musicFlowColors.accent,
      ServerAddressStatus.failed => context.musicFlowColors.error,
      ServerAddressStatus.unknown => context.musicFlowColors.muted,
    };
    final latency =
        address.lastLatencyMs == null
            ? loc.widgets_route_latency_unknown
            : '${address.lastLatencyMs}ms';
    final delayLabel = loc.widgets_route_latency_label(latency);

    return MusicFlowActionRow(
      icon: AppIcons.signalTower,
      title: address.label,
      subtitle: '${address.url}\n$statusLabel · $delayLabel',
      selected: isSelected,
      trailing: Semantics(
        label: statusLabel,
        child: Icon(
          isSelected ? AppIcons.check : statusIcon,
          size: 20,
          color: isSelected ? context.musicFlowColors.accent : statusColor,
        ),
      ),
      onPressed: onPressed,
    );
  }
}
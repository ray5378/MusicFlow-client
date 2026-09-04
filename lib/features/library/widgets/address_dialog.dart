import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../../core/design/music_flow_design.dart';
import '../../../core/utils/server_url_security.dart';
import '../../../data/models/server_address.dart';
import '../../../l10n/generated/app_localizations.dart';

class AddressDialog extends StatefulWidget {
  const AddressDialog({
    super.key,
    required this.libraryId,
    this.initialAddress,
  });

  final String libraryId;
  final ServerAddress? initialAddress;

  @override
  State<AddressDialog> createState() => _AddressDialogState();
}

class _AddressDialogState extends State<AddressDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _labelController;
  late final TextEditingController _urlController;

  bool get _showsHttpWarning => isInsecureHttpUrl(_urlController.text);

  @override
  void initState() {
    super.initState();
    _labelController = TextEditingController(
      text: widget.initialAddress?.label,
    );
    _urlController = TextEditingController(text: widget.initialAddress?.url);
    _urlController.addListener(_handleUrlChanged);
  }

  @override
  void dispose() {
    _urlController.removeListener(_handleUrlChanged);
    _labelController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  void _handleUrlChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _showHttpHint() async {
    final loc = AppLocalizations.of(context);
    await showMusicFlowBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      builder: (sheetContext) => MusicFlowBottomSheet(
        title: loc.library_http_tip_title,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              loc.library_http_hint,
              style: context.musicFlowTypography.body.copyWith(
                color: context.musicFlowColors.muted,
              ),
            ),
            SizedBox(height: context.musicFlowSpacing.lg),
            MusicFlowButton.primary(
              label: loc.library_got_it,
              expand: true,
              onPressed: () => Navigator.of(sheetContext).pop(),
            ),
          ],
        ),
      ),
    );
  }

  Future<bool> _confirmHttpSave(String normalizedUrl) async {
    final loc = AppLocalizations.of(context);
    final confirmed = await showMusicFlowBottomSheet<bool>(
      context: context,
      useRootNavigator: true,
      builder: (sheetContext) => MusicFlowBottomSheet(
        title: loc.library_save_insecure_http_title,
        subtitle: normalizedUrl,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              loc.library_http_insecure_warning,
              style: context.musicFlowTypography.body.copyWith(
                color: context.musicFlowColors.muted,
              ),
            ),
            SizedBox(height: context.musicFlowSpacing.lg),
            MusicFlowButton.destructive(
              label: loc.library_save_anyway,
              expand: true,
              onPressed: () => Navigator.of(sheetContext).pop(true),
            ),
            SizedBox(height: context.musicFlowSpacing.xs),
            MusicFlowButton.ghost(
              label: loc.settings_cancel,
              expand: true,
              onPressed: () => Navigator.of(sheetContext).pop(false),
            ),
          ],
        ),
      ),
    );
    return confirmed == true;
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final isEditing = widget.initialAddress != null;
    final normalizedUrl = _urlController.text.trim();
    final requiresConfirmation =
        isInsecureHttpUrl(normalizedUrl) &&
        (!isEditing || widget.initialAddress!.url.trim() != normalizedUrl);
    if (requiresConfirmation) {
      final confirmed = await _confirmHttpSave(normalizedUrl);
      if (!confirmed || !mounted) return;
    }

    final address = ServerAddress(
      id: widget.initialAddress?.id ?? const Uuid().v4(),
      libraryId: widget.libraryId,
      label: _labelController.text.trim(),
      url: normalizedUrl,
      priority: widget.initialAddress?.priority ?? 10,
      isLocked: widget.initialAddress?.isLocked ?? false,
    );
    if (mounted) Navigator.of(context).pop(address);
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final isEditing = widget.initialAddress != null;
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;

    return MusicFlowBottomSheet(
      title: isEditing ? loc.library_edit_address : loc.library_add_address,
      subtitle: loc.library_address_subtitle,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.74,
        ),
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: EdgeInsets.only(bottom: keyboardInset),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                MusicFlowTextField(
                  controller: _labelController,
                  label: loc.library_label,
                  hintText: loc.library_label_hint,
                  textInputAction: TextInputAction.next,
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return loc.library_label_required;
                    }
                    return null;
                  },
                ),
                SizedBox(height: context.musicFlowSpacing.md),
                MusicFlowTextField(
                  controller: _urlController,
                  label: loc.library_server_address,
                  hintText: loc.library_url_hint,
                  helperText: loc.library_http_hint,
                  leadingIcon: AppIcons.router,
                  trailing: _showsHttpWarning
                      ? MusicFlowIconButton(
                          icon: AppIcons.warning,
                          label: loc.library_http_tip_title,
                          foregroundColor: context.musicFlowColors.warning,
                          onPressed: _showHttpHint,
                        )
                      : null,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _save(),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return loc.library_server_required;
                    }
                    if (!isSupportedServerUrl(value)) {
                      return loc.library_url_invalid;
                    }
                    return null;
                  },
                ),
                SizedBox(height: context.musicFlowSpacing.lg),
                MusicFlowButton.primary(
                  label: loc.library_save_address,
                  leadingIcon: AppIcons.save,
                  expand: true,
                  onPressed: _save,
                ),
                SizedBox(height: context.musicFlowSpacing.xs),
                MusicFlowButton.ghost(
                  label: loc.settings_cancel,
                  expand: true,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

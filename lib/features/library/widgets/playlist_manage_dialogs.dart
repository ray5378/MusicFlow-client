import 'package:flutter/material.dart';

import '../../../core/design/music_flow_design.dart';
import '../../../l10n/generated/app_localizations.dart';

class PlaylistFormResult {
  const PlaylistFormResult({
    required this.name,
    required this.comment,
    required this.isPublic,
  });

  final String name;
  final String comment;
  final bool isPublic;
}

Future<PlaylistFormResult?> showPlaylistFormDialog({
  required BuildContext context,
  required String title,
  required String confirmText,
  String initialName = '',
  String initialComment = '',
  bool initialPublic = false,
}) async {
  return showMusicFlowBottomSheet<PlaylistFormResult>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    builder: (sheetContext) => _PlaylistFormSheet(
      title: title,
      confirmText: confirmText,
      initialName: initialName,
      initialComment: initialComment,
      initialPublic: initialPublic,
    ),
  );
}

Future<bool> showDeletePlaylistConfirmDialog({
  required BuildContext context,
  required String playlistName,
}) async {
  final loc = AppLocalizations.of(context);
  final confirmed = await showMusicFlowBottomSheet<bool>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    builder: (sheetContext) => MusicFlowBottomSheet(
      title: loc.library_delete_playlist,
      subtitle: loc.library_delete_playlist_irreversible,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            loc.library_delete_playlist_confirm(playlistName),
            style: sheetContext.musicFlowTypography.body.copyWith(
              color: sheetContext.musicFlowColors.muted,
            ),
          ),
          SizedBox(height: sheetContext.musicFlowSpacing.lg),
          Row(
            children: <Widget>[
              Expanded(
                child: MusicFlowButton.secondary(
                  label: loc.settings_cancel,
                  onPressed: () => Navigator.of(sheetContext).pop(false),
                ),
              ),
              SizedBox(width: sheetContext.musicFlowSpacing.sm),
              Expanded(
                child: MusicFlowButton.destructive(
                  label: loc.common_delete,
                  onPressed: () => Navigator.of(sheetContext).pop(true),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  return confirmed ?? false;
}

class _PlaylistFormSheet extends StatefulWidget {
  const _PlaylistFormSheet({
    required this.title,
    required this.confirmText,
    required this.initialName,
    required this.initialComment,
    required this.initialPublic,
  });

  final String title;
  final String confirmText;
  final String initialName;
  final String initialComment;
  final bool initialPublic;

  @override
  State<_PlaylistFormSheet> createState() => _PlaylistFormSheetState();
}

class _PlaylistFormSheetState extends State<_PlaylistFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _commentController;
  late bool _isPublic;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initialName);
    _commentController = TextEditingController(text: widget.initialComment);
    _isPublic = widget.initialPublic;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _commentController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.of(context).pop(
      PlaylistFormResult(
        name: _nameController.text.trim(),
        comment: _commentController.text.trim(),
        isPublic: _isPublic,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final motion = context.musicFlowMotion;

    return AnimatedPadding(
      duration: motion.resolve(context, motion.state),
      curve: motion.easeOut,
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: MusicFlowBottomSheet(
        title: widget.title,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.72,
          ),
          child: Form(
            key: _formKey,
            child: SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  MusicFlowTextField(
                    controller: _nameController,
                    label: loc.library_playlist_name,
                    hintText: loc.library_playlist_name_hint,
                    leadingIcon: AppIcons.playlist,
                    autofocus: true,
                    textInputAction: TextInputAction.next,
                    validator: (value) => value == null || value.trim().isEmpty
                        ? loc.library_playlist_name_required
                        : null,
                    onSubmitted: (_) => FocusScope.of(context).nextFocus(),
                  ),
                  SizedBox(height: context.musicFlowSpacing.md),
                  MusicFlowTextField(
                    controller: _commentController,
                    label: loc.library_playlist_comment,
                    hintText: loc.library_playlist_comment_example,
                    leadingIcon: AppIcons.fileText,
                    minLines: 2,
                    maxLines: 4,
                    textInputAction: TextInputAction.newline,
                  ),
                  SizedBox(height: context.musicFlowSpacing.md),
                  _MusicFlowToggleRow(
                    title: loc.library_playlist_public,
                    description: _isPublic
                        ? loc.library_playlist_public_desc
                        : loc.library_playlist_private_desc,
                    value: _isPublic,
                    onChanged: (value) => setState(() => _isPublic = value),
                  ),
                  SizedBox(height: context.musicFlowSpacing.lg),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: MusicFlowButton.secondary(
                          label: loc.settings_cancel,
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ),
                      SizedBox(width: context.musicFlowSpacing.sm),
                      Expanded(
                        child: MusicFlowButton.primary(
                          label: widget.confirmText,
                          onPressed: _submit,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MusicFlowToggleRow extends StatelessWidget {
  const _MusicFlowToggleRow({
    required this.title,
    required this.description,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String description;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.musicFlowColors;
    final motion = context.musicFlowMotion;
    final loc = AppLocalizations.of(context);

    return MusicFlowPressable(
      semanticLabel: loc.library_toggle_accessibility(title, value ? loc.state_enabled : loc.state_disabled, description),
      selected: value,
      onPressed: () => onChanged(!value),
      minimumSize: const Size(double.infinity, 72),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: context.musicFlowSpacing.sm,
          vertical: context.musicFlowSpacing.xs,
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title, style: context.musicFlowTypography.title),
                  SizedBox(height: context.musicFlowSpacing.xxs),
                  Text(
                    description,
                    style: context.musicFlowTypography.body.copyWith(
                      color: colors.muted,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(width: context.musicFlowSpacing.sm),
            AnimatedContainer(
              duration: motion.resolve(context, motion.state),
              curve: motion.easeOut,
              width: 52,
              height: 30,
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: value ? colors.accent : colors.raised,
                borderRadius: context.musicFlowRadii.pill,
                border: Border.all(
                  color: value ? colors.accent : colors.controlBoundary,
                ),
              ),
              child: AnimatedAlign(
                duration: motion.resolve(context, motion.state),
                curve: motion.easeOut,
                alignment: value
                    ? AlignmentDirectional.centerEnd
                    : AlignmentDirectional.centerStart,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: value ? colors.onAccent : colors.muted,
                    shape: BoxShape.circle,
                  ),
                  child: const SizedBox.square(dimension: 22),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

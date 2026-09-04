// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get app_title => 'MusicFlow';

  @override
  String get settings_language => 'Language';

  @override
  String get settings_language_caption =>
      'Change the language used by the app interface';

  @override
  String get language_follow_system => 'Follow system';

  @override
  String get language_follow_system_desc =>
      'Match the device language automatically; falls back to Chinese when unsupported';

  @override
  String get language_zh => 'Chinese';

  @override
  String get language_zh_desc => 'Always use Simplified Chinese';

  @override
  String get language_en => 'English';

  @override
  String get language_en_desc => 'Always use the English interface';

  @override
  String get settings_about => 'About';

  @override
  String get settings_about_desc => 'MusicFlow · Built on the Subsonic API';

  @override
  String get settings_about_subtitle =>
      'A music client built on the Subsonic API.';

  @override
  String get settings_about_title => 'About MusicFlow';

  @override
  String get settings_api_key => 'API Key';

  @override
  String get settings_api_key_helper =>
      'Choosing \"Clear\" removes the Key stored on this device.';

  @override
  String get settings_api_key_hint => 'Enter your Fanart.tv API Key';

  @override
  String get settings_audio_auto_switch => 'Switch automatically by network';

  @override
  String get settings_audio_auto_switch_off_desc =>
      'Use the same quality across all networks.';

  @override
  String get settings_audio_auto_switch_on_desc =>
      'Save quality separately for Wi-Fi and mobile data.';

  @override
  String get settings_audio_current_strategy => 'Current playback strategy';

  @override
  String get settings_audio_desc_data_saver =>
      'Reduces data usage; suits unstable connections';

  @override
  String get settings_audio_desc_high =>
      'High-fidelity sound for stable networks';

  @override
  String get settings_audio_desc_original =>
      'No bitrate limit; plays the server\'s original file';

  @override
  String get settings_audio_desc_standard =>
      'A balance of sound, startup speed, and data';

  @override
  String get settings_audio_effective_quality => 'Effective quality';

  @override
  String get settings_audio_global_section => 'Global quality';

  @override
  String get settings_audio_global_section_desc =>
      'This choice applies to all networks.';

  @override
  String get settings_audio_mobile_section => 'Mobile data quality';

  @override
  String get settings_audio_mobile_section_desc =>
      'Choose between data usage, startup speed, and sound.';

  @override
  String get settings_audio_network => 'Network';

  @override
  String get settings_audio_network_mobile => 'Mobile data';

  @override
  String get settings_audio_network_none => 'No network';

  @override
  String get settings_audio_network_strategy => 'Network strategy';

  @override
  String get settings_audio_network_strategy_desc =>
      'Automatically use different bitrates on Wi-Fi vs mobile data.';

  @override
  String get settings_audio_network_wifi => 'Wi-Fi';

  @override
  String get settings_audio_quality => 'Audio quality';

  @override
  String get settings_audio_quality_desc =>
      'Choose playback bitrate by network';

  @override
  String settings_audio_status_line(String label, String value) {
    return '$label: $value';
  }

  @override
  String get settings_audio_wifi_section => 'Wi-Fi quality';

  @override
  String get settings_audio_wifi_section_desc =>
      'Prioritize full fidelity while on Wi-Fi.';

  @override
  String get settings_autoplay => 'Auto-play on launch';

  @override
  String get settings_autoplay_desc =>
      'Restore and resume the last local queue and progress on launch.';

  @override
  String get settings_auth_password => 'Password';

  @override
  String get settings_auth_type => 'Auth method';

  @override
  String get settings_cancel => 'Cancel';

  @override
  String get settings_check_update => 'Check for updates';

  @override
  String get settings_check_update_checking_semantics =>
      'Checking for updates; connecting to GitHub Releases';

  @override
  String get settings_check_update_desc =>
      'Check for the latest version on GitHub Releases';

  @override
  String get settings_clear => 'Clear';

  @override
  String get settings_configure => 'Configure';

  @override
  String get settings_configure_fanart => 'Configure Fanart.tv';

  @override
  String get settings_configure_fanart_subtitle =>
      'Fanart.tv HD covers require a separate API Key.';

  @override
  String get settings_crossfade => 'Crossfade';

  @override
  String get settings_crossfade_desc =>
      'Set the fade duration between adjacent tracks.';

  @override
  String get settings_crossfade_off => 'Off';

  @override
  String get settings_crossfade_off_value => 'Disable crossfade';

  @override
  String settings_crossfade_seconds(String seconds) {
    return '${seconds}s';
  }

  @override
  String settings_crossfade_smooth(String label) {
    return 'Smoothly join adjacent tracks with $label';
  }

  @override
  String get settings_crossfade_subtitle =>
      'Choose the crossfade duration for overlapping adjacent tracks.';

  @override
  String get settings_cover_api_key_configured => 'API Key: configured';

  @override
  String get settings_cover_api_key_unconfigured => 'API Key: not configured';

  @override
  String get settings_cover_priority_desc =>
      'Cover lookup tries providers top to bottom. Drag the handle to reorder.';

  @override
  String get settings_cover_provider => 'Cover providers';

  @override
  String get settings_cover_provider_custom_desc => 'Custom API address';

  @override
  String get settings_cover_provider_desc =>
      'Adjust fetch order and configure Fanart.tv';

  @override
  String get settings_cover_provider_empty_desc =>
      'No provider config found. Retry later or check your app data.';

  @override
  String get settings_cover_provider_empty_title =>
      'No cover providers available';

  @override
  String get settings_cover_provider_fanart_desc =>
      'Fanart.tv HD covers (requires API Key)';

  @override
  String get settings_cover_provider_musicbrainz_desc =>
      'MusicBrainz Cover Art Archive';

  @override
  String settings_cover_provider_page_error_desc(String error) {
    return 'Provider order, enabled state, and config are temporarily unavailable.\n$error';
  }

  @override
  String get settings_cover_provider_page_error_title =>
      'Couldn\'t load cover providers';

  @override
  String get settings_cover_provider_subsonic_desc => 'Subsonic server covers';

  @override
  String get settings_current_connection => 'Current connection';

  @override
  String get settings_current_version => 'Current version';

  @override
  String get settings_desktop_lyrics => 'Desktop lyrics';

  @override
  String get settings_desktop_lyrics_desc =>
      'Shows a draggable always-on-top lyrics overlay that doesn\'t steal focus.';

  @override
  String get settings_diagnostics_section => 'Diagnostics & updates';

  @override
  String get settings_diagnostics_section_desc =>
      'View on-device diagnostic logs or check GitHub Releases.';

  @override
  String get settings_disable => 'Disable';

  @override
  String get settings_download => 'Go to download';

  @override
  String get settings_download_confirm_body =>
      'You\'ll be taken to the browser to start the download. After it finishes, complete the update yourself: on Windows unzip and overwrite your install directory; on Android install the downloaded apk.';

  @override
  String settings_dwell_seconds(String seconds) {
    return '${seconds}s';
  }

  @override
  String get settings_edit_library => 'Edit current library';

  @override
  String get settings_edit_library_desc =>
      'Manage server addresses, auth method, and library capabilities.';

  @override
  String get settings_edit_library_empty_desc =>
      'After selecting a library you can edit its server and auth info.';

  @override
  String get settings_enable => 'Enable';

  @override
  String settings_info_line_semantics(String label, String value) {
    return '$label: $value';
  }

  @override
  String get settings_later => 'Remind me later';

  @override
  String get settings_latest_version => 'Latest version';

  @override
  String settings_library_count_saved(int count) {
    return '$count music libraries saved';
  }

  @override
  String get settings_library_empty => 'No music libraries to switch to';

  @override
  String get settings_library_label => 'Library';

  @override
  String get settings_library_load_failed =>
      'Failed to load the library list. Tap to retry.';

  @override
  String get settings_library_loading => 'Loading library list';

  @override
  String get settings_library_section => 'Library & server';

  @override
  String get settings_library_section_desc =>
      'View the current connection, or switch and edit saved libraries.';

  @override
  String get settings_library_single => 'Only one library is available';

  @override
  String settings_library_switch_failed(String error) {
    return 'Failed to switch library: $error';
  }

  @override
  String get settings_library_switch_subtitle =>
      'The current library\'s content and playback state will refresh after switching.';

  @override
  String settings_library_switched(String name) {
    return 'Switched to \"$name\"';
  }

  @override
  String get settings_log_auto_refresh => 'Auto refresh';

  @override
  String get settings_log_clear_cache => 'Clear buffer';

  @override
  String get settings_log_copy => 'Copy';

  @override
  String settings_log_copied(int count) {
    return 'Copied $count lines of logs';
  }

  @override
  String get settings_log_diagnostics => 'Diagnostic logs';

  @override
  String get settings_log_empty => 'No logs yet';

  @override
  String get settings_log_filter_hint =>
      'Filter by keyword, e.g. DLNA-AUTO / SSDP / trigger resume';

  @override
  String get settings_log_no_content => 'No logs to copy right now';

  @override
  String get settings_log_status_live => 'live';

  @override
  String get settings_log_status_paused => 'paused';

  @override
  String settings_log_summary(int total, int shown, String status) {
    return '$total lines total | showing $shown lines ($status)';
  }

  @override
  String get settings_logging => 'Log to file';

  @override
  String get settings_logging_desc =>
      'Disabled by default with no logs captured; when enabled all logs are recorded (up to 5000 entries).';

  @override
  String get settings_lyrics_dwell => 'Lyrics follow dwell';

  @override
  String get settings_lyrics_dwell_default =>
      'Default: resumes after 3 seconds';

  @override
  String get settings_lyrics_dwell_desc =>
      'How long after manually scrolling lyrics before resuming auto-follow.';

  @override
  String settings_lyrics_dwell_resume(String duration) {
    return 'Resume following after $duration';
  }

  @override
  String get settings_lyrics_dwell_subtitle =>
      'After you scroll and stop, waits this long before resuming \"follow current lyrics\" auto-scroll.';

  @override
  String get settings_lyrics_priority_desc =>
      'Playback tries providers top to bottom. Drag the handle to reorder.';

  @override
  String get settings_lyrics_provider => 'Lyrics providers';

  @override
  String get settings_lyrics_provider_custom_desc => 'Custom API address';

  @override
  String get settings_lyrics_provider_desc =>
      'Adjust fetch order and enabled state';

  @override
  String get settings_lyrics_provider_empty_desc =>
      'No provider config found. Retry later or check your app data.';

  @override
  String get settings_lyrics_provider_empty_title =>
      'No lyrics providers available';

  @override
  String get settings_lyrics_provider_lrclib_desc => 'Public sync lyrics API';

  @override
  String get settings_lyrics_provider_netease_desc =>
      'Netease Cloud Music lyrics';

  @override
  String settings_lyrics_provider_page_error_desc(String error) {
    return 'Provider order and enabled state are temporarily unavailable.\n$error';
  }

  @override
  String get settings_lyrics_provider_page_error_title =>
      'Couldn\'t load lyrics providers';

  @override
  String get settings_lyrics_provider_subsonic_desc =>
      'OpenSubsonic / Subsonic embedded lyrics';

  @override
  String get settings_not_connected => 'Not connected';

  @override
  String get settings_not_selected => 'Not selected';

  @override
  String get settings_not_set => 'Not set';

  @override
  String get settings_playback_section => 'Playback & appearance';

  @override
  String get settings_playback_section_desc =>
      'These choices apply to this device immediately.';

  @override
  String get settings_priority_order => 'Priority order';

  @override
  String get settings_project_home => 'Project home';

  @override
  String get settings_provider_custom => 'Custom source';

  @override
  String settings_provider_drag_semantics(String title) {
    return 'Press and drag $title to adjust priority order';
  }

  @override
  String get settings_provider_fanart => 'Fanart.tv';

  @override
  String get settings_provider_lrclib => 'LRCLIB';

  @override
  String get settings_provider_musicbrainz => 'MusicBrainz';

  @override
  String get settings_provider_netease => 'Netease Cloud Music';

  @override
  String get settings_provider_subsonic => 'Server';

  @override
  String settings_provider_toggle_semantics(String action, String title) {
    return '$action$title';
  }

  @override
  String get settings_route_auto_fallback => 'Route auto-fallback';

  @override
  String get settings_route_auto_fallback_desc =>
      'When a manual route is unavailable, automatically switch to another available route.';

  @override
  String get settings_save => 'Save';

  @override
  String get settings_selected => 'Selected';

  @override
  String get settings_server_address => 'Server address';

  @override
  String get settings_server_unconfigured => 'No server address configured';

  @override
  String get settings_status_disabled => 'Disabled';

  @override
  String get settings_status_enabled => 'Enabled';

  @override
  String get settings_switch_library => 'Switch library';

  @override
  String get settings_theme => 'Theme';

  @override
  String get settings_theme_accent => 'Accent color';

  @override
  String get settings_theme_accent_desc =>
      'Used only for primary actions, current selection, and keyboard focus. Album colors don\'t spread to ordinary pages.';

  @override
  String get settings_theme_apply => 'Apply';

  @override
  String get settings_theme_appearance => 'Appearance';

  @override
  String get settings_theme_appearance_desc =>
      'Follow the device, or fix light or dark.';

  @override
  String get settings_theme_brightness => 'Brightness';

  @override
  String settings_theme_color(String hex) {
    return 'Accent color $hex';
  }

  @override
  String get settings_theme_color_picker_subtitle =>
      'The system calibrates contrast and chroma on save.';

  @override
  String get settings_theme_color_picker_title => 'Adjust accent color';

  @override
  String settings_theme_color_selected(String hex) {
    return 'Accent color $hex, selected';
  }

  @override
  String get settings_theme_current_accent => 'Current accent color';

  @override
  String get settings_theme_dark => 'Dark';

  @override
  String get settings_theme_dark_desc =>
      'A low-brightness night listening space';

  @override
  String get settings_theme_desc => 'Light/dark mode and accent color';

  @override
  String get settings_theme_fine_tune => 'Fine-tune';

  @override
  String get settings_theme_follow_system => 'Follow system';

  @override
  String get settings_theme_follow_system_desc =>
      'Automatically match the device\'s appearance';

  @override
  String get settings_theme_hue => 'Hue';

  @override
  String get settings_theme_light => 'Light';

  @override
  String get settings_theme_light_desc => 'A bright, neutral listening space';

  @override
  String get settings_theme_mode_dark => 'Dark';

  @override
  String get settings_theme_mode_light => 'Light';

  @override
  String get settings_theme_mode_system => 'Follow system';

  @override
  String get settings_theme_reset_default => 'Reset to default theme';

  @override
  String get settings_theme_saturation => 'Saturation';

  @override
  String get settings_title => 'Settings';

  @override
  String get settings_toggle_disabled => 'Off';

  @override
  String get settings_toggle_enabled => 'On';

  @override
  String settings_toggle_semantics(
    String title,
    String state,
    String description,
  ) {
    return '$title: $state, $description';
  }

  @override
  String settings_toggle_semantics_no_desc(String title, String state) {
    return '$title: $state';
  }

  @override
  String get settings_update_assets => 'Download files';

  @override
  String get settings_update_assets_desc =>
      'Choose the installer that fits this device.';

  @override
  String settings_update_check_failed(String error) {
    return 'Failed to check for updates: $error';
  }

  @override
  String get settings_update_found => 'Update available';

  @override
  String settings_update_found_version(String version) {
    return 'Update available: $version';
  }

  @override
  String settings_update_latest(String version) {
    return 'You\'re up to date ($version)';
  }

  @override
  String get settings_update_notes => 'Release notes';

  @override
  String settings_update_package(String version) {
    return 'Update package $version';
  }

  @override
  String get settings_username => 'Username';

  @override
  String get settings_view_logs => 'View logs';

  @override
  String get settings_view_logs_desc =>
      'View and copy diagnostic logs in-app (filterable by DLNA)';

  @override
  String get widgets_retry => 'Retry';

  @override
  String get widgets_settings => 'Settings';

  @override
  String get widgets_artists => 'Artists';

  @override
  String get widgets_albums => 'Albums';

  @override
  String get widgets_songs => 'Songs';

  @override
  String get widgets_playlists => 'Playlists';

  @override
  String get widgets_favorites => 'Favorites';

  @override
  String get widgets_connection_ok => 'Connected';

  @override
  String get widgets_connection_failed => 'Connection failed';

  @override
  String get widgets_connection_pending => 'Pending';

  @override
  String get widgets_connection_disconnected => 'Not connected';

  @override
  String get widgets_drawer_library_unselected => 'Not selected';

  @override
  String get widgets_drawer_no_active_route => 'No active route';

  @override
  String get widgets_drawer_library_empty_title => 'No music libraries yet';

  @override
  String get widgets_drawer_library_empty_desc =>
      'Add a Navidrome, Subsonic, or OpenSubsonic music library to start listening.';

  @override
  String get widgets_drawer_add_library => 'Add library';

  @override
  String get widgets_drawer_server_unconfigured =>
      'No server address configured';

  @override
  String get widgets_drawer_add_new_library => 'Add new library';

  @override
  String get widgets_drawer_add_new_library_subtitle =>
      'Connect another server or another account';

  @override
  String get widgets_drawer_library_error_title => 'Couldn\'t load libraries';

  @override
  String get widgets_drawer_library_error_desc =>
      'The library list is temporarily unavailable. Retrying won\'t affect what\'s currently playing.';

  @override
  String get widgets_cover_art_album => 'Album art';

  @override
  String get widgets_cover_art_load_failed =>
      'Cover failed to load; retrying automatically';

  @override
  String widgets_cover_art_load_failed_with_label(String label) {
    return '$label, cover failed to load';
  }

  @override
  String get widgets_cover_art_loading => 'Loading cover';

  @override
  String get widgets_cover_art_none => 'No cover';

  @override
  String get widgets_home => 'Home';

  @override
  String get widgets_music_flow => 'Music Flow';

  @override
  String get widgets_music => 'Music';

  @override
  String get widgets_i_like => 'My favorites';

  @override
  String get widgets_play => 'Play';

  @override
  String get widgets_shuffle => 'Shuffle';

  @override
  String get widgets_route_selection_title => 'Switch route';

  @override
  String get widgets_route_redetect_latency => 'Re-check latency';

  @override
  String get widgets_route_error_title => 'Couldn\'t load routes';

  @override
  String get widgets_route_error_desc =>
      'Route info is temporarily unavailable. Retry, or open library settings later to check addresses.';

  @override
  String get widgets_route_no_route_title => 'No available routes';

  @override
  String get widgets_route_no_route_desc =>
      'Add at least one server address in library settings first.';

  @override
  String get widgets_route_auto_enabled => 'Currently enabled';

  @override
  String widgets_route_auto_enabled_label(String label) {
    return 'Currently enabled · $label';
  }

  @override
  String get widgets_route_auto_select => 'Auto select';

  @override
  String get widgets_route_auto_select_desc =>
      'Pick routes by availability and latency';

  @override
  String get widgets_route_latency_unknown => 'unknown';

  @override
  String widgets_route_latency_label(String value) {
    return 'Latency $value';
  }

  @override
  String get widgets_song_selected => 'Selected';

  @override
  String widgets_song_more_semantics(String title) {
    return '$title, more actions';
  }

  @override
  String widgets_song_deselect(String title) {
    return 'Deselect $title';
  }

  @override
  String widgets_song_select(String title) {
    return 'Select $title';
  }

  @override
  String get widgets_song_favorite => 'Favorite';

  @override
  String get widgets_song_preview => 'Preview';

  @override
  String widgets_song_cover_semantics(String title) {
    return '$title cover';
  }

  @override
  String get widgets_song_now_playing => 'Now playing';

  @override
  String get widgets_window_minimize => 'Minimize';

  @override
  String get widgets_window_maximize_restore => 'Maximize/Restore';

  @override
  String get widgets_window_close => 'Close';

  @override
  String get widgets_drawer_frame_semantics => 'App menu';

  @override
  String widgets_drawer_identity_semantics(
    String username,
    String libraryName,
    String status,
    String address,
  ) {
    return 'Account $username, library $libraryName, $status, $address';
  }

  @override
  String get widgets_drawer_back_app_menu => 'Back to app menu';

  @override
  String get widgets_drawer_view_libraries => 'View libraries';

  @override
  String get widgets_drawer_current_library => 'Current library';

  @override
  String widgets_drawer_edit_library(String title) {
    return 'Edit $title';
  }

  @override
  String get widgets_network_cannot_reach_server => 'Can\'t reach the server';

  @override
  String get widgets_network_recovered => 'Connection restored';

  @override
  String get widgets_network_weak_title => 'Unstable connection';

  @override
  String get widgets_network_weak_desc =>
      'Retrying available routes; loaded content and offline songs still work';

  @override
  String get widgets_network_offline_title => 'Offline';

  @override
  String get widgets_network_offline_desc =>
      'Loaded content and offline songs still work; online actions resume once connected';

  @override
  String get widgets_nav_main => 'Main navigation';

  @override
  String get widgets_nav_main_collapsed => 'Main navigation (collapsed)';

  @override
  String get widgets_nav_expand_sidebar => 'Expand sidebar';

  @override
  String get widgets_nav_collapse_sidebar => 'Collapse sidebar';

  @override
  String get discover_category_nav => 'Category navigation';

  @override
  String discover_cover_semantics(String name) {
    return '$name cover';
  }

  @override
  String get discover_error_desc_check_route =>
      'Check your network or current route and try again.';

  @override
  String get discover_error_desc_switch_route =>
      'Check your network or switch routes, then retry.';

  @override
  String get discover_explore => 'Explore';

  @override
  String get discover_for_you => 'For you';

  @override
  String get discover_import_no_valid_id =>
      'No valid id was returned after importing the playlist';

  @override
  String discover_import_playlist_failed(String msg) {
    return 'Failed to import playlist: $msg';
  }

  @override
  String get discover_local_random => 'Local random';

  @override
  String get discover_local_random_load_failed =>
      'Failed to load local random playlists';

  @override
  String get discover_music_suffix => 'Music';

  @override
  String get discover_network_failed_play_playlist =>
      'Network error; unable to play the playlist';

  @override
  String get discover_no_library_selected => 'No music library selected';

  @override
  String get discover_not_connected_library =>
      'Not connected to a music library';

  @override
  String get discover_open_app_menu => 'Open app menu';

  @override
  String get discover_platform_load_failed =>
      'Failed to load platform recommendations';

  @override
  String get discover_platform_recommend => 'Platform recommendations';

  @override
  String get discover_play_playlist => 'Play playlist';

  @override
  String discover_play_playlist_failed(String msg) {
    return 'Failed to play playlist: $msg';
  }

  @override
  String get discover_play_random_songs => 'Play random songs';

  @override
  String get discover_playlist_empty => 'This playlist has no playable songs';

  @override
  String get discover_random_songs => 'Random songs';

  @override
  String discover_recent_album_semantics(String name) {
    return 'Recently played album $name';
  }

  @override
  String get discover_recent_playlists => 'Recently updated playlists';

  @override
  String get discover_recent_playlists_load_failed =>
      'Failed to load recently updated playlists';

  @override
  String discover_recent_song_count(String count) {
    return '$count songs';
  }

  @override
  String get discover_recently_played => 'Recently played';

  @override
  String get discover_recommend_load_failed => 'Failed to load recommendations';

  @override
  String get discover_recommend_service_unavailable =>
      'Recommendation service is temporarily unavailable; check whether the platform recommendation plugin is enabled';

  @override
  String get discover_refresh_recent_playlists =>
      'Refresh recently updated playlists';

  @override
  String get discover_search => 'Search';

  @override
  String get discover_section_unavailable_playlist =>
      'Playlists are temporarily unavailable';

  @override
  String get discover_shuffle_song_label =>
      'Load another batch of random songs';

  @override
  String discover_song_actions_semantics(String title) {
    return '$title actions';
  }

  @override
  String discover_track_count(String count) {
    return '$count songs';
  }

  @override
  String get discover_unavailable_local_random =>
      'Local random playlists are temporarily unavailable';

  @override
  String get discover_unavailable_platform =>
      'Platform recommendations are temporarily unavailable';

  @override
  String get discover_unavailable_recommend =>
      'Recommendations are temporarily unavailable';

  @override
  String get search_back => 'Back';

  @override
  String get search_clear => 'Clear search';

  @override
  String get search_clear_history => 'Clear search history';

  @override
  String get search_current_library => 'Current music library';

  @override
  String search_delete_history(String term) {
    return 'Delete history for $term';
  }

  @override
  String search_group_search_failed(String section) {
    return 'Failed to search $section; pull down to retry';
  }

  @override
  String get search_history => 'Search history';

  @override
  String get search_hint => 'Search songs, playlists, artists, albums';

  @override
  String get search_hot_search => 'Hot searches';

  @override
  String search_items_count(int count) {
    return '$count items';
  }

  @override
  String get search_local_no_results => 'No local results found';

  @override
  String get search_local_results => 'Local results';

  @override
  String get search_network_results => 'Web-wide results';

  @override
  String get search_network_results_subtitle =>
      'Aggregated search across enabled plugins; cards carry the plugin · platform label';

  @override
  String get search_scope_overlay => 'Search scope overlay';

  @override
  String search_search_term_semantics(String term) {
    return 'Search $term';
  }

  @override
  String search_showing_results(String query) {
    return 'Showing results for \"$query\"';
  }

  @override
  String search_song_count(String count) {
    return '$count songs';
  }

  @override
  String get discover_music_flow_title => 'Music Flow';

  @override
  String get discover_category_favorites => 'Favorites';

  @override
  String get discover_category_playlists => 'Playlists';

  @override
  String get discover_category_songs => 'Songs';

  @override
  String get discover_category_artists => 'Artists';

  @override
  String get discover_category_albums => 'Albums';
}

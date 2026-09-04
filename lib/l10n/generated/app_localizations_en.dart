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

  @override
  String get action_collapse => 'Collapse';

  @override
  String get action_show_all => 'Show all';

  @override
  String get common_delete => 'Delete';

  @override
  String get common_remove => 'Remove';

  @override
  String get common_save => 'Save';

  @override
  String get library_add_address => 'Add address';

  @override
  String get library_add_to_library => 'Add to library';

  @override
  String get library_add_to_playlist => 'Add to playlist';

  @override
  String get library_add_to_queue => 'Add to queue';

  @override
  String library_added_to_playlist(String name, String playlist) {
    return 'Added “$name” to playlist “$playlist”';
  }

  @override
  String library_added_to_queue(String count) {
    return 'Added $count songs to the queue';
  }

  @override
  String get library_address_subtitle => 'Server address';

  @override
  String get library_album_actions => 'Album actions';

  @override
  String library_album_count(String count) {
    return '$count albums';
  }

  @override
  String library_album_count_semantics(String name, String count) {
    return '$name, $count songs';
  }

  @override
  String library_album_cover(String name) {
    return '$name cover';
  }

  @override
  String get library_album_load_failed => 'Album load failed';

  @override
  String get library_album_load_failed_desc =>
      'Please check your network or server status and try again.';

  @override
  String library_album_metadata_semantics(String name, String metadata) {
    return '$name, $metadata';
  }

  @override
  String get library_album_no_songs => 'This album has no songs';

  @override
  String get library_album_no_tracks => 'No tracks';

  @override
  String get library_album_not_found => 'Album not found';

  @override
  String get library_album_not_found_desc =>
      'The album does not exist or has been deleted.';

  @override
  String library_album_semantics(String name) {
    return '$name';
  }

  @override
  String get library_album_title => 'Album';

  @override
  String get library_albums => 'Albums';

  @override
  String get library_all_albums => 'All albums';

  @override
  String get library_all_artists => 'All artists';

  @override
  String get library_all_playlists => 'All playlists';

  @override
  String get library_all_songs => 'All songs';

  @override
  String library_artist_counts(String songCount, String albumCount) {
    return '$songCount songs · $albumCount albums';
  }

  @override
  String library_artist_image_semantics(String name) {
    return '$name avatar';
  }

  @override
  String get library_artist_load_failed => 'Artist load failed';

  @override
  String get library_artist_load_failed_desc =>
      'Please check your network or server status and try again.';

  @override
  String get library_artist_no_albums => 'No albums for this artist';

  @override
  String get library_artist_no_songs => 'No songs for this artist';

  @override
  String get library_artist_not_found => 'Artist not found';

  @override
  String get library_artist_not_found_desc =>
      'The artist does not exist or has been deleted.';

  @override
  String library_artist_photo(String name) {
    return '$name photo';
  }

  @override
  String library_artist_semantics(String name) {
    return '$name artist';
  }

  @override
  String get library_artist_song_source => 'Song source';

  @override
  String get library_artist_song_source_desc =>
      'Shows the source information of this artist’s songs.';

  @override
  String get library_artist_title => 'Artist';

  @override
  String get library_artists => 'Artists';

  @override
  String get library_create_playlist_first => 'Create a playlist first';

  @override
  String get library_delete_failed_network =>
      'Delete failed. Please check your network.';

  @override
  String get library_delete_playlist => 'Delete playlist';

  @override
  String library_delete_playlist_confirm(String name) {
    return 'Delete playlist “$name”?';
  }

  @override
  String get library_delete_playlist_irreversible =>
      'This action cannot be undone.';

  @override
  String get library_deselect_all => 'Deselect all';

  @override
  String get library_edit_add_address => 'Add server address';

  @override
  String get library_edit_add_address_short => 'Add address';

  @override
  String get library_edit_address => 'Address';

  @override
  String get library_edit_address_failed => 'Invalid address';

  @override
  String get library_edit_address_ok => 'Address is valid';

  @override
  String get library_edit_address_unknown => 'Unknown';

  @override
  String get library_edit_addresses_desc =>
      'Manage the server addresses for this library.';

  @override
  String get library_edit_addresses => 'Server addresses';

  @override
  String get library_edit_basic_info => 'Basic information';

  @override
  String get library_edit_basic_info_desc =>
      'Edit the library name and other details.';

  @override
  String get library_edit_danger_zone => 'Danger zone';

  @override
  String get library_edit_danger_zone_desc =>
      'Deleting a library removes local configuration and cannot be undone.';

  @override
  String get library_edit_delete_address => 'Delete address';

  @override
  String library_edit_delete_address_confirm(String label) {
    return 'Delete address “$label”?';
  }

  @override
  String library_edit_delete_address_short(String label) {
    return 'Delete “$label”';
  }

  @override
  String get library_edit_delete_library => 'Delete library';

  @override
  String get library_edit_delete_library_action => 'Delete';

  @override
  String library_edit_delete_library_confirm(String name) {
    return 'Delete library “$name”?';
  }

  @override
  String library_edit_drag_hint(String label) {
    return 'Drag “$label” to change priority';
  }

  @override
  String library_edit_edit_address(String label) {
    return 'Edit “$label”';
  }

  @override
  String get library_edit_failed_network =>
      'Save failed. Please check your network.';

  @override
  String library_edit_latency(String ms) {
    return '$ms ms';
  }

  @override
  String get library_edit_latency_unknown => 'Latency unknown';

  @override
  String get library_edit_library => 'Edit library';

  @override
  String get library_edit_library_loading => 'Loading…';

  @override
  String get library_edit_library_name => 'Library name';

  @override
  String get library_edit_library_name_example => 'e.g. My main library';

  @override
  String get library_edit_library_updating => 'Updating…';

  @override
  String get library_edit_load_failed => 'Library load failed';

  @override
  String get library_edit_load_failed_desc =>
      'Please check your network or server status and try again.';

  @override
  String get library_edit_name_required => 'Please enter a library name';

  @override
  String get library_edit_no_addresses => 'No server addresses yet';

  @override
  String get library_edit_no_addresses_desc =>
      'Add a server address to connect to the library.';

  @override
  String get library_edit_playlist => 'Edit playlist';

  @override
  String get library_edit_probe_all => 'Test all';

  @override
  String get library_edit_save_success => 'Saved';

  @override
  String get library_edit_server_addresses => 'Server addresses';

  @override
  String get library_edit_verify_failed => 'Server verification failed';

  @override
  String get library_edit_verify_failed_desc =>
      'Cannot reach this server. Please check the address and network.';

  @override
  String get library_edit_verifying_server => 'Verifying server…';

  @override
  String get library_empty_albums => 'No albums';

  @override
  String get library_empty_albums_desc => 'There are no albums here yet.';

  @override
  String get library_empty_artists => 'No artists';

  @override
  String get library_empty_artists_desc => 'There are no artists here yet.';

  @override
  String get library_empty_playlists => 'No playlists';

  @override
  String get library_empty_playlists_desc => 'There are no playlists here yet.';

  @override
  String get library_empty_songs => 'No songs';

  @override
  String get library_empty_songs_desc => 'There are no songs here yet.';

  @override
  String get library_empty_tracks => 'No tracks';

  @override
  String get library_empty_tracks_desc => 'This library has no tracks.';

  @override
  String get library_exit_song_management => 'Exit song management';

  @override
  String get library_favorite_album => 'Favorite album';

  @override
  String get library_favorite_artist => 'Favorite artist';

  @override
  String get library_favorite_playlist => 'Favorite playlist';

  @override
  String get library_favorited_album => 'Album favorited';

  @override
  String get library_favorited_artist => 'Artist favorited';

  @override
  String library_favorited_playlist(String name) {
    return 'Favorited playlist “$name”';
  }

  @override
  String get library_got_it => 'Got it';

  @override
  String get library_http_hint => 'Use the http:// or https:// protocol';

  @override
  String get library_http_insecure_warning =>
      'This server uses an insecure HTTP connection.';

  @override
  String get library_http_tip_title => 'Insecure connection';

  @override
  String get library_label => 'Label';

  @override
  String get library_label_hint => 'Give the address an easy-to-identify label';

  @override
  String get library_label_required => 'Please enter a label';

  @override
  String get library_load_failed_retry => 'Load failed. Tap to retry';

  @override
  String get library_local_no_match_albums => 'No matching albums locally';

  @override
  String get library_local_no_match_artists => 'No matching artists locally';

  @override
  String get library_local_no_match_playlists =>
      'No matching playlists locally';

  @override
  String get library_local_no_match_songs => 'No matching songs locally';

  @override
  String get library_manage_playlist_songs => 'Manage playwright songs';

  @override
  String get library_network_add_failed =>
      'Add failed. Please check your network.';

  @override
  String get library_network_album_load_failed =>
      'Album load failed. Please check your network.';

  @override
  String get library_network_artist_load_failed =>
      'Artist load failed. Please check your network.';

  @override
  String get library_network_cached_content =>
      'Showing cached offline content.';

  @override
  String get library_network_op_failed =>
      'Operation failed. Please check your network.';

  @override
  String get library_no_albums => 'No albums';

  @override
  String get library_no_library_selected => 'No library selected';

  @override
  String get library_no_playable_songs => 'No playable songs';

  @override
  String get library_no_playlists => 'No playlists';

  @override
  String get library_no_songs => 'No songs';

  @override
  String library_operation_failed(String reason) {
    return 'Operation failed: $reason';
  }

  @override
  String get library_play_album => 'Play album';

  @override
  String get library_play_all => 'Play all';

  @override
  String get library_play_artist_top => 'Play top songs';

  @override
  String get library_play_failed_network =>
      'Playback failed. Please check your network.';

  @override
  String get library_play_songs => 'Play songs';

  @override
  String get library_playlist => 'Playlist';

  @override
  String get library_playlist_actions => 'Playlist actions';

  @override
  String get library_playlist_comment => 'Playlist comment';

  @override
  String get library_playlist_comment_example =>
      'e.g. My morning workout playlist';

  @override
  String library_playlist_count_duration(String count, String duration) {
    return '$count songs · $duration';
  }

  @override
  String library_playlist_cover(String name) {
    return '$name cover';
  }

  @override
  String library_playlist_deleted(String name) {
    return 'Deleted playlist “$name”';
  }

  @override
  String get library_playlist_empty => 'This playlist is empty';

  @override
  String get library_playlist_empty_desc =>
      'Try adding some songs to the playlist.';

  @override
  String get library_playlist_load_failed => 'Playlist load failed';

  @override
  String get library_playlist_load_failed_desc =>
      'Please check your network or server status and try again.';

  @override
  String get library_playlist_name => 'Playlist name';

  @override
  String get library_playlist_name_hint => 'Name your playlist';

  @override
  String get library_playlist_name_required => 'Please enter a playlist name';

  @override
  String get library_playlist_no_available_songs => 'No songs available to add';

  @override
  String get library_playlist_no_songs => 'This playlist has no songs';

  @override
  String get library_playlist_private_desc => 'Visible only to you';

  @override
  String get library_playlist_public_desc => 'Visible to all users';

  @override
  String get library_playlist_public => 'Public';

  @override
  String library_playlist_updated(String name) {
    return '“$name” updated';
  }

  @override
  String get library_playlist_updated_reselect =>
      'The playlist changed. Please select again';

  @override
  String get library_playlists => 'Playlists';

  @override
  String get library_playlists_unavailable => 'Playlists unavailable';

  @override
  String get library_private_playlist => 'Private playlist';

  @override
  String get library_public_playlist => 'Public playlist';

  @override
  String get library_remote_album_empty_desc =>
      'No albums in the remote library.';

  @override
  String get library_remote_album_load_failed_desc =>
      'Remote album load failed. Please check your network.';

  @override
  String get library_remote_artist_empty_desc =>
      'No artists in the remote library.';

  @override
  String get library_remote_artist_load_failed_desc =>
      'Remote artist load failed. Please check your network.';

  @override
  String get library_remote_load_failed => 'Load failed';

  @override
  String get library_remote_playlist_empty_desc =>
      'No playlists in the remote library.';

  @override
  String get library_remote_playlist_load_failed_desc =>
      'Remote playlist load failed. Please check your network.';

  @override
  String library_remove_failed(String reason) {
    return 'Failed to remove: $reason';
  }

  @override
  String get library_remove_failed_network =>
      'Remove failed. Please check your network.';

  @override
  String get library_remove_from_current_playlist =>
      'Remove from current playlist';

  @override
  String get library_remove_from_playlist => 'Remove from playlist';

  @override
  String get library_remove_no_permission =>
      'No permission to remove songs. Please check your account permissions.';

  @override
  String get library_remove_selected => 'Remove selected';

  @override
  String get library_remove_selected_semantics => 'Remove selected songs';

  @override
  String get library_remove_server_refused =>
      'The server refused the remove request.';

  @override
  String get library_remove_songs => 'Remove songs';

  @override
  String library_remove_songs_confirm(String name, String count) {
    return 'Remove $count songs from playlist “$name”?';
  }

  @override
  String get library_remove_songs_desc =>
      'The following songs will be removed from the playlist.';

  @override
  String library_removed_count(String count) {
    return 'Removed $count songs';
  }

  @override
  String library_removed_from_playlist(String title) {
    return 'Removed “$title” from the playlist';
  }

  @override
  String get library_removing => 'Removing…';

  @override
  String get library_retry_on_network => 'Tap to retry';

  @override
  String get library_save_address => 'Save address';

  @override
  String get library_save_anyway => 'Save anyway';

  @override
  String get library_save_insecure_http_title => 'Save an insecure address?';

  @override
  String get library_save_library => 'Save library';

  @override
  String get library_search_albums => 'Search albums';

  @override
  String get library_search_artists => 'Search artists';

  @override
  String get library_search_playlists => 'Search playlists';

  @override
  String get library_search_songs => 'Search songs';

  @override
  String get library_select_all => 'Select all';

  @override
  String get library_select_songs_to_remove => 'Select songs to remove';

  @override
  String library_selected_count(String count) {
    return '$count selected';
  }

  @override
  String library_selected_count_rationale(String count) {
    return '$count songs selected';
  }

  @override
  String get library_server_address => 'Server address';

  @override
  String get library_server_required => 'Please enter a server address';

  @override
  String library_song_count(String count) {
    return '$count songs';
  }

  @override
  String get library_song_sort => 'Song order';

  @override
  String library_song_sort_current(String sort) {
    return 'Current order: $sort';
  }

  @override
  String library_song_sort_option(String sort) {
    return 'Order: $sort';
  }

  @override
  String get library_songs => 'Songs';

  @override
  String library_songs_count(String count) {
    return '$count songs';
  }

  @override
  String get library_sort_sheet_subtitle => 'Choose the order of songs.';

  @override
  String library_starred_label(String label) {
    return '$label (favorites)';
  }

  @override
  String get library_starred_load_failed => 'Favorites load failed';

  @override
  String get library_starred_load_failed_desc =>
      'Please check your network or server status and try again.';

  @override
  String get library_starred_no_albums => 'No favorited albums';

  @override
  String get library_starred_no_albums_desc =>
      'Albums you favorite will show up here.';

  @override
  String get library_starred_no_artists => 'No favorited artists';

  @override
  String get library_starred_no_artists_desc =>
      'Artists you favorite will show up here.';

  @override
  String get library_starred_no_playlists => 'No favorited playlists';

  @override
  String get library_starred_no_playlists_desc =>
      'Playlists you favorite will show up here.';

  @override
  String get library_starred_no_songs => 'No favorited songs';

  @override
  String get library_starred_no_songs_desc =>
      'Songs you favorite will show up here.';

  @override
  String library_starred_playlist_cover_semantics(String name) {
    return '$name cover';
  }

  @override
  String library_starred_playlist_favorited_semantics(
    String name,
    String count,
  ) {
    return '$name, $count songs, favorited';
  }

  @override
  String library_starred_playlist_meta(String count, String duration) {
    return '$count songs · $duration';
  }

  @override
  String get library_starred_playlists_load_failed => 'Playlist load failed';

  @override
  String get library_starred_title => 'Favorites';

  @override
  String library_starred_total(String count) {
    return '$count favorites';
  }

  @override
  String library_toggle_accessibility(
    String title,
    String state,
    String description,
  ) {
    return '$title, $state, $description';
  }

  @override
  String get library_top_songs => 'Top songs';

  @override
  String library_top_songs_count(String count) {
    return '$count top songs';
  }

  @override
  String get library_top_songs_unavailable => 'Top songs unavailable';

  @override
  String library_track_count_sort(String count, String sort) {
    return '$count songs · $sort';
  }

  @override
  String get library_tracks => 'Tracks';

  @override
  String get library_unfavorite_album => 'Unfavorite album';

  @override
  String get library_unfavorite_artist => 'Unfavorite artist';

  @override
  String get library_unfavorite_playlist => 'Unfavorite playlist';

  @override
  String get library_unfavorited_album => 'Album unfavorited';

  @override
  String get library_unfavorited_artist => 'Artist unfavorited';

  @override
  String library_unfavorited_playlist(String name) {
    return 'Unfavorited playlist “$name”';
  }

  @override
  String get library_unfavorited_short => 'Unfavorited';

  @override
  String get library_unknown_artist => 'Unknown artist';

  @override
  String get library_url_hint => 'e.g. http://192.168.1.100:4533';

  @override
  String get library_url_invalid => 'Invalid address format';

  @override
  String get playlist_sort_updated_asc => 'Recently updated (ascending)';

  @override
  String get playlist_sort_updated_desc => 'Recently updated';

  @override
  String get song_sort_alphabetical_asc => 'By title (ascending)';

  @override
  String get song_sort_alphabetical_desc => 'By title (descending)';

  @override
  String get song_sort_default_order => 'Default order';

  @override
  String get song_sort_duration_asc => 'By duration (ascending)';

  @override
  String get song_sort_duration_desc => 'By duration (descending)';

  @override
  String get song_sort_recent_added => 'Recently added';

  @override
  String get song_sort_title_asc => 'By title (ascending)';

  @override
  String get song_sort_updated_asc => 'By update time (ascending)';

  @override
  String get song_sort_updated_desc => 'By update time (descending)';

  @override
  String get state_disabled => 'Off';

  @override
  String get state_enabled => 'On';

  @override
  String get player_close => 'Close player';

  @override
  String get player_empty_title => 'Nothing playing';

  @override
  String get player_empty_desc =>
      'Choose a song from the feed, search, or library to start playing.';

  @override
  String get player_collapse => 'Collapse player';

  @override
  String player_page_dots(int page, int total) {
    return 'Player page, page $page of $total';
  }

  @override
  String get player_no_lyrics_title => 'No lyrics yet';

  @override
  String get player_no_lyrics_desc =>
      'No lyrics are available for the current track.';

  @override
  String get player_lyrics_load_failed_title => 'Failed to load lyrics';

  @override
  String get player_lyrics_load_failed_desc =>
      'Playback is unaffected; you can retry now.';

  @override
  String get player_lyrics_loading => 'Loading lyrics';

  @override
  String get player_lyrics_synced_label => 'Synced lyrics';

  @override
  String get player_lyrics_label => 'Lyrics';

  @override
  String get player_lyrics_current => 'Current line';

  @override
  String player_lyrics_seek(String time) {
    return 'Jump to $time';
  }

  @override
  String get player_mode_shuffle => 'Shuffle; tap to switch to order';

  @override
  String get player_mode_loop_one => 'Repeat one; tap to switch to list loop';

  @override
  String get player_mode_order => 'Order; tap to switch to repeat one';

  @override
  String get player_mode_list => 'List loop; tap to switch to shuffle';

  @override
  String get player_previous => 'Previous';

  @override
  String get player_pause => 'Pause';

  @override
  String get player_next => 'Next';

  @override
  String get player_queue => 'Play queue';

  @override
  String get player_dlna_local => 'LAN DLNA cast';

  @override
  String player_dlna_local_casting(String device) {
    return 'LAN DLNA cast, streaming to “$device”';
  }

  @override
  String get player_unfavorite => 'Unlike';

  @override
  String get player_favorite => 'Like';

  @override
  String player_switch_current(String name) {
    return 'Switch player, current: $name';
  }

  @override
  String player_casting_to(String name) {
    return 'Streaming to “$name”';
  }

  @override
  String get player_switched_local => 'Switched to local playback';

  @override
  String get player_dlna_dialog_subtitle =>
      'The client discovers LAN devices and pushes streams locally, independent of “Switch player” (server-side casting).';

  @override
  String get player_progress => 'Playback progress';

  @override
  String player_progress_percent(int percent) {
    return 'Playback progress $percent%';
  }

  @override
  String get player_playlist_label => 'Current play queue';

  @override
  String get player_playing_state => 'Playing';

  @override
  String get player_paused_state => 'Paused';

  @override
  String get player_not_playing => 'Not playing';

  @override
  String player_mini_semantic(String title, String subtitle) {
    return 'Mini player, $title$subtitle';
  }

  @override
  String get player_seek_forward => 'Seek forward 10s';

  @override
  String get player_seek_backward => 'Seek backward 10s';

  @override
  String get player_choose_song_prompt => 'Choose a song to start playing';

  @override
  String get player_volume_inc => 'Increase volume';

  @override
  String get player_volume_dec => 'Decrease volume';

  @override
  String player_volume_percent(int percent) {
    return 'Volume $percent%';
  }

  @override
  String get player_select_source_title => 'Select player';

  @override
  String get player_select_source_subtitle =>
      'Switching player only changes the control target and won\'t stop other players.';

  @override
  String get player_source_local_title => 'Play on this device';

  @override
  String get player_source_local_desc => 'Use this device\'s speakers';

  @override
  String get player_source_casting => 'Currently casting';

  @override
  String get player_source_offline => 'Device offline, polling paused';

  @override
  String get player_stop_cast => 'Stop casting';

  @override
  String player_stop_cast_subtitle(String name) {
    return 'Stop “$name” playback and clear control';
  }

  @override
  String player_cast_failed(String name) {
    return 'Failed to switch to “$name”; check if the device is online';
  }

  @override
  String get player_loading_peers => 'Fetching available players…';

  @override
  String get player_no_other_players => 'No other players found.';

  @override
  String get player_refresh_players => 'Refresh player list';

  @override
  String get player_stopped_cast => 'Stopped casting';

  @override
  String player_remote_control(String name) {
    return 'Remotely controlling “$name”';
  }

  @override
  String song_cover_semantic(String title) {
    return '$title cover';
  }

  @override
  String get dlna_no_queue_to_cast => 'No play queue available to cast';

  @override
  String dlna_cast_success(String device) {
    return 'Now streaming to “$device”';
  }

  @override
  String dlna_cast_failed(String device) {
    return 'Failed to stream to “$device”; check if the device is online';
  }

  @override
  String get dlna_cast_stopped => 'Stopped LAN casting';

  @override
  String get dlna_queue_ended => 'Queue ended';

  @override
  String get dlna_stop => 'Stop LAN casting';

  @override
  String get dlna_stop_subtitle =>
      'Stop device playback and release the local cast queue';

  @override
  String get dlna_scan_devices => 'Scan for LAN DLNA devices';

  @override
  String get dlna_device_subtitle => 'Found on this LAN · direct cast';

  @override
  String get dlna_searching => 'Searching for DLNA devices on the LAN…';

  @override
  String get dlna_no_device =>
      'No DLNA devices found. Make sure your speaker/TV is on the same network, then scan again.';

  @override
  String get dlna_background_hint =>
      'To keep casting in the background and auto-advance to the next track: in system settings, set MusicFlow\'s “Battery optimization” to “Unrestricted” and “App launch management” to “Manual”, then allow everything (auto-launch / associated launch / background activity) so playback isn\'t frozen at the end of a track.';

  @override
  String get queue_title => 'Play queue';

  @override
  String queue_count(int count) {
    return '$count tracks';
  }

  @override
  String get queue_close => 'Close play queue';

  @override
  String get queue_empty => 'Queue is empty';

  @override
  String get queue_empty_desc => 'Songs you play next will appear here.';

  @override
  String get queue_clear_after => 'Clear following queue';

  @override
  String get queue_clear_after_semantic =>
      'Clear the following queue, keeping the current track';

  @override
  String get queue_remove => 'Remove from queue';

  @override
  String queue_remove_more_semantic(String song) {
    return '$song, remove from cast queue';
  }

  @override
  String queue_more_actions_semantic(String song) {
    return '$song, more actions';
  }

  @override
  String get queue_cast_title => 'Cast queue';

  @override
  String queue_cast_count(int count, String device) {
    return '$count tracks · streaming to “$device”';
  }

  @override
  String get queue_cast_offline_suffix => ' · offline';

  @override
  String get queue_cast_close => 'Close cast queue';

  @override
  String get queue_cast_empty => 'Cast queue is empty';

  @override
  String get queue_cast_empty_desc =>
      'The server cast queue is empty; add songs via the song menu.';

  @override
  String get queue_cast_clear => 'Clear and stop casting';

  @override
  String get queue_cast_clear_semantic =>
      'Clear the cast queue and stop casting';

  @override
  String get queue_device_local => 'LAN device';

  @override
  String get song_info_title => 'Song info';

  @override
  String get song_info_duration => 'Duration';

  @override
  String get song_info_genre => 'Genre';

  @override
  String get song_info_disc => 'Disc';

  @override
  String get song_info_audio_title => 'Audio info';

  @override
  String get song_info_file_type => 'File type';

  @override
  String get song_info_bit_rate => 'Bit rate';

  @override
  String get song_info_sample_rate => 'Sample rate';

  @override
  String get song_info_bit_depth => 'Bit depth';

  @override
  String get song_info_channels => 'Channels';

  @override
  String get song_info_file_title => 'File info';

  @override
  String get song_info_file_size => 'File size';

  @override
  String get song_info_path => 'Song path';

  @override
  String get song_info_actions_title => 'Actions';

  @override
  String get song_info_song_actions => 'Song actions';

  @override
  String get song_info_song_actions_desc =>
      'Play next, add to playlist, show artist and album';

  @override
  String song_info_action_row(String label, String description) {
    return '$label, $description';
  }

  @override
  String get song_info_mono => 'Mono';

  @override
  String get song_info_stereo => 'Stereo';

  @override
  String song_info_channels_count(int count) {
    return '$count channels';
  }

  @override
  String get song_option_unknown_artist => 'Unknown artist';

  @override
  String get song_option_unknown_album => 'Unknown album';

  @override
  String get song_option_enqueue => 'Add to cast queue';

  @override
  String get song_option_enqueued => 'Added to cast queue';

  @override
  String get song_option_play_next => 'Play next';

  @override
  String get song_option_play_next_added => 'Added to play next';

  @override
  String get song_option_favorite_added => 'Liked';

  @override
  String get song_option_favorite_removed => 'Unliked';

  @override
  String get song_option_operation_failed => 'Operation failed';

  @override
  String song_option_artist(String name) {
    return 'Artist: $name';
  }

  @override
  String song_option_album(String name) {
    return 'Album: $name';
  }

  @override
  String song_option_artist_copied(String name) {
    return 'Copied artist: $name';
  }

  @override
  String song_option_album_copied(String name) {
    return 'Copied album: $name';
  }

  @override
  String get song_option_title_preview => 'Preview song actions';

  @override
  String get song_option_title => 'Song actions';

  @override
  String song_option_copied_title(String title) {
    return 'Copied song title: $title';
  }

  @override
  String song_option_summary_semantic(
    String title,
    String artist,
    String album,
  ) {
    return '$title, $artist, $album, long-press to copy the title';
  }

  @override
  String get song_option_selected => 'Selected';

  @override
  String get song_option_not_available => 'Not available';

  @override
  String get song_option_playlist_load_failed => 'Failed to load playlists';

  @override
  String get song_option_no_playlists => 'No playlists yet';

  @override
  String get song_option_load_failed_desc =>
      'Please check your network or server status and try again.';

  @override
  String get song_option_create_playlist_hint =>
      'Create a playlist and you can add this song to it.';

  @override
  String song_option_added_to_playlist(String name) {
    return 'Added to playlist “$name”';
  }

  @override
  String get song_option_network_error => 'Network error, failed to add';

  @override
  String song_option_playlist_row_semantic(String name, int count) {
    return '$name, $count songs';
  }

  @override
  String song_option_song_count(int count) {
    return '$count songs';
  }
}

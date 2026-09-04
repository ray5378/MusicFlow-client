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
}

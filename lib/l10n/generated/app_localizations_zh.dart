// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get app_title => 'MusicFlow';

  @override
  String get settings_language => '界面语言';

  @override
  String get settings_language_caption => '切换应用界面使用的语言';

  @override
  String get language_follow_system => '跟随系统';

  @override
  String get language_follow_system_desc => '自动匹配设备语言，不支持时回退中文';

  @override
  String get language_zh => '中文';

  @override
  String get language_zh_desc => '始终使用简体中文';

  @override
  String get language_en => 'English';

  @override
  String get language_en_desc => '始终使用英文界面';

  @override
  String get widgets_retry => '重试';

  @override
  String get widgets_settings => '设置';

  @override
  String get widgets_artists => '艺术家';

  @override
  String get widgets_albums => '专辑';

  @override
  String get widgets_songs => '歌曲';

  @override
  String get widgets_playlists => '歌单';

  @override
  String get widgets_favorites => '喜欢';

  @override
  String get widgets_connection_ok => '连接正常';

  @override
  String get widgets_connection_failed => '连接失败';

  @override
  String get widgets_connection_pending => '等待检测';

  @override
  String get widgets_connection_disconnected => '未连接';

  @override
  String get widgets_drawer_library_unselected => '未选择';

  @override
  String get widgets_drawer_no_active_route => '没有活动线路';

  @override
  String get widgets_drawer_library_empty_title => '还没有音乐库';

  @override
  String get widgets_drawer_library_empty_desc =>
      '添加一个 Navidrome、Subsonic 或 OpenSubsonic 音乐库后即可开始聆听。';

  @override
  String get widgets_drawer_add_library => '添加音乐库';

  @override
  String get widgets_drawer_server_unconfigured => '未配置服务器地址';

  @override
  String get widgets_drawer_add_new_library => '添加新音乐库';

  @override
  String get widgets_drawer_add_new_library_subtitle => '连接另一台服务器或另一个账户';

  @override
  String get widgets_drawer_library_error_title => '无法读取音乐库';

  @override
  String get widgets_drawer_library_error_desc => '音乐库列表暂时不可用。重试不会影响当前正在播放的内容。';

  @override
  String get widgets_cover_art_album => '专辑封面';

  @override
  String get widgets_cover_art_load_failed => '封面加载失败，自动重试中';

  @override
  String widgets_cover_art_load_failed_with_label(String label) {
    return '$label，封面加载失败';
  }

  @override
  String get widgets_cover_art_loading => '封面加载中';

  @override
  String get widgets_cover_art_none => '暂无封面';

  @override
  String get widgets_home => '主页';

  @override
  String get widgets_music_flow => '音乐流';

  @override
  String get widgets_music => '音乐';

  @override
  String get widgets_i_like => '我喜欢';

  @override
  String get widgets_play => '播放';

  @override
  String get widgets_shuffle => '随机播放';

  @override
  String get widgets_route_selection_title => '切换线路';

  @override
  String get widgets_route_redetect_latency => '重新检测延迟';

  @override
  String get widgets_route_error_title => '无法读取线路';

  @override
  String get widgets_route_error_desc => '线路信息暂时不可用。请重试，或稍后打开音乐库设置检查地址。';

  @override
  String get widgets_route_no_route_title => '没有可用线路';

  @override
  String get widgets_route_no_route_desc => '请先在音乐库设置中添加至少一个服务器地址。';

  @override
  String get widgets_route_auto_enabled => '当前已开启';

  @override
  String widgets_route_auto_enabled_label(String label) {
    return '当前已开启 · $label';
  }

  @override
  String get widgets_route_auto_select => '自动选择';

  @override
  String get widgets_route_auto_select_desc => '根据可用性和延迟选择线路';

  @override
  String get widgets_route_latency_unknown => '未知';

  @override
  String widgets_route_latency_label(String value) {
    return '延迟 $value';
  }

  @override
  String get widgets_song_selected => '已选择';

  @override
  String widgets_song_more_semantics(String title) {
    return '$title，更多操作';
  }

  @override
  String widgets_song_deselect(String title) {
    return '取消选择 $title';
  }

  @override
  String widgets_song_select(String title) {
    return '选择 $title';
  }

  @override
  String get widgets_song_favorite => '已收藏';

  @override
  String get widgets_song_preview => '试听';

  @override
  String widgets_song_cover_semantics(String title) {
    return '$title 封面';
  }

  @override
  String get widgets_song_now_playing => '正在播放';

  @override
  String get widgets_window_minimize => '最小化';

  @override
  String get widgets_window_maximize_restore => '最大化/还原';

  @override
  String get widgets_window_close => '关闭';

  @override
  String get widgets_drawer_frame_semantics => '应用菜单';

  @override
  String widgets_drawer_identity_semantics(
    String username,
    String libraryName,
    String status,
    String address,
  ) {
    return '当前账户 $username，音乐库 $libraryName，$status，$address';
  }

  @override
  String get widgets_drawer_back_app_menu => '返回应用功能菜单';

  @override
  String get widgets_drawer_view_libraries => '查看音乐库';

  @override
  String get widgets_drawer_current_library => '当前音乐库';

  @override
  String widgets_drawer_edit_library(String title) {
    return '编辑 $title';
  }

  @override
  String get widgets_network_cannot_reach_server => '连接不到服务器';

  @override
  String get widgets_network_recovered => '网络已恢复';

  @override
  String get widgets_network_weak_title => '网络不稳定';

  @override
  String get widgets_network_weak_desc => '正在重试可用线路，已加载内容和离线歌曲仍可使用';

  @override
  String get widgets_network_offline_title => '当前离线';

  @override
  String get widgets_network_offline_desc => '已加载内容和离线歌曲仍可使用，在线操作将在联网后恢复';

  @override
  String get widgets_nav_main => '主导航';

  @override
  String get widgets_nav_main_collapsed => '主导航（已收起）';

  @override
  String get widgets_nav_expand_sidebar => '展开侧边栏';

  @override
  String get widgets_nav_collapse_sidebar => '收起侧边栏';
}

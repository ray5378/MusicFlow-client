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
  String get settings_about => '关于';

  @override
  String get settings_about_desc => 'MusicFlow · 基于 Subsonic API';

  @override
  String get settings_about_subtitle => '基于 Subsonic API 的音乐客户端。';

  @override
  String get settings_about_title => '关于 MusicFlow';

  @override
  String get settings_api_key => 'API Key';

  @override
  String get settings_api_key_helper => '选择“清空”会移除本机保存的 Key。';

  @override
  String get settings_api_key_hint => '输入 Fanart.tv API Key';

  @override
  String get settings_audio_auto_switch => '按网络自动切换';

  @override
  String get settings_audio_auto_switch_off_desc => '所有网络都使用同一音质。';

  @override
  String get settings_audio_auto_switch_on_desc => 'Wi-Fi 与移动数据分别保存音质。';

  @override
  String get settings_audio_current_strategy => '当前播放策略';

  @override
  String get settings_audio_desc_data_saver => '减少流量消耗，适合信号波动时使用';

  @override
  String get settings_audio_desc_high => '高保真听感，适合稳定网络';

  @override
  String get settings_audio_desc_original => '不限制码率，直接播放服务器原始文件';

  @override
  String get settings_audio_desc_standard => '兼顾听感、启动速度与流量';

  @override
  String get settings_audio_effective_quality => '生效音质';

  @override
  String get settings_audio_global_section => '全局音质';

  @override
  String get settings_audio_global_section_desc => '此选择将用于所有网络。';

  @override
  String get settings_audio_mobile_section => '移动数据音质';

  @override
  String get settings_audio_mobile_section_desc => '在流量消耗、启动速度与听感之间选择。';

  @override
  String get settings_audio_network => '网络';

  @override
  String get settings_audio_network_mobile => '移动数据';

  @override
  String get settings_audio_network_none => '无网络';

  @override
  String get settings_audio_network_strategy => '网络策略';

  @override
  String get settings_audio_network_strategy_desc => '在 Wi-Fi 与移动数据之间自动使用不同码率。';

  @override
  String get settings_audio_network_wifi => 'Wi-Fi';

  @override
  String get settings_audio_quality => '音质设置';

  @override
  String get settings_audio_quality_desc => '按网络选择播放码率';

  @override
  String settings_audio_status_line(String label, String value) {
    return '$label，$value';
  }

  @override
  String get settings_audio_wifi_section => 'Wi-Fi 音质';

  @override
  String get settings_audio_wifi_section_desc => '连接 Wi-Fi 时优先保证音乐完整度。';

  @override
  String get settings_autoplay => '打开时自动播放';

  @override
  String get settings_autoplay_desc => '启动后恢复上次本机播放队列与进度，并自动续播。';

  @override
  String get settings_auth_password => '密码';

  @override
  String get settings_auth_type => '认证方式';

  @override
  String get settings_cancel => '取消';

  @override
  String get settings_check_update => '检查更新';

  @override
  String get settings_check_update_checking_semantics =>
      '检查更新，正在连接 GitHub Releases';

  @override
  String get settings_check_update_desc => '从 GitHub Releases 检查最新版本';

  @override
  String get settings_clear => '清空';

  @override
  String get settings_configure => '配置';

  @override
  String get settings_configure_fanart => '配置 Fanart.tv';

  @override
  String get settings_configure_fanart_subtitle =>
      'Fanart.tv 高清封面需要单独的 API Key。';

  @override
  String get settings_crossfade => '切歌淡入淡出';

  @override
  String get settings_crossfade_desc => '设置相邻曲目之间的交叉衰减时长。';

  @override
  String get settings_crossfade_off => '关闭';

  @override
  String get settings_crossfade_off_value => '关闭交叉衰减';

  @override
  String settings_crossfade_seconds(String seconds) {
    return '$seconds 秒';
  }

  @override
  String settings_crossfade_smooth(String label) {
    return '用 $label 平滑衔接相邻曲目';
  }

  @override
  String get settings_crossfade_subtitle => '选择相邻曲目同时播放的交叉衰减时长。';

  @override
  String get settings_cover_api_key_configured => 'API Key：已配置';

  @override
  String get settings_cover_api_key_unconfigured => 'API Key：未配置';

  @override
  String get settings_cover_priority_desc => '查找封面时会从上到下依次尝试。按住拖动图标可调整顺序。';

  @override
  String get settings_cover_provider => '封面提供商';

  @override
  String get settings_cover_provider_custom_desc => '自定义 API 地址';

  @override
  String get settings_cover_provider_desc => '调整获取顺序并配置 Fanart.tv';

  @override
  String get settings_cover_provider_empty_desc => '提供商配置为空，请稍后重试或检查应用数据。';

  @override
  String get settings_cover_provider_empty_title => '没有可用的封面提供商';

  @override
  String get settings_cover_provider_fanart_desc =>
      'Fanart.tv 高清封面（需要 API Key）';

  @override
  String get settings_cover_provider_musicbrainz_desc =>
      'MusicBrainz Cover Art Archive';

  @override
  String settings_cover_provider_page_error_desc(String error) {
    return '提供商顺序、启用状态和配置暂时不可用。\n$error';
  }

  @override
  String get settings_cover_provider_page_error_title => '无法读取封面提供商';

  @override
  String get settings_cover_provider_subsonic_desc => 'Subsonic 服务端封面';

  @override
  String get settings_current_connection => '当前连接';

  @override
  String get settings_current_version => '当前版本';

  @override
  String get settings_desktop_lyrics => '桌面歌词';

  @override
  String get settings_desktop_lyrics_desc => '开启后，桌面显示可拖动的歌词浮窗(置顶、不抢焦点)。';

  @override
  String get settings_diagnostics_section => '诊断与更新';

  @override
  String get settings_diagnostics_section_desc =>
      '查看本机诊断日志，或检查 GitHub Releases。';

  @override
  String get settings_disable => '停用';

  @override
  String get settings_download => '前往下载';

  @override
  String get settings_download_confirm_body =>
      '将跳转到浏览器开始下载。下载完成后请自行完成更新安装：Windows 请解压 zip 覆盖到安装目录，Android 请安装下载的 apk。';

  @override
  String settings_dwell_seconds(String seconds) {
    return '$seconds 秒';
  }

  @override
  String get settings_edit_library => '编辑当前音乐库';

  @override
  String get settings_edit_library_desc => '管理服务器地址、认证方式与音乐库能力。';

  @override
  String get settings_edit_library_empty_desc => '选择音乐库后可编辑服务器与认证信息。';

  @override
  String get settings_enable => '启用';

  @override
  String settings_info_line_semantics(String label, String value) {
    return '$label，$value';
  }

  @override
  String get settings_later => '稍后再说';

  @override
  String get settings_latest_version => '最新版本';

  @override
  String settings_library_count_saved(int count) {
    return '已保存 $count 个音乐库';
  }

  @override
  String get settings_library_empty => '当前没有可切换的音乐库';

  @override
  String get settings_library_label => '音乐库';

  @override
  String get settings_library_load_failed => '音乐库列表读取失败，点击重试';

  @override
  String get settings_library_loading => '正在读取音乐库列表';

  @override
  String get settings_library_section => '音乐库与服务器';

  @override
  String get settings_library_section_desc => '查看当前连接，也可以切换或编辑已经保存的音乐库。';

  @override
  String get settings_library_single => '当前仅有一个音乐库';

  @override
  String settings_library_switch_failed(String error) {
    return '切换音乐库失败: $error';
  }

  @override
  String get settings_library_switch_subtitle => '选择后会刷新当前音乐库的内容与播放状态。';

  @override
  String settings_library_switched(String name) {
    return '已切换到“$name”';
  }

  @override
  String get settings_log_auto_refresh => '自动刷新';

  @override
  String get settings_log_clear_cache => '清空缓存';

  @override
  String get settings_log_copy => '复制';

  @override
  String settings_log_copied(int count) {
    return '已复制 $count 行日志';
  }

  @override
  String get settings_log_diagnostics => '诊断日志';

  @override
  String get settings_log_empty => '暂无日志';

  @override
  String get settings_log_filter_hint => '筛选关键字，如 DLNA-AUTO / SSDP / 触发续播';

  @override
  String get settings_log_no_content => '当前没有可复制的日志';

  @override
  String get settings_log_status_live => '实时刷新中';

  @override
  String get settings_log_status_paused => '已暂停';

  @override
  String settings_log_summary(int total, int shown, String status) {
    return '共 $total 行｜显示 $shown 行（$status）';
  }

  @override
  String get settings_logging => '记录日志';

  @override
  String get settings_logging_desc => '默认关闭不抓取任何日志；开启后记录全部日志（最多 5000 条）。';

  @override
  String get settings_lyrics_dwell => '歌词跟随停靠时长';

  @override
  String get settings_lyrics_dwell_default => '默认：停下 3 秒后恢复跟随';

  @override
  String get settings_lyrics_dwell_desc => '手动滚动歌词后，过多久恢复自动跟随当前歌词。';

  @override
  String settings_lyrics_dwell_resume(String duration) {
    return '停下 $duration 后恢复跟随';
  }

  @override
  String get settings_lyrics_dwell_subtitle => '手动滚动并停下后，等待该时长再恢复「跟随当前歌词」自动滚动。';

  @override
  String get settings_lyrics_priority_desc => '播放时会从上到下依次尝试。按住拖动图标可调整顺序。';

  @override
  String get settings_lyrics_provider => '歌词提供商';

  @override
  String get settings_lyrics_provider_custom_desc => '自定义 API 地址';

  @override
  String get settings_lyrics_provider_desc => '调整获取顺序与启用状态';

  @override
  String get settings_lyrics_provider_empty_desc => '提供商配置为空，请稍后重试或检查应用数据。';

  @override
  String get settings_lyrics_provider_empty_title => '没有可用的歌词提供商';

  @override
  String get settings_lyrics_provider_lrclib_desc => '公共同步歌词 API';

  @override
  String get settings_lyrics_provider_netease_desc => '网易云音乐歌词';

  @override
  String settings_lyrics_provider_page_error_desc(String error) {
    return '提供商顺序和启用状态暂时不可用。\n$error';
  }

  @override
  String get settings_lyrics_provider_page_error_title => '无法读取歌词提供商';

  @override
  String get settings_lyrics_provider_subsonic_desc =>
      'OpenSubsonic / Subsonic 内嵌歌词';

  @override
  String get settings_not_connected => '未连接';

  @override
  String get settings_not_selected => '未选择';

  @override
  String get settings_not_set => '未设置';

  @override
  String get settings_playback_section => '播放与外观';

  @override
  String get settings_playback_section_desc => '这些选择会立即应用到当前设备。';

  @override
  String get settings_priority_order => '优先顺序';

  @override
  String get settings_project_home => '项目主页';

  @override
  String get settings_provider_custom => '自定义源';

  @override
  String settings_provider_drag_semantics(String title) {
    return '按住并拖动$title，调整优先顺序';
  }

  @override
  String get settings_provider_fanart => 'Fanart.tv';

  @override
  String get settings_provider_lrclib => 'LRCLIB';

  @override
  String get settings_provider_musicbrainz => 'MusicBrainz';

  @override
  String get settings_provider_netease => '网易云音乐';

  @override
  String get settings_provider_subsonic => '服务端';

  @override
  String settings_provider_toggle_semantics(String action, String title) {
    return '$action$title';
  }

  @override
  String get settings_route_auto_fallback => '线路自动回退';

  @override
  String get settings_route_auto_fallback_desc => '手动线路不可用时，自动切换到其他可用线路。';

  @override
  String get settings_save => '保存';

  @override
  String get settings_selected => '已选择';

  @override
  String get settings_server_address => '服务器地址';

  @override
  String get settings_server_unconfigured => '未配置服务器地址';

  @override
  String get settings_status_disabled => '已停用';

  @override
  String get settings_status_enabled => '已启用';

  @override
  String get settings_switch_library => '切换音乐库';

  @override
  String get settings_theme => '主题设置';

  @override
  String get settings_theme_accent => '强调色';

  @override
  String get settings_theme_accent_desc => '只用于主要操作、当前选择与键盘焦点。专辑颜色不会扩散到普通页面。';

  @override
  String get settings_theme_apply => '应用';

  @override
  String get settings_theme_appearance => '外观模式';

  @override
  String get settings_theme_appearance_desc => '跟随设备，或固定使用浅色与深色界面。';

  @override
  String get settings_theme_brightness => '明度';

  @override
  String settings_theme_color(String hex) {
    return '强调色 $hex';
  }

  @override
  String get settings_theme_color_picker_subtitle => '系统会在保存时校准对比度和色度。';

  @override
  String get settings_theme_color_picker_title => '调整强调色';

  @override
  String settings_theme_color_selected(String hex) {
    return '强调色 $hex，已选择';
  }

  @override
  String get settings_theme_current_accent => '当前强调色';

  @override
  String get settings_theme_dark => '深色';

  @override
  String get settings_theme_dark_desc => '使用低亮度的夜间试听空间';

  @override
  String get settings_theme_desc => '明暗模式与主题色';

  @override
  String get settings_theme_fine_tune => '精细调整';

  @override
  String get settings_theme_follow_system => '跟随系统';

  @override
  String get settings_theme_follow_system_desc => '自动匹配设备的外观设置';

  @override
  String get settings_theme_hue => '色相';

  @override
  String get settings_theme_light => '浅色';

  @override
  String get settings_theme_light_desc => '使用明亮、中性的试听空间';

  @override
  String get settings_theme_mode_dark => '黑色';

  @override
  String get settings_theme_mode_light => '白色';

  @override
  String get settings_theme_mode_system => '跟随系统';

  @override
  String get settings_theme_reset_default => '恢复默认主题';

  @override
  String get settings_theme_saturation => '饱和度';

  @override
  String get settings_title => '设置';

  @override
  String get settings_toggle_disabled => '已关闭';

  @override
  String get settings_toggle_enabled => '已开启';

  @override
  String settings_toggle_semantics(
    String title,
    String state,
    String description,
  ) {
    return '$title，$state，$description';
  }

  @override
  String settings_toggle_semantics_no_desc(String title, String state) {
    return '$title，$state';
  }

  @override
  String get settings_update_assets => '下载文件';

  @override
  String get settings_update_assets_desc => '选择适合当前设备的安装文件。';

  @override
  String settings_update_check_failed(String error) {
    return '检查更新失败: $error';
  }

  @override
  String get settings_update_found => '发现新版本';

  @override
  String settings_update_found_version(String version) {
    return '发现新版本 $version';
  }

  @override
  String settings_update_latest(String version) {
    return '当前已是最新版本 ($version)';
  }

  @override
  String get settings_update_notes => '更新说明';

  @override
  String settings_update_package(String version) {
    return '更新包 $version';
  }

  @override
  String get settings_username => '用户名';

  @override
  String get settings_view_logs => '查看日志';

  @override
  String get settings_view_logs_desc => '应用内直接查看并复制诊断日志（可筛选 DLNA）';

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

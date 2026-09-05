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
  String get offline_cache_title => '离线缓存';

  @override
  String get offline_cache_settings_desc => '缓存歌曲/封面/歌词，断网可播放，自动轮转';

  @override
  String get offline_cache_usage => '缓存占用';

  @override
  String get offline_cache_used => '已用';

  @override
  String get offline_cache_song => '歌曲';

  @override
  String get offline_cache_lyric => '歌词';

  @override
  String get offline_cache_cover => '封面';

  @override
  String get offline_cache_playlist_cover => '歌单封面';

  @override
  String get offline_cache_clear => '清空缓存';

  @override
  String get offline_cache_cleared => '缓存已清空';

  @override
  String get offline_cache_size_section => '总容量';

  @override
  String get offline_cache_size_section_desc => '容量用满后自动轮转，按最久未使用清理';

  @override
  String get offline_cache_size_default => '默认';

  @override
  String get offline_cache_unit_mb => 'MB';

  @override
  String get offline_cache_unit_gb => 'GB';

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

  @override
  String get discover_category_nav => '分类导航';

  @override
  String discover_cover_semantics(String name) {
    return '$name 封面';
  }

  @override
  String get discover_error_desc_check_route => '请检查网络或当前线路，然后重试。';

  @override
  String get discover_error_desc_switch_route => '请检查网络或切换线路后重试。';

  @override
  String get discover_explore => '探索';

  @override
  String get discover_for_you => '为你推荐';

  @override
  String get discover_import_no_valid_id => '歌单导入后未返回有效 id';

  @override
  String discover_import_playlist_failed(String msg) {
    return '导入歌单失败：$msg';
  }

  @override
  String get discover_local_random => '本地随机';

  @override
  String get discover_local_random_load_failed => '本地随机加载失败';

  @override
  String get discover_music_suffix => '音乐';

  @override
  String get discover_network_failed_play_playlist => '网络异常，无法播放歌单';

  @override
  String get discover_no_library_selected => '未选择音乐库';

  @override
  String get discover_not_connected_library => '未连接到音乐库';

  @override
  String get discover_open_app_menu => '打开应用菜单';

  @override
  String get discover_platform_load_failed => '平台推荐加载失败';

  @override
  String get discover_platform_recommend => '平台推荐';

  @override
  String get discover_play_playlist => '播放歌单';

  @override
  String discover_play_playlist_failed(String msg) {
    return '播放歌单失败：$msg';
  }

  @override
  String get discover_play_random_songs => '播放随机歌曲';

  @override
  String get discover_playlist_empty => '歌单暂无可用歌曲';

  @override
  String get discover_random_songs => '随机歌曲';

  @override
  String discover_recent_album_semantics(String name) {
    return '最近播放专辑 $name';
  }

  @override
  String get discover_recent_playlists => '最近更新的歌单';

  @override
  String get discover_recent_playlists_load_failed => '最近更新歌单加载失败';

  @override
  String discover_recent_song_count(String count) {
    return '$count 首歌曲';
  }

  @override
  String get discover_recently_played => '最近听过';

  @override
  String get discover_recommend_load_failed => '为你推荐加载失败';

  @override
  String get discover_recommend_service_unavailable =>
      '推荐服务暂不可用，请检查平台推荐插件是否已启用';

  @override
  String get discover_refresh_recent_playlists => '刷新最近更新歌单';

  @override
  String get discover_search => '搜索';

  @override
  String get discover_section_unavailable_playlist => '歌单暂时不可用';

  @override
  String get discover_shuffle_song_label => '换一批随机歌曲';

  @override
  String discover_song_actions_semantics(String title) {
    return '$title 操作';
  }

  @override
  String discover_track_count(String count) {
    return '$count 首';
  }

  @override
  String get discover_unavailable_local_random => '本地随机暂时不可用';

  @override
  String get discover_unavailable_platform => '平台推荐暂时不可用';

  @override
  String get discover_unavailable_recommend => '为你推荐暂时不可用';

  @override
  String get search_back => '返回';

  @override
  String get search_clear => '清空搜索';

  @override
  String get search_clear_history => '清空搜索历史';

  @override
  String get search_current_library => '当前音乐库';

  @override
  String search_delete_history(String term) {
    return '删除历史 $term';
  }

  @override
  String search_group_search_failed(String section) {
    return '$section搜索失败,可下拉重试';
  }

  @override
  String get search_history => '搜索历史';

  @override
  String get search_hint => '搜索歌曲、歌单、艺术家、专辑';

  @override
  String get search_hot_search => '热门搜索';

  @override
  String search_items_count(int count) {
    return '$count 项';
  }

  @override
  String get search_local_no_results => '本地没有找到相关结果';

  @override
  String get search_local_results => '本地结果';

  @override
  String get search_network_results => '全网结果';

  @override
  String get search_network_results_subtitle => '已启用插件的合并搜索,卡片带插件·平台标签';

  @override
  String get search_scope_overlay => '搜索范围浮层';

  @override
  String search_search_term_semantics(String term) {
    return '搜索 $term';
  }

  @override
  String search_showing_results(String query) {
    return '正在显示“$query”的结果';
  }

  @override
  String search_song_count(String count) {
    return '$count 首';
  }

  @override
  String get discover_music_flow_title => '音乐流';

  @override
  String get discover_category_favorites => '喜欢';

  @override
  String get discover_category_playlists => '歌单';

  @override
  String get discover_category_songs => '歌曲';

  @override
  String get discover_category_artists => '艺术家';

  @override
  String get discover_category_albums => '专辑';

  @override
  String get action_collapse => '收起';

  @override
  String get action_show_all => '查看全部';

  @override
  String get common_delete => '删除';

  @override
  String get common_remove => '移除';

  @override
  String get common_save => '保存';

  @override
  String get library_add_address => '添加地址';

  @override
  String get library_add_to_library => '添加到音乐库';

  @override
  String get library_add_to_playlist => '添加到歌单';

  @override
  String get library_add_to_queue => '添加到播放队列';

  @override
  String library_added_to_playlist(String name, String playlist) {
    return '已添加「$name」到歌单「$playlist」';
  }

  @override
  String library_added_to_queue(String count) {
    return '已添加 $count 首到播放队列';
  }

  @override
  String get library_address_subtitle => '服务器地址';

  @override
  String get library_album_actions => '专辑操作';

  @override
  String library_album_count(String count) {
    return '$count 张专辑';
  }

  @override
  String library_album_count_semantics(String name, String count) {
    return '$name，$count 首';
  }

  @override
  String library_album_cover(String name) {
    return '$name 封面';
  }

  @override
  String get library_album_load_failed => '专辑加载失败';

  @override
  String get library_album_load_failed_desc => '请检查网络或服务器状态后重试。';

  @override
  String library_album_metadata_semantics(String name, String metadata) {
    return '$name，$metadata';
  }

  @override
  String get library_album_no_songs => '这张专辑没有歌曲';

  @override
  String get library_album_no_tracks => '暂无曲目';

  @override
  String get library_album_not_found => '未找到该专辑';

  @override
  String get library_album_not_found_desc => '该专辑不存在或已被删除。';

  @override
  String library_album_semantics(String name) {
    return '$name';
  }

  @override
  String get library_album_title => '专辑';

  @override
  String get library_albums => '专辑';

  @override
  String get library_all_albums => '全部专辑';

  @override
  String get library_all_artists => '全部歌手';

  @override
  String get library_all_playlists => '全部歌单';

  @override
  String get library_all_songs => '全部歌曲';

  @override
  String library_artist_counts(String songCount, String albumCount) {
    return '$songCount 首 · $albumCount 张专辑';
  }

  @override
  String library_artist_image_semantics(String name) {
    return '$name 头像';
  }

  @override
  String get library_artist_load_failed => '歌手加载失败';

  @override
  String get library_artist_load_failed_desc => '请检查网络或服务器状态后重试。';

  @override
  String get library_artist_no_albums => '该歌手暂无专辑';

  @override
  String get library_artist_no_songs => '该歌手暂无歌曲';

  @override
  String get library_artist_not_found => '未找到该歌手';

  @override
  String get library_artist_not_found_desc => '该歌手不存在或已被删除。';

  @override
  String library_artist_photo(String name) {
    return '$name 照片';
  }

  @override
  String library_artist_semantics(String name) {
    return '$name 歌手';
  }

  @override
  String get library_artist_song_source => '歌曲来源';

  @override
  String get library_artist_song_source_desc => '展示该歌手的歌曲来源信息。';

  @override
  String get library_artist_title => '歌手';

  @override
  String get library_artists => '歌手';

  @override
  String get library_create_playlist_first => '请先创建歌单';

  @override
  String get library_delete_failed_network => '删除失败，请检查网络。';

  @override
  String get library_delete_playlist => '删除歌单';

  @override
  String library_delete_playlist_confirm(String name) {
    return '确定删除歌单「$name」吗？';
  }

  @override
  String get library_delete_playlist_irreversible => '此操作不可撤销。';

  @override
  String get library_deselect_all => '取消全选';

  @override
  String get library_edit_add_address => '添加服务器地址';

  @override
  String get library_edit_add_address_short => '添加地址';

  @override
  String get library_edit_address => '地址';

  @override
  String get library_edit_address_failed => '地址无效';

  @override
  String get library_edit_address_ok => '地址有效';

  @override
  String get library_edit_address_unknown => '未知';

  @override
  String get library_edit_addresses_desc => '管理该音乐库的服务器地址。';

  @override
  String get library_edit_addresses => '服务器地址';

  @override
  String get library_edit_basic_info => '基本信息';

  @override
  String get library_edit_basic_info_desc => '编辑音乐库的名称等信息。';

  @override
  String get library_edit_danger_zone => '危险操作';

  @override
  String get library_edit_danger_zone_desc => '删除音乐库会移除本地配置，且不可恢复。';

  @override
  String get library_edit_delete_address => '删除地址';

  @override
  String library_edit_delete_address_confirm(String label) {
    return '确定删除地址「$label」吗？';
  }

  @override
  String library_edit_delete_address_short(String label) {
    return '删除「$label」';
  }

  @override
  String get library_edit_delete_library => '删除音乐库';

  @override
  String get library_edit_delete_library_action => '删除';

  @override
  String library_edit_delete_library_confirm(String name) {
    return '确定删除音乐库「$name」吗？';
  }

  @override
  String library_edit_drag_hint(String label) {
    return '拖动「$label」调整优先级';
  }

  @override
  String library_edit_edit_address(String label) {
    return '编辑「$label」';
  }

  @override
  String get library_edit_failed_network => '保存失败，请检查网络。';

  @override
  String library_edit_latency(String ms) {
    return '$ms ms';
  }

  @override
  String get library_edit_latency_unknown => '延迟未知';

  @override
  String get library_edit_library => '编辑音乐库';

  @override
  String get library_edit_library_loading => '加载中…';

  @override
  String get library_edit_library_name => '音乐库名称';

  @override
  String get library_edit_library_name_example => '例如：我的主音乐库';

  @override
  String get library_edit_library_updating => '更新中…';

  @override
  String get library_edit_load_failed => '音乐库加载失败';

  @override
  String get library_edit_load_failed_desc => '请检查网络或服务器状态后重试。';

  @override
  String get library_edit_name_required => '请输入音乐库名称';

  @override
  String get library_edit_no_addresses => '暂无服务器地址';

  @override
  String get library_edit_no_addresses_desc => '添加一个服务器地址以连接音乐库。';

  @override
  String get library_edit_playlist => '编辑歌单';

  @override
  String get library_edit_probe_all => '全部测试';

  @override
  String get library_edit_save_success => '已保存';

  @override
  String get library_edit_server_addresses => '服务器地址';

  @override
  String get library_edit_verify_failed => '服务器验证失败';

  @override
  String get library_edit_verify_failed_desc => '无法连接该服务器，请检查地址与网络。';

  @override
  String get library_edit_verifying_server => '正在验证服务器…';

  @override
  String get library_empty_albums => '暂无专辑';

  @override
  String get library_empty_albums_desc => '这里还没有任何专辑。';

  @override
  String get library_empty_artists => '暂无歌手';

  @override
  String get library_empty_artists_desc => '这里还没有任何歌手。';

  @override
  String get library_empty_playlists => '暂无歌单';

  @override
  String get library_empty_playlists_desc => '这里还没有任何歌单。';

  @override
  String get library_empty_songs => '暂无歌曲';

  @override
  String get library_empty_songs_desc => '这里还没有任何歌曲。';

  @override
  String get library_empty_tracks => '暂无曲目';

  @override
  String get library_empty_tracks_desc => '该音乐库暂无曲目。';

  @override
  String get library_exit_song_management => '退出歌曲管理';

  @override
  String get library_favorite_album => '收藏专辑';

  @override
  String get library_favorite_artist => '收藏歌手';

  @override
  String get library_favorite_playlist => '收藏歌单';

  @override
  String get library_favorited_album => '已收藏该专辑';

  @override
  String get library_favorited_artist => '已收藏该歌手';

  @override
  String library_favorited_playlist(String name) {
    return '已收藏歌单「$name」';
  }

  @override
  String get library_got_it => '知道了';

  @override
  String get library_http_hint => '请使用 http:// 或 https:// 协议';

  @override
  String get library_http_insecure_warning => '该服务器使用不安全的 HTTP 连接。';

  @override
  String get library_http_tip_title => '连接不安全';

  @override
  String get library_label => '标签';

  @override
  String get library_label_hint => '为地址指定一个便于识别的标签';

  @override
  String get library_label_required => '请输入标签';

  @override
  String get library_load_failed_retry => '加载失败，点击重试';

  @override
  String get library_local_no_match_albums => '本地未找到匹配的专辑';

  @override
  String get library_local_no_match_artists => '本地未找到匹配的歌手';

  @override
  String get library_local_no_match_playlists => '本地未找到匹配的歌单';

  @override
  String get library_local_no_match_songs => '本地未找到匹配的歌曲';

  @override
  String get library_manage_playlist_songs => '管理歌单歌曲';

  @override
  String get library_network_add_failed => '添加失败，请检查网络。';

  @override
  String get library_network_album_load_failed => '专辑加载失败，请检查网络。';

  @override
  String get library_network_artist_load_failed => '歌手加载失败，请检查网络。';

  @override
  String get library_network_cached_content => '当前正在使用缓存的离线内容。';

  @override
  String get library_network_op_failed => '操作失败，请检查网络。';

  @override
  String get library_no_albums => '暂无专辑';

  @override
  String get library_no_library_selected => '未选择音乐库';

  @override
  String get library_no_playable_songs => '没有可播放的歌曲';

  @override
  String get library_no_playlists => '暂无歌单';

  @override
  String get library_no_songs => '暂无歌曲';

  @override
  String library_operation_failed(String reason) {
    return '操作失败：$reason';
  }

  @override
  String get library_play_album => '播放专辑';

  @override
  String get library_play_all => '播放全部';

  @override
  String get library_play_artist_top => '播放歌手热门歌曲';

  @override
  String get library_play_failed_network => '播放失败，请检查网络。';

  @override
  String get library_play_songs => '播放歌曲';

  @override
  String get library_playlist => '歌单';

  @override
  String get library_playlist_actions => '歌单操作';

  @override
  String get library_playlist_comment => '歌单评论';

  @override
  String get library_playlist_comment_example => '例如：我的晨练歌单';

  @override
  String library_playlist_count_duration(String count, String duration) {
    return '$count 首 · $duration';
  }

  @override
  String library_playlist_cover(String name) {
    return '$name 封面';
  }

  @override
  String library_playlist_deleted(String name) {
    return '已删除歌单「$name」';
  }

  @override
  String get library_playlist_empty => '这个歌单是空的';

  @override
  String get library_playlist_empty_desc => '尝试添加一些歌曲到歌单。';

  @override
  String get library_playlist_load_failed => '歌单加载失败';

  @override
  String get library_playlist_load_failed_desc => '请检查网络或服务器状态后重试。';

  @override
  String get library_playlist_name => '歌单名称';

  @override
  String get library_playlist_name_hint => '给歌单起个名字';

  @override
  String get library_playlist_name_required => '请输入歌单名称';

  @override
  String get library_playlist_no_available_songs => '没有可添加的歌曲';

  @override
  String get library_playlist_no_songs => '该歌单暂无歌曲';

  @override
  String get library_playlist_private_desc => '仅自己可见';

  @override
  String get library_playlist_public_desc => '所有用户可见';

  @override
  String get library_playlist_public => '公开';

  @override
  String library_playlist_updated(String name) {
    return '已更新「$name」';
  }

  @override
  String get library_playlist_updated_reselect => '歌单内容已变化，请重新选择';

  @override
  String get library_playlists => '歌单';

  @override
  String get library_playlists_unavailable => '歌单暂不可用';

  @override
  String get library_private_playlist => '私有歌单';

  @override
  String get library_public_playlist => '公开歌单';

  @override
  String get library_remote_album_empty_desc => '远程音乐库暂无专辑。';

  @override
  String get library_remote_album_load_failed_desc => '远程专辑加载失败，请检查网络。';

  @override
  String get library_remote_artist_empty_desc => '远程音乐库暂无歌手。';

  @override
  String get library_remote_artist_load_failed_desc => '远程歌手加载失败，请检查网络。';

  @override
  String get library_remote_load_failed => '加载失败';

  @override
  String get library_remote_playlist_empty_desc => '远程音乐库暂无歌单。';

  @override
  String get library_remote_playlist_load_failed_desc => '远程歌单加载失败，请检查网络。';

  @override
  String library_remove_failed(String reason) {
    return '移除失败：$reason';
  }

  @override
  String get library_remove_failed_network => '移除失败，请检查网络。';

  @override
  String get library_remove_from_current_playlist => '从当前歌单移除';

  @override
  String get library_remove_from_playlist => '从歌单移除';

  @override
  String get library_remove_no_permission => '没有权限移除歌曲，请检查账户权限。';

  @override
  String get library_remove_selected => '移除所选';

  @override
  String get library_remove_selected_semantics => '移除所选歌曲';

  @override
  String get library_remove_server_refused => '服务器拒绝了移除请求。';

  @override
  String get library_remove_songs => '移除歌曲';

  @override
  String library_remove_songs_confirm(String name, String count) {
    return '将移除 $count 首歌曲，确定从歌单「$name」移除吗？';
  }

  @override
  String get library_remove_songs_desc => '已选择以下歌曲，执行后将从歌单移除。';

  @override
  String library_removed_count(String count) {
    return '已移除 $count 首';
  }

  @override
  String library_removed_from_playlist(String title) {
    return '已将「$title」移出歌单';
  }

  @override
  String get library_removing => '移除中…';

  @override
  String get library_retry_on_network => '点击重试';

  @override
  String get library_save_address => '保存地址';

  @override
  String get library_save_anyway => '仍然保存';

  @override
  String get library_save_insecure_http_title => '保存不安全的地址？';

  @override
  String get library_save_library => '保存音乐库';

  @override
  String get library_search_albums => '搜索专辑';

  @override
  String get library_search_artists => '搜索歌手';

  @override
  String get library_search_playlists => '搜索歌单';

  @override
  String get library_search_songs => '搜索歌曲';

  @override
  String get library_select_all => '全选';

  @override
  String get library_select_songs_to_remove => '选择要移除的歌曲';

  @override
  String library_selected_count(String count) {
    return '已选择 $count 项';
  }

  @override
  String library_selected_count_rationale(String count) {
    return '已选择 $count 首歌曲';
  }

  @override
  String get library_server_address => '服务器地址';

  @override
  String get library_server_required => '请输入服务器地址';

  @override
  String library_song_count(String count) {
    return '$count 首歌曲';
  }

  @override
  String get library_song_sort => '歌曲排序';

  @override
  String library_song_sort_current(String sort) {
    return '当前排序：$sort';
  }

  @override
  String library_song_sort_option(String sort) {
    return '排序：$sort';
  }

  @override
  String get library_songs => '歌曲';

  @override
  String library_songs_count(String count) {
    return '$count 首歌曲';
  }

  @override
  String get library_sort_sheet_subtitle => '选择歌曲的排列顺序。';

  @override
  String library_starred_label(String label) {
    return '$label（收藏）';
  }

  @override
  String get library_starred_load_failed => '收藏加载失败';

  @override
  String get library_starred_load_failed_desc => '请检查网络或服务器状态后重试。';

  @override
  String get library_starred_no_albums => '暂无收藏专辑';

  @override
  String get library_starred_no_albums_desc => '在专辑卡片点亮红心后，会显示在这里。';

  @override
  String get library_starred_no_artists => '暂无收藏歌手';

  @override
  String get library_starred_no_artists_desc => '在歌手卡片点亮红心后，会显示在这里。';

  @override
  String get library_starred_no_playlists => '暂无收藏歌单';

  @override
  String get library_starred_no_playlists_desc => '在歌单卡片点亮红心后，会显示在这里。';

  @override
  String get library_starred_no_songs => '暂无收藏歌曲';

  @override
  String get library_starred_no_songs_desc => '在歌曲列表点亮红心后，会显示在这里。';

  @override
  String library_starred_playlist_cover_semantics(String name) {
    return '$name 封面';
  }

  @override
  String library_starred_playlist_favorited_semantics(
    String name,
    String count,
  ) {
    return '$name，$count 首，已收藏';
  }

  @override
  String library_starred_playlist_meta(String count, String duration) {
    return '$count 首 · $duration';
  }

  @override
  String get library_starred_playlists_load_failed => '歌单加载失败';

  @override
  String get library_starred_title => '我喜欢';

  @override
  String library_starred_total(String count) {
    return '共收藏 $count 项';
  }

  @override
  String library_toggle_accessibility(
    String title,
    String state,
    String description,
  ) {
    return '$title，$state，$description';
  }

  @override
  String get library_top_songs => '热门歌曲';

  @override
  String library_top_songs_count(String count) {
    return '热门歌曲 $count 首';
  }

  @override
  String get library_top_songs_unavailable => '热门歌曲不可用';

  @override
  String library_track_count_sort(String count, String sort) {
    return '$count 首 · $sort';
  }

  @override
  String get library_tracks => '曲目';

  @override
  String get library_unfavorite_album => '取消收藏专辑';

  @override
  String get library_unfavorite_artist => '取消收藏歌手';

  @override
  String get library_unfavorite_playlist => '取消收藏歌单';

  @override
  String get library_unfavorited_album => '已取消收藏该专辑';

  @override
  String get library_unfavorited_artist => '已取消收藏该歌手';

  @override
  String library_unfavorited_playlist(String name) {
    return '已取消收藏歌单「$name」';
  }

  @override
  String get library_unfavorited_short => '已取消收藏';

  @override
  String get library_unknown_artist => '未知歌手';

  @override
  String get library_url_hint => '例如：http://192.168.1.100:4533';

  @override
  String get library_url_invalid => '地址格式无效';

  @override
  String get playlist_sort_updated_asc => '最近更新（升序）';

  @override
  String get playlist_sort_updated_desc => '最近更新';

  @override
  String get song_sort_alphabetical_asc => '按标题（升序）';

  @override
  String get song_sort_alphabetical_desc => '按标题（降序）';

  @override
  String get song_sort_default_order => '默认排序';

  @override
  String get song_sort_duration_asc => '按时长（升序）';

  @override
  String get song_sort_duration_desc => '按时长（降序）';

  @override
  String get song_sort_recent_added => '最近添加';

  @override
  String get song_sort_title_asc => '按标题（升序）';

  @override
  String get song_sort_updated_asc => '按更新时间（升序）';

  @override
  String get song_sort_updated_desc => '按更新时间（降序）';

  @override
  String get state_disabled => '已关闭';

  @override
  String get state_enabled => '已开启';

  @override
  String get player_close => '关闭播放器';

  @override
  String get player_empty_title => '暂无播放内容';

  @override
  String get player_empty_desc => '从音乐流、搜索或资料库选择一首歌曲开始播放。';

  @override
  String get player_collapse => '收起播放器';

  @override
  String player_page_dots(int page, int total) {
    return '播放器页面，第 $page 页，共 $total 页';
  }

  @override
  String get player_no_lyrics_title => '暂无歌词';

  @override
  String get player_no_lyrics_desc => '当前曲目没有可用的歌词内容。';

  @override
  String get player_lyrics_load_failed_title => '歌词加载失败';

  @override
  String get player_lyrics_load_failed_desc => '播放不受影响，可以立即重试。';

  @override
  String get player_lyrics_loading => '歌词加载中';

  @override
  String get player_lyrics_synced_label => '同步歌词';

  @override
  String get player_lyrics_label => '歌词';

  @override
  String get player_lyrics_current => '当前歌词';

  @override
  String player_lyrics_seek(String time) {
    return '跳转到 $time';
  }

  @override
  String get player_mode_shuffle => '随机播放，点击切换到顺序播放';

  @override
  String get player_mode_loop_one => '单曲循环，点击切换到列表循环';

  @override
  String get player_mode_order => '顺序播放，点击切换到单曲循环';

  @override
  String get player_mode_list => '列表循环，点击切换到随机播放';

  @override
  String get player_previous => '上一首';

  @override
  String get player_pause => '暂停';

  @override
  String get player_next => '下一首';

  @override
  String get player_queue => '播放队列';

  @override
  String get player_dlna_local => '局域网 DLNA 直投';

  @override
  String player_dlna_local_casting(String device) {
    return '局域网 DLNA 直投，正在投屏到「$device」';
  }

  @override
  String get player_unfavorite => '取消红心';

  @override
  String get player_favorite => '红心';

  @override
  String player_switch_current(String name) {
    return '切换播放器，当前：$name';
  }

  @override
  String get player_sleep_timer => '定时暂停';

  @override
  String get player_sleep_timer_dialog_title => '定时暂停';

  @override
  String get player_sleep_timer_off => '关闭定时';

  @override
  String player_sleep_timer_minutes(int count) {
    return '$count 分钟';
  }

  @override
  String player_sleep_timer_hours(int count) {
    return '$count 小时';
  }

  @override
  String get player_sleep_timer_custom => '自定义';

  @override
  String get player_sleep_timer_minutes_unit => '分钟';

  @override
  String get player_sleep_timer_finish_song_title => '播完整首歌曲再关闭';

  @override
  String get player_sleep_timer_finish_song_desc => '计时结束后，会等当前歌曲播完再停止';

  @override
  String get player_sleep_timer_start => '开始定时';

  @override
  String player_casting_to(String name) {
    return '正在投屏到「$name」';
  }

  @override
  String get player_switched_local => '已切换为本机播放';

  @override
  String get player_dlna_dialog_subtitle =>
      '客户端自扫局域网设备并本地推流，与「切换播放器」（服务端投屏）相互独立。';

  @override
  String get player_progress => '播放进度';

  @override
  String player_progress_percent(int percent) {
    return '播放进度 $percent%';
  }

  @override
  String get player_playlist_label => '当前播放列表';

  @override
  String get player_playing_state => '正在播放';

  @override
  String get player_paused_state => '已暂停';

  @override
  String get player_not_playing => '未在播放';

  @override
  String player_mini_semantic(String title, String subtitle) {
    return '迷你播放器，$title$subtitle';
  }

  @override
  String get player_seek_forward => '快进 10 秒';

  @override
  String get player_seek_backward => '后退 10 秒';

  @override
  String get player_choose_song_prompt => '选择一首歌曲开始播放';

  @override
  String get player_volume_inc => '增大音量';

  @override
  String get player_volume_dec => '减小音量';

  @override
  String player_volume_percent(int percent) {
    return '音量 $percent%';
  }

  @override
  String get player_select_source_title => '选择播放器';

  @override
  String get player_select_source_subtitle => '切换播放器仅改变当前控制目标,不会停止其他播放器。';

  @override
  String get player_source_local_title => '本机播放';

  @override
  String get player_source_local_desc => '使用此设备扬声器';

  @override
  String get player_source_casting => '当前正在投屏';

  @override
  String get player_source_offline => '设备离线,已暂停轮询';

  @override
  String get player_stop_cast => '停止投屏';

  @override
  String player_stop_cast_subtitle(String name) {
    return '停止「$name」播放并清除控制';
  }

  @override
  String player_cast_failed(String name) {
    return '切换到「$name」失败,请检查设备是否在线';
  }

  @override
  String get player_loading_peers => '正在获取可用播放器…';

  @override
  String get player_no_other_players => '未发现其他可用播放器。';

  @override
  String get player_refresh_players => '刷新播放器列表';

  @override
  String get player_stopped_cast => '已停止投屏';

  @override
  String player_remote_control(String name) {
    return '正在远控「$name」';
  }

  @override
  String song_cover_semantic(String title) {
    return '$title 封面';
  }

  @override
  String get dlna_no_queue_to_cast => '当前没有可投屏的播放队列';

  @override
  String dlna_cast_success(String device) {
    return '已投屏到「$device」';
  }

  @override
  String dlna_cast_failed(String device) {
    return '投屏到「$device」失败，请检查设备是否在线';
  }

  @override
  String get dlna_cast_stopped => '已停止局域网投屏';

  @override
  String get dlna_queue_ended => '队列已结束';

  @override
  String get dlna_stop => '停止局域网投屏';

  @override
  String get dlna_stop_subtitle => '停止设备播放并释放本地投屏队列';

  @override
  String get dlna_scan_devices => '扫描局域网 DLNA 设备';

  @override
  String get dlna_device_subtitle => '本机局域网发现 · 直投';

  @override
  String get dlna_searching => '正在搜索局域网内的 DLNA 设备…';

  @override
  String get dlna_no_device => '未发现可用 DLNA 设备。请确认与音箱/电视处于同一网络后再扫描。';

  @override
  String get dlna_background_hint =>
      '为保证后台持续投屏并自动切下一首：请在系统设置中将 MusicFlow 的「电池优化」改为「不限制」，并将「应用启动管理」改为「手动管理」后全部允许（允许自启动 / 关联启动 / 后台活动），避免曲末时因后台冻结而停播。';

  @override
  String get queue_title => '播放队列';

  @override
  String queue_count(int count) {
    return '$count 首曲目';
  }

  @override
  String get queue_close => '关闭播放队列';

  @override
  String get queue_empty => '队列为空';

  @override
  String get queue_empty_desc => '开始播放一首歌曲后，接下来的曲目会出现在这里。';

  @override
  String get queue_clear_after => '清空后续队列';

  @override
  String get queue_clear_after_semantic => '清空后续播放队列，保留当前曲目';

  @override
  String get queue_remove => '从队列移除';

  @override
  String queue_remove_more_semantic(String song) {
    return '$song，从投屏队列移除';
  }

  @override
  String queue_more_actions_semantic(String song) {
    return '$song，更多操作';
  }

  @override
  String get queue_cast_title => '投屏队列';

  @override
  String queue_cast_count(int count, String device) {
    return '$count 首曲目 · 正在投屏到「$device」';
  }

  @override
  String get queue_cast_offline_suffix => ' · 设备离线';

  @override
  String get queue_cast_close => '关闭投屏队列';

  @override
  String get queue_cast_empty => '投屏队列为空';

  @override
  String get queue_cast_empty_desc => '后端投屏队列暂无曲目,可在歌曲菜单中添加到投屏队列。';

  @override
  String get queue_cast_clear => '清空并停止投屏';

  @override
  String get queue_cast_clear_semantic => '清空投屏队列并停止投屏';

  @override
  String get queue_device_local => '局域网设备';

  @override
  String get song_info_title => '歌曲信息';

  @override
  String get song_info_duration => '时长';

  @override
  String get song_info_genre => '按流派';

  @override
  String get song_info_disc => '唱片号';

  @override
  String get song_info_audio_title => '音频信息';

  @override
  String get song_info_file_type => '文件类型';

  @override
  String get song_info_bit_rate => '码率';

  @override
  String get song_info_sample_rate => '采样率';

  @override
  String get song_info_bit_depth => '位深';

  @override
  String get song_info_channels => '声道';

  @override
  String get song_info_file_title => '文件信息';

  @override
  String get song_info_file_size => '文件大小';

  @override
  String get song_info_path => '歌曲路径';

  @override
  String get song_info_actions_title => '操作';

  @override
  String get song_info_song_actions => '歌曲操作';

  @override
  String get song_info_song_actions_desc => '下一曲播放、添加到歌单、查看歌手与专辑';

  @override
  String song_info_action_row(String label, String description) {
    return '$label，$description';
  }

  @override
  String get song_info_mono => '单声道';

  @override
  String get song_info_stereo => '立体声';

  @override
  String song_info_channels_count(int count) {
    return '$count 声道';
  }

  @override
  String get song_option_unknown_artist => '未知歌手';

  @override
  String get song_option_unknown_album => '未知专辑';

  @override
  String get song_option_enqueue => '加入投屏队列';

  @override
  String get song_option_enqueued => '已加入投屏队列';

  @override
  String get song_option_play_next => '下一曲播放';

  @override
  String get song_option_play_next_added => '已添加到下一曲';

  @override
  String get song_option_favorite_added => '已添加红心';

  @override
  String get song_option_favorite_removed => '已取消红心';

  @override
  String get song_option_operation_failed => '操作失败';

  @override
  String song_option_artist(String name) {
    return '歌手：$name';
  }

  @override
  String song_option_album(String name) {
    return '专辑：$name';
  }

  @override
  String song_option_artist_copied(String name) {
    return '已复制歌手: $name';
  }

  @override
  String song_option_album_copied(String name) {
    return '已复制专辑: $name';
  }

  @override
  String get song_option_title_preview => '试听歌曲操作';

  @override
  String get song_option_title => '歌曲操作';

  @override
  String song_option_copied_title(String title) {
    return '已复制歌曲名: $title';
  }

  @override
  String song_option_summary_semantic(
    String title,
    String artist,
    String album,
  ) {
    return '$title，$artist，$album，长按复制歌曲名';
  }

  @override
  String get song_option_selected => '已选中';

  @override
  String get song_option_not_available => '不可用';

  @override
  String get song_option_playlist_load_failed => '歌单加载失败';

  @override
  String get song_option_no_playlists => '暂无歌单';

  @override
  String get song_option_load_failed_desc => '请检查网络或服务器状态后重试。';

  @override
  String get song_option_create_playlist_hint => '创建歌单后，即可将这首歌曲加入收藏。';

  @override
  String song_option_added_to_playlist(String name) {
    return '已添加到歌单「$name」';
  }

  @override
  String get song_option_network_error => '网络异常，添加失败';

  @override
  String song_option_playlist_row_semantic(String name, int count) {
    return '$name，$count 首歌曲';
  }

  @override
  String song_option_song_count(int count) {
    return '$count 首';
  }

  @override
  String get login_connect_server => '连接到服务器';

  @override
  String get login_confirm_server_first => '先确认服务器地址';

  @override
  String get login_enter_auth => '输入认证信息';

  @override
  String get login_detecting => '正在检测…';

  @override
  String get login_logging_in => '正在登录…';

  @override
  String get login_next => '下一步';

  @override
  String get login_login => '登录';

  @override
  String get login_previous => '上一步';

  @override
  String get login_detecting_ability => '正在检测服务器能力';

  @override
  String get login_verifying_auth => '正在验证认证信息';

  @override
  String get login_cannot_connect => '无法连接到服务器，请检查地址是否正确';

  @override
  String get login_http_insecure_title => 'HTTP 连接不安全';

  @override
  String get login_http_insecure_body =>
      'HTTP 不会加密传输。密码、API Key、令牌以及媒体请求都可能被同一网络中的其他人窃听或篡改。仅当你信任当前网络和该服务器时才继续。';

  @override
  String get login_continue_anyway => '仍然继续';

  @override
  String get login_server_section => '服务器';

  @override
  String get login_server_section_desc => 'MusicFlow 会先探测服务器能力，再决定可用的认证方式。';

  @override
  String get login_server_url_hint => 'https://your-server.com';

  @override
  String get login_server_url_http_helper => '优先使用 HTTPS。只有在可信局域网中才建议使用 HTTP。';

  @override
  String get login_server_url_required => '请输入完整的 URL（包括 http:// 或 https://）';

  @override
  String get login_library_name_label => '音乐库名称（可选）';

  @override
  String get login_library_name_hint => '例如：家庭 NAS';

  @override
  String get login_library_name_helper => '不填写则自动使用服务器类型。';

  @override
  String get login_address_label => '线路名称（可选）';

  @override
  String get login_address_hint => '例如：主线路 / 家里';

  @override
  String get login_address_helper => '不填写则默认使用 Primary。';

  @override
  String get login_auth_section => '认证信息';

  @override
  String get login_auth_section_desc => '认证信息只用于连接你的音乐服务器。';

  @override
  String get login_opensubsonic_detected => '已检测到 OpenSubsonic';

  @override
  String get login_unknown_server_type => '未知服务器类型';

  @override
  String get login_username_required => '请输入用户名';

  @override
  String get login_api_key_label => 'API Key（推荐）';

  @override
  String get login_api_key_helper => '填写 API Key 后将优先使用 API Key 认证。';

  @override
  String get login_or_password => '或使用密码';

  @override
  String get login_password_required => '请输入密码';

  @override
  String login_step_semantics(String step, String total) {
    return '登录进度，第 $step 步，共 $total 步';
  }

  @override
  String get login_step_server => '服务器';

  @override
  String get login_step_auth => '认证';

  @override
  String get search_source_not_specified => '未指定来源插件';

  @override
  String search_entity_no_playable(String kind) {
    return '该$kind暂无可播放歌曲';
  }

  @override
  String search_play_failed(String error) {
    return '播放失败: $error';
  }

  @override
  String get search_import_submitted => '已提交入库任务，完成后会通知你';

  @override
  String search_import_failed(String error) {
    return '入库失败: $error';
  }

  @override
  String search_import_done(String name) {
    return '《$name》入库完成，可在音乐库查看';
  }

  @override
  String search_import_entry_failed(String name, String error) {
    return '《$name》入库失败: $error';
  }

  @override
  String search_playlist_import_submitted(String name) {
    return '《$name》入库任务已提交，完成后会通知你';
  }

  @override
  String get search_scope_all => '所有';

  @override
  String get search_scope_all_desc => '全部内容';

  @override
  String get search_scope_playlist_desc => '仅歌单';

  @override
  String get search_scope_song_desc => '即歌曲';

  @override
  String get search_scope_artist_desc => '歌手';

  @override
  String get search_network_search_failed => '全网搜索失败';

  @override
  String get search_network_no_results => '全网暂无结果';

  @override
  String get search_try_another_keyword => '换个关键词试试。';

  @override
  String get search_bar_clear => '清空搜索词';

  @override
  String get search_add_to_library => '加入库';

  @override
  String get search_scope_title => '搜索范围';

  @override
  String get search_scope_select_title => '选择搜索范围';

  @override
  String get core_back => '返回';

  @override
  String get core_close => '关闭';

  @override
  String get core_close_menu => '关闭菜单';

  @override
  String get core_close_notification => '关闭通知';

  @override
  String get core_dlna_cast_required_hint => '直投功能必须在媒体库中先添加http连接';

  @override
  String core_field_error(String message) {
    return '错误：$message';
  }

  @override
  String get core_network_error => '网络异常';

  @override
  String core_network_switched_notice(String name) {
    return '已切换线路：$name';
  }

  @override
  String get core_pull_to_refresh => '下拉刷新';

  @override
  String get core_refresh_complete => '刷新完成';

  @override
  String get core_refresh_failed => '刷新失败';

  @override
  String get core_refreshing => '正在刷新';

  @override
  String get core_release_to_refresh => '松开刷新';

  @override
  String get core_selected => '已选择';

  @override
  String get core_unknown_device => '未知设备';

  @override
  String get audio_quality_original => '原始无损';

  @override
  String get audio_quality_high => '高品质 (320kbps)';

  @override
  String get audio_quality_standard => '标准 (192kbps)';

  @override
  String get audio_quality_data_saver => '流量节省 (128kbps)';

  @override
  String get peer_self => '本机';

  @override
  String get peer_group => '群组';

  @override
  String peer_queue_total_playing(int count) {
    return '$count 首 · 播放中';
  }

  @override
  String peer_queue_total(int count) {
    return '$count 首';
  }

  @override
  String get peer_unknown => '未知';

  @override
  String duration_hours_minutes(int hours, int minutes) {
    return '$hours时$minutes分';
  }

  @override
  String duration_hours(int hours) {
    return '$hours时';
  }

  @override
  String duration_minutes(int minutes) {
    return '$minutes分';
  }

  @override
  String get import_recommend_playlist_failed => '导入推荐歌单失败';

  @override
  String get import_playlist_failed => '导入歌单失败';

  @override
  String get import_task_failed => '导入任务失败';

  @override
  String get import_task_timeout => '入库任务超时,请稍后在音乐库查看';

  @override
  String get import_failed => '导入失败';

  @override
  String get import_task_running => '导入任务进行中，请稍候';

  @override
  String get import_no_task_returned => '导入未返回任务';

  @override
  String get source_custom => '自定义源';

  @override
  String get source_server => '服务端';

  @override
  String get source_netease => '网易云音乐';

  @override
  String get unknown_audio_quality => '未知音质';

  @override
  String get unknown_song => '未知歌曲';

  @override
  String get unknown_artist => '未知歌手';

  @override
  String get unable_to_parse_preview_link => '无法解析试听链接';

  @override
  String unable_to_parse_preview_link_error(String error) {
    return '无法解析试听链接: $error';
  }

  @override
  String get provider_cast_notify_permission => '通知权限未授予，前台服务常驻可能受限 → 后台续播不可靠';

  @override
  String provider_artists_count(int count) {
    return '$count 位艺术家';
  }

  @override
  String provider_albums_count(int count) {
    return '$count 张专辑';
  }

  @override
  String provider_songs_count(int count) {
    return '$count 首歌曲';
  }

  @override
  String provider_playlists_count(int count) {
    return '$count 个歌单';
  }

  @override
  String provider_artists_total(int count) {
    return '共 $count 名艺人';
  }

  @override
  String provider_albums_total(int count) {
    return '共 $count 张专辑';
  }

  @override
  String provider_songs_total(int count) {
    return '共 $count 首歌曲';
  }

  @override
  String provider_playlists_total(int count) {
    return '共 $count 个歌单';
  }

  @override
  String get provider_network_error_album => '网络异常，专辑加载失败';

  @override
  String get provider_network_error_song => '网络异常，歌曲加载失败';

  @override
  String get provider_network_error_artist => '网络异常，歌手列表加载失败';

  @override
  String get provider_network_error_artist_detail => '网络异常，歌手详情加载失败';

  @override
  String get provider_network_error_favorites => '网络异常，收藏加载失败';

  @override
  String get provider_network_error_playlist => '网络异常，歌单加载失败';

  @override
  String get provider_network_error_no_route => '网络异常，当前无可用线路';

  @override
  String get provider_preview_link_parse_failed => '试听链接解析失败';

  @override
  String get provider_preview_play_no_route => '试听播放失败，当前无可用线路';

  @override
  String get provider_playback_all_unavailable => '当前歌单歌曲均不可播，请检查服务器连接与音频源是否可用';
}

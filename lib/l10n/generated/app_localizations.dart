import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'generated/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
  ];

  /// No description provided for @app_title.
  ///
  /// In zh, this message translates to:
  /// **'MusicFlow'**
  String get app_title;

  /// No description provided for @settings_language.
  ///
  /// In zh, this message translates to:
  /// **'界面语言'**
  String get settings_language;

  /// No description provided for @settings_language_caption.
  ///
  /// In zh, this message translates to:
  /// **'切换应用界面使用的语言'**
  String get settings_language_caption;

  /// No description provided for @language_follow_system.
  ///
  /// In zh, this message translates to:
  /// **'跟随系统'**
  String get language_follow_system;

  /// No description provided for @language_follow_system_desc.
  ///
  /// In zh, this message translates to:
  /// **'自动匹配设备语言，不支持时回退中文'**
  String get language_follow_system_desc;

  /// No description provided for @language_zh.
  ///
  /// In zh, this message translates to:
  /// **'中文'**
  String get language_zh;

  /// No description provided for @language_zh_desc.
  ///
  /// In zh, this message translates to:
  /// **'始终使用简体中文'**
  String get language_zh_desc;

  /// No description provided for @language_en.
  ///
  /// In zh, this message translates to:
  /// **'English'**
  String get language_en;

  /// No description provided for @language_en_desc.
  ///
  /// In zh, this message translates to:
  /// **'始终使用英文界面'**
  String get language_en_desc;

  /// No description provided for @settings_about.
  ///
  /// In zh, this message translates to:
  /// **'关于'**
  String get settings_about;

  /// No description provided for @settings_about_desc.
  ///
  /// In zh, this message translates to:
  /// **'MusicFlow · 基于 Subsonic API'**
  String get settings_about_desc;

  /// No description provided for @settings_about_subtitle.
  ///
  /// In zh, this message translates to:
  /// **'基于 Subsonic API 的音乐客户端。'**
  String get settings_about_subtitle;

  /// No description provided for @settings_about_title.
  ///
  /// In zh, this message translates to:
  /// **'关于 MusicFlow'**
  String get settings_about_title;

  /// No description provided for @settings_api_key.
  ///
  /// In zh, this message translates to:
  /// **'API Key'**
  String get settings_api_key;

  /// No description provided for @settings_api_key_helper.
  ///
  /// In zh, this message translates to:
  /// **'选择“清空”会移除本机保存的 Key。'**
  String get settings_api_key_helper;

  /// No description provided for @settings_api_key_hint.
  ///
  /// In zh, this message translates to:
  /// **'输入 Fanart.tv API Key'**
  String get settings_api_key_hint;

  /// No description provided for @settings_audio_auto_switch.
  ///
  /// In zh, this message translates to:
  /// **'按网络自动切换'**
  String get settings_audio_auto_switch;

  /// No description provided for @settings_audio_auto_switch_off_desc.
  ///
  /// In zh, this message translates to:
  /// **'所有网络都使用同一音质。'**
  String get settings_audio_auto_switch_off_desc;

  /// No description provided for @settings_audio_auto_switch_on_desc.
  ///
  /// In zh, this message translates to:
  /// **'Wi-Fi 与移动数据分别保存音质。'**
  String get settings_audio_auto_switch_on_desc;

  /// No description provided for @settings_audio_current_strategy.
  ///
  /// In zh, this message translates to:
  /// **'当前播放策略'**
  String get settings_audio_current_strategy;

  /// No description provided for @settings_audio_desc_data_saver.
  ///
  /// In zh, this message translates to:
  /// **'减少流量消耗，适合信号波动时使用'**
  String get settings_audio_desc_data_saver;

  /// No description provided for @settings_audio_desc_high.
  ///
  /// In zh, this message translates to:
  /// **'高保真听感，适合稳定网络'**
  String get settings_audio_desc_high;

  /// No description provided for @settings_audio_desc_original.
  ///
  /// In zh, this message translates to:
  /// **'不限制码率，直接播放服务器原始文件'**
  String get settings_audio_desc_original;

  /// No description provided for @settings_audio_desc_standard.
  ///
  /// In zh, this message translates to:
  /// **'兼顾听感、启动速度与流量'**
  String get settings_audio_desc_standard;

  /// No description provided for @settings_audio_effective_quality.
  ///
  /// In zh, this message translates to:
  /// **'生效音质'**
  String get settings_audio_effective_quality;

  /// No description provided for @settings_audio_global_section.
  ///
  /// In zh, this message translates to:
  /// **'全局音质'**
  String get settings_audio_global_section;

  /// No description provided for @settings_audio_global_section_desc.
  ///
  /// In zh, this message translates to:
  /// **'此选择将用于所有网络。'**
  String get settings_audio_global_section_desc;

  /// No description provided for @settings_audio_mobile_section.
  ///
  /// In zh, this message translates to:
  /// **'移动数据音质'**
  String get settings_audio_mobile_section;

  /// No description provided for @settings_audio_mobile_section_desc.
  ///
  /// In zh, this message translates to:
  /// **'在流量消耗、启动速度与听感之间选择。'**
  String get settings_audio_mobile_section_desc;

  /// No description provided for @settings_audio_network.
  ///
  /// In zh, this message translates to:
  /// **'网络'**
  String get settings_audio_network;

  /// No description provided for @settings_audio_network_mobile.
  ///
  /// In zh, this message translates to:
  /// **'移动数据'**
  String get settings_audio_network_mobile;

  /// No description provided for @settings_audio_network_none.
  ///
  /// In zh, this message translates to:
  /// **'无网络'**
  String get settings_audio_network_none;

  /// No description provided for @settings_audio_network_strategy.
  ///
  /// In zh, this message translates to:
  /// **'网络策略'**
  String get settings_audio_network_strategy;

  /// No description provided for @settings_audio_network_strategy_desc.
  ///
  /// In zh, this message translates to:
  /// **'在 Wi-Fi 与移动数据之间自动使用不同码率。'**
  String get settings_audio_network_strategy_desc;

  /// No description provided for @settings_audio_network_wifi.
  ///
  /// In zh, this message translates to:
  /// **'Wi-Fi'**
  String get settings_audio_network_wifi;

  /// No description provided for @settings_audio_quality.
  ///
  /// In zh, this message translates to:
  /// **'音质设置'**
  String get settings_audio_quality;

  /// No description provided for @settings_audio_quality_desc.
  ///
  /// In zh, this message translates to:
  /// **'按网络选择播放码率'**
  String get settings_audio_quality_desc;

  /// 音质页状态行（标签与值）的语义标签
  ///
  /// In zh, this message translates to:
  /// **'{label}，{value}'**
  String settings_audio_status_line(String label, String value);

  /// No description provided for @settings_audio_wifi_section.
  ///
  /// In zh, this message translates to:
  /// **'Wi-Fi 音质'**
  String get settings_audio_wifi_section;

  /// No description provided for @settings_audio_wifi_section_desc.
  ///
  /// In zh, this message translates to:
  /// **'连接 Wi-Fi 时优先保证音乐完整度。'**
  String get settings_audio_wifi_section_desc;

  /// No description provided for @settings_autoplay.
  ///
  /// In zh, this message translates to:
  /// **'打开时自动播放'**
  String get settings_autoplay;

  /// No description provided for @settings_autoplay_desc.
  ///
  /// In zh, this message translates to:
  /// **'启动后恢复上次本机播放队列与进度，并自动续播。'**
  String get settings_autoplay_desc;

  /// No description provided for @settings_auth_password.
  ///
  /// In zh, this message translates to:
  /// **'密码'**
  String get settings_auth_password;

  /// No description provided for @settings_auth_type.
  ///
  /// In zh, this message translates to:
  /// **'认证方式'**
  String get settings_auth_type;

  /// No description provided for @settings_cancel.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get settings_cancel;

  /// No description provided for @settings_check_update.
  ///
  /// In zh, this message translates to:
  /// **'检查更新'**
  String get settings_check_update;

  /// No description provided for @settings_check_update_checking_semantics.
  ///
  /// In zh, this message translates to:
  /// **'检查更新，正在连接 GitHub Releases'**
  String get settings_check_update_checking_semantics;

  /// No description provided for @settings_check_update_desc.
  ///
  /// In zh, this message translates to:
  /// **'从 GitHub Releases 检查最新版本'**
  String get settings_check_update_desc;

  /// No description provided for @settings_clear.
  ///
  /// In zh, this message translates to:
  /// **'清空'**
  String get settings_clear;

  /// No description provided for @settings_configure.
  ///
  /// In zh, this message translates to:
  /// **'配置'**
  String get settings_configure;

  /// No description provided for @settings_configure_fanart.
  ///
  /// In zh, this message translates to:
  /// **'配置 Fanart.tv'**
  String get settings_configure_fanart;

  /// No description provided for @settings_configure_fanart_subtitle.
  ///
  /// In zh, this message translates to:
  /// **'Fanart.tv 高清封面需要单独的 API Key。'**
  String get settings_configure_fanart_subtitle;

  /// No description provided for @settings_crossfade.
  ///
  /// In zh, this message translates to:
  /// **'切歌淡入淡出'**
  String get settings_crossfade;

  /// No description provided for @settings_crossfade_desc.
  ///
  /// In zh, this message translates to:
  /// **'设置相邻曲目之间的交叉衰减时长。'**
  String get settings_crossfade_desc;

  /// No description provided for @settings_crossfade_off.
  ///
  /// In zh, this message translates to:
  /// **'关闭'**
  String get settings_crossfade_off;

  /// No description provided for @settings_crossfade_off_value.
  ///
  /// In zh, this message translates to:
  /// **'关闭交叉衰减'**
  String get settings_crossfade_off_value;

  /// 交叉衰减时长数值标签（秒）
  ///
  /// In zh, this message translates to:
  /// **'{seconds} 秒'**
  String settings_crossfade_seconds(String seconds);

  /// 带时长的交叉衰减选项描述
  ///
  /// In zh, this message translates to:
  /// **'用 {label} 平滑衔接相邻曲目'**
  String settings_crossfade_smooth(String label);

  /// No description provided for @settings_crossfade_subtitle.
  ///
  /// In zh, this message translates to:
  /// **'选择相邻曲目同时播放的交叉衰减时长。'**
  String get settings_crossfade_subtitle;

  /// No description provided for @settings_cover_api_key_configured.
  ///
  /// In zh, this message translates to:
  /// **'API Key：已配置'**
  String get settings_cover_api_key_configured;

  /// No description provided for @settings_cover_api_key_unconfigured.
  ///
  /// In zh, this message translates to:
  /// **'API Key：未配置'**
  String get settings_cover_api_key_unconfigured;

  /// No description provided for @settings_cover_priority_desc.
  ///
  /// In zh, this message translates to:
  /// **'查找封面时会从上到下依次尝试。按住拖动图标可调整顺序。'**
  String get settings_cover_priority_desc;

  /// No description provided for @settings_cover_provider.
  ///
  /// In zh, this message translates to:
  /// **'封面提供商'**
  String get settings_cover_provider;

  /// No description provided for @settings_cover_provider_custom_desc.
  ///
  /// In zh, this message translates to:
  /// **'自定义 API 地址'**
  String get settings_cover_provider_custom_desc;

  /// No description provided for @settings_cover_provider_desc.
  ///
  /// In zh, this message translates to:
  /// **'调整获取顺序并配置 Fanart.tv'**
  String get settings_cover_provider_desc;

  /// No description provided for @settings_cover_provider_empty_desc.
  ///
  /// In zh, this message translates to:
  /// **'提供商配置为空，请稍后重试或检查应用数据。'**
  String get settings_cover_provider_empty_desc;

  /// No description provided for @settings_cover_provider_empty_title.
  ///
  /// In zh, this message translates to:
  /// **'没有可用的封面提供商'**
  String get settings_cover_provider_empty_title;

  /// No description provided for @settings_cover_provider_fanart_desc.
  ///
  /// In zh, this message translates to:
  /// **'Fanart.tv 高清封面（需要 API Key）'**
  String get settings_cover_provider_fanart_desc;

  /// No description provided for @settings_cover_provider_musicbrainz_desc.
  ///
  /// In zh, this message translates to:
  /// **'MusicBrainz Cover Art Archive'**
  String get settings_cover_provider_musicbrainz_desc;

  /// 封面提供商列表加载失败的描述（含错误信息）
  ///
  /// In zh, this message translates to:
  /// **'提供商顺序、启用状态和配置暂时不可用。\n{error}'**
  String settings_cover_provider_page_error_desc(String error);

  /// No description provided for @settings_cover_provider_page_error_title.
  ///
  /// In zh, this message translates to:
  /// **'无法读取封面提供商'**
  String get settings_cover_provider_page_error_title;

  /// No description provided for @settings_cover_provider_subsonic_desc.
  ///
  /// In zh, this message translates to:
  /// **'Subsonic 服务端封面'**
  String get settings_cover_provider_subsonic_desc;

  /// No description provided for @settings_current_connection.
  ///
  /// In zh, this message translates to:
  /// **'当前连接'**
  String get settings_current_connection;

  /// No description provided for @settings_current_version.
  ///
  /// In zh, this message translates to:
  /// **'当前版本'**
  String get settings_current_version;

  /// No description provided for @settings_desktop_lyrics.
  ///
  /// In zh, this message translates to:
  /// **'桌面歌词'**
  String get settings_desktop_lyrics;

  /// No description provided for @settings_desktop_lyrics_desc.
  ///
  /// In zh, this message translates to:
  /// **'开启后，桌面显示可拖动的歌词浮窗(置顶、不抢焦点)。'**
  String get settings_desktop_lyrics_desc;

  /// No description provided for @settings_diagnostics_section.
  ///
  /// In zh, this message translates to:
  /// **'诊断与更新'**
  String get settings_diagnostics_section;

  /// No description provided for @settings_diagnostics_section_desc.
  ///
  /// In zh, this message translates to:
  /// **'查看本机诊断日志，或检查 GitHub Releases。'**
  String get settings_diagnostics_section_desc;

  /// No description provided for @settings_disable.
  ///
  /// In zh, this message translates to:
  /// **'停用'**
  String get settings_disable;

  /// No description provided for @settings_download.
  ///
  /// In zh, this message translates to:
  /// **'前往下载'**
  String get settings_download;

  /// No description provided for @settings_download_confirm_body.
  ///
  /// In zh, this message translates to:
  /// **'将跳转到浏览器开始下载。下载完成后请自行完成更新安装：Windows 请解压 zip 覆盖到安装目录，Android 请安装下载的 apk。'**
  String get settings_download_confirm_body;

  /// 歌词跟随停靠时长数值标签（秒）
  ///
  /// In zh, this message translates to:
  /// **'{seconds} 秒'**
  String settings_dwell_seconds(String seconds);

  /// No description provided for @settings_edit_library.
  ///
  /// In zh, this message translates to:
  /// **'编辑当前音乐库'**
  String get settings_edit_library;

  /// No description provided for @settings_edit_library_desc.
  ///
  /// In zh, this message translates to:
  /// **'管理服务器地址、认证方式与音乐库能力。'**
  String get settings_edit_library_desc;

  /// No description provided for @settings_edit_library_empty_desc.
  ///
  /// In zh, this message translates to:
  /// **'选择音乐库后可编辑服务器与认证信息。'**
  String get settings_edit_library_empty_desc;

  /// No description provided for @settings_enable.
  ///
  /// In zh, this message translates to:
  /// **'启用'**
  String get settings_enable;

  /// 信息行（标签与值）的语义标签
  ///
  /// In zh, this message translates to:
  /// **'{label}，{value}'**
  String settings_info_line_semantics(String label, String value);

  /// No description provided for @settings_later.
  ///
  /// In zh, this message translates to:
  /// **'稍后再说'**
  String get settings_later;

  /// No description provided for @settings_latest_version.
  ///
  /// In zh, this message translates to:
  /// **'最新版本'**
  String get settings_latest_version;

  /// 已保存的音乐库数量描述
  ///
  /// In zh, this message translates to:
  /// **'已保存 {count} 个音乐库'**
  String settings_library_count_saved(int count);

  /// No description provided for @settings_library_empty.
  ///
  /// In zh, this message translates to:
  /// **'当前没有可切换的音乐库'**
  String get settings_library_empty;

  /// No description provided for @settings_library_label.
  ///
  /// In zh, this message translates to:
  /// **'音乐库'**
  String get settings_library_label;

  /// No description provided for @settings_library_load_failed.
  ///
  /// In zh, this message translates to:
  /// **'音乐库列表读取失败，点击重试'**
  String get settings_library_load_failed;

  /// No description provided for @settings_library_loading.
  ///
  /// In zh, this message translates to:
  /// **'正在读取音乐库列表'**
  String get settings_library_loading;

  /// No description provided for @settings_library_section.
  ///
  /// In zh, this message translates to:
  /// **'音乐库与服务器'**
  String get settings_library_section;

  /// No description provided for @settings_library_section_desc.
  ///
  /// In zh, this message translates to:
  /// **'查看当前连接，也可以切换或编辑已经保存的音乐库。'**
  String get settings_library_section_desc;

  /// No description provided for @settings_library_single.
  ///
  /// In zh, this message translates to:
  /// **'当前仅有一个音乐库'**
  String get settings_library_single;

  /// 切换音乐库失败的提示（含错误信息）
  ///
  /// In zh, this message translates to:
  /// **'切换音乐库失败: {error}'**
  String settings_library_switch_failed(String error);

  /// No description provided for @settings_library_switch_subtitle.
  ///
  /// In zh, this message translates to:
  /// **'选择后会刷新当前音乐库的内容与播放状态。'**
  String get settings_library_switch_subtitle;

  /// 成功切换到某音乐库的提示（含库名）
  ///
  /// In zh, this message translates to:
  /// **'已切换到“{name}”'**
  String settings_library_switched(String name);

  /// No description provided for @settings_log_auto_refresh.
  ///
  /// In zh, this message translates to:
  /// **'自动刷新'**
  String get settings_log_auto_refresh;

  /// No description provided for @settings_log_clear_cache.
  ///
  /// In zh, this message translates to:
  /// **'清空缓存'**
  String get settings_log_clear_cache;

  /// No description provided for @settings_log_copy.
  ///
  /// In zh, this message translates to:
  /// **'复制'**
  String get settings_log_copy;

  /// 复制日志成功提示（含行数）
  ///
  /// In zh, this message translates to:
  /// **'已复制 {count} 行日志'**
  String settings_log_copied(int count);

  /// No description provided for @settings_log_diagnostics.
  ///
  /// In zh, this message translates to:
  /// **'诊断日志'**
  String get settings_log_diagnostics;

  /// No description provided for @settings_log_empty.
  ///
  /// In zh, this message translates to:
  /// **'暂无日志'**
  String get settings_log_empty;

  /// No description provided for @settings_log_filter_hint.
  ///
  /// In zh, this message translates to:
  /// **'筛选关键字，如 DLNA-AUTO / SSDP / 触发续播'**
  String get settings_log_filter_hint;

  /// No description provided for @settings_log_no_content.
  ///
  /// In zh, this message translates to:
  /// **'当前没有可复制的日志'**
  String get settings_log_no_content;

  /// No description provided for @settings_log_status_live.
  ///
  /// In zh, this message translates to:
  /// **'实时刷新中'**
  String get settings_log_status_live;

  /// No description provided for @settings_log_status_paused.
  ///
  /// In zh, this message translates to:
  /// **'已暂停'**
  String get settings_log_status_paused;

  /// 日志窗口的统计信息（总数、显示数、刷新状态）
  ///
  /// In zh, this message translates to:
  /// **'共 {total} 行｜显示 {shown} 行（{status}）'**
  String settings_log_summary(int total, int shown, String status);

  /// No description provided for @settings_logging.
  ///
  /// In zh, this message translates to:
  /// **'记录日志'**
  String get settings_logging;

  /// No description provided for @settings_logging_desc.
  ///
  /// In zh, this message translates to:
  /// **'默认关闭不抓取任何日志；开启后记录全部日志（最多 5000 条）。'**
  String get settings_logging_desc;

  /// No description provided for @settings_lyrics_dwell.
  ///
  /// In zh, this message translates to:
  /// **'歌词跟随停靠时长'**
  String get settings_lyrics_dwell;

  /// No description provided for @settings_lyrics_dwell_default.
  ///
  /// In zh, this message translates to:
  /// **'默认：停下 3 秒后恢复跟随'**
  String get settings_lyrics_dwell_default;

  /// No description provided for @settings_lyrics_dwell_desc.
  ///
  /// In zh, this message translates to:
  /// **'手动滚动歌词后，过多久恢复自动跟随当前歌词。'**
  String get settings_lyrics_dwell_desc;

  /// 指定时长后恢复跟随的选项描述
  ///
  /// In zh, this message translates to:
  /// **'停下 {duration} 后恢复跟随'**
  String settings_lyrics_dwell_resume(String duration);

  /// No description provided for @settings_lyrics_dwell_subtitle.
  ///
  /// In zh, this message translates to:
  /// **'手动滚动并停下后，等待该时长再恢复「跟随当前歌词」自动滚动。'**
  String get settings_lyrics_dwell_subtitle;

  /// No description provided for @settings_lyrics_priority_desc.
  ///
  /// In zh, this message translates to:
  /// **'播放时会从上到下依次尝试。按住拖动图标可调整顺序。'**
  String get settings_lyrics_priority_desc;

  /// No description provided for @settings_lyrics_provider.
  ///
  /// In zh, this message translates to:
  /// **'歌词提供商'**
  String get settings_lyrics_provider;

  /// No description provided for @settings_lyrics_provider_custom_desc.
  ///
  /// In zh, this message translates to:
  /// **'自定义 API 地址'**
  String get settings_lyrics_provider_custom_desc;

  /// No description provided for @settings_lyrics_provider_desc.
  ///
  /// In zh, this message translates to:
  /// **'调整获取顺序与启用状态'**
  String get settings_lyrics_provider_desc;

  /// No description provided for @settings_lyrics_provider_empty_desc.
  ///
  /// In zh, this message translates to:
  /// **'提供商配置为空，请稍后重试或检查应用数据。'**
  String get settings_lyrics_provider_empty_desc;

  /// No description provided for @settings_lyrics_provider_empty_title.
  ///
  /// In zh, this message translates to:
  /// **'没有可用的歌词提供商'**
  String get settings_lyrics_provider_empty_title;

  /// No description provided for @settings_lyrics_provider_lrclib_desc.
  ///
  /// In zh, this message translates to:
  /// **'公共同步歌词 API'**
  String get settings_lyrics_provider_lrclib_desc;

  /// No description provided for @settings_lyrics_provider_netease_desc.
  ///
  /// In zh, this message translates to:
  /// **'网易云音乐歌词'**
  String get settings_lyrics_provider_netease_desc;

  /// 歌词提供商列表加载失败的描述（含错误信息）
  ///
  /// In zh, this message translates to:
  /// **'提供商顺序和启用状态暂时不可用。\n{error}'**
  String settings_lyrics_provider_page_error_desc(String error);

  /// No description provided for @settings_lyrics_provider_page_error_title.
  ///
  /// In zh, this message translates to:
  /// **'无法读取歌词提供商'**
  String get settings_lyrics_provider_page_error_title;

  /// No description provided for @settings_lyrics_provider_subsonic_desc.
  ///
  /// In zh, this message translates to:
  /// **'OpenSubsonic / Subsonic 内嵌歌词'**
  String get settings_lyrics_provider_subsonic_desc;

  /// No description provided for @settings_not_connected.
  ///
  /// In zh, this message translates to:
  /// **'未连接'**
  String get settings_not_connected;

  /// No description provided for @settings_not_selected.
  ///
  /// In zh, this message translates to:
  /// **'未选择'**
  String get settings_not_selected;

  /// No description provided for @settings_not_set.
  ///
  /// In zh, this message translates to:
  /// **'未设置'**
  String get settings_not_set;

  /// No description provided for @settings_playback_section.
  ///
  /// In zh, this message translates to:
  /// **'播放与外观'**
  String get settings_playback_section;

  /// No description provided for @settings_playback_section_desc.
  ///
  /// In zh, this message translates to:
  /// **'这些选择会立即应用到当前设备。'**
  String get settings_playback_section_desc;

  /// No description provided for @settings_priority_order.
  ///
  /// In zh, this message translates to:
  /// **'优先顺序'**
  String get settings_priority_order;

  /// No description provided for @settings_project_home.
  ///
  /// In zh, this message translates to:
  /// **'项目主页'**
  String get settings_project_home;

  /// No description provided for @settings_provider_custom.
  ///
  /// In zh, this message translates to:
  /// **'自定义源'**
  String get settings_provider_custom;

  /// 提供商列表拖动排序手柄的语义标签（含名称）
  ///
  /// In zh, this message translates to:
  /// **'按住并拖动{title}，调整优先顺序'**
  String settings_provider_drag_semantics(String title);

  /// No description provided for @settings_provider_fanart.
  ///
  /// In zh, this message translates to:
  /// **'Fanart.tv'**
  String get settings_provider_fanart;

  /// No description provided for @settings_provider_lrclib.
  ///
  /// In zh, this message translates to:
  /// **'LRCLIB'**
  String get settings_provider_lrclib;

  /// No description provided for @settings_provider_musicbrainz.
  ///
  /// In zh, this message translates to:
  /// **'MusicBrainz'**
  String get settings_provider_musicbrainz;

  /// No description provided for @settings_provider_netease.
  ///
  /// In zh, this message translates to:
  /// **'网易云音乐'**
  String get settings_provider_netease;

  /// No description provided for @settings_provider_subsonic.
  ///
  /// In zh, this message translates to:
  /// **'服务端'**
  String get settings_provider_subsonic;

  /// 提供商开关的语义标签（启用/停用动作加名称）
  ///
  /// In zh, this message translates to:
  /// **'{action}{title}'**
  String settings_provider_toggle_semantics(String action, String title);

  /// No description provided for @settings_route_auto_fallback.
  ///
  /// In zh, this message translates to:
  /// **'线路自动回退'**
  String get settings_route_auto_fallback;

  /// No description provided for @settings_route_auto_fallback_desc.
  ///
  /// In zh, this message translates to:
  /// **'手动线路不可用时，自动切换到其他可用线路。'**
  String get settings_route_auto_fallback_desc;

  /// No description provided for @settings_save.
  ///
  /// In zh, this message translates to:
  /// **'保存'**
  String get settings_save;

  /// No description provided for @settings_selected.
  ///
  /// In zh, this message translates to:
  /// **'已选择'**
  String get settings_selected;

  /// No description provided for @settings_server_address.
  ///
  /// In zh, this message translates to:
  /// **'服务器地址'**
  String get settings_server_address;

  /// No description provided for @settings_server_unconfigured.
  ///
  /// In zh, this message translates to:
  /// **'未配置服务器地址'**
  String get settings_server_unconfigured;

  /// No description provided for @settings_status_disabled.
  ///
  /// In zh, this message translates to:
  /// **'已停用'**
  String get settings_status_disabled;

  /// No description provided for @settings_status_enabled.
  ///
  /// In zh, this message translates to:
  /// **'已启用'**
  String get settings_status_enabled;

  /// No description provided for @settings_switch_library.
  ///
  /// In zh, this message translates to:
  /// **'切换音乐库'**
  String get settings_switch_library;

  /// No description provided for @settings_theme.
  ///
  /// In zh, this message translates to:
  /// **'主题设置'**
  String get settings_theme;

  /// No description provided for @settings_theme_accent.
  ///
  /// In zh, this message translates to:
  /// **'强调色'**
  String get settings_theme_accent;

  /// No description provided for @settings_theme_accent_desc.
  ///
  /// In zh, this message translates to:
  /// **'只用于主要操作、当前选择与键盘焦点。专辑颜色不会扩散到普通页面。'**
  String get settings_theme_accent_desc;

  /// No description provided for @settings_theme_apply.
  ///
  /// In zh, this message translates to:
  /// **'应用'**
  String get settings_theme_apply;

  /// No description provided for @settings_theme_appearance.
  ///
  /// In zh, this message translates to:
  /// **'外观模式'**
  String get settings_theme_appearance;

  /// No description provided for @settings_theme_appearance_desc.
  ///
  /// In zh, this message translates to:
  /// **'跟随设备，或固定使用浅色与深色界面。'**
  String get settings_theme_appearance_desc;

  /// No description provided for @settings_theme_brightness.
  ///
  /// In zh, this message translates to:
  /// **'明度'**
  String get settings_theme_brightness;

  /// 预设主题色按钮的语义标签（含色值）
  ///
  /// In zh, this message translates to:
  /// **'强调色 {hex}'**
  String settings_theme_color(String hex);

  /// No description provided for @settings_theme_color_picker_subtitle.
  ///
  /// In zh, this message translates to:
  /// **'系统会在保存时校准对比度和色度。'**
  String get settings_theme_color_picker_subtitle;

  /// No description provided for @settings_theme_color_picker_title.
  ///
  /// In zh, this message translates to:
  /// **'调整强调色'**
  String get settings_theme_color_picker_title;

  /// 已选中的预设主题色按钮语义标签（含色值）
  ///
  /// In zh, this message translates to:
  /// **'强调色 {hex}，已选择'**
  String settings_theme_color_selected(String hex);

  /// No description provided for @settings_theme_current_accent.
  ///
  /// In zh, this message translates to:
  /// **'当前强调色'**
  String get settings_theme_current_accent;

  /// No description provided for @settings_theme_dark.
  ///
  /// In zh, this message translates to:
  /// **'深色'**
  String get settings_theme_dark;

  /// No description provided for @settings_theme_dark_desc.
  ///
  /// In zh, this message translates to:
  /// **'使用低亮度的夜间试听空间'**
  String get settings_theme_dark_desc;

  /// No description provided for @settings_theme_desc.
  ///
  /// In zh, this message translates to:
  /// **'明暗模式与主题色'**
  String get settings_theme_desc;

  /// No description provided for @settings_theme_fine_tune.
  ///
  /// In zh, this message translates to:
  /// **'精细调整'**
  String get settings_theme_fine_tune;

  /// No description provided for @settings_theme_follow_system.
  ///
  /// In zh, this message translates to:
  /// **'跟随系统'**
  String get settings_theme_follow_system;

  /// No description provided for @settings_theme_follow_system_desc.
  ///
  /// In zh, this message translates to:
  /// **'自动匹配设备的外观设置'**
  String get settings_theme_follow_system_desc;

  /// No description provided for @settings_theme_hue.
  ///
  /// In zh, this message translates to:
  /// **'色相'**
  String get settings_theme_hue;

  /// No description provided for @settings_theme_light.
  ///
  /// In zh, this message translates to:
  /// **'浅色'**
  String get settings_theme_light;

  /// No description provided for @settings_theme_light_desc.
  ///
  /// In zh, this message translates to:
  /// **'使用明亮、中性的试听空间'**
  String get settings_theme_light_desc;

  /// No description provided for @settings_theme_mode_dark.
  ///
  /// In zh, this message translates to:
  /// **'黑色'**
  String get settings_theme_mode_dark;

  /// No description provided for @settings_theme_mode_light.
  ///
  /// In zh, this message translates to:
  /// **'白色'**
  String get settings_theme_mode_light;

  /// No description provided for @settings_theme_mode_system.
  ///
  /// In zh, this message translates to:
  /// **'跟随系统'**
  String get settings_theme_mode_system;

  /// No description provided for @settings_theme_reset_default.
  ///
  /// In zh, this message translates to:
  /// **'恢复默认主题'**
  String get settings_theme_reset_default;

  /// No description provided for @settings_theme_saturation.
  ///
  /// In zh, this message translates to:
  /// **'饱和度'**
  String get settings_theme_saturation;

  /// No description provided for @settings_title.
  ///
  /// In zh, this message translates to:
  /// **'设置'**
  String get settings_title;

  /// No description provided for @settings_toggle_disabled.
  ///
  /// In zh, this message translates to:
  /// **'已关闭'**
  String get settings_toggle_disabled;

  /// No description provided for @settings_toggle_enabled.
  ///
  /// In zh, this message translates to:
  /// **'已开启'**
  String get settings_toggle_enabled;

  /// 带描述的开关行的语义标签
  ///
  /// In zh, this message translates to:
  /// **'{title}，{state}，{description}'**
  String settings_toggle_semantics(
    String title,
    String state,
    String description,
  );

  /// 无描述的开关行的语义标签
  ///
  /// In zh, this message translates to:
  /// **'{title}，{state}'**
  String settings_toggle_semantics_no_desc(String title, String state);

  /// No description provided for @settings_update_assets.
  ///
  /// In zh, this message translates to:
  /// **'下载文件'**
  String get settings_update_assets;

  /// No description provided for @settings_update_assets_desc.
  ///
  /// In zh, this message translates to:
  /// **'选择适合当前设备的安装文件。'**
  String get settings_update_assets_desc;

  /// 检查更新失败的提示（含错误信息）
  ///
  /// In zh, this message translates to:
  /// **'检查更新失败: {error}'**
  String settings_update_check_failed(String error);

  /// No description provided for @settings_update_found.
  ///
  /// In zh, this message translates to:
  /// **'发现新版本'**
  String get settings_update_found;

  /// 发现新版本对话框标题（含最新版本号）
  ///
  /// In zh, this message translates to:
  /// **'发现新版本 {version}'**
  String settings_update_found_version(String version);

  /// 已是最新版本的提示（含当前版本号）
  ///
  /// In zh, this message translates to:
  /// **'当前已是最新版本 ({version})'**
  String settings_update_latest(String version);

  /// No description provided for @settings_update_notes.
  ///
  /// In zh, this message translates to:
  /// **'更新说明'**
  String get settings_update_notes;

  /// 更新安装包下载项名称（含版本号）
  ///
  /// In zh, this message translates to:
  /// **'更新包 {version}'**
  String settings_update_package(String version);

  /// No description provided for @settings_username.
  ///
  /// In zh, this message translates to:
  /// **'用户名'**
  String get settings_username;

  /// No description provided for @settings_view_logs.
  ///
  /// In zh, this message translates to:
  /// **'查看日志'**
  String get settings_view_logs;

  /// No description provided for @settings_view_logs_desc.
  ///
  /// In zh, this message translates to:
  /// **'应用内直接查看并复制诊断日志（可筛选 DLNA）'**
  String get settings_view_logs_desc;

  /// No description provided for @widgets_retry.
  ///
  /// In zh, this message translates to:
  /// **'重试'**
  String get widgets_retry;

  /// No description provided for @widgets_settings.
  ///
  /// In zh, this message translates to:
  /// **'设置'**
  String get widgets_settings;

  /// No description provided for @widgets_artists.
  ///
  /// In zh, this message translates to:
  /// **'艺术家'**
  String get widgets_artists;

  /// No description provided for @widgets_albums.
  ///
  /// In zh, this message translates to:
  /// **'专辑'**
  String get widgets_albums;

  /// No description provided for @widgets_songs.
  ///
  /// In zh, this message translates to:
  /// **'歌曲'**
  String get widgets_songs;

  /// No description provided for @widgets_playlists.
  ///
  /// In zh, this message translates to:
  /// **'歌单'**
  String get widgets_playlists;

  /// No description provided for @widgets_favorites.
  ///
  /// In zh, this message translates to:
  /// **'喜欢'**
  String get widgets_favorites;

  /// No description provided for @widgets_connection_ok.
  ///
  /// In zh, this message translates to:
  /// **'连接正常'**
  String get widgets_connection_ok;

  /// No description provided for @widgets_connection_failed.
  ///
  /// In zh, this message translates to:
  /// **'连接失败'**
  String get widgets_connection_failed;

  /// No description provided for @widgets_connection_pending.
  ///
  /// In zh, this message translates to:
  /// **'等待检测'**
  String get widgets_connection_pending;

  /// No description provided for @widgets_connection_disconnected.
  ///
  /// In zh, this message translates to:
  /// **'未连接'**
  String get widgets_connection_disconnected;

  /// No description provided for @widgets_drawer_library_unselected.
  ///
  /// In zh, this message translates to:
  /// **'未选择'**
  String get widgets_drawer_library_unselected;

  /// No description provided for @widgets_drawer_no_active_route.
  ///
  /// In zh, this message translates to:
  /// **'没有活动线路'**
  String get widgets_drawer_no_active_route;

  /// No description provided for @widgets_drawer_library_empty_title.
  ///
  /// In zh, this message translates to:
  /// **'还没有音乐库'**
  String get widgets_drawer_library_empty_title;

  /// No description provided for @widgets_drawer_library_empty_desc.
  ///
  /// In zh, this message translates to:
  /// **'添加一个 Navidrome、Subsonic 或 OpenSubsonic 音乐库后即可开始聆听。'**
  String get widgets_drawer_library_empty_desc;

  /// No description provided for @widgets_drawer_add_library.
  ///
  /// In zh, this message translates to:
  /// **'添加音乐库'**
  String get widgets_drawer_add_library;

  /// No description provided for @widgets_drawer_server_unconfigured.
  ///
  /// In zh, this message translates to:
  /// **'未配置服务器地址'**
  String get widgets_drawer_server_unconfigured;

  /// No description provided for @widgets_drawer_add_new_library.
  ///
  /// In zh, this message translates to:
  /// **'添加新音乐库'**
  String get widgets_drawer_add_new_library;

  /// No description provided for @widgets_drawer_add_new_library_subtitle.
  ///
  /// In zh, this message translates to:
  /// **'连接另一台服务器或另一个账户'**
  String get widgets_drawer_add_new_library_subtitle;

  /// No description provided for @widgets_drawer_library_error_title.
  ///
  /// In zh, this message translates to:
  /// **'无法读取音乐库'**
  String get widgets_drawer_library_error_title;

  /// No description provided for @widgets_drawer_library_error_desc.
  ///
  /// In zh, this message translates to:
  /// **'音乐库列表暂时不可用。重试不会影响当前正在播放的内容。'**
  String get widgets_drawer_library_error_desc;

  /// No description provided for @widgets_cover_art_album.
  ///
  /// In zh, this message translates to:
  /// **'专辑封面'**
  String get widgets_cover_art_album;

  /// No description provided for @widgets_cover_art_load_failed.
  ///
  /// In zh, this message translates to:
  /// **'封面加载失败，自动重试中'**
  String get widgets_cover_art_load_failed;

  /// 封面加载失败的语义标签（含自定义无障碍标签）
  ///
  /// In zh, this message translates to:
  /// **'{label}，封面加载失败'**
  String widgets_cover_art_load_failed_with_label(String label);

  /// No description provided for @widgets_cover_art_loading.
  ///
  /// In zh, this message translates to:
  /// **'封面加载中'**
  String get widgets_cover_art_loading;

  /// No description provided for @widgets_cover_art_none.
  ///
  /// In zh, this message translates to:
  /// **'暂无封面'**
  String get widgets_cover_art_none;

  /// No description provided for @widgets_home.
  ///
  /// In zh, this message translates to:
  /// **'主页'**
  String get widgets_home;

  /// No description provided for @widgets_music_flow.
  ///
  /// In zh, this message translates to:
  /// **'音乐流'**
  String get widgets_music_flow;

  /// No description provided for @widgets_music.
  ///
  /// In zh, this message translates to:
  /// **'音乐'**
  String get widgets_music;

  /// No description provided for @widgets_i_like.
  ///
  /// In zh, this message translates to:
  /// **'我喜欢'**
  String get widgets_i_like;

  /// No description provided for @widgets_play.
  ///
  /// In zh, this message translates to:
  /// **'播放'**
  String get widgets_play;

  /// No description provided for @widgets_shuffle.
  ///
  /// In zh, this message translates to:
  /// **'随机播放'**
  String get widgets_shuffle;

  /// No description provided for @widgets_route_selection_title.
  ///
  /// In zh, this message translates to:
  /// **'切换线路'**
  String get widgets_route_selection_title;

  /// No description provided for @widgets_route_redetect_latency.
  ///
  /// In zh, this message translates to:
  /// **'重新检测延迟'**
  String get widgets_route_redetect_latency;

  /// No description provided for @widgets_route_error_title.
  ///
  /// In zh, this message translates to:
  /// **'无法读取线路'**
  String get widgets_route_error_title;

  /// No description provided for @widgets_route_error_desc.
  ///
  /// In zh, this message translates to:
  /// **'线路信息暂时不可用。请重试，或稍后打开音乐库设置检查地址。'**
  String get widgets_route_error_desc;

  /// No description provided for @widgets_route_no_route_title.
  ///
  /// In zh, this message translates to:
  /// **'没有可用线路'**
  String get widgets_route_no_route_title;

  /// No description provided for @widgets_route_no_route_desc.
  ///
  /// In zh, this message translates to:
  /// **'请先在音乐库设置中添加至少一个服务器地址。'**
  String get widgets_route_no_route_desc;

  /// No description provided for @widgets_route_auto_enabled.
  ///
  /// In zh, this message translates to:
  /// **'当前已开启'**
  String get widgets_route_auto_enabled;

  /// 自动模式已开启提示（含当前线路名称）
  ///
  /// In zh, this message translates to:
  /// **'当前已开启 · {label}'**
  String widgets_route_auto_enabled_label(String label);

  /// No description provided for @widgets_route_auto_select.
  ///
  /// In zh, this message translates to:
  /// **'自动选择'**
  String get widgets_route_auto_select;

  /// No description provided for @widgets_route_auto_select_desc.
  ///
  /// In zh, this message translates to:
  /// **'根据可用性和延迟选择线路'**
  String get widgets_route_auto_select_desc;

  /// No description provided for @widgets_route_latency_unknown.
  ///
  /// In zh, this message translates to:
  /// **'未知'**
  String get widgets_route_latency_unknown;

  /// 延迟数值标签
  ///
  /// In zh, this message translates to:
  /// **'延迟 {value}'**
  String widgets_route_latency_label(String value);

  /// No description provided for @widgets_song_selected.
  ///
  /// In zh, this message translates to:
  /// **'已选择'**
  String get widgets_song_selected;

  /// 歌曲行更多操作按钮的语义标签
  ///
  /// In zh, this message translates to:
  /// **'{title}，更多操作'**
  String widgets_song_more_semantics(String title);

  /// 取消选择某首歌曲的操作标签
  ///
  /// In zh, this message translates to:
  /// **'取消选择 {title}'**
  String widgets_song_deselect(String title);

  /// 选择某首歌曲的操作标签
  ///
  /// In zh, this message translates to:
  /// **'选择 {title}'**
  String widgets_song_select(String title);

  /// No description provided for @widgets_song_favorite.
  ///
  /// In zh, this message translates to:
  /// **'已收藏'**
  String get widgets_song_favorite;

  /// No description provided for @widgets_song_preview.
  ///
  /// In zh, this message translates to:
  /// **'试听'**
  String get widgets_song_preview;

  /// 歌曲封面的语义标签
  ///
  /// In zh, this message translates to:
  /// **'{title} 封面'**
  String widgets_song_cover_semantics(String title);

  /// No description provided for @widgets_song_now_playing.
  ///
  /// In zh, this message translates to:
  /// **'正在播放'**
  String get widgets_song_now_playing;

  /// No description provided for @widgets_window_minimize.
  ///
  /// In zh, this message translates to:
  /// **'最小化'**
  String get widgets_window_minimize;

  /// No description provided for @widgets_window_maximize_restore.
  ///
  /// In zh, this message translates to:
  /// **'最大化/还原'**
  String get widgets_window_maximize_restore;

  /// No description provided for @widgets_window_close.
  ///
  /// In zh, this message translates to:
  /// **'关闭'**
  String get widgets_window_close;

  /// No description provided for @widgets_drawer_frame_semantics.
  ///
  /// In zh, this message translates to:
  /// **'应用菜单'**
  String get widgets_drawer_frame_semantics;

  /// 抽屉身份头部（账户/音乐库/线路状态）的语义标签
  ///
  /// In zh, this message translates to:
  /// **'当前账户 {username}，音乐库 {libraryName}，{status}，{address}'**
  String widgets_drawer_identity_semantics(
    String username,
    String libraryName,
    String status,
    String address,
  );

  /// No description provided for @widgets_drawer_back_app_menu.
  ///
  /// In zh, this message translates to:
  /// **'返回应用功能菜单'**
  String get widgets_drawer_back_app_menu;

  /// No description provided for @widgets_drawer_view_libraries.
  ///
  /// In zh, this message translates to:
  /// **'查看音乐库'**
  String get widgets_drawer_view_libraries;

  /// No description provided for @widgets_drawer_current_library.
  ///
  /// In zh, this message translates to:
  /// **'当前音乐库'**
  String get widgets_drawer_current_library;

  /// 编辑某个音乐库的操作标签
  ///
  /// In zh, this message translates to:
  /// **'编辑 {title}'**
  String widgets_drawer_edit_library(String title);

  /// No description provided for @widgets_network_cannot_reach_server.
  ///
  /// In zh, this message translates to:
  /// **'连接不到服务器'**
  String get widgets_network_cannot_reach_server;

  /// No description provided for @widgets_network_recovered.
  ///
  /// In zh, this message translates to:
  /// **'网络已恢复'**
  String get widgets_network_recovered;

  /// No description provided for @widgets_network_weak_title.
  ///
  /// In zh, this message translates to:
  /// **'网络不稳定'**
  String get widgets_network_weak_title;

  /// No description provided for @widgets_network_weak_desc.
  ///
  /// In zh, this message translates to:
  /// **'正在重试可用线路，已加载内容和离线歌曲仍可使用'**
  String get widgets_network_weak_desc;

  /// No description provided for @widgets_network_offline_title.
  ///
  /// In zh, this message translates to:
  /// **'当前离线'**
  String get widgets_network_offline_title;

  /// No description provided for @widgets_network_offline_desc.
  ///
  /// In zh, this message translates to:
  /// **'已加载内容和离线歌曲仍可使用，在线操作将在联网后恢复'**
  String get widgets_network_offline_desc;

  /// No description provided for @widgets_nav_main.
  ///
  /// In zh, this message translates to:
  /// **'主导航'**
  String get widgets_nav_main;

  /// No description provided for @widgets_nav_main_collapsed.
  ///
  /// In zh, this message translates to:
  /// **'主导航（已收起）'**
  String get widgets_nav_main_collapsed;

  /// No description provided for @widgets_nav_expand_sidebar.
  ///
  /// In zh, this message translates to:
  /// **'展开侧边栏'**
  String get widgets_nav_expand_sidebar;

  /// No description provided for @widgets_nav_collapse_sidebar.
  ///
  /// In zh, this message translates to:
  /// **'收起侧边栏'**
  String get widgets_nav_collapse_sidebar;

  /// No description provided for @discover_category_nav.
  ///
  /// In zh, this message translates to:
  /// **'分类导航'**
  String get discover_category_nav;

  /// 媒体封面图片的语义标签（含名称）
  ///
  /// In zh, this message translates to:
  /// **'{name} 封面'**
  String discover_cover_semantics(String name);

  /// No description provided for @discover_error_desc_check_route.
  ///
  /// In zh, this message translates to:
  /// **'请检查网络或当前线路，然后重试。'**
  String get discover_error_desc_check_route;

  /// No description provided for @discover_error_desc_switch_route.
  ///
  /// In zh, this message translates to:
  /// **'请检查网络或切换线路后重试。'**
  String get discover_error_desc_switch_route;

  /// No description provided for @discover_explore.
  ///
  /// In zh, this message translates to:
  /// **'探索'**
  String get discover_explore;

  /// No description provided for @discover_for_you.
  ///
  /// In zh, this message translates to:
  /// **'为你推荐'**
  String get discover_for_you;

  /// No description provided for @discover_import_no_valid_id.
  ///
  /// In zh, this message translates to:
  /// **'歌单导入后未返回有效 id'**
  String get discover_import_no_valid_id;

  /// 导入推荐歌单失败的提示（含错误信息）
  ///
  /// In zh, this message translates to:
  /// **'导入歌单失败：{msg}'**
  String discover_import_playlist_failed(String msg);

  /// No description provided for @discover_local_random.
  ///
  /// In zh, this message translates to:
  /// **'本地随机'**
  String get discover_local_random;

  /// No description provided for @discover_local_random_load_failed.
  ///
  /// In zh, this message translates to:
  /// **'本地随机加载失败'**
  String get discover_local_random_load_failed;

  /// No description provided for @discover_music_suffix.
  ///
  /// In zh, this message translates to:
  /// **'音乐'**
  String get discover_music_suffix;

  /// No description provided for @discover_network_failed_play_playlist.
  ///
  /// In zh, this message translates to:
  /// **'网络异常，无法播放歌单'**
  String get discover_network_failed_play_playlist;

  /// No description provided for @discover_no_library_selected.
  ///
  /// In zh, this message translates to:
  /// **'未选择音乐库'**
  String get discover_no_library_selected;

  /// No description provided for @discover_not_connected_library.
  ///
  /// In zh, this message translates to:
  /// **'未连接到音乐库'**
  String get discover_not_connected_library;

  /// No description provided for @discover_open_app_menu.
  ///
  /// In zh, this message translates to:
  /// **'打开应用菜单'**
  String get discover_open_app_menu;

  /// No description provided for @discover_platform_load_failed.
  ///
  /// In zh, this message translates to:
  /// **'平台推荐加载失败'**
  String get discover_platform_load_failed;

  /// No description provided for @discover_platform_recommend.
  ///
  /// In zh, this message translates to:
  /// **'平台推荐'**
  String get discover_platform_recommend;

  /// No description provided for @discover_play_playlist.
  ///
  /// In zh, this message translates to:
  /// **'播放歌单'**
  String get discover_play_playlist;

  /// 播放歌单失败的提示（含错误信息）
  ///
  /// In zh, this message translates to:
  /// **'播放歌单失败：{msg}'**
  String discover_play_playlist_failed(String msg);

  /// No description provided for @discover_play_random_songs.
  ///
  /// In zh, this message translates to:
  /// **'播放随机歌曲'**
  String get discover_play_random_songs;

  /// No description provided for @discover_playlist_empty.
  ///
  /// In zh, this message translates to:
  /// **'歌单暂无可用歌曲'**
  String get discover_playlist_empty;

  /// No description provided for @discover_random_songs.
  ///
  /// In zh, this message translates to:
  /// **'随机歌曲'**
  String get discover_random_songs;

  /// 最近播放专辑卡片的语义标签（含专辑名）
  ///
  /// In zh, this message translates to:
  /// **'最近播放专辑 {name}'**
  String discover_recent_album_semantics(String name);

  /// No description provided for @discover_recent_playlists.
  ///
  /// In zh, this message translates to:
  /// **'最近更新的歌单'**
  String get discover_recent_playlists;

  /// No description provided for @discover_recent_playlists_load_failed.
  ///
  /// In zh, this message translates to:
  /// **'最近更新歌单加载失败'**
  String get discover_recent_playlists_load_failed;

  /// 最近播放专辑卡片的歌曲数描述
  ///
  /// In zh, this message translates to:
  /// **'{count} 首歌曲'**
  String discover_recent_song_count(String count);

  /// No description provided for @discover_recently_played.
  ///
  /// In zh, this message translates to:
  /// **'最近听过'**
  String get discover_recently_played;

  /// No description provided for @discover_recommend_load_failed.
  ///
  /// In zh, this message translates to:
  /// **'为你推荐加载失败'**
  String get discover_recommend_load_failed;

  /// No description provided for @discover_recommend_service_unavailable.
  ///
  /// In zh, this message translates to:
  /// **'推荐服务暂不可用，请检查平台推荐插件是否已启用'**
  String get discover_recommend_service_unavailable;

  /// No description provided for @discover_refresh_recent_playlists.
  ///
  /// In zh, this message translates to:
  /// **'刷新最近更新歌单'**
  String get discover_refresh_recent_playlists;

  /// No description provided for @discover_search.
  ///
  /// In zh, this message translates to:
  /// **'搜索'**
  String get discover_search;

  /// No description provided for @discover_section_unavailable_playlist.
  ///
  /// In zh, this message translates to:
  /// **'歌单暂时不可用'**
  String get discover_section_unavailable_playlist;

  /// No description provided for @discover_shuffle_song_label.
  ///
  /// In zh, this message translates to:
  /// **'换一批随机歌曲'**
  String get discover_shuffle_song_label;

  /// 歌曲行更多操作按钮的语义标签（含歌名）
  ///
  /// In zh, this message translates to:
  /// **'{title} 操作'**
  String discover_song_actions_semantics(String title);

  /// 歌单卡片的歌曲数副标题（含数量）
  ///
  /// In zh, this message translates to:
  /// **'{count} 首'**
  String discover_track_count(String count);

  /// No description provided for @discover_unavailable_local_random.
  ///
  /// In zh, this message translates to:
  /// **'本地随机暂时不可用'**
  String get discover_unavailable_local_random;

  /// No description provided for @discover_unavailable_platform.
  ///
  /// In zh, this message translates to:
  /// **'平台推荐暂时不可用'**
  String get discover_unavailable_platform;

  /// No description provided for @discover_unavailable_recommend.
  ///
  /// In zh, this message translates to:
  /// **'为你推荐暂时不可用'**
  String get discover_unavailable_recommend;

  /// No description provided for @search_back.
  ///
  /// In zh, this message translates to:
  /// **'返回'**
  String get search_back;

  /// No description provided for @search_clear.
  ///
  /// In zh, this message translates to:
  /// **'清空搜索'**
  String get search_clear;

  /// No description provided for @search_clear_history.
  ///
  /// In zh, this message translates to:
  /// **'清空搜索历史'**
  String get search_clear_history;

  /// No description provided for @search_current_library.
  ///
  /// In zh, this message translates to:
  /// **'当前音乐库'**
  String get search_current_library;

  /// 删除某条搜索历史记录的按钮语义标签（含关键词）
  ///
  /// In zh, this message translates to:
  /// **'删除历史 {term}'**
  String search_delete_history(String term);

  /// 某范围搜索失败的提示（含范围名）
  ///
  /// In zh, this message translates to:
  /// **'{section}搜索失败,可下拉重试'**
  String search_group_search_failed(String section);

  /// No description provided for @search_history.
  ///
  /// In zh, this message translates to:
  /// **'搜索历史'**
  String get search_history;

  /// No description provided for @search_hint.
  ///
  /// In zh, this message translates to:
  /// **'搜索歌曲、歌单、艺术家、专辑'**
  String get search_hint;

  /// No description provided for @search_hot_search.
  ///
  /// In zh, this message translates to:
  /// **'热门搜索'**
  String get search_hot_search;

  /// 搜索结果条目数量标签
  ///
  /// In zh, this message translates to:
  /// **'{count} 项'**
  String search_items_count(int count);

  /// No description provided for @search_local_no_results.
  ///
  /// In zh, this message translates to:
  /// **'本地没有找到相关结果'**
  String get search_local_no_results;

  /// No description provided for @search_local_results.
  ///
  /// In zh, this message translates to:
  /// **'本地结果'**
  String get search_local_results;

  /// No description provided for @search_network_results.
  ///
  /// In zh, this message translates to:
  /// **'全网结果'**
  String get search_network_results;

  /// No description provided for @search_network_results_subtitle.
  ///
  /// In zh, this message translates to:
  /// **'已启用插件的合并搜索,卡片带插件·平台标签'**
  String get search_network_results_subtitle;

  /// No description provided for @search_scope_overlay.
  ///
  /// In zh, this message translates to:
  /// **'搜索范围浮层'**
  String get search_scope_overlay;

  /// 搜索某个关键词的按钮语义标签（含关键词）
  ///
  /// In zh, this message translates to:
  /// **'搜索 {term}'**
  String search_search_term_semantics(String term);

  /// 结果列表的语义标签（含关键词）
  ///
  /// In zh, this message translates to:
  /// **'正在显示“{query}”的结果'**
  String search_showing_results(String query);

  /// 歌单卡片的歌曲数副标题（含数量）
  ///
  /// In zh, this message translates to:
  /// **'{count} 首'**
  String search_song_count(String count);

  /// No description provided for @discover_music_flow_title.
  ///
  /// In zh, this message translates to:
  /// **'音乐流'**
  String get discover_music_flow_title;

  /// No description provided for @discover_category_favorites.
  ///
  /// In zh, this message translates to:
  /// **'喜欢'**
  String get discover_category_favorites;

  /// No description provided for @discover_category_playlists.
  ///
  /// In zh, this message translates to:
  /// **'歌单'**
  String get discover_category_playlists;

  /// No description provided for @discover_category_songs.
  ///
  /// In zh, this message translates to:
  /// **'歌曲'**
  String get discover_category_songs;

  /// No description provided for @discover_category_artists.
  ///
  /// In zh, this message translates to:
  /// **'艺术家'**
  String get discover_category_artists;

  /// No description provided for @discover_category_albums.
  ///
  /// In zh, this message translates to:
  /// **'专辑'**
  String get discover_category_albums;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}

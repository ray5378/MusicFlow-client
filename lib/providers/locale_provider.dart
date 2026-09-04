import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/sources/local_storage.dart';

/// 语言偏好：跟随系统 / 强制中文 / 强制英文。默认中文。
enum AppLanguagePreference {
  /// 跟随系统（OS 为英文则英文，否则中文兜底）。
  system,
  zh,
  en,
}

/// 语言偏好设置模型。
class LocaleSettings {
  final AppLanguagePreference preference;

  const LocaleSettings({this.preference = AppLanguagePreference.zh});

  LocaleSettings copyWith({AppLanguagePreference? preference}) {
    return LocaleSettings(preference: preference ?? this.preference);
  }

  /// 显式中文/英文时返回对应 Locale；跟随系统返回 null（由 MaterialApp 用系统
  /// locale，不支持的系统语言靠 supportedLocales 兜底回中文）。
  Locale? effectiveLocale() {
    switch (preference) {
      case AppLanguagePreference.zh:
        return const Locale('zh');
      case AppLanguagePreference.en:
        return const Locale('en');
      case AppLanguagePreference.system:
        return null;
    }
  }
}

/// 语言偏Provider（StateNotifier 镜像 themeSettingsProvider）。
final appLanguageProvider =
    StateNotifierProvider<AppLanguageNotifier, LocaleSettings>(
      (ref) => AppLanguageNotifier(),
    );

/// 语言偏好 Notifier：默认中文，异步从本地存储加载并持久化。
class AppLanguageNotifier extends StateNotifier<LocaleSettings> {
  AppLanguageNotifier() : super(const LocaleSettings()) {
    _load();
  }

  Future<void> _load() async {
    final raw = await LocalStorage.getAppLanguage();
    state = LocaleSettings(preference: _fromStorage(raw));
  }

  Future<void> setPreference(AppLanguagePreference pref) async {
    if (state.preference == pref) return;
    state = state.copyWith(preference: pref);
    await LocalStorage.setAppLanguage(_toStorage(pref));
  }

  static AppLanguagePreference _fromStorage(String raw) {
    switch (raw) {
      case 'zh':
        return AppLanguagePreference.zh;
      case 'en':
        return AppLanguagePreference.en;
      case 'system':
      default:
        return AppLanguagePreference.system;
    }
  }

  static String _toStorage(AppLanguagePreference pref) {
    switch (pref) {
      case AppLanguagePreference.zh:
        return 'zh';
      case AppLanguagePreference.en:
        return 'en';
      case AppLanguagePreference.system:
        return 'system';
    }
  }
}
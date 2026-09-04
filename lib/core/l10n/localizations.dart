import 'package:flutter/widgets.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../providers/locale_provider.dart';

/// 无 BuildContext 环境（providers / services）读取当前语言文案的统一入口。
///
/// gen-l10n 生成的 `AppLocalizations(localeName)` 可直接构造：各 getter 依
/// localeName 返回对应语言文案。这里按语言偏好解析出生效的 locale：
/// - zh/en：显式使用中文/英文；
/// - system：跟随系统（OS 为英文则英文，否则中文兜底）。
AppLocalizations l10nNow(AppLanguagePreference pref) {
  final name = switch (pref) {
    AppLanguagePreference.zh => 'zh',
    AppLanguagePreference.en => 'en',
    AppLanguagePreference.system => _systemLocale(),
  };
  return lookupAppLocalizations(Locale(name));
}

String _systemLocale() {
  try {
    final code = WidgetsBinding.instance.platformDispatcher.locale.languageCode;
    return code.startsWith('en') ? 'en' : 'zh';
  } catch (_) {
    return 'zh';
  }
}
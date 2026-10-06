import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/data/models/audio_quality.dart';
import 'package:musicflow_client/data/models/home_section_layout.dart';
import 'package:musicflow_client/data/models/server_config.dart';
import 'package:musicflow_client/data/sources/json_file_store.dart';
import 'package:musicflow_client/data/sources/local_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 直接写原始 prefs 键制造脏数据。
Future<void> raw(Map<String, Object> values) async {
  SharedPreferences.setMockInitialValues(values);
}

void main() {
  late Directory tmpDir;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmpDir = Directory.systemTemp.createTempSync('b34b_ls_');
    JsonFileStore.instance.debugDirectory = tmpDir;
  });

  tearDown(() {
    JsonFileStore.instance.debugDirectory = null;
    tmpDir.deleteSync(recursive: true);
  });

  group('播放模式（含旧版枚举名迁移）', () {
    test('未设置默认 all', () async {
      expect(await LocalStorage.getPlaybackMode(), 'all');
    });

    test('合法值 shuffle/all/one/order 原样读回', () async {
      for (final mode in ['shuffle', 'all', 'one', 'order']) {
        await raw({'playback_mode': mode});
        expect(await LocalStorage.getPlaybackMode(), mode);
      }
      await LocalStorage.setPlaybackMode('shuffle');
      expect(await LocalStorage.getPlaybackMode(), 'shuffle');
    });

    test('旧版持久化名 repeatAll/repeatOne 迁移为 all/one', () async {
      await raw({'playback_mode': 'repeatAll'});
      expect(await LocalStorage.getPlaybackMode(), 'all');
      await raw({'playback_mode': 'repeatOne'});
      expect(await LocalStorage.getPlaybackMode(), 'one');
    });

    test('非法值回落 all', () async {
      await raw({'playback_mode': 'bogus'});
      expect(await LocalStorage.getPlaybackMode(), 'all');
    });
  });

  group('主题模式 / 主色 / 语言', () {
    test('主题模式默认 system，合法值读回，非法回落 system', () async {
      expect(await LocalStorage.getThemeModeSetting(), 'system');
      await raw({'theme_mode': 'dark'});
      expect(await LocalStorage.getThemeModeSetting(), 'dark');
      await raw({'theme_mode': 'light'});
      expect(await LocalStorage.getThemeModeSetting(), 'light');
      await raw({'theme_mode': 'weird'});
      expect(await LocalStorage.getThemeModeSetting(), 'system');
      await LocalStorage.setThemeModeSetting('dark');
      expect(await LocalStorage.getThemeModeSetting(), 'dark');
    });

    test('主题主色默认 0xFF4CAF50，写入后读回', () async {
      expect(await LocalStorage.getThemeSeedColorValue(), 0xFF4CAF50);
      await LocalStorage.setThemeSeedColorValue(0xFF123456);
      expect(await LocalStorage.getThemeSeedColorValue(), 0xFF123456);
    });

    test('语言默认 zh，合法值读回，非法回落 zh', () async {
      expect(await LocalStorage.getAppLanguage(), 'zh');
      await LocalStorage.setAppLanguage('en');
      expect(await LocalStorage.getAppLanguage(), 'en');
      await LocalStorage.setAppLanguage('system');
      expect(await LocalStorage.getAppLanguage(), 'system');
      await raw({'app_language': 'fr'});
      expect(await LocalStorage.getAppLanguage(), 'zh');
    });
  });

  group('数值型设置', () {
    test('音频缓存上限：默认 null，写入读回', () async {
      expect(await LocalStorage.getMaxCacheSize(), isNull);
      await LocalStorage.setMaxCacheSize(1024);
      expect(await LocalStorage.getMaxCacheSize(), 1024);
    });

    test('淡入淡出时长：默认 0，写入读回', () async {
      expect(await LocalStorage.getCrossfadeDurationMs(), 0);
      await LocalStorage.setCrossfadeDurationMs(500);
      expect(await LocalStorage.getCrossfadeDurationMs(), 500);
    });

    test('歌词停靠时长：默认 3 秒，写入读回', () async {
      expect(await LocalStorage.getLyricsScrollDwellSeconds(), 3);
      await LocalStorage.setLyricsScrollDwellSeconds(7);
      expect(await LocalStorage.getLyricsScrollDwellSeconds(), 7);
    });
  });

  group('移动网络缓存节省流量累计', () {
    test('空 libraryId / 无数据 → 0', () async {
      expect(await LocalStorage.getMobileCacheSavedBytes(libraryId: ''), 0);
      expect(await LocalStorage.getMobileCacheSavedBytes(libraryId: 'lib1'), 0);
    });

    test('累加与多库隔离；bytes<=0 / 空 libraryId 忽略', () async {
      await LocalStorage.addMobileCacheSavedBytes(
          libraryId: 'lib1', bytes: 100);
      await LocalStorage.addMobileCacheSavedBytes(
          libraryId: 'lib1', bytes: 50);
      await LocalStorage.addMobileCacheSavedBytes(
          libraryId: 'lib2', bytes: 7);
      expect(await LocalStorage.getMobileCacheSavedBytes(libraryId: 'lib1'),
          150);
      expect(await LocalStorage.getMobileCacheSavedBytes(libraryId: 'lib2'), 7);

      await LocalStorage.addMobileCacheSavedBytes(
          libraryId: 'lib1', bytes: 0);
      await LocalStorage.addMobileCacheSavedBytes(
          libraryId: 'lib1', bytes: -5);
      await LocalStorage.addMobileCacheSavedBytes(libraryId: '  ', bytes: 99);
      expect(await LocalStorage.getMobileCacheSavedBytes(libraryId: 'lib1'),
          150);
    });

    test('脏数据（非 JSON）→ 读 0 且后续累加仍正常', () async {
      await raw({'mobile_cache_saved_bytes_by_library_v1': 'not-json'});
      expect(await LocalStorage.getMobileCacheSavedBytes(libraryId: 'lib1'), 0);
      await LocalStorage.addMobileCacheSavedBytes(
          libraryId: 'lib1', bytes: 20);
      expect(await LocalStorage.getMobileCacheSavedBytes(libraryId: 'lib1'),
          20);
    });

    test('值为字符串/浮点/负数时按 _parsePositiveInt 语义解析', () async {
      await raw({
        'mobile_cache_saved_bytes_by_library_v1':
            jsonEncode({'s': '55', 'd': 12.9, 'n': -3}),
      });
      expect(await LocalStorage.getMobileCacheSavedBytes(libraryId: 's'), 55);
      expect(await LocalStorage.getMobileCacheSavedBytes(libraryId: 'd'), 12);
      expect(await LocalStorage.getMobileCacheSavedBytes(libraryId: 'n'), 0);
      expect(
        await LocalStorage.getMobileCacheSavedBytes(libraryId: 'missing'),
        0,
      );
    });
  });

  group('播放会话（JsonFileStore）', () {
    test('保存后可读回；清除后为 null', () async {
      final session = <String, dynamic>{
        'queue': ['a', 'b'],
        'index': 1,
        'position': 12.5,
      };
      await LocalStorage.savePlaybackSession(session);
      final read = await LocalStorage.getPlaybackSession();
      expect(read, isNotNull);
      expect(read!['index'], 1);
      expect(read['position'], 12.5);

      await LocalStorage.clearPlaybackSession();
      expect(await LocalStorage.getPlaybackSession(), isNull);
    });

    test('非 Map / 损坏 JSON → null 不抛异常', () async {
      await JsonFileStore.instance.writeString('playback_session_v1', '[1,2]');
      expect(await LocalStorage.getPlaybackSession(), isNull);
      await JsonFileStore.instance.writeString('playback_session_v1', '{bad');
      expect(await LocalStorage.getPlaybackSession(), isNull);
    });
  });

  group('播放音量（JsonFileStore）', () {
    test('默认 0.8；写入读回；越界值 clamp 到 [0,1]', () async {
      expect(await LocalStorage.getPlayerVolume(), 0.8);
      await LocalStorage.setPlayerVolume(0.5);
      expect(await LocalStorage.getPlayerVolume(), 0.5);
      await LocalStorage.setPlayerVolume(1.5);
      expect(await LocalStorage.getPlayerVolume(), 1.0);
      await LocalStorage.setPlayerVolume(-0.2);
      expect(await LocalStorage.getPlayerVolume(), 0.0);
    });

    test('损坏数据回落 0.8', () async {
      await JsonFileStore.instance.writeString('player_volume', 'not-json');
      expect(await LocalStorage.getPlayerVolume(), 0.8);
      await JsonFileStore.instance
          .writeString('player_volume', jsonEncode({'v': 'NaN'}));
      expect(await LocalStorage.getPlayerVolume(), 0.8);
    });
  });

  group('首页分区布局', () {
    test('未设置返回 null；保存读回；清除后 null', () async {
      expect(await LocalStorage.getHomeSectionLayout(), isNull);
      await LocalStorage.saveHomeSectionLayout(const HomeSectionLayout(
        order: ['a', 'b'],
        hidden: ['c'],
        miniPlayerVisible: false,
      ));
      final layout = await LocalStorage.getHomeSectionLayout();
      expect(layout, isNotNull);
      expect(layout!.order, ['a', 'b']);
      expect(layout.hidden, ['c']);
      expect(layout.miniPlayerVisible, isFalse);
      await LocalStorage.clearHomeSectionLayout();
      expect(await LocalStorage.getHomeSectionLayout(), isNull);
    });

    test('脏 payload（非 JSON / 非 Map）→ null', () async {
      await raw({'home_section_layout_v1': 'garbage'});
      expect(await LocalStorage.getHomeSectionLayout(), isNull);
      await raw({'home_section_layout_v1': '[1,2]'});
      expect(await LocalStorage.getHomeSectionLayout(), isNull);
    });
  });

  group('服务器配置（凭据走钥匙串，测试环境静默降级）', () {
    test('无配置 → null / hasServerConfig false', () async {
      expect(await LocalStorage.getServerConfig(), isNull);
      expect(await LocalStorage.hasServerConfig(), isFalse);
    });

    test('保存后：非敏感字段读回，凭据字段为空（钥匙串不可用）', () async {
      const config = ServerConfig(
        serverUrl: 'https://srv.example.com',
        username: 'alice',
        password: 'secret',
        apiKey: 'key-123',
        authType: AuthType.token,
      );
      await LocalStorage.saveServerConfig(config);
      expect(await LocalStorage.hasServerConfig(), isTrue);

      final loaded = await LocalStorage.getServerConfig();
      expect(loaded, isNotNull);
      expect(loaded!.serverUrl, 'https://srv.example.com');
      expect(loaded.username, 'alice');
      expect(loaded.authType, AuthType.token);
      // prefs 里凭据已被清洗，钥匙串在测试环境不可用 → 读回为空。
      expect(loaded.password, anyOf(isNull, 'secret'));
      expect(loaded.apiKey, anyOf(isNull, 'key-123'));

      await LocalStorage.clearServerConfig();
      expect(await LocalStorage.hasServerConfig(), isFalse);
      expect(await LocalStorage.getServerConfig(), isNull);
    });

    test('旧版明文凭据自动迁移（清洗 prefs）', () async {
      final legacy = <String, dynamic>{
        'serverUrl': 'https://old.example.com',
        'username': 'bob',
        'password': 'plaintext',
        'apiKey': null,
        'authType': 'apiKey',
      };
      await raw({'server_config': jsonEncode(legacy)});
      final loaded = await LocalStorage.getServerConfig();
      expect(loaded, isNotNull);
      expect(loaded!.username, 'bob');
      expect(loaded.password, isNull,
          reason: '明文凭据应被迁移清洗，钥匙串不可用时读回为空');

      // prefs 中不再残留明文。
      final prefs = await SharedPreferences.getInstance();
      final stored = jsonDecode(prefs.getString('server_config')!)
          as Map<String, dynamic>;
      expect(stored['password'], isNull);
    });
  });

  group('音质设置', () {
    test('默认设置；保存后读回', () async {
      final defaults = await LocalStorage.getAudioQualitySettings();
      expect(defaults.wifiQuality, AudioQualityLevel.original);
      expect(defaults.mobileQuality, AudioQualityLevel.standard);

      const custom = AudioQualitySettings(
        wifiQuality: AudioQualityLevel.high,
        mobileQuality: AudioQualityLevel.dataSaver,
        autoSwitch: false,
      );
      await LocalStorage.setAudioQualitySettings(custom);
      final loaded = await LocalStorage.getAudioQualitySettings();
      expect(loaded.wifiQuality, AudioQualityLevel.high);
      expect(loaded.mobileQuality, AudioQualityLevel.dataSaver);
      expect(loaded.autoSwitch, isFalse);
    });

    test('损坏 JSON → 回落默认', () async {
      await raw({'audio_quality_settings': '{broken'});
      final settings = await LocalStorage.getAudioQualitySettings();
      expect(settings.wifiQuality, AudioQualityLevel.original);
    });
  });
}

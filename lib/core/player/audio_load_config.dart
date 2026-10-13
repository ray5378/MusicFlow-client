/// 起播/重缓冲缓冲标定（just_audio `AudioLoadConfiguration` 单一常量源）。
///
/// 背景（2026-10-13 起播缓冲标定）：本配置原先在
/// `lib/core/services/audio_handler_service.dart`（AudioService 初始化）与
/// `lib/providers/player/player_provider.dart`（桌面端降级路径）各复制粘贴一份
/// —— Android/iOS 两条 LoadControl 参数完全相同。「改一边忘一边」的漂移风险
/// 实打实存在，故提取为全 App 唯一常量源，两处调用方共用，并由测试断言一致。
///
/// 与服务端起播策略的认知对齐（非联动，参数不随服务端变）：服务端对网络源做
/// 整曲内存缓冲 + 有界等待分档（已知大小 8s / 未知 6s，权威定义见服务端
/// `backend/src/routes/rest/index.ts` 的 `STREAM_BUFFER_HEAD_WAIT_MS`），
/// 首字节经 ffmpeg 管道回来后由本配置决定「攒多少媒体秒才起播」——
/// 实测首字节后 13~21MB/s 瞬间填满，故 5s/10s 两档不是起播瓶颈，维持原值。
library;

import 'package:just_audio/just_audio.dart';

/// 全 App 唯一的 [AudioLoadConfiguration]（Android/iOS LoadControl 标定）。
///
/// 参数语义（Android LoadControl，单位是**媒体秒**缓冲，非起播瓶颈）：
///   · `bufferForPlaybackDuration` 5s / 重缓冲后 10s：首字节后的起播阈值；
///   · `minBufferDuration` 10min / `maxBufferDuration` 15min：内存驻留窗口
///     （服务端 membuf 回环吐的是整曲，缓冲区天然够，不构成起播延迟）；
///   · Darwin `preferredForwardBufferDuration` 10min：iOS 同义。
const AudioLoadConfiguration kAudioLoadConfiguration = AudioLoadConfiguration(
  androidLoadControl: AndroidLoadControl(
    minBufferDuration: Duration(minutes: 10),
    maxBufferDuration: Duration(minutes: 15),
    bufferForPlaybackDuration: Duration(seconds: 5),
    bufferForPlaybackAfterRebufferDuration: Duration(seconds: 10),
  ),
  darwinLoadControl: DarwinLoadControl(
    preferredForwardBufferDuration: Duration(minutes: 10),
  ),
);

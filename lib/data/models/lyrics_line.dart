/// 单行歌词
class LyricsLine {
  final int? startMs;
  final String value;

  LyricsLine({this.startMs, required this.value});

  factory LyricsLine.fromJson(Map<String, dynamic> json) {
    return LyricsLine(
      // start 容错：非整数实现（浮点/字符串）不应让整组歌词丢弃。
      startMs: switch (json['start']) {
        num value => value.toInt(),
        String value => int.tryParse(value),
        _ => null,
      },
      value: json['value'] is String ? json['value'] as String : '',
    );
  }

  Map<String, dynamic> toJson() {
    return {if (startMs != null) 'start': startMs, 'value': value};
  }
}

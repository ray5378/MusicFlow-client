import 'package:flutter/material.dart';

import 'app.dart';
import 'core/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MusicFlowApp());
}

/// 预留：主题令牌自检（AppTypography 在 core/theme.dart）。
// ignore: unused_element
const _themeSanity = AppTypography(Brightness.light);

import 'dart:io';

import 'package:sp_util/sp_util.dart';

class EnvUtil {
  static bool? _isMobile;
  static const List<String> proxyList = ['', 'https://easytv.suntengfei.top/', 'http://ghp.keleyaa.com/'];

  static bool isTV() {
    return const bool.fromEnvironment('isTV');
  }

  static int get _proxyIndex => SpUtil.getInt('dataValueProxy', defValue: 1)!;

  static bool get isMobile {
    if (_isMobile != null) return _isMobile!;
    _isMobile = Platform.isAndroid || Platform.isIOS;
    return _isMobile!;
  }

  static String sourceDownloadHost() {
    return '${proxyList[_proxyIndex]}https://github.com/aiyakuaile/easy_tv_live/releases/download';
  }

  static String sourceReleaseHost() {
    return 'https://github.com/aiyakuaile/easy_tv_live/releases';
  }

  static String sourceHomeHost() {
    return 'https://github.com/aiyakuaile/easy_tv_live';
  }

  /// 内置默认直播源（直接访问，不走 GitHub 代理）
  static const String defaultChannelSourceUrl = 'https://dsh.966887.xyz/lntv.txt';

  static String videoDefaultChannelHost() {
    return defaultChannelSourceUrl;
  }

  static String checkVersionHost() {
    return '${proxyList[_proxyIndex]}https://raw.githubusercontent.com/aiyakuaile/easy_tv_live/main/versions.json';
  }

  static String fontLink() {
    return '${proxyList[_proxyIndex]}https://raw.githubusercontent.com/aiyakuaile/easy_tv_font/main';
  }
}

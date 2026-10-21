import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:easy_tv_live/provider/theme_provider.dart';
import 'package:easy_tv_live/setting/qr_scan_page.dart';
import 'package:easy_tv_live/setting/setting_font_page.dart';
import 'package:easy_tv_live/setting/setting_remote.dart';
import 'package:easy_tv_live/setting/subscribe_page.dart';
import 'package:easy_tv_live/util/env_util.dart';
import 'package:easy_tv_live/util/log_util.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_easyloading_plus/flutter_easyloading_plus.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:fvp/fvp.dart' as fvp;
import 'package:provider/provider.dart';
import 'package:sp_util/sp_util.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

import 'generated/l10n.dart';
import 'live_home_page.dart';
import 'provider/download_provider.dart';
import 'router_keys.dart';
import 'setting/setting_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  LogUtil.init(isDebug: kDebugMode, tag: 'EasyTV');
  LogUtil.e('==== EasyTV 启动开始 ====');
  FlutterError.onError = (FlutterErrorDetails details) {
    LogUtil.e('FlutterError::::${details.exceptionAsString()}\n${details.stack}');
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    LogUtil.e('未捕获异常::::$error\n$stack');
    return true;
  };
  ErrorWidget.builder = (FlutterErrorDetails details) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: Colors.black,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text('启动/渲染异常：\n${details.exceptionAsString()}', style: const TextStyle(color: Colors.white, fontSize: 12)),
          ),
        ),
      ),
    );
  };
  runZonedGuarded(
    () => _bootstrap(),
    (Object error, StackTrace stack) => LogUtil.e('Zone 未捕获异常::::$error\n$stack'),
  );
}

Future<void> _bootstrap() async {
  // 桌面端窗口初始化失败不应该阻塞 App 启动
  if (!EnvUtil.isMobile) {
    try {
      await windowManager.ensureInitialized();
      const WindowOptions windowOptions = WindowOptions(
        size: Size(900, 900 * 9 / 16),
        minimumSize: Size(300, 300 * 9 / 16),
        center: true,
        backgroundColor: Colors.transparent,
        skipTaskbar: false,
        titleBarStyle: TitleBarStyle.normal,
        title: '极简TV',
      );
      windowManager.waitUntilReadyToShow(windowOptions, () async {
        await windowManager.show();
        await windowManager.focus();
      });
    } catch (e, s) {
      LogUtil.e('桌面窗口初始化失败::::$e\n$s');
    }
  }

  unawaited(_safeWakelock());

  try {
    await SpUtil.getInstance();
    LogUtil.e('SpUtil 初始化完成');
  } catch (e, s) {
    LogUtil.e('SpUtil 初始化失败::::$e\n$s');
  }

  // fvp/播放器初始化异常不能把 App 卡在启动页，捕获后继续启动界面
  try {
    fvp.registerWith(
      options: {
        'platforms': ['android', 'ios', 'windows', 'linux', 'macos'],
        'video.decoders': ['D3D11', 'NVDEC', 'FFmpeg'],
        'player': {'cc': '0', 'buffer': '3000+60000'},
        'global': {'logLevel': 'Error'},
      },
    );
    LogUtil.e('fvp 初始化完成');
  } catch (e, s) {
    LogUtil.e('fvp 初始化失败（不影响界面启动）::::$e\n$s');
  }

  try {
    runApp(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => ThemeProvider()),
          ChangeNotifierProvider(create: (_) => DownloadProvider()),
        ],
        child: const MyApp(),
      ),
    );
    LogUtil.e('runApp 已调用');
  } catch (e, s) {
    LogUtil.e('runApp 失败::::$e\n$s');
    runApp(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(child: Text('启动失败：$e', style: const TextStyle(color: Colors.white))),
        ),
      ),
    );
  }

  if (Platform.isAndroid) {
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(statusBarColor: Colors.transparent));
  }
}

Future<void> _safeWakelock() async {
  try {
    await WakelockPlus.enable();
  } catch (e) {
    LogUtil.e('Wakelock 初始化失败::::$e');
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Selector<ThemeProvider, ({String fontFamily, double textScaleFactor})>(
      selector: (_, provider) => (fontFamily: provider.fontFamily, textScaleFactor: provider.textScaleFactor),
      builder: (context, data, child) {
        String? fontFamily = data.fontFamily;
        if (fontFamily == 'system') {
          fontFamily = null;
        }
        return MaterialApp(
          title: '极简TV',
          theme: ThemeData(
            brightness: Brightness.dark,
            fontFamily: fontFamily,
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.redAccent, brightness: Brightness.dark),
            scaffoldBackgroundColor: Colors.black,
            appBarTheme: const AppBarTheme(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              elevation: 0,
              scrolledUnderElevation: 0,
              centerTitle: true,
            ),
            useMaterial3: true,
          ),
          routes: {
            RouterKeys.subScribe: (BuildContext context) => const SubScribePage(),
            RouterKeys.setting: (BuildContext context) => const SettingPage(),
            RouterKeys.settingFont: (BuildContext context) => const SettingFontPage(),
            RouterKeys.settingQrScan: (BuildContext context) => const QrScanPage(),
            RouterKeys.settingRemote: (BuildContext context) => const SettingRemote(),
          },
          localizationsDelegates: const [
            S.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: S.delegate.supportedLocales,
          localeResolutionCallback: (locale, supportedLocales) {
            if (locale == null) {
              return const Locale('en', 'US');
            }
            for (var supportedLocale in supportedLocales) {
              if (supportedLocale.languageCode == locale.languageCode && supportedLocale.countryCode == locale.countryCode) {
                return supportedLocale;
              }
            }
            for (var supportedLocale in supportedLocales) {
              if (supportedLocale.languageCode == locale.languageCode && supportedLocale.countryCode != locale.countryCode) {
                return supportedLocale;
              }
            }
            return const Locale('en', 'US');
          },
          debugShowCheckedModeBanner: false,
          home: Platform.isWindows || Platform.isLinux ? const DragToResizeArea(child: DragToMoveArea(child: LiveHomePage())) : const LiveHomePage(),
          builder: (context, child) {
            return MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(data.textScaleFactor)),
              child: FlutterEasyLoading(child: child),
            );
          },
        );
      },
    );
  }
}

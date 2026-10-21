import 'dart:async';
import 'dart:io';

import 'package:easy_tv_live/provider/download_provider.dart';
import 'package:easy_tv_live/provider/theme_provider.dart';
import 'package:easy_tv_live/util/latency_checker_util.dart';
import 'package:easy_tv_live/util/remote_util.dart';
import 'package:easy_tv_live/widget/focus_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_easyloading_plus/flutter_easyloading_plus.dart';
import 'package:provider/provider.dart';
import 'package:responsive_builder/responsive_builder.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'channel_drawer_page.dart';
import 'entity/play_channel_list_model.dart';
import 'generated/l10n.dart';
import 'mobile_video_widget.dart';
import 'table_video_widget.dart';
import 'tv/tv_page.dart';
import 'util/check_version_util.dart';
import 'util/env_util.dart';
import 'util/epg_util.dart';
import 'util/log_util.dart';
import 'util/m3u_util.dart';
import 'widget/empty_page.dart';

class LiveHomePage extends StatefulWidget {
  const LiveHomePage({super.key});

  @override
  State<LiveHomePage> createState() => _LiveHomePageState();
}

class _LiveHomePageState extends State<LiveHomePage> {
  String toastString = S.current.loading;

  PlayChannelListModel? _channelListModel;

  Channel? _currentChannel;

  int _sourceIndex = 0;

  VideoPlayerController? _playerController;

  /// 起播令牌：每次切换播放自增，用于作废过期的异步回调
  int _playToken = 0;

  /// 已处理过失败的控制器，避免监听器与 catch 对同一次失败重复计数
  VideoPlayerController? _handledFailedController;

  bool isBuffering = false;

  bool isPlaying = false;
  double aspectRatio = 16/9;

  bool _drawerIsOpen = false;

  int _channelSerialNum = 1;

  Future<void> _playVideo(String entMsg) async {
    final channel = _currentChannel;
    if (channel == null) return;
    final urls = channel.urls;
    if (urls == null || urls.isEmpty) {
      _playToken++;
      if (!mounted) return;
      setState(() {
        toastString = S.current.playError(channel.title ?? '');
      });
      return;
    }
    // 每次起播递增令牌：异步过程中若又切了台或页面已销毁，旧请求自行作废
    final token = ++_playToken;
    _channelSerialNum = channel.serialNum ?? 1;
    var timeoutNum = 15;
    if (mounted) {
      context.read<ThemeProvider>().setPrePlaySerialNum(_channelSerialNum);
      timeoutNum = context.read<ThemeProvider>().timeoutSwitchLine;
    }
    if (_sourceIndex < 0 || _sourceIndex >= urls.length) {
      _sourceIndex = 0;
    }
    final url = urls[_sourceIndex];
    if (!mounted) return;
    setState(() {
      toastString = S.current.lineToast(_sourceIndex + 1, channel.title ?? '');
    });
    LogUtil.v('PlayVideo:【$entMsg】正在播放:$_sourceIndex::$url');

    // 旧控制器无条件释放（含初始化未完成的情况），避免原生播放器泄漏
    final oldController = _playerController;
    _playerController = null;
    _disposeController(oldController);
    if (!mounted || token != _playToken) return;

    LogUtil.v('检测User-Agent::::::${_channelListModel?.uaHint}');
    final httpHeader = <String, String>{};
    final uaHint = _channelListModel?.uaHint;
    if (uaHint != null && uaHint.isNotEmpty) {
      httpHeader['User-Agent'] = uaHint;
    }

    VideoPlayerController? pendingController;
    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(url),
        videoPlayerOptions: VideoPlayerOptions(
          allowBackgroundPlayback: false,
          mixWithOthers: false,
          webOptions: const VideoPlayerWebOptions(controls: VideoPlayerWebOptionsControls.enabled()),
        ),
        httpHeaders: httpHeader,
      );
      pendingController = controller;
      await controller.initialize().timeout(
        Duration(seconds: timeoutNum),
        onTimeout: () {
          LogUtil.v('视频初始化超时');
          throw TimeoutException('Video initialization timeout', Duration(seconds: timeoutNum));
        },
      );
      await controller.setVolume(1.0);
      if (!mounted || token != _playToken) {
        // 期间用户已切台或页面已销毁，丢弃本次结果
        _disposeController(controller);
        return;
      }
      _playerController = controller;
      _handledFailedController = null;
      controller.addListener(_videoListener);
      await controller.play();
      if (!mounted || token != _playToken) return;
      // play() 期间监听器可能已经处理过失败并切走，这里不要再把提示盖回“正在加载”
      if (!identical(_playerController, controller) || identical(_handledFailedController, controller)) return;
      final controllerAspectRatio = controller.value.aspectRatio;
      setState(() {
        toastString = S.current.loading;
        aspectRatio = controllerAspectRatio > 0 ? controllerAspectRatio : 16 / 9;
      });
    } catch (e) {
      LogUtil.v('播放出错:::::$e');
      if (!mounted || token != _playToken) {
        // 本次请求已过期，只需要清理自己的控制器
        _disposeController(pendingController);
        return;
      }
      await _handlePlayFailure(pendingController, allowReconnect: false);
    }
  }

  /// 释放控制器但不阻塞调用方：初始化超时的 controller 调 dispose 可能长时间不返回
  void _disposeController(VideoPlayerController? controller) {
    if (controller == null) return;
    controller.removeListener(_videoListener);
    if (identical(_playerController, controller)) {
      _playerController = null;
    }
    unawaited(_disposeControllerAsync(controller));
  }

  Future<void> _disposeControllerAsync(VideoPlayerController controller) async {
    try {
      await controller.dispose();
    } catch (error) {
      LogUtil.v('释放播放器异常::::$error');
    }
  }

  /// 播放失败统一入口：同一次失败只处理一次，避免一次错误连跳两条线路
  Future<void> _handlePlayFailure(VideoPlayerController? failedController, {required bool allowReconnect}) async {
    if (failedController != null) {
      if (identical(_handledFailedController, failedController)) return;
      _handledFailedController = failedController;
      _disposeController(failedController);
    }
    final channel = _currentChannel;
    final urls = channel?.urls;
    if (!mounted || channel == null || urls == null || urls.isEmpty) return;
    final token = _playToken;
    _sourceIndex += 1;
    if (_sourceIndex >= urls.length) {
      _sourceIndex = 0;
      if (!allowReconnect) {
        setState(() {
          toastString = S.current.playError(channel.title ?? '');
        });
        return;
      }
      setState(() {
        toastString = S.current.playReconnect;
      });
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted || token != _playToken || !identical(_currentChannel, channel)) return;
      await _playVideo('videoListener事件监听进入:触发播放重连:::');
      return;
    }
    setState(() {
      toastString = '${S.current.switchLine(_sourceIndex + 1)}...';
    });
    await Future.delayed(const Duration(seconds: 2));
    if (!mounted || token != _playToken || !identical(_currentChannel, channel)) return;
    await _playVideo('videoListener事件监听进入:触发切换线路:::');
  }

  Future<void> _videoListener() async {
    final controller = _playerController;
    if (controller == null || !mounted) return;
    final value = controller.value;
    if (value.hasError && !value.isCompleted) {
      // 摘监听、计数、换线统一在 _handlePlayFailure 里做，避免同一错误被处理两次
      await _handlePlayFailure(controller, allowReconnect: value.errorDescription == null);
      return;
    }
    if (isBuffering != value.isBuffering) {
      setState(() {
        isBuffering = value.isBuffering;
      });
    }

    if (isPlaying != value.isPlaying) {
      setState(() {
        isPlaying = value.isPlaying;
      });
    }
  }

  void _onTapChannel(Channel? model) {
    if (model == null) return;
    final urls = model.urls;
    if (urls == null || urls.isEmpty) {
      EasyLoading.showToast(S.current.playError(model.title ?? ''));
      return;
    }
    _currentChannel = model;
    _sourceIndex = 0;
    final channelListModel = _channelListModel;
    if (channelListModel != null) {
      channelListModel.playGroupIndex = model.groupIndex;
      channelListModel.playChannelIndex = model.channelIndex;
    }
    LogUtil.v('切换频道:::::${model.toJson()}');
    _playVideo('onTapChannel方法进入');
  }

  @override
  void initState() {
    super.initState();
    EasyLoading.instance
      ..loadingStyle = EasyLoadingStyle.custom
      ..indicatorColor = Colors.black
      ..textColor = Colors.black
      ..backgroundColor = Colors.white70;
    // if (!EnvUtil.isMobile) windowManager.setTitleBarStyle(TitleBarStyle.hidden);
    Future.delayed(Duration.zero, _loadData);
  }

  _loadData() async {
    await RemoteUtil.getRemoteData(context);
    await _parseData(true);
    if (mounted) {
      if (context.read<ThemeProvider>().useAutoUpdate && Platform.isAndroid) {
        final url = await CheckVersionUtil.checkVersionAndAutoUpdate();
        if (mounted && url != null) {
          EasyLoading.showToast('新版本开始下载，稍后为您自动安装', toastPosition: EasyLoadingToastPosition.top);
          context.read<DownloadProvider>().downloadApk(url);
        }
      } else {
        if (context.read<ThemeProvider>().useLightVersionCheck) {
          CheckVersionUtil.checkLightVersion();
        } else {
          CheckVersionUtil.checkVersion(context, false, false);
        }
      }
    }
  }

  @override
  void dispose() {
    _playToken++; // 让所有仍在进行的起播流程作废
    _disposeController(_playerController);
    WakelockPlus.disable();
    super.dispose();
  }

  _parseData([bool isSkipRestSerialNum = false]) async {
    final resMap = await M3uUtil.getDefaultM3uData();
    if (!mounted) return;
    _channelListModel = resMap;
    _sourceIndex = 0;
    if (!isSkipRestSerialNum) {
      context.read<ThemeProvider>().setPrePlaySerialNum(1);
    }
    if ((_channelListModel?.playList?.isNotEmpty) ?? false) {
      final preNum = context.read<ThemeProvider>().prePlaySerialNum;
      final channel = M3uUtil.serialNumMap[preNum.toString()] ?? M3uUtil.serialNumMap['1'];
      if (channel != null) {
        _onTapChannel(channel);
      }
      if (_channelListModel!.type == PlayListType.m3u) {
        final epgUrl = _channelListModel?.epgUrl;
        if (epgUrl != null && epgUrl.isNotEmpty) {
          EpgUtil.loadEPGXML(epgUrl);
        }
      }
    } else {
      _playToken++;
      _disposeController(_playerController);
      setState(() {
        _currentChannel = null;
        toastString = 'UNKNOWN';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (EnvUtil.isTV()) {
      return TvPage(
        channelSerialNum: _channelSerialNum,
        channelListModel: _channelListModel,
        onTapChannel: _onTapChannel,
        toastString: toastString,
        controller: _playerController,
        isBuffering: isBuffering,
        isPlaying: isPlaying,
        aspectRatio: aspectRatio,
        onChangeSubSource: _parseData,
        changeChannelSources: _changeChannelSources,
      );
    }
    return Material(
      child: OrientationLayoutBuilder(
        portrait: (context) {
          SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
          return MobileVideoWidget(
            toastString: toastString,
            controller: _playerController,
            changeChannelSources: _changeChannelSources,
            isLandscape: false,
            isBuffering: isBuffering,
            isPlaying: isPlaying,
            aspectRatio: aspectRatio,
            onChangeSubSource: _parseData,
            drawChild: ChannelDrawerPage(channelListModel: _channelListModel, onTapChannel: _onTapChannel, isLandscape: false),
            onPreviousChannel: _previousChannel,
            onNextChannel: _nextChannel,
            onSwitchSource: _switchSource,
          );
        },
        landscape: (context) {
          SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
          return PopScope(
            canPop: false,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) {
                SystemChrome.setPreferredOrientations([
                  DeviceOrientation.portraitUp,
                  DeviceOrientation.landscapeLeft,
                  DeviceOrientation.landscapeRight,
                ]);
              }
            },
            child: Scaffold(
              drawer: ChannelDrawerPage(channelListModel: _channelListModel, onTapChannel: _onTapChannel, isLandscape: true),
              drawerEdgeDragWidth: MediaQuery.of(context).size.width * 0.3,
              drawerScrimColor: Colors.transparent,
              onDrawerChanged: (bool isOpened) {
                setState(() {
                  _drawerIsOpen = isOpened;
                });
              },
              body: Builder(
                builder: (context) {
                  return CallbackShortcuts(
                    bindings: <ShortcutActivator, VoidCallback>{
                      const SingleActivator(LogicalKeyboardKey.arrowUp): _previousChannel,
                      const SingleActivator(LogicalKeyboardKey.arrowDown): _nextChannel,
                      const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _pushChannelDrawer(context),
                      const SingleActivator(LogicalKeyboardKey.arrowRight): () => _switchSource(),
                      const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true): () => _changeChannelSources(),
                      if (Platform.isMacOS) const SingleActivator(LogicalKeyboardKey.comma, meta: true): () => _pushSettingPage(context),
                      if (Platform.isWindows || Platform.isLinux)
                        const SingleActivator(LogicalKeyboardKey.comma, control: true): () => _pushSettingPage(context),
                    },
                    child: Focus(
                      autofocus: true,
                      child: toastString == 'UNKNOWN'
                          ? InkWell(
                              canRequestFocus: false,
                              onTap: _parseData,
                              // onHover: (bool isHover) {
                              //   if (isHover) {
                              //     windowManager.setTitleBarStyle(TitleBarStyle.hidden, windowButtonVisibility: true);
                              //   } else {
                              //     windowManager.setTitleBarStyle(TitleBarStyle.hidden, windowButtonVisibility: false);
                              //   }
                              // },
                              child: EmptyPage(
                                onRefresh: _parseData,
                                onEnterSetting: () async {
                                  await M3uUtil.openAddSource(context);
                                  _parseData();
                                },
                              ),
                            )
                          : TableVideoWidget(
                              toastString: toastString,
                              controller: _playerController,
                              isBuffering: isBuffering,
                              isPlaying: isPlaying,
                              aspectRatio: aspectRatio,
                              drawerIsOpen: _drawerIsOpen,
                              changeChannelSources: _changeChannelSources,
                              onChangeSubSource: _parseData,
                              isLandscape: true,
                              onPreviousChannel: _previousChannel,
                              onNextChannel: _nextChannel,
                              onSwitchSource: _switchSource,
                            ),
                    ),
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _changeChannelSources([FocusNode? videoNode]) async {
    LogUtil.v('_changeChannelSources:::::::::::');
    final channel = _currentChannel;
    final sources = channel?.urls;
    if (channel == null || sources == null || sources.isEmpty) {
      if (mounted) EasyLoading.showToast('🤣没有更多线路！');
      return;
    }
    videoNode?.unfocus();
    final selectedIndex = await showModalBottomSheet(
      context: context,
      useRootNavigator: true,
      barrierColor: Colors.transparent,
      backgroundColor: Colors.black87,
      builder: (BuildContext context) {
        return SingleChildScrollView(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.only(left: 20, right: 20, top: 20, bottom: 40),
            color: Colors.transparent,
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              children: List.generate(sources.length, (index) {
                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    FocusButton(
                      autofocus: _sourceIndex == index,
                      onTap: _sourceIndex == index
                          ? null
                          : () {
                              Navigator.pop(context, index);
                            },
                      title: S.current.lineIndex(index + 1),
                      selected: _sourceIndex == index,
                    ),
                    Positioned(
                      top: -2,
                      right: 8,
                      child: FutureBuilder<Color>(
                        future: LatencyCheckerUtil.checkLatencies(sources[index]),
                        initialData: Colors.transparent,
                        builder: (BuildContext context, AsyncSnapshot<Color> snapshot) {
                          return Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(color: snapshot.data, borderRadius: BorderRadius.circular(4)),
                          );
                        },
                      ),
                    ),
                  ],
                );
              }),
            ),
          ),
        );
      },
    );
    if (!mounted) return;
    videoNode?.requestFocus();
    if (selectedIndex != null && _sourceIndex != selectedIndex) {
      _sourceIndex = selectedIndex;
      LogUtil.v('切换线路:====线路${_sourceIndex + 1}');
      _playVideo('changeChannelSources方法进入');
    }
  }

  _nextChannel() async {
    if (toastString == 'UNKNOWN') return;
    final channelListModel = _channelListModel;
    if (channelListModel == null) return;
    final lastIndex = _channelSerialNum + 1;
    final channel = M3uUtil.serialNumMap[lastIndex.toString()];
    if (channel != null) {
      channelListModel.playChannelIndex = channel.channelIndex;
      channelListModel.playGroupIndex = channel.groupIndex;
      _onTapChannel.call(channel);
    } else {
      EasyLoading.showToast('已是最后一个节目');
    }
  }

  _previousChannel() async {
    if (toastString == 'UNKNOWN') return;
    final channelListModel = _channelListModel;
    if (channelListModel == null) return;
    final lastIndex = _channelSerialNum - 1;
    final channel = M3uUtil.serialNumMap[lastIndex.toString()];
    if (channel != null) {
      channelListModel.playChannelIndex = channel.channelIndex;
      channelListModel.playGroupIndex = channel.groupIndex;
      _onTapChannel.call(channel);
    } else {
      EasyLoading.showToast('已是第一个节目');
    }
  }

  _switchSource() async {
    if (toastString == 'UNKNOWN') return;
    final channel = _currentChannel;
    final urls = channel?.urls;
    if (channel == null || urls == null || urls.isEmpty) return;
    if (urls.length == 1) {
      EasyLoading.showToast('🤣只有一条线路，正在重试');
      _sourceIndex = 0;
      await _playVideo('switchSource点击屏幕切换线路方法进入');
      return;
    }
    _sourceIndex = (_sourceIndex + 1) % urls.length;
    await _playVideo('switchSource点击屏幕切换线路方法进入');
  }

  _pushSettingPage(BuildContext context) async {
    LogUtil.v('设置：：：：');
    _playerController?.pause();
    await M3uUtil.openAddSource(context);
    final isChange = await M3uUtil.isChangeChannelLink();
    if (isChange) {
      _parseData();
    } else {
      _playerController?.play();
    }
  }

  _pushChannelDrawer(BuildContext context) {
    if (toastString == 'UNKNOWN') return;
    LogUtil.v('节目菜单：：：：');
    Scaffold.of(context).openDrawer();
  }
}

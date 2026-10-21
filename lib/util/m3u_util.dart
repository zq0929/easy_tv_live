import 'dart:async';
import 'dart:io';

import 'package:easy_tv_live/entity/play_channel_list_model.dart';
import 'package:easy_tv_live/util/date_util.dart';
import 'package:easy_tv_live/util/env_util.dart';
import 'package:easy_tv_live/util/http_util.dart';
import 'package:flutter/material.dart';
import 'package:flutter_easyloading_plus/flutter_easyloading_plus.dart';
import 'package:sp_util/sp_util.dart';

import '../entity/sub_scribe_model.dart';
import '../generated/l10n.dart';
import '../tv/tv_setting_page.dart';
import 'log_util.dart';

class M3uUtil {
  M3uUtil._();

  static final Map<String, Channel> _serialNumMap = {};

  static Map<String, Channel> get serialNumMap => _serialNumMap;

  static String? currentPlayChannelLink = '';

  /// 支持的直播协议（兼容 "scheme://" 与 "scheme/xxx" 两种写法）
  static const Set<String> _liveSchemes = {
    'http',
    'https',
    'rtmp',
    'rtmps',
    'rtsp',
    'rtp',
    'udp',
    'p3p',
    'mms',
    'ws',
    'wss',
    'srt',
    'file',
  };

  /// 任意 scheme:// 形式的播放地址（具体协议交给播放器判断）
  static final RegExp _schemeLinkRegExp = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*://');

  /// 形如 key="value"、key='value' 或 key=value 的属性
  /// 分组：1=key，2=整体值，3=双引号值，4=单引号值，5=裸值
  static final RegExp _attributeRegExp = RegExp(r"""([A-Za-z0-9_-]+)=("([^"]*)"|'([^']*)'|([^\s,"']+))""");

  // 获取默认的m3u文件
  static Future<PlayChannelListModel?> getDefaultM3uData() async {
    _serialNumMap.clear();
    String m3uData = '';
    final models = await getLocalData();
    if (models.isNotEmpty) {
      final defaultModel = models.firstWhere((element) => element.selected == true, orElse: () => models.first);
      currentPlayChannelLink = defaultModel.link;
      if (defaultModel.local == true) {
        final localLink = defaultModel.link;
        if (localLink == null || localLink.isEmpty) {
          EasyLoading.showToast(S.current.noFile);
          return null;
        }
        final m3uFile = File(localLink);
        final isExit = await m3uFile.exists();
        LogUtil.v('本地数据是否存在$localLink::::::$isExit');
        if (isExit) {
          m3uData = await m3uFile.readAsString();
          await SpUtil.putString('m3u_cache', m3uData);
        } else {
          EasyLoading.showToast(S.current.noFile);
          return null;
        }
      } else {
        final rawLink = defaultModel.link;
        final isBuiltIn = rawLink == null || rawLink.isEmpty || rawLink == 'default';
        final link = isBuiltIn ? EnvUtil.videoDefaultChannelHost() : rawLink;
        if (isBuiltIn) {
          // 内置源约 780KB 且源站较慢：命中缓存时先秒开，再后台静默刷新（下次启动生效）
          final cachedLink = SpUtil.getString(_cacheLinkKey, defValue: '');
          final cachedData = SpUtil.getString(_cacheKey, defValue: '');
          if (cachedLink == link && cachedData != null && cachedData.isNotEmpty) {
            LogUtil.v('内置源命中缓存，后台刷新::::::');
            m3uData = cachedData;
            unawaited(_refreshSourceCache(link, isShowLoading: false));
          }
        }
        if (m3uData.isEmpty) {
          final newRes = await _loadSource(link, isShowLoading: isBuiltIn);
          if (newRes != null && newRes.isNotEmpty) {
            LogUtil.v('已获取新数据::::::');
            m3uData = newRes;
            await _saveSourceCache(link, m3uData);
          } else {
            final oldRes = SpUtil.getString(_cacheKey, defValue: '');
            if (oldRes != null && oldRes.isNotEmpty) {
              LogUtil.v('已获取到历史保存的数据::::::');
              m3uData = oldRes;
            }
          }
        }
      }
      if (m3uData.isEmpty) {
        return null;
      }
    } else {
      m3uData = await _fetchData();
      final defaultModel = SubScribeModel(
        time: DateUtil.formatDate(DateTime.now(), format: DateFormats.full),
        link: 'default',
        selected: true,
      );
      await saveLocalData([defaultModel]);
      currentPlayChannelLink = defaultModel.link;
    }
    String ua = '';
    final currentLink = currentPlayChannelLink;
    if (currentLink != null && currentLink.startsWith('http')) {
      try {
        ua = Uri.parse(currentLink).queryParameters['ua'] ?? '';
      } catch (e) {
        LogUtil.v('解析订阅链接UA参数失败::::$e');
      }
    }
    final channelModels = await _parseM3u(m3uData, ua);
    final playList = channelModels.playList;
    if (playList != null && playList.isNotEmpty) {
      int index = 1;
      for (int i = 0; i < playList.length; i++) {
        final playModel = playList[i];
        final channels = playModel.channel;
        if (channels == null || channels.isEmpty) continue;
        for (int j = 0; j < channels.length; j++) {
          final channel = channels[j];
          // 没有可用线路的频道不参与播放与选台，避免播放时取下标越界
          if (channel.urls == null || channel.urls!.isEmpty) continue;
          channel.serialNum = index;
          channel.groupIndex = i;
          channel.channelIndex = j;
          _serialNumMap[index.toString()] = channel;
          index += 1;
        }
      }
    }
    return channelModels;
  }

  static Future<bool> isChangeChannelLink() async {
    final models = await getLocalData();
    if (models.isEmpty) return false;
    final defaultModel = models.firstWhere((element) => element.selected == true, orElse: () => models.first);
    return currentPlayChannelLink != defaultModel.link;
  }

  // 获取本地m3u数据
  static Future<List<SubScribeModel>> getLocalData() async {
    return SpUtil.getObjList('local_m3u', (v) => SubScribeModel.fromJson(v), defValue: <SubScribeModel>[]) ?? <SubScribeModel>[];
  }

  // 保存本地m3u数据
  static Future<bool> saveLocalData(List<SubScribeModel> models) async {
    final res = await SpUtil.putObjectList('local_m3u', models.map((e) => e.toJson()).toList());
    return res ?? false;
  }

  static const String _cacheKey = 'm3u_cache';
  static const String _cacheLinkKey = 'm3u_cache_link';

  /// 下载直播源文本（源文件较大，使用更宽松的超时）
  static Future<String?> _loadSource(String link, {required bool isShowLoading}) async {
    if (isShowLoading) EasyLoading.show(status: '正在加载内置源，请稍候…');
    try {
      return await HttpUtil().getSourceText(link, isShowLoading: false);
    } finally {
      if (isShowLoading) EasyLoading.dismiss();
    }
  }

  static Future<void> _saveSourceCache(String link, String data) async {
    await SpUtil.putString(_cacheKey, data);
    await SpUtil.putString(_cacheLinkKey, link);
  }

  /// 后台刷新内置源缓存，失败时静默保留旧缓存
  static Future<void> _refreshSourceCache(String link, {required bool isShowLoading}) async {
    final data = await _loadSource(link, isShowLoading: isShowLoading);
    if (data == null || data.isEmpty) return;
    await _saveSourceCache(link, data);
    LogUtil.v('内置源缓存已刷新::::::${data.length}');
  }

  static Future<String> _fetchData() async {
    final defaultM3u = EnvUtil.videoDefaultChannelHost();
    final res = await _loadSource(defaultM3u, isShowLoading: true);
    if (res == null || res.isEmpty) {
      EasyLoading.showToast(S.current.getDefaultError);
      return '';
    }
    await _saveSourceCache(defaultM3u, res);
    return res;
  }

  static bool isLiveLink(String link) {
    final tLink = link.trim().toLowerCase();
    if (tLink.isEmpty) return false;
    if (_schemeLinkRegExp.hasMatch(tLink)) return true;
    // 兼容 udp/239.1.1.1:1234、rtp/239.1.1.1:1234 这类省略 "://" 的写法
    final slashIndex = tLink.indexOf('/');
    if (slashIndex > 0) {
      final scheme = tLink.substring(0, slashIndex);
      if (_liveSchemes.contains(scheme)) return true;
    }
    return false;
  }

  // 解析m3u文件
  static Future<PlayChannelListModel> _parseM3u(String m3u, String ua) async {
    final lines = _normalizeLines(m3u);
    final playListModel = PlayChannelListModel(type: PlayListType.txt, playList: [], uaHint: ua);
    // #EXTM3U 是标准头；没有头时要求“既有 #EXTINF 又有独立的链接行”，避免把带注释的 txt 误判
    final bool hasExtM3u = lines.any((line) => line.toLowerCase().startsWith('#extm3u'));
    final bool hasExtInf = lines.any((line) => line.toLowerCase().startsWith('#extinf'));
    final bool hasBareLink = lines.any((line) => !line.startsWith('#') && isLiveLink(line));
    final bool isM3uContent = hasExtM3u || (hasExtInf && hasBareLink);

    final groupModels = <String, PlayModel>{};
    PlayModel groupModel(String group) {
      return groupModels.putIfAbsent(group, () {
        final model = PlayModel(group: group, channel: []);
        playListModel.playList!.add(model);
        return model;
      });
    }

    Channel channelModel(String group, String title, {String? id, String? logo}) {
      final model = groupModel(group);
      final channels = model.channel!;
      for (final channel in channels) {
        if (channel.title == title) return channel;
      }
      final channel = Channel(id: id, logo: logo, title: title, urls: []);
      channels.add(channel);
      return channel;
    }

    if (isM3uContent) {
      playListModel.type = PlayListType.m3u;
      String currentGroup = S.current.defaultText;
      Channel? currentChannel;
      for (final line in lines) {
        final lowerLine = line.toLowerCase();
        if (lowerLine.startsWith('#extm3u')) {
          final attrs = _parseAttributes(line.substring(_extM3uPrefixLength));
          final tvgUrl = (attrs['x-tvg-url'] ?? attrs['url-tvg'] ?? '').trim();
          if (tvgUrl.isNotEmpty) {
            playListModel.epgUrl = tvgUrl;
          }
          continue;
        }
        if (lowerLine.startsWith('#extinf')) {
          final info = _parseExtInf(line);
          currentGroup = info.group;
          currentChannel = channelModel(currentGroup, info.title, id: info.channelId, logo: info.logo);
          continue;
        }
        if (lowerLine.startsWith('#ua-hint')) {
          if (ua.isEmpty) {
            final hint = line.substring(_uaHintPrefixLength).trim();
            if (hint.isNotEmpty) {
              playListModel.uaHint = hint;
            }
          }
          continue;
        }
        if (lowerLine.startsWith('#')) {
          // #EXTVLCOPT、#EXTGRP 等其它指令行直接跳过
          continue;
        }
        if (currentChannel == null || !isLiveLink(line)) {
          continue;
        }
        // 一个频道下可能有多条线路，用 # 分隔或写成多行
        for (final item in line.split('#')) {
          final url = item.trim();
          if (url.isEmpty || !isLiveLink(url)) continue;
          if (!currentChannel.urls!.contains(url)) {
            currentChannel.urls!.add(url);
          }
        }
      }
    } else {
      String tempGroup = S.current.defaultText;
      for (int i = 0; i < lines.length; i++) {
        final line = lines[i];
        final lowerLine = line.toLowerCase();
        if (lowerLine.startsWith('#ua-hint')) {
          if (ua.isEmpty) {
            final hint = line.substring(_uaHintPrefixLength).trim();
            if (hint.isNotEmpty) {
              playListModel.uaHint = hint;
            }
          }
          continue;
        }
        if (lowerLine.startsWith('#')) continue;
        final commaIndex = line.indexOf(',');
        if (commaIndex <= 0) continue;
        var name = line.substring(0, commaIndex).trim();
        var linkPart = line.substring(commaIndex + 1).trim();
        if (!isLiveLink(linkPart)) {
          // 兼容 "CCTV-1,综合,http://..." 这种频道名里带逗号的写法：判断最后一个逗号后是否为直链
          final lastCommaIndex = line.lastIndexOf(',');
          if (lastCommaIndex > commaIndex) {
            final maybeLink = line.substring(lastCommaIndex + 1).trim();
            if (isLiveLink(maybeLink)) {
              name = line.substring(0, lastCommaIndex).trim();
              linkPart = maybeLink;
            }
          }
        }
        if (linkPart.isEmpty) continue;
        if (isLiveLink(linkPart)) {
          // 旧实现用名称同时作为 id 与标题，这里保持兼容（EPG 匹配依赖 id）
          final channel = channelModel(tempGroup, name, id: name);
          // 支持 "名称,url1,url2"：只有当逗号分隔的每一段都是直链时才拆分
          final commaParts = linkPart.split(',').map((item) => item.trim()).toList();
          final candidates = commaParts.length > 1 && commaParts.every(isLiveLink) ? commaParts : <String>[linkPart];
          for (final candidate in candidates) {
            for (final item in candidate.split('#')) {
              final url = item.trim();
              if (url.isEmpty || !isLiveLink(url)) continue;
              if (!channel.urls!.contains(url)) {
                channel.urls!.add(url);
              }
            }
          }
        } else {
          tempGroup = name.isEmpty ? '${S.current.defaultText}${i + 1}' : name;
        }
      }
    }

    // 清理解析过程中产生的空频道与空分组，避免播放端拿到空 urls
    for (final model in playListModel.playList!) {
      model.channel?.removeWhere((channel) => channel.urls == null || channel.urls!.isEmpty);
    }
    playListModel.playList!.removeWhere((model) => model.channel == null || model.channel!.isEmpty);

    if (playListModel.playList!.isEmpty) {
      EasyLoading.showError(S.current.parseError);
    }
    final uaHint = playListModel.uaHint;
    if (uaHint != null && uaHint.isNotEmpty) EasyLoading.showToast('User-Agent=$uaHint');
    return playListModel;
  }

  /// 统一换行符（兼容 CRLF/CR）、去掉 BOM、逐行 trim 并丢弃空行
  static List<String> _normalizeLines(String m3u) {
    final content = m3u.replaceFirst('\uFEFF', '').replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    return content
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
  }

  static const int _extM3uPrefixLength = 7; // '#EXTM3U'
  static const int _uaHintPrefixLength = 8; // '#UA-Hint'

  /// 解析 #EXTINF 行：属性部分 + 引号外的第一个逗号之后的频道名
  static _ExtInf _parseExtInf(String line) {
    final body = line.substring('#EXTINF'.length);
    String attrPart = body;
    String title = '';
    String? activeQuote;
    for (int i = 0; i < body.length; i++) {
      final char = body[i];
      if (activeQuote != null) {
        if (char == activeQuote) activeQuote = null;
        continue;
      }
      if (char == '"' || char == "'") {
        activeQuote = char;
        continue;
      }
      if (char == ',') {
        attrPart = body.substring(0, i);
        title = body.substring(i + 1).trim();
        break;
      }
    }
    final attrs = _parseAttributes(attrPart);
    var group = (attrs['group-title'] ?? '').trim();
    if (group.isEmpty) group = S.current.defaultText;
    // EPG 的 XMLTV channel 属性通常是 tvg-id，优先用它，tvg-name 只做兜底
    var channelId = (attrs['tvg-id'] ?? '').trim();
    if (channelId.isEmpty) channelId = (attrs['tvg-name'] ?? '').trim();
    return _ExtInf(
      title: title.isEmpty ? (channelId.isEmpty ? S.current.defaultText : channelId) : title,
      group: group,
      channelId: channelId,
      logo: (attrs['tvg-logo'] ?? '').trim(),
    );
  }

  static Map<String, String> _parseAttributes(String attrText) {
    final attrs = <String, String>{};
    for (final match in _attributeRegExp.allMatches(attrText)) {
      final key = (match.group(1) ?? '').toLowerCase();
      if (key.isEmpty) continue;
      attrs[key] = match.group(3) ?? match.group(4) ?? match.group(5) ?? '';
    }
    return attrs;
  }

  static Future<bool?> openAddSource(BuildContext context) async {
    return Navigator.push<bool>(
      context,
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) {
          return const TvSettingPage();
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          var begin = const Offset(0.0, -1.0);
          var end = Offset.zero;
          var curve = Curves.ease;

          var tween = Tween(begin: begin, end: end).chain(CurveTween(curve: curve));

          return SlideTransition(position: animation.drive(tween), child: child);
        },
      ),
    );
  }
}

class _ExtInf {
  const _ExtInf({required this.title, required this.group, required this.channelId, required this.logo});

  final String title;
  final String group;
  final String channelId;
  final String logo;
}

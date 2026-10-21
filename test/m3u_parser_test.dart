import 'dart:io';

import 'package:easy_tv_live/entity/sub_scribe_model.dart';
import 'package:easy_tv_live/generated/l10n.dart';
import 'package:easy_tv_live/util/m3u_util.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sp_util/sp_util.dart';

Future<String> _writeTemp(String name, String content) async {
  final dir = await Directory.systemTemp.createTemp('m3u_test');
  final file = File('${dir.path}/$name');
  await file.writeAsString(content);
  return file.path;
}

Future<void> _selectLocalSource(String path) async {
  await M3uUtil.saveLocalData([SubScribeModel(time: '2026-01-01', link: path, selected: true, local: true)]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await SpUtil.getInstance();
    await S.load(const Locale('zh'));
  });

  test('txt: CRLF + 多线路 + 空线路过滤', () async {
    final path = await _writeTemp('a.txt', '央视频道,#genre#\r\nCCTV-1,http://a/1\r\nCCTV-2,http://a/2#http://a/3\r\nCCTV-3\r\n');
    await _selectLocalSource(path);
    final model = await M3uUtil.getDefaultM3uData();
    expect(model, isNotNull);
    expect(model!.type!.name, 'txt');
    final groups = model.playList!;
    expect(groups.length, 1);
    expect(groups.first.group, '央视频道');
    expect(groups.first.channel!.length, 2);
    expect(groups.first.channel![0].urls, ['http://a/1']);
    expect(groups.first.channel![1].urls, ['http://a/2', 'http://a/3']);
    expect(M3uUtil.serialNumMap.length, 2);
    expect(M3uUtil.serialNumMap['1']!.title, 'CCTV-1');
    final allUrls = groups.expand((g) => g.channel!).expand((c) => c.urls!);
    expect(allUrls.any((u) => u.contains('\r')), isFalse);
  });

  test('m3u: CRLF + BOM + 引号属性 + 名字含逗号 + 无链接频道剔除', () async {
    final content = [
      '\uFEFF#EXTM3U x-tvg-url="http://epg.example/e.xml?a=1&b=2"',
      '#EXTINF:-1 tvg-id="c1" tvg-name="CCTV-1" tvg-logo="http://l/1.png" group-title="A, B",CCTV-1, 综合',
      '#EXTVLCOPT:network-caching=1000',
      'http://a/1',
      "#EXTINF:-1 group-title='地方' tvg-id='d1',卫视",
      'rtmp://x/y',
      '#EXTINF:-1,无链接频道',
      '#EXTINF:-1,末频道',
      'http://a/9',
    ].join('\r\n');
    final path = await _writeTemp('b.m3u', content);
    await _selectLocalSource(path);
    final model = await M3uUtil.getDefaultM3uData();
    expect(model!.type!.name, 'm3u');
    expect(model.epgUrl, 'http://epg.example/e.xml?a=1&b=2');
    final groups = model.playList!;
    // 无链接频道被剔除后，默认分组只剩“末频道”，分组本身保留
    expect(groups.map((g) => g.group), ['A, B', '地方', '默认']);
    expect(groups[0].channel!.single.id, 'c1');
    expect(groups[0].channel!.single.title, 'CCTV-1, 综合');
    expect(groups[0].channel!.single.urls, ['http://a/1']);
    expect(groups[1].channel!.single.title, '卫视');
    expect(groups[1].channel!.single.urls, ['rtmp://x/y']);
    expect(groups[2].channel!.single.title, '末频道');
    expect(groups[2].channel!.single.urls, ['http://a/9']);
    expect(groups.expand((g) => g.channel!).any((c) => c.title == '无链接频道'), isFalse);
  });

  test('空订阅列表不会崩', () async {
    await M3uUtil.saveLocalData([]);
    expect(await M3uUtil.isChangeChannelLink(), isFalse);
  });
}

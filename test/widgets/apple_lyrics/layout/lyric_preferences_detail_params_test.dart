import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// LyricPreferences「已播字上浮高度」参数的单元测试。
///
/// 锁定三件事：
/// 1. 默认值必须等于历史写死值 3.0（默认观感不得变）；
/// 2. 越界输入被 clamp 到声明范围；
/// 3. setter 落盘到约定的 SharedPreferences key（改名会静默丢用户设置）。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    addTearDown(() => LyricPreferences.instance.reset());
  });

  group('① 已播字上浮高度 liftHeightPx', () {
    test('默认 3.0（等于历史写死值 3px）', () {
      expect(LyricPreferences.instance.liftHeightPx,
          equals(LyricPreferences.defaultLiftHeightPx));
      expect(LyricPreferences.instance.liftHeightPx, equals(3.0));
    });

    test('setter 生效并 clamp 到 [0.0, 10.0]', () async {
      await LyricPreferences.instance.setLiftHeightPx(6.5);
      expect(LyricPreferences.instance.liftHeightPx, equals(6.5));

      await LyricPreferences.instance.setLiftHeightPx(999);
      expect(LyricPreferences.instance.liftHeightPx,
          equals(LyricPreferences.maxLiftHeightPx));

      await LyricPreferences.instance.setLiftHeightPx(-5);
      expect(LyricPreferences.instance.liftHeightPx,
          equals(LyricPreferences.minLiftHeightPx));
    });

    test('持久化到 lyric_lift_height_px', () async {
      await LyricPreferences.instance.setLiftHeightPx(4.5);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('lyric_lift_height_px'), equals(4.5));
    });

    test('reset 后回到默认值且 key 被移除', () async {
      await LyricPreferences.instance.setLiftHeightPx(9);

      await LyricPreferences.instance.reset();

      expect(LyricPreferences.instance.liftHeightPx,
          equals(LyricPreferences.defaultLiftHeightPx));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('lyric_lift_height_px'), isNull);
    });
  });

  group('④ 级联错峰起点 staggerFromCurrentLine', () {
    test('默认 true（从当前行开始错峰）', () {
      expect(LyricPreferences.instance.staggerFromCurrentLine, isTrue);
      expect(LyricPreferences.instance.staggerFromCurrentLine,
          equals(LyricPreferences.defaultStaggerFromCurrentLine));
    });

    test('setter 落盘到 lyric_stagger_from_current', () async {
      await LyricPreferences.instance.setStaggerFromCurrentLine(false);
      expect(LyricPreferences.instance.staggerFromCurrentLine, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('lyric_stagger_from_current'), isFalse);
    });

    test('reset 后回到默认 true 且 key 被移除', () async {
      await LyricPreferences.instance.setStaggerFromCurrentLine(false);
      await LyricPreferences.instance.reset();
      expect(LyricPreferences.instance.staggerFromCurrentLine, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('lyric_stagger_from_current'), isNull);
    });
  });

  /// 字内渐变模型（classic / sweep 二选一）：默认 classic、可持久化、reset 复位。
  ///
  /// classic 是本仓历史观感，**默认值绝不能变**；sweep 为 myune 扫光移植。
  group('⑤ 字内渐变样式 fillMode', () {
    test('默认 classic（历史观感不变）', () {
      expect(LyricPreferences.instance.fillMode, LyricFillMode.classic);
    });

    test('setFillMode 生效并 notifyListeners', () async {
      int notified = 0;
      void listener() => notified++;
      LyricPreferences.instance.addListener(listener);
      addTearDown(() => LyricPreferences.instance.removeListener(listener));

      await LyricPreferences.instance.setFillMode(LyricFillMode.sweep);
      expect(LyricPreferences.instance.fillMode, LyricFillMode.sweep);
      expect(notified, 1, reason: '值变化必须通知，歌词视图才能切到 sweep 模型');

      // 同值写入不再通知（沿用仓内 setter 的门控写法）
      await LyricPreferences.instance.setFillMode(LyricFillMode.sweep);
      expect(notified, 1);
    });

    test('持久化到 lyric_fill_mode', () async {
      await LyricPreferences.instance.setFillMode(LyricFillMode.sweep);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('lyric_fill_mode'), 'sweep');
    });

    test('load 读取已持久化的 lyric_fill_mode=sweep', () async {
      // 注意：LyricPreferences 是单例且 load() 有 _loaded 门控（同 isolate 只会
      // 真正读盘一次），故本文件只有这一处调用 load()；未知 / 缺失值回落 classic
      // 由 `_fillModeFromName`（仅 'sweep' → sweep）保证。
      SharedPreferences.setMockInitialValues(<String, Object>{
        'lyric_fill_mode': 'sweep',
      });
      await LyricPreferences.instance.load();
      expect(LyricPreferences.instance.fillMode, LyricFillMode.sweep);
    });

    test('reset 置 classic 且 key 被移除', () async {
      await LyricPreferences.instance.setFillMode(LyricFillMode.sweep);
      await LyricPreferences.instance.reset();
      expect(LyricPreferences.instance.fillMode, LyricFillMode.classic);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('lyric_fill_mode'), isNull);
    });
  });
}

import 'dart:async';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/core/services/player_frame_driver.dart';
import 'package:md3music/widgets/flowing_background.dart';
import 'package:md3music/widgets/flowing_gradient_painter.dart';

/// [FlowingBackground] 的驱动约定（AGENTS.md §10 / 功耗分析报告 P0-1、P0-2）：
///
/// - 流光必须挂在全局共享节拍 [PlayerFrameDriver] 上、每 2 拍推进一次（≈30fps），
///   不得再自建独立 `Timer.periodic`；
/// - 停帧判据必须覆盖「暂停」「被不透明路由覆盖（TickerMode=false）」「移出树」
///   三种场景，即解绑驱动 → `PlayerFrameDriver.instance.hasListeners == false`。
///
/// 全部用例只以 `hasListeners`（公开诊断属性）为观测点，不引入任何生产代码测试钩子。
void main() {
  // 结构保持稳定，只切 TickerMode.enabled —— 这样同一 State 被复用，
  // 才能真正走到 didChangeDependencies 的同步路径（而不是重建 initState）。
  Widget host(Widget child, {bool tickerEnabled = true}) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: TickerMode(
            enabled: tickerEnabled,
            child: SizedBox(width: 300, height: 600, child: child),
          ),
        ),
      ),
    );
  }

  // artworkUrl 传 null：不触发任何封面下载/取色，用例只关心驱动订阅状态。
  Widget flowing({bool isPlaying = true}) =>
      host(FlowingBackground(artworkUrl: null, isPlaying: isPlaying));

  setUp(() {
    expect(
      PlayerFrameDriver.instance.hasListeners,
      isFalse,
      reason: '用例之间不得残留共享节拍订阅（否则互相污染）',
    );
  });

  tearDown(() {
    expect(
      PlayerFrameDriver.instance.hasListeners,
      isFalse,
      reason: '用例结束必须已解绑（dispose/deactivate 不泄漏）',
    );
  });

  testWidgets('暂停时不挂共享节拍（完全静止）', (tester) async {
    await tester.pumpWidget(flowing(isPlaying: false));
    await tester.pump();
    // 跨过 400ms 入场延迟，确认"确实是因为没在播"而不是"还没到时间"。
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      PlayerFrameDriver.instance.hasListeners,
      isFalse,
      reason: 'isPlaying=false 时不得占用共享节拍',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('播放中：过完 400ms 入场延迟后挂共享节拍', (tester) async {
    await tester.pumpWidget(flowing());
    await tester.pump();

    expect(
      PlayerFrameDriver.instance.hasListeners,
      isFalse,
      reason: '入场延迟（400ms）走完之前不得开跑，避免与路由入场动画叠加',
    );

    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    expect(
      PlayerFrameDriver.instance.hasListeners,
      isTrue,
      reason: '播放中且可见时应挂共享 60fps 节拍，在回调内每 2 拍推进一次（§10.3）',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('TickerMode 关闭（被不透明路由覆盖）：不挂共享节拍', (tester) async {
    await tester.pumpWidget(
      host(FlowingBackground(artworkUrl: null, isPlaying: true),
          tickerEnabled: false),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      PlayerFrameDriver.instance.hasListeners,
      isFalse,
      reason: '被覆盖时必须停帧（§10.4.3：不可见仍持续 tick 是本仓最常见漏电点）',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('TickerMode 由关闭切回开启：经 didChangeDependencies 重新挂上',
      (tester) async {
    await tester.pumpWidget(
      host(FlowingBackground(artworkUrl: null, isPlaying: true),
          tickerEnabled: false),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(PlayerFrameDriver.instance.hasListeners, isFalse);

    // 同一 State 重建为 TickerMode(true)，等价于路由 pop / TabBarView 切回。
    await tester.pumpWidget(flowing());
    await tester.pump();

    expect(
      PlayerFrameDriver.instance.hasListeners,
      isTrue,
      reason: '重新可见必须立刻恢复驱动（依赖 didChangeDependencies 而非重建）',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('移出树后解绑，不留订阅', (tester) async {
    await tester.pumpWidget(flowing());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(PlayerFrameDriver.instance.hasListeners, isTrue);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    expect(
      PlayerFrameDriver.instance.hasListeners,
      isFalse,
      reason: 'dispose/deactivate 必须解绑，否则离屏仍持续产帧',
    );
  });

  /// shader 回退路径：测试环境（无 GPU）真实 `FragmentProgram` 不可用，因此把
  /// 加载器做成可注入的，验证「加载失败 → 永久回退到径向光斑 painter、不抛异常」。
  group('shader 不可用时的回退路径', () {
    setUp(FlowingBackground.debugResetShaderState);
    tearDown(FlowingBackground.debugResetShaderState);

    /// 是否存在回退 painter（随机森林：Material 自身也可能插 CustomPaint）。
    bool hasFallbackPainter(WidgetTester tester) => tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .any((widget) => widget.painter is FlowingGradientPainter);

    testWidgets('加载失败 → 走回退 painter、置不可用标记、不抛异常', (tester) async {
      FlowingBackground.debugProgramLoader = (String assetName) =>
          Future<ui.FragmentProgram>.error(StateError('test: no fragment shader'));

      await tester.pumpWidget(flowing(isPlaying: false));
      // 首帧后的 post-frame 回调触发异步加载；再 pump 一拍 flush 微任务
      await tester.pump();
      await tester.pump();

      expect(
        FlowingBackground.debugShaderUnavailable,
        isTrue,
        reason: '加载失败必须置永久回退标记',
      );
      expect(tester.takeException(), isNull, reason: 'shader 失败不得抛异常');
      expect(hasFallbackPainter(tester), isTrue,
          reason: '不可用时应绘制回退 painter（静态基底 + 径向光斑）');

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('已判定不可用（进入页面前置位）直接走回退，不再尝试加载', (tester) async {
      var loadAttempts = 0;
      FlowingBackground.debugMarkShaderUnavailable();
      FlowingBackground.debugProgramLoader = (String assetName) {
        loadAttempts++;
        return Future<ui.FragmentProgram>.error(StateError('should not run'));
      };

      await tester.pumpWidget(flowing(isPlaying: false));
      await tester.pump();
      await tester.pump();

      expect(loadAttempts, 0, reason: '已判定不可用时不得再发起加载');
      expect(hasFallbackPainter(tester), isTrue);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
    });
  });

  /// 频谱律动数据源（uMotion）：订阅窗口必须与共享节拍驱动窗口完全一致——
  /// 暂停 / 被不透明路由覆盖 / 移出树 / 入场延迟期都不得订阅，否则等于给
  /// 频谱服务多挂一个常驻 listener（AGENTS.md §10 的漏电点）。
  group('频谱律动订阅门控（uMotion 数据源）', () {
    late StreamController<List<double>> spectrum;

    setUp(() {
      spectrum = StreamController<List<double>>.broadcast();
      FlowingBackground.debugSpectrumStream = spectrum.stream;
    });

    tearDown(() async {
      FlowingBackground.debugSpectrumStream = null;
      await spectrum.close();
    });

    testWidgets('入场延迟内不订阅；驱动挂上后订阅；移出树退订', (tester) async {
      await tester.pumpWidget(flowing());
      await tester.pump();
      expect(spectrum.hasListener, isFalse,
          reason: '400ms 入场延迟内不得订阅频谱（省电）');

      await tester.pump(const Duration(milliseconds: 500));
      expect(spectrum.hasListener, isTrue, reason: '驱动挂上时必须同步订阅频谱');

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(spectrum.hasListener, isFalse, reason: '移出树必须退订');
    });

    testWidgets('暂停 / 恢复播放：订阅随之退订与重挂', (tester) async {
      await tester.pumpWidget(flowing());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(spectrum.hasListener, isTrue);

      await tester.pumpWidget(flowing(isPlaying: false));
      await tester.pump();
      expect(spectrum.hasListener, isFalse, reason: '暂停必须退订频谱');

      await tester.pumpWidget(flowing());
      await tester.pump();
      expect(spectrum.hasListener, isTrue, reason: '恢复播放应重新订阅');

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('频谱帧到达不抛异常（复用缓冲、只登记不插值）', (tester) async {
      await tester.pumpWidget(flowing());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      spectrum.add(List<double>.filled(40, 0.9));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 64));
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
    });
  });

  /// 真机 bug 回归：播放页被封面形变系统缓存复用（`pageBuilds=1`），播放/暂停
  /// **不会重建整页** → `isPlaying` 构造参数会永远停在挂载那一刻的值。真机日志
  /// 实证：`[FlowingBG] build … playing=false` 之后再无 build、`driver` 从未 bind、
  /// `paint t=0.00` 恒定（流光完全静止）。传 `playingStream` 后必须能自愈。
  group('播放态流（宿主不重建时的自愈路径）', () {
    late StreamController<bool> playing;

    setUp(() {
      playing = StreamController<bool>.broadcast();
    });

    tearDown(() async {
      await playing.close();
    });

    testWidgets('prop 恒为 false，流翻 true 后仍会挂上驱动', (tester) async {
      await tester.pumpWidget(
        host(FlowingBackground(
          artworkUrl: null,
          isPlaying: false,
          playingStream: playing.stream,
        )),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(PlayerFrameDriver.instance.hasListeners, isFalse,
          reason: '流未翻 true 前（prop=false）不得占用共享节拍');

      playing.add(true);
      await tester.pump();
      expect(PlayerFrameDriver.instance.hasListeners, isTrue,
          reason: '播放态流翻 true 必须挂上共享节拍，否则流光永远静止');

      playing.add(false);
      await tester.pump();
      expect(PlayerFrameDriver.instance.hasListeners, isFalse,
          reason: '流翻 false 必须立即停帧');

      await tester.pumpWidget(const SizedBox());
    });
  });

  /// 真机 bug 回归（根因）：`deactivate` 会取消入场延迟定时器，而播放页在
  /// 「跟手覆盖层 → 路由」的入场交接中会被重新挂载（GlobalKey 复用 →
  /// deactivate + activate）。若只在 initState 武装一次，`_initialDelayElapsed`
  /// 永远是 false，驱动四判据永远差这一闸 → 永不 bind、`t` 恒 0.00（完全静止）。
  /// 真机日志实证：`gates[ticker=true fg=true entry=false bound=false playing=true]`。
  group('入场交接被 deactivate 打断（entry 闸回归）', () {
    testWidgets('重新入树后补武装入场延迟，最终仍会挂上驱动', (tester) async {
      final GlobalKey flowKey = GlobalKey();

      await tester.pumpWidget(
        host(SizedBox(
          key: const ValueKey<String>('slot-a'),
          child: FlowingBackground(
            key: flowKey,
            artworkUrl: null,
            isPlaying: true,
          ),
        )),
      );
      // 入场延迟（400ms）还没走完就进入交接
      await tester.pump(const Duration(milliseconds: 100));
      expect(PlayerFrameDriver.instance.hasListeners, isFalse,
          reason: '入场延迟未走完不得开跑');

      // GlobalKey 复用 → 同帧 deactivate + activate（等价真机的页面交接）
      // 注意用定尺 SizedBox 换父节点，避免 FlowingBackground 在无界 Column 里溢出
      await tester.pumpWidget(
        host(SizedBox(
          key: const ValueKey<String>('slot-b'),
          width: 300,
          height: 600,
          child: FlowingBackground(
            key: flowKey,
            artworkUrl: null,
            isPlaying: true,
          ),
        )),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(PlayerFrameDriver.instance.hasListeners, isTrue,
          reason: '重新入树后必须补武装入场延迟并最终挂上驱动，否则流光永远静止');

      await tester.pumpWidget(const SizedBox());
    });
  });
}
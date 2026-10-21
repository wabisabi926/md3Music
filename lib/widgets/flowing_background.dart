import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../core/services/player_frame_driver.dart';
import '../core/services/rhythm_motion.dart';
import '../core/services/spectrum_service.dart';
import 'flowing_background_palette.dart';
import 'flowing_background_uniforms.dart';
import 'flowing_gradient_painter.dart';

/// 动态流光背景效果。
///
/// 显示效果对齐 myune_music_android-main 的 fluid background（4 个 pigment 场 +
/// 域扭曲 + vignette + 抖动），但保留本仓性能架构：
///
/// - 时间由共享节拍 [PlayerFrameDriver.instance] 每 2 拍推进一次（≈30fps），
///   不使用 `Ticker`、不自建 `Timer.periodic`；
/// - shader 可用时整屏**一次** `drawRect`（单次全屏 fragment pass，原回退实现
///   为 4 次：3 层径向光斑 + 基底）；
/// - 逐帧零分配：`Float32List` 复用、shader/Paint 常驻、只在 palette 变化时
///   重建 palette 相关数据；
/// - shader 加载失败/平台不支持时**永久回退**到 [FlowingGradientPainter]，
///   不弹错、不崩溃（设置页预览卡复用同一回退 painter）；
/// - `uMotion` 由仓库既有频谱流驱动（[RhythmMotionEnvelope]）：**无频谱数据时
///   恒为 1.0**（等价改动前的观感）；只消费频谱、绝不主动启动采集，且订阅窗口
///   与共享节拍驱动窗口完全同生命周期（暂停/不可见/后台零订阅）。
class FlowingBackground extends StatefulWidget {
  final String? artworkUrl;
  final bool isPlaying;

  /// 播放态流（可选，但**真机必须传**）。
  ///
  /// 播放页会被封面形变系统**缓存复用**（`pageBuilds=1`，见 `[CoverMorphPerf]`），
  /// 播放/暂停不会重建整页 → 只靠 [isPlaying] 这个构造参数，组件会永远停在
  /// 「挂载那一刻」的播放态。真机 `[FlowingBG]` 日志实证：页面在恢复播放前
  /// 挂载（`playing=false`），随后 `[PlayerState] playingStream → true` 但本组件
  /// 再也收不到重建，`_syncDriver` 永不 bind → `t=0.00` 恒定，**流光完全静止**。
  ///
  /// 传流后由组件自行订阅播放态（与 `SpectrumBackground` 自行订阅频谱同款口径），
  /// 不再依赖宿主重建；`null` 时退回纯 [isPlaying] 行为（测试/预览不受影响）。
  final Stream<bool>? playingStream;

  const FlowingBackground({
    super.key,
    this.artworkUrl,
    this.isPlaying = true,
    this.playingStream,
  });

  /// shader 资产路径（与 `pubspec.yaml` 的 `shaders:` 段、文件头对齐）。
  static const String shaderAsset = 'shaders/flowing_background.frag';

  // ── FragmentProgram 静态缓存（进程级，加载一次，永不释放）─────────────────

  /// 在途/已完成的 program 请求（保证并发 State 只加载一次）。
  static Future<ui.FragmentProgram>? _programRequest;

  /// 已加载成功的 program（静态缓存；program 不释放，各 State 只持有自己的
  /// [ui.FragmentShader]）。
  static ui.FragmentProgram? _program;

  /// shader 是否已确定不可用（加载失败/平台不支持）：一旦为 true 永久回退，
  /// 不再重试，避免每进一次播放器就重新尝试加载 + 打日志。
  static bool _shaderUnavailable = false;

  /// 测试注入点：替换 `ui.FragmentProgram.fromAsset`（测试环境无 GPU，真实
  /// 加载必然失败，用它验证"加载失败 → 回退"分支）。
  @visibleForTesting
  static Future<ui.FragmentProgram> Function(String assetName)? debugProgramLoader;

  /// 测试观测点：shader 是否已被判定不可用。
  @visibleForTesting
  static bool get debugShaderUnavailable => _shaderUnavailable;

  /// 测试用：重置静态 shader 缓存（每个用例之间必须调用，避免互相污染）。
  @visibleForTesting
  static void debugResetShaderState() {
    _program = null;
    _programRequest = null;
    _shaderUnavailable = false;
    debugProgramLoader = null;
  }

  /// 测试用：直接置"shader 不可用"（等价于从失败态进入页面的路径）。
  @visibleForTesting
  static void debugMarkShaderUnavailable() {
    _shaderUnavailable = true;
  }

  /// 测试注入点：替换频谱数据流（默认 [SpectrumService.instance.spectrumStream]）。
  ///
  /// 用例用 `StreamController.broadcast()` 作为替身，就能观测「订阅是否随驱动
  /// 挂上/退订」，而不依赖真实频谱服务。
  @visibleForTesting
  static Stream<List<double>>? debugSpectrumStream;

  @override
  State<FlowingBackground> createState() => _FlowingBackgroundState();
}

class _FlowingBackgroundState extends State<FlowingBackground>
    with WidgetsBindingObserver {
  // 时间累积通过 ValueNotifier 驱动 CustomPainter 重绘，避免每帧 setState
  // 触发 widget 重建
  final ValueNotifier<double> _timeNotifier = ValueNotifier<double>(0);

  /// 每 [_beatsPerAdvance] 个共享节拍拍推进一次（30fps 档）。
  ///
  /// 驱动源是全局共享节拍 [PlayerFrameDriver]（16ms，名义 62.5Hz），
  /// 每 2 拍推进一次即 ≈30fps（16ms × 2 = 32ms）。
  ///
  /// **为什么是拍计数器而不是「累加 dt 到阈值再清零」**：
  /// 节拍是 16ms 网格，30fps 需要 33.3ms，在该网格上凑不出整数倍。
  /// 沿用旧的 `_accumulatedDt >= 1/30; _accumulatedDt = 0` 写法要累积到 48ms
  /// 才够阈值，会**静默退化成 20.8fps**——代码看上去完全正常，只是悄悄少了 1/3 帧。
  /// 拍计数器 `++_beat` 每 2 拍恰好推进一次，不依赖定时器抖动，也不会踩这个坑。
  static const int _beatsPerAdvance = 2;

  /// 共享节拍单拍时长（秒），直接取自 [PlayerFrameDriver.step]（16ms）。
  ///
  /// 用 `static final` 而非写死常量：共享节拍若调整档位（§10.2 分档表），
  /// 这里自动跟随，不会静默失配成另一个帧率。
  static final double _beatStepSeconds =
      PlayerFrameDriver.step.inMicroseconds / Duration.microsecondsPerSecond;

  /// 单次推进 `_time` 的步长（秒）= `_beatStepSeconds × _beatsPerAdvance × 0.5`。
  ///
  /// 0.5 是原实现的流光速度倍率（约 4 秒一个周期）。
  /// 数值上 = 0.016 × 2 × 0.5 = **0.016**。
  ///
  /// 视觉速度逐项对齐原实现（单步 32ms vs 42ms，但步长同比缩小）：
  /// 原 `0.042 × 0.5 = 0.021 / 42ms` → 0.5 秒流光/秒；
  /// 新 `0.016 / 32ms`（16ms × 2 拍 × 0.5）→ 同样是 0.5 秒流光/秒。
  /// shader 路径的 orbit = `time × 0.15` 直接吃这个秒数，与上游时间语义一致。
  static final double _advanceSeconds =
      _beatStepSeconds * _beatsPerAdvance * 0.5;

  /// 是否已挂在共享节拍上（见 [_syncDriver]）。
  bool _driverBound = false;

  /// 拍计数器：每 [_beatsPerAdvance] 拍归零一次。
  ///
  /// 必须与订阅状态同生共死：[PlayerFrameDriver] 是「首订阅者启、末订阅者退」，
  /// 暂停再恢复后定时器是全新的，若不复位会带着上次的余数，恢复首帧多推一帧。
  int _beat = 0;

  /// App 是否退到后台/失去焦点（引擎不产帧，Timer 空转纯属唤醒浪费）。
  bool _lifecycleSuspended = false;

  /// [TickerMode] 是否启用：播放页被不透明路由（MV 页 / 歌曲信息页等）覆盖时
  /// Flutter 会把它关掉，见 [didChangeDependencies]。
  bool _tickerModeEnabled = true;

  /// 入场延迟（400ms）是否已走完。未走完时不订阅共享节拍。
  bool _initialDelayElapsed = false;

  /// 当前调色板：4 个 pigment + base + 32 个运动色。
  ///
  /// 初始值 = 中性 slate 兜底（与原 `_colors` 三色基调一致），取色完成后整体替换，
  /// 不做 palette 过渡（本仓切歌直接换色，上游的 650~1200ms 交叉淡入不移植）。
  FlowingPalette _palette = FlowingPalette.fallback;

  String? _lastArtworkUrl;

  // dispose 标志：用于取消 _extractColors 异步任务，
  // 避免 setState 在 widget 销毁后被调用
  bool _disposed = false;

  /// 提取结果缓存（url → 调色板），跨播放器往返复用。
  ///
  /// 同一封面反复进出播放器时，避免每次重新解码 + PaletteGenerator 分析；
  /// 仅缓存成功结果（失败不缓存，避免临时网络问题导致该封面永远用默认色）。
  static final FlowingPaletteCache _paletteCache = FlowingPaletteCache.instance;

  // ── shader 相关（每个 State 一个 FragmentShader；program 静态）──────────

  /// 本 State 持有的 fragment shader（shader 可用时非空）；`dispose` 时释放。
  ui.FragmentShader? _shader;

  /// shader 路径的 painter（常驻，palette / shader 变化时才重建）。
  _FlowingShaderPainter? _shaderPainter;

  /// 45 个 uniform 的复用缓冲区 + 脏检查状态（逐帧零分配）。
  final Float32List _uniformValues =
      Float32List(FlowingUniforms.uniformFloatCount);
  final FlowingUniformState _uniformState = FlowingUniformState();

  // ── 频谱律动（uMotion）──────────────────────────────────────────────────
  //
  // 只**消费**既有的 [SpectrumService] 广播流：不主动 start 采集、不新建帧源。
  // 订阅窗口与驱动窗口完全一致（暂停/被覆盖/后台/入场延迟期零订阅）。

  /// 频谱流订阅（仅在 [_driverBound] 为 true 期间存在）。
  StreamSubscription<List<double>>? _spectrumSub;

  /// 频谱 → 律动强度的标量包络（无数据恒 1.0，等价改动前观感）。
  final RhythmMotionEnvelope _rhythm = RhythmMotionEnvelope();

  /// 测量真实帧间隔，供包络按**时间**推进（与 `SpectrumBackground` 同款：
  /// Stopwatch 跨停/启会累积，每次重新挂订阅都要 reset）。
  final Stopwatch _rhythmClock = Stopwatch();
  int _lastRhythmTickUs = 0;

  /// 当前写入 `uMotion` 的值（初值 1.0 = 无频谱数据时的基线）。
  double _motion = 1.0;

  // ── 播放态（prop 初值 + 可选流；见 [FlowingBackground.playingStream]）─────

  /// 权威播放态：初值取 [FlowingBackground.isPlaying]，随后由流更新。
  late bool _playing;
  StreamSubscription<bool>? _playingSub;

  /// 进入页面时延迟启动的 Timer（只负责放行 [_initialDelayElapsed]，不驱动帧）。
  ///
  /// 打开播放器的瞬间不立即开始全屏渐变绘制，
  /// 等路由入场动画（~300ms）结束后再流动，避免与入场动画、
  /// 模糊背景首帧叠加导致卡顿。
  Timer? _delayedStartTimer;

  /// 驱动订阅的唯一收口（幂等）。
  ///
  /// 判据四取一与：[widget.isPlaying] && [_tickerModeEnabled]（未被不透明路由覆盖）
  /// && ![_lifecycleSuspended]（App 在前台）&& [_initialDelayElapsed]（入场延迟走完）
  /// && ![_disposed]。
  ///
  /// 订阅/退订时一并复位 [_beat]：共享节拍是「首订启/末订停」，恢复后定时器全新，
  /// 不复位会让恢复首帧多推一帧。
  void _syncDriver() {
    final bool shouldRun = _playing &&
        _tickerModeEnabled &&
        !_lifecycleSuspended &&
        _initialDelayElapsed &&
        !_disposed;
    if (shouldRun == _driverBound) return;
    if (shouldRun) {
      PlayerFrameDriver.instance.addListener(_onSharedTick);
      _startSpectrumSub();
    } else {
      PlayerFrameDriver.instance.removeListener(_onSharedTick);
      _stopSpectrumSub();
    }
    _driverBound = shouldRun;
    _beat = 0;
  }

  /// 更新权威播放态并重算驱动（幂等；供 prop 与 [FlowingBackground.playingStream] 共用）。
  void _setPlaying(bool playing) {
    if (_playing == playing) return;
    _playing = playing;
    _syncDriver();
  }

  /// 订阅/重订阅播放态流（`null` 时退化为纯 prop 行为）。
  void _subscribePlayingStream() {
    _playingSub?.cancel();
    _playingSub = null;
    final Stream<bool>? stream = widget.playingStream;
    if (stream == null) return;
    _playingSub = stream.listen((bool playing) {
      if (!mounted || _disposed) return;
      _setPlaying(playing);
    });
  }

  /// 幂等退订（供 [deactivate] / [dispose] 调用）。
  ///
  /// 这两处不能依赖 `mounted` / `_syncDriver` 的判据：此时 State 可能已被移出树，
  /// `widget` 是否还有效并不可靠，直接按 [_driverBound] 标志退订最稳。
  void _unbindDriver() {
    if (!_driverBound) return;
    PlayerFrameDriver.instance.removeListener(_onSharedTick);
    _stopSpectrumSub();
    _driverBound = false;
    _beat = 0;
  }

  /// 订阅频谱流（幂等）：与驱动同生命周期，且**不**主动启动采集。
  ///
  /// 频谱服务是引用计数的，只有播放页在用户开启「频谱总开关」时才 `start`；
  /// 这里只挂广播流，所以「用户没开频谱」= 没有数据 = `uMotion` 恒 1.0，
  /// 不引入任何原生采集开销。
  void _startSpectrumSub() {
    if (_spectrumSub != null || _disposed) return;
    // 重新起算时间基线：Stopwatch 跨停/启会累积，直接 elapsed 会得到巨大 dt
    _rhythmClock
      ..reset()
      ..start();
    _lastRhythmTickUs = 0;
    final stream = FlowingBackground.debugSpectrumStream ??
        SpectrumService.instance.spectrumStream;
    _spectrumSub = stream.listen(_onSpectrumBands);
  }

  /// 退订频谱流并把律动复位到基线（暂停/被覆盖/后台/销毁时调用）。
  ///
  /// 复位到 1.0 而不是保留当前值：下次可见的第一帧必须与改动前完全一致。
  void _stopSpectrumSub() {
    _spectrumSub?.cancel();
    _spectrumSub = null;
    _rhythmClock.stop();
    _lastRhythmTickUs = 0;
    _rhythm.resetToAmbient();
    _motion = _rhythm.motion;
  }

  /// 频谱数据到达（约 20fps，sync 广播）：**只登记，不插值、不 setState**。
  ///
  /// `bands` 是服务端复用缓冲，回调外不得持有；[RhythmMotionEnvelope.setBands]
  /// 当场归约成两个标量，不保留引用。
  void _onSpectrumBands(List<double> bands) {
    if (_disposed || !mounted) return;
    _rhythm.setBands(bands);
  }

  @override
  void initState() {
    super.initState();
    // 注册生命周期监听：后台时停止定时器，前台时按播放态决定是否恢复
    WidgetsBinding.instance.addObserver(this);
    // 权威播放态初值 = prop；随后由 playingStream 更新（页面被缓存复用、播放态
    // 变化不重建整页时，只靠 prop 会永远停在挂载那一刻 → 流光完全静止）。
    _playing = widget.isPlaying;
    _subscribePlayingStream();
    // 延迟到入场动画结束后再开跑：进入播放器瞬间避免全屏渐变绘制
    // 与路由入场动画 / 模糊背景首帧叠加导致卡顿。
    // （暂停/恢复等后续状态切换仍由 didUpdateWidget 即时处理；
    //   重新入树由 activate 补武装，见 _armEntryKick）
    _armEntryKick();
    // 延迟到首帧渲染完成后再做两件异步工作（都不阻塞首帧）：
    // 1) 加载 fragment shader：失败则永久回退到径向光斑 painter；
    // 2) 提取封面颜色：立即提取会触发封面网络下载 + 图片解码 + 分析，
    //    与路由入场动画 / 首帧构建抢资源，导致点击 MiniPlayer 展开时卡顿。
    //    切歌时的提取仍在 didUpdateWidget 中立即触发（页面已稳定，无此问题）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _disposed) return;
      _loadShader();
      _extractColors();
    });
  }

  /// 共享 `Timer` 不受 `TickerMode` 约束（§10.3），必须自行同步挂起，
  /// 否则「组件不可见仍持续产帧」——本仓最常见的漏电点（§10.4.3）。
  ///
  /// 覆盖场景：播放页被 **不透明** 路由压住时，`Overlay` 会给下层条目传
  /// `tickerEnabled: false`（Flutter `widgets/overlay.dart` 中
  /// `_theatre` 计算 + `_OverlayEntryWidget` 包 `TickerMode`），
  /// 所以 push 出 MV 页 / 歌曲信息页时这里立刻变 false → 解绑驱动。
  ///
  /// 非不透明路由（对话框、底部弹窗）不会关闭 `TickerMode`，此时继续运行 ——
  /// 页面仍部分可见，可接受。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool enabled = TickerMode.valuesOf(context).enabled;
    // 重新入树后 didChangeDependencies 一定会跑：兜底补武装入场 kick
    // （activate 已经补过一次，_armEntryKick 幂等）
    _armEntryKick();
    if (enabled == _tickerModeEnabled) return;
    _tickerModeEnabled = enabled;
    _syncDriver();
  }

  @override
  void didUpdateWidget(covariant FlowingBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artworkUrl != widget.artworkUrl) {
      _extractColors();
    }
    // 宿主换了一份播放态流（极少见）：重新订阅，避免留着旧订阅
    if (oldWidget.playingStream != widget.playingStream) {
      _subscribePlayingStream();
    }
    // prop 的播放态变化（宿主重建时）照旧生效；_setPlaying 内部幂等
    if (oldWidget.isPlaying != widget.isPlaying) {
      _setPlaying(widget.isPlaying);
    }
  }

  /// 响应 App 生命周期：后台时停止定时器节省功耗。
  ///
  /// 不依赖 Flutter TickerMode 的原因：部分 Android ROM 在后台仍触发 vsync，
  /// 导致 Ticker 持续运行。显式停止定时器可确保后台零功耗。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final bool suspended = state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached;
    if (suspended == _lifecycleSuspended) return;
    _lifecycleSuspended = suspended;
    _syncDriver();
  }

  /// widget 从树中移除时（如路由收起）立即解绑驱动。
  ///
  /// 关键修复：路由 dismiss 时 removeRoute 会触发子树 deactivate，
  /// 若仍在持续触发 setState，子树会保持 dirty 状态，
  /// 导致 InheritedElement.debugDeactivated 中的
  /// `_dependents.isEmpty` 断言失败（dependent 还未清理）。
  /// 在 deactivate 中提前停止可避免此竞态。
  @override
  void deactivate() {
    _delayedStartTimer?.cancel();
    _unbindDriver();
    super.deactivate();
  }

  /// 重新入树（跟手覆盖层 → 路由的页面交接、GlobalKey 复用等）时补武装入场 kick。
  ///
  /// **这是真机「流光完全静止」的根因修复**：`deactivate` 会取消入场延迟定时器，
  /// 而播放页在入场交接中会被重新挂载；只靠一次性定时器时 `_initialDelayElapsed`
  /// 永远是 false，驱动四判据永远差这一闸 → 永不 bind → `t` 恒 0.00。
  /// 真机 `[FlowingBG]` 日志实证：`gates[ticker=true fg=true entry=false
  /// bound=false playing=true]`。
  @override
  void activate() {
    super.activate();
    _armEntryKick();
  }

  /// 武装「入场延迟走完」的 kick 定时器（幂等）。
  ///
  /// 只做一件事：400ms 后把 [_initialDelayElapsed] 置 true 并重算驱动；
  /// 不驱动帧、不影响限帧口径（AGENTS §10：入场延迟只是放行条件）。
  void _armEntryKick() {
    if (_disposed || _initialDelayElapsed) return;
    _delayedStartTimer?.cancel();
    _delayedStartTimer = Timer(const Duration(milliseconds: 400), () {
      if (_disposed || _initialDelayElapsed) return;
      _initialDelayElapsed = true;
      _syncDriver();
    });
  }

  /// 共享节拍回调：每 [_beatsPerAdvance] 拍推进一次流光时间与律动包络（30fps）。
  void _onSharedTick() {
    // 防御性检查：State 已销毁时跳过
    if (_disposed) return;
    if (++_beat < _beatsPerAdvance) return;
    _beat = 0;
    // 律动包络按**真实 dt** 推进（与 SpectrumBandEnvelope 同一口径：按时间、
    // 不按帧，避免节拍抖动改变上升/回落手感）。dt 由本 State 的 Stopwatch 实测。
    final int nowUs = _rhythmClock.elapsedMicroseconds;
    final int dtUs = nowUs - _lastRhythmTickUs;
    _lastRhythmTickUs = nowUs;
    if (dtUs > 0) {
      _rhythm.advance(Duration(microseconds: dtUs));
      final double next = _rhythm.motion;
      // 1e-3 远低于可见差异：不逐帧制造无意义的重绘信号
      if ((next - _motion).abs() >= 1e-3) _motion = next;
    }
    // 不需要 setState：CustomPainter 通过 _timeNotifier 自动重绘
    _timeNotifier.value += _advanceSeconds;
  }

  // ── shader 加载 ─────────────────────────────────────────────────────────

  /// 触发（幂等）shader 加载：已加载/已判定不可用/已持有 shader 时直接返回。
  ///
  /// 同步部分只有一次静态缓存查询；真正的 `fromAsset` 通过 [Future] 完成，
  /// 不阻塞首帧。
  void _loadShader() {
    if (_disposed || _shader != null || FlowingBackground._shaderUnavailable) {
      return;
    }
    final program = FlowingBackground._program;
    if (program != null) {
      _attachShader(program);
      return;
    }
    unawaited(_loadProgram().then((program) {
      if (program == null || _disposed || !mounted) return;
      _attachShader(program);
    }));
  }

  /// 加载（或复用）静态 [ui.FragmentProgram]；失败置 `_shaderUnavailable` 永久回退。
  static Future<ui.FragmentProgram?> _loadProgram() async {
    if (FlowingBackground._shaderUnavailable) return null;
    final cached = FlowingBackground._program;
    if (cached != null) return cached;
    try {
      final request = FlowingBackground._programRequest ??=
          _requestProgram(FlowingBackground.shaderAsset);
      final program = await request;
      FlowingBackground._program = program;
      return program;
    } catch (e) {
      // 不弹错、不崩溃：测试环境（无 GPU）与部分平台不支持 fragment shader 时
      // 都会走到这里，永久回退到径向光斑 painter。
      debugPrint('[FlowingBackground] shader 不可用，回退径向光斑：$e');
      FlowingBackground._shaderUnavailable = true;
      return null;
    }
  }

  /// 发起 program 请求（测试可通过 [FlowingBackground.debugProgramLoader] 注入）。
  static Future<ui.FragmentProgram> _requestProgram(String assetName) {
    final loader = FlowingBackground.debugProgramLoader;
    if (loader != null) return loader(assetName);
    return ui.FragmentProgram.fromAsset(assetName);
  }

  /// 为当前 State 创建 shader + painter（每个 State 一个 FragmentShader）。
  void _attachShader(ui.FragmentProgram program) {
    if (_disposed || !mounted) return;
    final ui.FragmentShader shader;
    try {
      shader = program.fragmentShader();
    } catch (e) {
      // program 加载成功但实例化失败（极端平台/驱动）同样按永久不可用处理。
      debugPrint('[FlowingBackground] FragmentShader 实例化失败，回退径向光斑：$e');
      FlowingBackground._shaderUnavailable = true;
      return;
    }
    setState(() {
      _shader = shader;
      _rebuildShaderPainter();
    });
  }

  /// 重建 shader painter（shader 或 palette 变化时）。
  ///
  /// 复用同一个 [_uniformValues] / [_uniformState]，只有 painter 对象本身重建；
  /// 同一帧内 uniform 值未变时脏检查保证 0 次 `setFloat`。
  void _rebuildShaderPainter() {
    final shader = _shader;
    if (shader == null) {
      _shaderPainter = null;
      return;
    }
    _shaderPainter = _FlowingShaderPainter(
      shader: shader,
      palette: _palette,
      timeNotifier: _timeNotifier,
      values: _uniformValues,
      uniformState: _uniformState,
      motionOf: () => _motion,
    );
  }

  // ── 取色 ────────────────────────────────────────────────────────────────

  /// 首帧后/切歌时异步取色，取到后替换整份调色板。
  Future<void> _extractColors() async {
    final url = widget.artworkUrl;
    if (url == null || url.isEmpty) return;
    if (_lastArtworkUrl == url) return;
    _lastArtworkUrl = url;

    // 跨播放器往返缓存命中：直接复用上次提取的调色板，跳过解码 + 分析
    final cached = _paletteCache.peek(url);
    if (cached != null) {
      if (mounted && !_disposed) _applyPalette(cached);
      return;
    }

    try {
      // 统一走 FlowingPaletteCache（内部经 ArtworkColorExtractor.loadPalette）：
      // 兼容 http(s) 网络封面与 local:// / content:// / file:// 本地封面，
      // 网络封面经 CachedNetworkImageProvider 与 UI 封面共用磁盘缓存。
      final palette = await _paletteCache.paletteFor(url);
      // 双重检查：mounted（widget 还在树中）+ _disposed（State 未销毁）
      if (!mounted || _disposed) return;
      _applyPalette(palette);
    } catch (_) {}
  }

  /// 应用新调色板：同步重建 shader painter（回退 painter 在 build 里按 palette 重建）。
  void _applyPalette(FlowingPalette palette) {
    if (identical(palette, _palette)) return;
    setState(() {
      _palette = palette;
      _rebuildShaderPainter();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _delayedStartTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _unbindDriver(); // 幂等解绑（deactivate 已解绑过则直接 return）
    _playingSub?.cancel();
    _playingSub = null;
    // shader 必须释放；program 是进程级静态缓存，不释放。
    _shader?.dispose();
    _shader = null;
    _shaderPainter = null;
    _timeNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shaderPainter = _shaderPainter;
    if (shaderPainter != null) {
      // shader 可用：整屏一次 drawRect（单次全屏 fragment pass）。
      // 形变/取色/vignette/抖动全部在 GPU 侧完成，不需要静态基底或叠加层。
      return RepaintBoundary(
        child: CustomPaint(
          painter: shaderPainter,
          size: Size.infinite,
        ),
      );
    }

    // 回退实现（shader 不可用 / 尚在加载）与抽取前的绘制行为保持一致：
    // 静态基底 + 多层径向光斑，逐帧零分配。
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // 静态基底：整屏不透明对角线性渐变（深→中）。
        // 拆成独立 RepaintBoundary：它每个 tick 都不变，单独缓存栅格结果后，
        // 每帧只需重绘下面那个只含光斑的边界（全屏 pass 4 → 3，栅格 −25%）。
        RepaintBoundary(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  _palette.pigments[2], // pigments[2] 最深
                  _palette.pigments[1], // pigments[1] 中间
                ],
              ),
            ),
          ),
        ),
        // 动态层：多层光斑，每 2 拍（≈30fps）重绘一次。
        // 保留外层 RepaintBoundary 隔离，避免整页 setState 连坐本层重绘。
        RepaintBoundary(
          child: CustomPaint(
            painter: FlowingGradientPainter(
              colors: _palette.pigments,
              timeNotifier: _timeNotifier,
            ),
            size: Size.infinite,
          ),
        ),
      ],
    );
  }
}

/// shader 路径的绘制器：每帧只做「算 45 个 uniform + 提交脏项 + 一次 drawRect」。
///
/// - shader / Paint / uniform 缓冲区全部常驻（State 持有），逐帧零分配；
/// - `repaint: timeNotifier` 让共享节拍推进时只重绘这一层；
/// - `uMotion` 由频谱律动包络提供（[motionOf]，无数据 = 1.0），
///   `uDim` 恒 0（本仓继续用既有 0.35 蒙版）。
class _FlowingShaderPainter extends CustomPainter {
  _FlowingShaderPainter({
    required this.shader,
    required this.palette,
    required this.timeNotifier,
    required this.values,
    required this.uniformState,
    required this.motionOf,
  }) : super(repaint: timeNotifier) {
    _paint = Paint()..shader = shader;
  }

  final ui.FragmentShader shader;
  final FlowingPalette palette;
  final ValueNotifier<double> timeNotifier;
  final Float32List values;
  final FlowingUniformState uniformState;

  /// 取当前律动强度（由 State 的包络每拍更新）。
  ///
  /// **刻意不新增 repaint 源**：时间本来每拍都变、每拍都会重绘，paint 时读到的
  /// 一定是本拍最新值；多一个 notifier 只会多一次 `Listenable.merge` 与通知。
  final double Function() motionOf;

  late final Paint _paint;

  /// 屏幕矩形缓存（避免每帧 `Offset.zero & size` 分配）。
  Size? _cachedSize;
  Rect? _cachedRect;

  /// 本仓口径：变暗由既有 0.35 蒙版负责，shader 内 dim 项不参与。
  static const double _dim = 0.0;

  /// `_time` → 真实秒的换算（= 1 / 0.5）。
  ///
  /// `_advanceSeconds` 沿用旧实现的 0.5 流光速度倍率（时间基 = 0.5 秒/秒），
  /// 而 shader 的 `orbit = time × 0.15`、`shapePhase = orbit × 1.6`、hub/颜色相位
  /// 全部按**上游真实秒**标定（orbit 周期 41.888s）。因此进入 uniform 时换算回
  /// 真实秒（×2），让 shader 路径的流速与 myune 完全一致；
  /// 回退 painter 仍吃原始 `_time`，保持抽取前的旧速度（逐字一致）。
  static const double _wallClockScale = 2.0;

  @override
  void paint(Canvas canvas, Size size) {
    writeFlowingUniforms(
      values,
      size: size,
      time: timeNotifier.value * _wallClockScale,
      motion: motionOf(),
      dim: _dim,
      palette: palette,
      state: uniformState,
    );
    uniformState.flush(shader);
    if (_cachedSize != size) {
      _cachedSize = size;
      _cachedRect = Offset.zero & size;
    }
    canvas.drawRect(_cachedRect!, _paint);
  }

  @override
  bool shouldRepaint(covariant _FlowingShaderPainter oldDelegate) {
    // time 变化由 Listenable (super(repaint: timeNotifier)) 自动驱动重绘；
    // 这里只需在 palette / shader 实例变化时重建。
    return !identical(oldDelegate.palette, palette) ||
        !identical(oldDelegate.shader, shader);
  }
}

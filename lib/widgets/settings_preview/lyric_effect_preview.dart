import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../widgets/apple_lyrics/layout/duet_layout.dart';
import '../../widgets/apple_lyrics/layout/lyric_preferences.dart';
import 'preview_demo_assets.dart';
import 'settings_preview_frame.dart';

/// 「歌词效果」三级子页的演示卡。
///
/// 三行歌词：上一行（已唱，暗 + 缩放 + **可选高斯模糊**）、当前行（高亮，
/// 可动态取色 / 逐字辉光 / 已播字上浮）、下一行（待唱，暗 + 缩放 + 可选模糊）。
/// 所有视觉参数逐帧读 [LyricPreferences]，与播放页同一份真值源。
///
/// ## 为什么固定为「当前行 = 第 1 行」
///
/// 这是设置页，不是播放页。若让歌词自动推进，用户会分不清「这是效果还是
/// 内容」；固定一行则每个特效都停在同一位置，可以左右对照开关前后的差别。
/// 取第 1 行（中间那行）而非第 0 行，是为了上下各留一行对照：上看已唱、
/// 下看待唱。
///
/// ## 三个「只作用一行」的口径，全部与播放页一致
///
/// 1. **高斯模糊只糊非当前行**：播放页的 `_blurGeometry` 只对非当前行建模糊层，
///    当前行永远清晰（apple_lyrics_view.dart:2592 `if (geom.sigma < 0.1) continue;`
///    那条路径只服务背景行）。演示卡若把当前行也糊掉，用户就**没有参照物**，
///    分不清「糊了」和「本来就这样」。
/// 2. **辉光只给当前行正在唱的那个字**：播放页按 word 逐个判定
///    （[EmphasizeEffect.shouldEmphasize]：字时长过短、纯符号、歌手标签都不触发），
///    行内呈现是「唱到的字放大 + 辉光，同行的其余字保持普通」。
///    整行辉光不是本功能的行为，会让用户以为播放页会整行发光。
/// 3. **对唱是左右分列**：男→左、女→右、合→居中，且「男：」「女：」前缀
///    会被剥掉（见 [DuetLayout.process]）。
///
/// ## AM / MD3 的能力差异必须如实呈现
///
/// 7 个开关里只有「平衡行换行」有两份（AM / MD3 各一个），其余 6 个只作用
/// 于 AM：MD3 播放器没有模糊 / 辉光 / 对唱 / 动态色实现。因此 [isAmStyle]
/// 为 false 时**不能**把 AM 的开关状态画进演示卡——那会让用户在 MD3 播放页
/// 看到一个根本不存在的效果。
class LyricEffectPreview extends StatelessWidget {
  /// true = 演示 Apple Music 风格歌词；false = Material 风格。
  final bool isAmStyle;

  /// 当前行索引（0..2）。默认 1（中间行），上下各留一行做对照。
  static const int _currentLineIndex = 1;

  const LyricEffectPreview({super.key, required this.isAmStyle});

  @override
  Widget build(BuildContext context) {
    // AM 偏好是本卡的唯一真值源（MD3 只额外读 lineBalance）
    final amPrefs = LyricPreferences.instance;

    return ListenableBuilder(
      listenable: amPrefs,
      builder: (context, _) {
        final theme = Theme.of(context);
        final colorScheme = theme.colorScheme;

        final showDuet = isAmStyle && amPrefs.useDuetLayout;

        return SettingsPreviewFrame(
          title: '歌词效果预览',
          subtitle: isAmStyle ? '当前：Apple Music 风格' : '当前：Material 风格',
          footnote: '对唱 / 模糊 / 辉光 / 换行 等开关与滑块即时生效',
          height: 190,
          background: colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: showDuet
                ? _buildDuet(context, colorScheme, amPrefs)
                : _buildSingle(context, colorScheme, amPrefs),
          ),
        );
      },
    );
  }

  // ───────────────────────── 非对唱：三行单列 ─────────────────────────

  Widget _buildSingle(
    BuildContext context,
    ColorScheme colorScheme,
    LyricPreferences amPrefs,
  ) {
    final base = _PreviewColors.of(context, colorScheme);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < kPreviewSingleTexts.length; i++) ...[
          if (i > 0) const SizedBox(height: 12),
          _buildLine(
            context: context,
            colors: base,
            text: kPreviewSingleTexts[i],
            isCurrent: i == _currentLineIndex,
            amPrefs: amPrefs,
            alignment: CrossAxisAlignment.start,
          ),
        ],
      ],
    );
  }

  // ───────────────────────── 对唱：男左女右 ─────────────────────────

  Widget _buildDuet(
    BuildContext context,
    ColorScheme colorScheme,
    LyricPreferences amPrefs,
  ) {
    final base = _PreviewColors.of(context, colorScheme);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < kPreviewDuetTexts.length; i++) ...[
          if (i > 0) const SizedBox(height: 12),
          _buildLine(
            context: context,
            colors: base,
            text: kPreviewDuetTexts[i],
            isCurrent: i == 0,
            amPrefs: amPrefs,
            // 性别 → 对齐：男=左、女=右（与 DuetLayout._genderToAlign 同口径）
            alignment: _crossAlignFromGender(kPreviewDuetPrefixes[i]),
          ),
        ],
      ],
    );
  }

  /// 一行歌词，含模糊 / 辉光 / 上浮 / 缩放。
  Widget _buildLine({
    required BuildContext context,
    required _PreviewColors colors,
    required String text,
    required bool isCurrent,
    required LyricPreferences amPrefs,
    required CrossAxisAlignment alignment,
  }) {
    // 行内拆字：辉光只给当前行「正在唱」的那一个字（固定取第一个字），
    // 同行的其余字保持普通 —— 与播放页逐字判定的呈现一致。
    final runes = text.runes.toList();
    final chars = [for (final r in runes) String.fromCharCode(r)];

    final glowOn = isAmStyle && amPrefs.useGlowEffect && isCurrent;
    // 模糊只给非当前行：当前行恒清晰，留作对比参照（见类文档第 1 条）。
    final blurSigma = isAmStyle && amPrefs.useGaussianBlur && !isCurrent
        ? _blurSigmaFor(amPrefs.blurIntensity)
        : 0.0;
    // 动态取色：85% 白 + 15% 主题主色，再抬明度到 ≥0.78（口径见
    // apple_lyrics_view.dart:2344-2349 的 forceDarkBackground 分支）。
    final color = isCurrent && isAmStyle && amPrefs.useDynamicLyricColor
        ? _liftLightness(Color.lerp(colors.base, colors.accent, 0.15)!)
        : (isCurrent ? colors.active : colors.base);

    final line = Column(
      crossAxisAlignment: alignment,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 已播字上浮：当前行整体上浮 liftHeightPx（取负值 = 向上）
        Transform.translate(
          offset: Offset(0, isCurrent ? -amPrefs.liftHeightPx : 0),
          child: Transform.scale(
            scale: isCurrent ? 1.0 : amPrefs.inactiveScale,
            alignment: switch (alignment) {
              CrossAxisAlignment.end => Alignment.centerRight,
              CrossAxisAlignment.center => Alignment.center,
              _ => Alignment.centerLeft,
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                for (var i = 0; i < chars.length; i++)
                  _buildChar(
                    char: chars[i],
                    color: color,
                    isCurrent: isCurrent,
                    emphasized: glowOn && i == 0,
                  ),
              ],
            ),
          ),
        ),
      ],
    );

    if (blurSigma <= 0) return line;
    return ImageFiltered(
      imageFilter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
      child: line,
    );
  }

  /// 行内的一个字。[emphasized] 时按播放页同款两段式辉光放大。
  Widget _buildChar({
    required String char,
    required Color color,
    required bool isCurrent,
    required bool emphasized,
  }) {
    return Text(
      char,
      style: TextStyle(
        color: color,
        fontSize: 17,
        fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w500,
        height: 1.3,
        shadows: emphasized
            ? [
                // 近距实影 + 远距弥散，两段才出得来「发光」而非「脏边」
                Shadow(color: color, blurRadius: 8),
                Shadow(
                  color: color.withValues(alpha: 0.55),
                  blurRadius: 18,
                ),
              ]
            : null,
      ),
    );
  }

  /// 非当前行的模糊 sigma：取播放页最远分级（5）× 用户倍数，clamp 0.5~10。
  ///
  /// 演示卡只演示「非当前行」这一档，不逐行分级：三行里两行都糊时差异反而
  /// 看不清，固定用最远档最能体现「模糊开了」。
  static double _blurSigmaFor(double intensity) =>
      (5.0 * intensity).clamp(0.5, 10.0);

  /// 抬明度到 ≥0.78（只抬明度、保留色相与饱和度），保证深色底可读。
  static Color _liftLightness(Color color) {
    final hsl = HSLColor.fromColor(color);
    return hsl.withLightness(hsl.lightness < 0.78 ? 0.78 : hsl.lightness).toColor();
  }

  /// 性别 → 行内对齐方式。口径同 `DuetLayout._genderToAlign`：
  /// 男=左、女=右、合=居中，其余按默认（左）。
  static CrossAxisAlignment _crossAlignFromGender(String gender) {
    switch (_genderToAlign(gender)) {
      case DuetAlignment.right:
        return CrossAxisAlignment.end;
      case DuetAlignment.center:
        return CrossAxisAlignment.center;
      default:
        return CrossAxisAlignment.start;
    }
  }

  /// 性别 → [DuetAlignment]。口径同 `DuetLayout._genderToAlign`。
  static DuetAlignment _genderToAlign(String gender) {
    if (gender == '合') return DuetAlignment.center;
    if (gender == '男') return DuetAlignment.left;
    if (gender == '女') return DuetAlignment.right;
    return DuetAlignment.defaultAlign;
  }
}

/// 演示卡取用的三个颜色：底色文字、当前行文字、主题强调色。
class _PreviewColors {
  final Color base;
  final Color active;
  final Color accent;

  const _PreviewColors({
    required this.base,
    required this.active,
    required this.accent,
  });

  /// 深色底用白、浅色底用 onSurface：否则浅色主题里整张卡是一片白
  /// （真机截图验证过）。
  static _PreviewColors of(BuildContext context, ColorScheme colorScheme) {
    final dark = colorScheme.brightness == Brightness.dark;
    return _PreviewColors(
      base: dark ? Colors.white70 : colorScheme.onSurfaceVariant,
      active: dark ? Colors.white : colorScheme.onSurface,
      accent: colorScheme.primary,
    );
  }
}

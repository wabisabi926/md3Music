import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../theme/app_dimens.dart';
import 'responsive_layout.dart';

/// 局部坐标下的双栏/单栏几何。竖直铰链两侧够宽时分栏，否则用较宽一侧。
({
  double masterLeft,
  double masterWidth,
  double detailLeft,
  double detailWidth,
  bool twoPane,
})
resolvePaneGeometry({
  required double width,
  required double masterFraction,
  List<Rect> verticalObstructions = const [],
}) {
  for (final bounds in verticalObstructions) {
    if (bounds.left <= 0 || bounds.right >= width) continue;
    final rightWidth = width - bounds.right;
    if (usesTwoPane(width) &&
        bounds.left >= AppLayout.twoPaneMasterWidth &&
        rightWidth >= 480) {
      return (
        masterLeft: 0,
        masterWidth: bounds.left,
        detailLeft: bounds.right,
        detailWidth: rightWidth,
        twoPane: true,
      );
    }
    final left = bounds.left >= rightWidth ? 0.0 : bounds.right;
    final available = bounds.left >= rightWidth ? bounds.left : rightWidth;
    return (
      masterLeft: left,
      masterWidth: available,
      detailLeft: left,
      detailWidth: available,
      twoPane: false,
    );
  }
  final twoPane = usesTwoPane(width);
  final master = twoPane
      ? (masterFraction * width).clamp(
          AppLayout.twoPaneMasterWidth,
          width - 496,
        )
      : width;
  final detailLeft = twoPane ? master + 16 : 0.0;
  return (
    masterLeft: 0,
    masterWidth: master,
    detailLeft: detailLeft,
    detailWidth: width - detailLeft,
    twoPane: twoPane,
  );
}

/// 该显示特性是否**把可用视口分隔成互不相通的两块**。
///
/// 口径对齐 Android `FoldingFeature.isSeparating()`：
/// - [ui.DisplayFeatureType.hinge]（物理铰链 / 双屏机）恒分隔；
/// - [ui.DisplayFeatureType.fold]（柔性屏折痕）**仅半开时分隔**。折叠屏完全展开
///   时系统仍会上报这道折痕，姿势是 [ui.DisplayFeatureState.postureFlat]
///   （dart:ui：*"The foldable device is completely open. The screen space that is
///   presented to the user is flat."*），而 dart:ui 对 fold 的定义就是**不遮挡**：
///   *"[DisplayFeatureType.hinge] and [DisplayFeatureType.cutout] both obstruct the
///   display, while [DisplayFeatureType.fold] does not"* —— 完全展开时内容可以
///   横跨折痕，只有半开（Flex 模式）才真的把可用区分成两块；
/// - 挖孔（cutout）由 SafeArea / padding 处理，不是分栏依据；
/// - 状态 `unknown` 一律按"不在场"处理：**宁可漏分栏，也不能把整页内容挤到
///   一侧**（2026-10-14 issue #138：折叠屏展开竖屏下整页被挤到折痕一侧、
///   另一侧近半屏留白）。
bool isSeparatingDisplayFeature(ui.DisplayFeature feature) {
  if (feature.type == ui.DisplayFeatureType.hinge) return true;
  return feature.type == ui.DisplayFeatureType.fold &&
      feature.state == ui.DisplayFeatureState.postureHalfOpened;
}

/// 从 [MediaQueryData.displayFeatures] 挑出**需要避让的竖直分隔障碍**，并把
/// 窗口坐标换算到内容面板的局部坐标（面板左边被 NavigationRail / 左安全区占掉
/// [leftInset]）。调用方是响应式双栏（`DesktopTwoPane` 的 responsive 分支）。
///
/// 三条判据缺一不可：
/// 1. [isSeparatingDisplayFeature] —— 平展折痕不是障碍（issue #138 的错判点：
///    原先只按 `height > width && height >= 视口高/2` 裸判几何，把折叠屏展开时
///    的折痕当成竖直铰链，两栏被一起塞到折痕一侧）；
/// 2. **0 宽且非半开**的特性跳过：dart:ui 明确 fold 的 bounds 可以是 0 宽
///    （只标出折痕线），物理上不占空间；框架自己的避让口径同源
///    （`widgets/display_feature_sub_screen.dart` 的 `avoidBounds`：
///    `shortestSide > 0 || state == postureHalfOpened`）；
/// 3. 仍是**竖长**特性且高度 ≥ 视口一半：横屏时折痕是水平的，不能据此分栏
///    （这也是"横屏正常"的原因）。
List<Rect> verticalPaneObstructions({
  required List<ui.DisplayFeature> features,
  required Size viewSize,
  required double leftInset,
}) {
  final result = <Rect>[];
  for (final feature in features) {
    if (!isSeparatingDisplayFeature(feature)) continue;
    final bounds = feature.bounds;
    final bool occupiesArea = bounds.shortestSide > 0;
    if (!occupiesArea &&
        feature.state != ui.DisplayFeatureState.postureHalfOpened) {
      continue;
    }
    if (bounds.height <= bounds.width ||
        bounds.height < viewSize.height / 2) {
      continue;
    }
    result.add(bounds.shift(Offset(-leftInset, 0)));
  }
  return result;
}

/// 壳层的页面形态表。设置页保留独立的页内状态双列，沉浸页不参与分栏。
const Set<String> kTwoPaneTabs = {
  'library',
  'favorites',
  'search',
  'charts',
  'scene',
  'channel',
  'discover',
  'ip',
  'user',
  'audiobook',
};

const Set<String> kConstrainedTabs = {'user', 'audiobook'};

/// 保持手机尺寸，只在内容过宽时居中限宽；使用局部约束，不改 MediaQuery。
class ContentWidth extends StatelessWidget {
  const ContentWidth({
    super.key,
    required this.child,
    this.maxWidth = AppLayout.maxContentWidth,
  });

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: SizedBox(width: double.infinity, child: child),
    ),
  );
}

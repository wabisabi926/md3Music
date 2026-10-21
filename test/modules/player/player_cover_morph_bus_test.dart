import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/player/player_cover_morph.dart';

void main() {
  test('coverSuppressed=true 时封面不画，文字判据不受影响', () {
    final bus = PlayerCoverMorphBus.instance;
    bus.coverSuppressed = false;
    bus.eligible = true;
    bus.miniRect = const Rect.fromLTWH(0, 0, 44, 44);
    bus.settledRect = const Rect.fromLTWH(40, 60, 300, 300);
    bus.miniTextRect = const Rect.fromLTWH(60, 10, 200, 30);
    bus.settledTextRect = const Rect.fromLTWH(40, 380, 300, 60);
    bus.textEligible = true;
    addTearDown(() {
      bus.coverSuppressed = false;
      bus.eligible = false;
      bus.textEligible = false;
      bus.miniRect = null;
      bus.settledRect = null;
      bus.miniTextRect = null;
      bus.settledTextRect = null;
    });

    expect(bus.layerWillDraw, isTrue);
    expect(bus.coverLayerWillDraw, isTrue);
    expect(bus.textWillDraw, isTrue);

    bus.coverSuppressed = true;
    expect(bus.coverLayerWillDraw, isFalse);
    // 文字形变保留（用户明确要求）
    expect(bus.textWillDraw, isTrue);
  });

  group('publishMini 的圆角 / 旋转上报（悬浮形态起点）', () {
    tearDown(PlayerCoverMorphBus.instance.reset);

    test('缺省 = 常驻条口径（6dp 圆角、0 旋转）', () {
      final bus = PlayerCoverMorphBus.instance;
      bus.publishMini(const Rect.fromLTWH(0, 0, 44, 44));
      expect(bus.miniCoverCornerRadius, kCoverMorphMiniRadius);
      expect(bus.miniCoverRotation, 0.0);
    });

    test('胶囊 / 圆盘：正圆半径与当前唱片角都进登记簿', () {
      final bus = PlayerCoverMorphBus.instance;
      bus.publishMini(
        const Rect.fromLTWH(19, 3, 58, 58),
        cornerRadius: 29,
        rotation: 1.234,
      );
      expect(bus.miniCoverCornerRadius, 29);
      expect(bus.miniCoverRotation, 1.234);
    });

    test('圆角/旋转参与变更判据（矩形不变也要 bump revision）', () {
      final bus = PlayerCoverMorphBus.instance;
      bus.publishMini(const Rect.fromLTWH(0, 0, 58, 58), cornerRadius: 29);
      final afterFirst = bus.revision.value;
      // 同矩形 + 同圆角：圆盘停转时逐帧 paint 上报，不该空转 revision
      bus.publishMini(const Rect.fromLTWH(0, 0, 58, 58), cornerRadius: 29);
      expect(bus.revision.value, afterFirst);
      // 同矩形 + 角度变了（唱片在转）：必须 bump，否则形变层停在旧角度
      bus.publishMini(
        const Rect.fromLTWH(0, 0, 58, 58),
        cornerRadius: 29,
        rotation: 0.5,
      );
      expect(bus.revision.value, afterFirst + 1);
    });

    test('非法值回退（NaN 圆角按缺省、NaN 角度按 0）', () {
      final bus = PlayerCoverMorphBus.instance;
      bus.publishMini(
        const Rect.fromLTWH(0, 0, 58, 58),
        cornerRadius: double.nan,
        rotation: double.infinity,
      );
      expect(bus.miniCoverCornerRadius, kCoverMorphMiniRadius);
      expect(bus.miniCoverRotation, 0.0);
    });

    test('reset() 把新字段也复位（跨用例不泄漏）', () {
      final bus = PlayerCoverMorphBus.instance;
      bus.publishMini(
        const Rect.fromLTWH(0, 0, 56, 56),
        cornerRadius: 28,
        rotation: 2.0,
      );
      bus.reset();
      expect(bus.miniCoverCornerRadius, kCoverMorphMiniRadius);
      expect(bus.miniCoverRotation, 0.0);
      expect(bus.miniRect, isNull);
    });
  });

  group('coverMorphLocalRadius 的起点参数化', () {
    test('startRadius=29（胶囊正圆）：屏幕上 t=0 恰为 29', () {
      // scale=1 时局部半径 == 屏幕半径
      expect(coverMorphLocalRadius(0, 1, startRadius: 29), closeTo(29, 1e-9));
      expect(coverMorphLocalRadius(0.5, 1, startRadius: 29), closeTo(22.5, 1e-9));
      expect(coverMorphLocalRadius(1, 1, startRadius: 29), closeTo(16, 1e-9));
    });

    test('scale≠1：屏幕半径 = 局部 × scale，仍从 startRadius 起', () {
      const scale = 0.25;
      expect(
        coverMorphLocalRadius(0, scale, startRadius: 29) * scale,
        closeTo(29, 1e-9),
      );
      expect(
        coverMorphLocalRadius(1, scale) * scale,
        closeTo(16, 1e-9),
      );
    });

    test('非法 startRadius 回退缺省 6（旧行为兜底）', () {
      expect(coverMorphLocalRadius(0, 1, startRadius: double.nan), 6.0);
      expect(coverMorphLocalRadius(0, 1, startRadius: -4), 6.0);
    });
  });
}

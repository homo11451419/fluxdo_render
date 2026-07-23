/// 命中测试 —— 全局坐标 → DocumentPosition。
///
/// 对齐 fleather 的「父协调定位块 + 子委派块内 getPositionForOffset」:
/// 顶层手势层拿到全局坐标 → [positionAt] 找命中块 → 委派 RenderParagraph.
/// getPositionForOffset 拿块内渲染偏移。
library;

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import 'selectable_block_handle.dart';
import 'selection_geometry.dart';
import 'selection_registry.dart';

class SelectionHitTester {
  const SelectionHitTester(this.registry);

  final SelectionRegistry registry;

  /// 全局坐标 → DocumentPosition。
  ///
  /// **优先用框架真实 hit-test**(从 [hitTestRoot] = 当前 chunk 手势层的
  /// RenderObject 往下):框架 hit-test 只走真实可见、未被 viewport 裁剪的渲染
  /// 路径 —— 天然排除「被 keepAlive 保活但已滚出视口」的块(它们的 RepaintBoundary
  /// 停在旧屏幕位置,globalRect 会陈旧地"占着"屏幕、污染命中,导致窗口尺寸变化
  /// 后划词跳到完全另一段)。命中到已注册的 RenderParagraph 即返回。
  ///
  /// 框架 hit-test 取不到(点在 padding/空隙、或在别的 chunk 里 = 跨 chunk 拖拽
  /// 扩展)时,回退到 globalRect 包含/最近兜底(下方原逻辑)。
  DocumentPosition? positionAt(Offset global, {RenderObject? hitTestRoot}) {
    final framework = _frameworkHit(global, hitTestRoot);
    if (framework != null) return framework;

    final blocks = registry.liveHandles;

    // 1. 几何包含;多个重叠时取最小 rect(最内层)。
    SelectableBlockHandle? hit;
    double hitArea = double.infinity;
    for (final h in blocks) {
      final r = h.globalRect();
      if (r == null || !r.contains(global)) continue;
      final area = r.width * r.height;
      if (area < hitArea) {
        hitArea = area;
        hit = h;
      }
    }
    if (hit != null) return _localPosition(hit, global);

    // 2. 最近距离兜底(按到块 rect 的垂直距离)
    SelectableBlockHandle? nearest;
    Rect? nearestRect;
    double best = double.infinity;
    for (final h in blocks) {
      final r = h.globalRect();
      if (r == null) continue;
      final dy = global.dy < r.top
          ? r.top - global.dy
          : global.dy > r.bottom
              ? global.dy - r.bottom
              : 0.0;
      if (dy < best) {
        best = dy;
        nearest = h;
        nearestRect = r;
      }
    }
    if (nearest == null || nearestRect == null) return null;
    // 把点夹进最近块的 rect 再委派(用边缘 y,x 保留以定位行内列)。
    final clamped = Offset(
      global.dx.clamp(nearestRect.left, nearestRect.right),
      global.dy.clamp(nearestRect.top, nearestRect.bottom),
    );
    return _localPosition(nearest, clamped);
  }

  /// 框架真实 hit-test:从 [root] 往下,命中路径里第一个「已注册」块的
  /// 几何宿主 RenderBox(路径是 deepest-first,故第一个 = 最内层,与嵌套
  /// 容器取最内一致)。RichText 路径宿主 = RenderParagraph,直绘路径 =
  /// 直绘 RenderObject 本体。取不到返回 null(交由 globalRect 兜底)。
  DocumentPosition? _frameworkHit(Offset global, RenderObject? root) {
    if (root is! RenderBox || !root.attached || !root.hasSize) return null;
    final local = root.globalToLocal(global);
    if (!local.dx.isFinite || !local.dy.isFinite) return null;
    final result = BoxHitTestResult();
    if (!root.hitTest(result, position: local)) return null;
    final live = registry.liveHandles;
    for (final entry in result.path) {
      final target = entry.target;
      if (target is! RenderBox) continue;
      for (final h in live) {
        final g = h.geometry;
        if (g != null && identical(g.renderBox, target)) {
          return _localPosition(h, global);
        }
      }
    }
    return null;
  }

  DocumentPosition? _localPosition(SelectableBlockHandle h, Offset global) {
    final g = h.geometry;
    if (g == null) return null;
    final local = g.renderBox.globalToLocal(global);
    final tp = g.getPositionForOffset(local);
    return DocumentPosition(
      blockId: h.id,
      renderOffset: tp.offset,
      affinity: tp.affinity,
    );
  }

  /// 块内某渲染偏移处的「词」边界(长按选词用)。
  /// 落在 ￼(emoji/mention)上时 getWordBoundary 返回 (n, n+1) → 整颗选中
  /// (已探针实测)。
  ({int start, int end})? wordBoundaryAt(DocumentPosition pos) {
    final h = registry.byId(pos.blockId);
    final g = h?.geometry;
    if (g == null) return null;
    final wb = g.getWordBoundary(TextPosition(offset: pos.renderOffset));
    return (start: wb.start, end: wb.end);
  }

  /// 位置处 caret 的**全局矩形**(宽 0)。手柄拖拽的半行补偿、放大镜焦点
  /// 「指文字所在行」都用它(对齐 SDK _buildInfoForMagnifier 的 caretRect)。
  /// 块不可见(回收/离屏 NaN)时返回 null。
  Rect? caretRectAt(DocumentPosition pos) {
    final g = registry.byId(pos.blockId)?.geometry;
    if (g == null || !g.isLive) return null;
    final local = g.caretRectAt(pos.renderOffset);
    final topLeft = g.renderBox.localToGlobal(local.topLeft);
    if (!topLeft.dx.isFinite || !topLeft.dy.isFinite) return null;
    return topLeft & local.size;
  }

  /// 编辑光标的**全局矩形**(宽 0)—— 与 [caretRectAt] 的区别:高度是
  /// 调用方传入的**固定行高**([lineHeight],由编辑器按 baseStyle 用
  /// TextPainter.preferredLineHeight 算一次),垂直落位交给引擎的
  /// caretPrototype 机制(getOffsetForCaret 第二参)。
  ///
  /// 这是 EditableText/RenderEditable 的官方做法:光标高度与内容无关、
  /// 构造上恒定 —— 此前用 getFullHeightForCaret(段末回退裸字体度量)
  /// 和行盒(tight/max、空段无盒)都会在不同位置给出不同高度,表现为
  /// 光标"输入前后高矮不一"。
  ///
  /// [affinity] 决定软换行点的落行(见 DocumentPosition.affinity)。
  Rect? editingCaretRectAt(DocumentPosition pos, {required double lineHeight}) {
    final p = registry.byId(pos.blockId)?.paragraph;
    if (p == null || !p.attached || !p.hasSize) return null;
    final local =
        editingCaretRectIn(p, pos.renderOffset, lineHeight, pos.affinity);
    final topLeft = p.localToGlobal(local.topLeft);
    if (!topLeft.dx.isFinite || !topLeft.dy.isFinite) return null;
    return topLeft & local.size;
  }

  /// [editingCaretRectAt] 的段落内实现(局部坐标;独立出来可单测)。
  ///
  /// - x/top:getOffsetForCaret(带 [affinity] —— 软换行点 upstream 落
  ///   上一行行末,downstream 落下一行行首,跟用户点击的行走);
  /// - 高度:恒 [lineHeight](构造保证一致);
  /// - top:getOffsetForCaret 的 dy 在**段末**回退字体度量(实测 3.71 vs
  ///   行内 0.4)→ 用相邻字符的**整行盒**(BoxHeightStyle.max)校正;
  ///   前后盒都有时取与 dy 更近的那个;无盒(空段落)保留 dy。
  ///   校正基准 = 行盒 **bottom - lineHeight**(非 top):非均匀行
  ///   (行内大图 WidgetSpan bottom 对齐撑高行)行盒 top 是图顶,而
  ///   文字/光标在行底部 —— 用 top 光标悬到图顶。均匀行两者等价。
  @visibleForTesting
  static Rect editingCaretRectIn(
    RenderParagraph p,
    int offset,
    double lineHeight, [
    TextAffinity affinity = TextAffinity.downstream,
  ]) {
    final prototype = Rect.fromLTWH(0, 0, 2, lineHeight);
    final position = TextPosition(offset: offset, affinity: affinity);
    final local = p.getOffsetForCaret(position, prototype);

    final plain = p.text.toPlainText(
      includeSemanticsLabels: false,
      includePlaceholders: true,
    );
    // 前一个字符是换行符时,它的选区盒画在**上一行**,拿它当基准会把
    // 光标按上一行去定位(上一行含大图时偏差就是整个图高)。
    final afterLineBreak = offset > 0 &&
        offset - 1 < plain.length &&
        plain[offset - 1] == '\n';

    double top = local.dy;
    TextBox? nearest;
    if (offset > 0 && !afterLineBreak) {
      final before = p.getBoxesForSelection(
        TextSelection(baseOffset: offset - 1, extentOffset: offset),
        boxHeightStyle: ui.BoxHeightStyle.max,
      );
      if (before.isNotEmpty) nearest = before.last;
    }
    final after = p.getBoxesForSelection(
      TextSelection(baseOffset: offset, extentOffset: offset + 1),
      boxHeightStyle: ui.BoxHeightStyle.max,
    );
    if (after.isNotEmpty) {
      final a = after.first;
      if (nearest == null ||
          (a.top - local.dy).abs() < (nearest.top - local.dy).abs()) {
        nearest = a;
      }
    }
    if (nearest != null) {
      // 空末行的行高是**虚高**的:段落以 `\n` 收尾时,Flutter 把那条空行
      // 排成与本段最高行等高(实测 [图片原子, \n] 段落高 318 = 159×2,
      // 空行白白继承了图片行的 159)。此时 `bottom - lineHeight` 会把光标
      // 压到虚高行的底部 —— 就是"图片后回车,光标掉到图下面老远"那个 bug,
      // 随便打个字行高塌回正常值(179)又自己好了。
      //
      // 空行没有内容可对齐,行首就是它该在的地方,所以锚 top。
      final onEmptyTrailingLine = afterLineBreak && offset >= plain.length;
      top = onEmptyTrailingLine ? nearest.top : nearest.bottom - lineHeight;
    }

    return Offset(local.dx, top) & Size(0, lineHeight);
  }

  /// 块的渲染总长度(三击选段用)。走逻辑块表 → 回收块也能取。未注册返回 null。
  int? renderLengthOf(SelectableBlockId blockId) {
    return registry.logicalById(blockId)?.renderLength;
  }
}

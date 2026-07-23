/// 编辑光标几何测试 —— 固化「光标高度构造上恒定」。
///
/// 历史教训(两轮返工):
/// - getFullHeightForCaret 在段末回退裸字体度量(top 下沉、高度变);
/// - getBoxesForSelection 的 tight 盒是字形紧贴高度(中文 16px vs 行高
///   25.6px),max 盒又在空段无盒可取 —— 两版都"位置不同高度不同"。
/// 终版对齐 EditableText/RenderEditable 官方做法:高度 = TextPainter.
/// preferredLineHeight(按 baseStyle 算一次,处处同一个值),垂直落位交给
/// getOffsetForCaret 的 caretPrototype。高度一致性由构造保证,测试只固化
/// 「不同位置 top 一致 + 落位随行」。
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/selection/hit_tester.dart';

void main() {
  const style = TextStyle(fontSize: 16, height: 1.6);

  double lineHeightOf(TextStyle s) {
    final tp = TextPainter(
      text: TextSpan(text: ' ', style: s),
      textDirection: TextDirection.ltr,
    )..layout();
    final h = tp.preferredLineHeight;
    tp.dispose();
    return h;
  }

  Future<RenderParagraph> pumpPara(
    WidgetTester tester,
    String text, {
    double? width,
  }) async {
    // 与 EditableParagraph 同款 strut(空段/满段同高的前提)
    final strut = StrutStyle.fromTextStyle(style, forceStrutHeight: true);
    Widget child = Text.rich(
      TextSpan(text: text, style: style),
      strutStyle: strut,
      key: const Key('p'),
    );
    if (width != null) child = SizedBox(width: width, child: child);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
    return tester.renderObject<RenderParagraph>(find.byKey(const Key('p')));
  }

  testWidgets('中英混排行内:所有位置 top/height 完全一致(含段末)', (tester) async {
    final p = await pumpPara(tester, '中文abc');
    final lh = lineHeightOf(style);
    final rects = [
      for (var i = 0; i <= 5; i++)
        SelectionHitTester.editingCaretRectIn(p, i, lh),
    ];
    final tops = rects.map((r) => r.top).toSet();
    final heights = rects.map((r) => r.height).toSet();
    expect(heights, {lh}, reason: '高度应恒等于 preferredLineHeight');
    expect(tops.length, 1, reason: '同一行所有位置 top 应一致: $tops');
  });

  testWidgets('空段落与非空段落高度一致', (tester) async {
    final lh = lineHeightOf(style);
    final pEmpty = await pumpPara(tester, '');
    final rEmpty = SelectionHitTester.editingCaretRectIn(pEmpty, 0, lh);
    final pFull = await pumpPara(tester, '中文abc');
    final rFull = SelectionHitTester.editingCaretRectIn(pFull, 3, lh);
    expect(rEmpty.height, rFull.height);
  });

  testWidgets('输入前后(空段 vs 有字):top 与 height 都不变', (tester) async {
    final lh = lineHeightOf(style);
    final pEmpty = await pumpPara(tester, '');
    final before = SelectionHitTester.editingCaretRectIn(pEmpty, 0, lh);
    final pTyped = await pumpPara(tester, '1');
    final after = SelectionHitTester.editingCaretRectIn(pTyped, 1, lh);
    expect(after.height, before.height, reason: '输入一个字后光标高度不得变化');
    expect(after.top, closeTo(before.top, 0.5),
        reason: '输入一个字后光标 top 漂移应在亚像素内(行盒 vs 空段度量的舍入差)');
    // 段落自身高度也不突变(strut 保证)
    expect(pTyped.size.height, pEmpty.size.height);
  });

  testWidgets('软换行:第二行位置的 top 在第一行之下', (tester) async {
    final lh = lineHeightOf(style);
    final p = await pumpPara(tester, 'aaaa bbbb', width: 60);
    final first = SelectionHitTester.editingCaretRectIn(p, 1, lh);
    // 段末字符必在换行后的行
    final last = SelectionHitTester.editingCaretRectIn(p, 9, lh);
    expect(last.top, greaterThan(first.top));
    expect(last.height, first.height);
  });


  // ---- 软换行后停在空的末行 ----
  //
  // 回归:回车软换行(段内 `\n`)后光标"偏下",一打字就正常。
  // `\n` 自己的选区盒落在**上一行**,而末行没有任何字符可取盒 ——
  // top 校正若吃了这个盒,光标就会被拽离它该在的行。
  testWidgets('软换行后的空末行:光标落在第二行,不是第一行', (tester) async {
    final lh = lineHeightOf(style);
    final p = await pumpPara(tester, '细说\n');
    final line1 = SelectionHitTester.editingCaretRectIn(p, 0, lh);
    final line2 = SelectionHitTester.editingCaretRectIn(p, 3, lh);
    expect(line2.height, lh, reason: '高度必须恒定');
    expect(
      line2.top,
      closeTo(line1.top + lh, 1.0),
      reason: '空末行光标应正好在第一行下方一个行高处,实际 '
          'line1=${line1.top} line2=${line2.top}',
    );
  });

  testWidgets('空末行 vs 打字后:top 不变', (tester) async {
    final lh = lineHeightOf(style);
    final pEmpty = await pumpPara(tester, '细说\n');
    final rEmpty = SelectionHitTester.editingCaretRectIn(pEmpty, 3, lh);
    final pTyped = await pumpPara(tester, '细说\na');
    final rTyped = SelectionHitTester.editingCaretRectIn(pTyped, 3, lh);
    expect(rEmpty.top, closeTo(rTyped.top, 0.5),
        reason: '打字前后光标不该跳:空=${rEmpty.top} 有字=${rTyped.top}');
  });
}

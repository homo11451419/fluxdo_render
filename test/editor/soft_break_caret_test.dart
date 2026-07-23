/// 回归:软换行(段内 `\n`)后光标落位偏下,随便打个字又正常。
///
/// 段内几何(editingCaretRectIn)已由 editing_caret_rect_test 固化,这里
/// 走**整条链路**(state → 投影 → 命中 → caretRect),抓的是投影/映射层
/// 把末尾 `\n` 丢掉导致 renderOffset 落到别处的那类问题。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart' show ImageRun;

void main() {
  Future<(EditorState, List<Rect?>)> boot(WidgetTester tester) async {
    final rects = <Rect?>[];
    final state = EditorState(blocks: [
      TextBlock(id: 'e_0', content: EditableTextContent(text: '细说')),
    ]);
    state.enterInsertsSoftBreak = true;
    addTearDown(state.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 300,
          child: FluxdoEditor(
            state: state,
            autofocus: true,
            onCaretRectChanged: rects.add,
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    return (state, rects);
  }

  testWidgets('软换行后光标不该乱跳:与随后打字的位置一致', (tester) async {
    final (state, rects) = await boot(tester);

    state.updateSelection(const EditorSelection.collapsed(
      EditorPosition(blockId: 'e_0', offset: 2),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    final beforeBreak = rects.lastWhere((r) => r != null)!;

    // 回车 → 段内软换行,光标停在空的第二行
    state.insertNewline();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    final onEmptyLine = rects.lastWhere((r) => r != null)!;

    // 再打一个字,光标该在同一个地方(只是右移一个字宽)
    state.insertText('a');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    final afterTyping = rects.lastWhere((r) => r != null)!;

    expect(
      onEmptyLine.top,
      closeTo(afterTyping.top, 1.0),
      reason: '空行光标 top=${onEmptyLine.top},打字后 top=${afterTyping.top}'
          '(换行前 top=${beforeBreak.top})',
    );
    expect(
      onEmptyLine.top,
      greaterThan(beforeBreak.top),
      reason: '换行后应该在下一行',
    );
    expect(onEmptyLine.height, closeTo(afterTyping.height, 0.5));

    // 拆掉编辑器,否则光标闪烁 Timer 会在 teardown 报 pending
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  // 真实场景:上传图片 → 手动回车。那一行里有个**高**图片原子,行盒
  // 高度远大于行高,top 校正的基准就不一样了。
  testWidgets('图片原子后软换行:光标不该偏下', (tester) async {
    final rects = <Rect?>[];
    final state = EditorState(blocks: [
      TextBlock(id: 'e_0', content: EditableTextContent(text: '')),
    ]);
    state.enterInsertsSoftBreak = true;
    addTearDown(state.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 600,
          child: FluxdoEditor(
            state: state,
            autofocus: true,
            onCaretRectChanged: rects.add,
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));

    state.updateSelection(const EditorSelection.collapsed(
      EditorPosition(blockId: 'e_0', offset: 0),
    ));
    state.insertAtom(const ImageRun(src: 'x.png', width: 200, height: 150));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));

    state.insertNewline();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    final onEmptyLine = rects.lastWhere((r) => r != null)!;

    state.insertText('a');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    final afterTyping = rects.lastWhere((r) => r != null)!;

    expect(
      onEmptyLine.top,
      closeTo(afterTyping.top, 1.0),
      reason: '空行 top=${onEmptyLine.top},打字后 top=${afterTyping.top}',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
}

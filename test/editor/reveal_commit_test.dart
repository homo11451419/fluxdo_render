/// 显形收口:离开显形区的路径不止方向键 —— 回车切块、退格并块、
/// 失焦提交都必须把字面标记收回结构,否则 `**粗**` 被当正文提交。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/model/editable_text_content.dart';
import 'package:fluxdo_render/src/editor/model/editor_state.dart';

EditorState boldAt(int caret, {List<String> texts = const ['hello world']}) {
  final s = EditorState(blocks: [
    for (var i = 0; i < texts.length; i++)
      TextBlock(
        id: 'b$i',
        content: EditableTextContent(
          text: texts[i],
          marks: i == 0
              ? [const MarkSpan(start: 6, end: 11, kind: MarkKind.strong)]
              : const [],
        ),
      ),
  ]);
  addTearDown(s.dispose);
  // 光标到 mark 边界 → 展开成 "hello **world**"
  s.navigateSelection(
      EditorSelection.collapsed(EditorPosition(blockId: 'b0', offset: caret)));
  return s;
}

TextBlock b(EditorState s, String id) => s.textBlockById(id)!;

void main() {
  test('前置条件:光标到边界确实展开了', () {
    final s = boldAt(6);
    expect(b(s, 'b0').content.text, 'hello **world**');
  });

  test('回车切块前收口 —— 字面标记不会被切进新块', () {
    final s = boldAt(6);
    s.splitBlock();
    // 收口后 b0 恢复成 "hello world" + strong,再按光标切分
    final all = s.blocks.whereType<TextBlock>().map((t) => t.content.text);
    expect(all.join('|').contains('**'), isFalse, reason: '不留字面星号');
    expect(
      s.blocks.whereType<TextBlock>().any(
          (t) => t.content.marks.any((m) => m.kind == MarkKind.strong)),
      isTrue,
      reason: 'strong 已收回成结构',
    );
  });

  test('退格并块前收口', () {
    final s = boldAt(6, texts: ['hello world', '第二段']);
    s.mergeWithPrevious('b1');
    final merged = s.blocks.whereType<TextBlock>().first;
    expect(merged.content.text.contains('**'), isFalse);
    expect(merged.content.marks.any((m) => m.kind == MarkKind.strong), isTrue);
  });

  test('commitReveals 幂等,没显形时是空操作', () {
    final s = boldAt(6);
    s.commitReveals();
    final once = b(s, 'b0').content.text;
    s.commitReveals();
    expect(b(s, 'b0').content.text, once);
    expect(once, 'hello world');
  });
}

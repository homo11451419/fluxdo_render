/// mark reveal 单元测试：光标在 mark 边界时展开标记字符。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';

void main() {
  group('mark reveal', () {
    test('光标移到 bold mark 起始边界时展开 **，光标在开标记之后', () {
      final state = EditorState(blocks: [
        TextBlock(
          id: 'b0',
          content: EditableTextContent(
            text: 'hello world',
            marks: [
              MarkSpan(start: 6, end: 11, kind: MarkKind.strong),
            ],
          ),
        ),
      ]);

      state.navigateSelection(EditorSelection.collapsed(
        EditorPosition(blockId: 'b0', offset: 6),
      ));

      final block = state.blocks[0] as TextBlock;
      expect(block.content.text, 'hello **world**');
      expect(block.content.marks, isEmpty);
      // 光标应在开标记之后 (offset=8)，不是标记之前 (6)
      expect(state.selection!.extent.offset, 8);
    });

    test('光标移到 bold mark 结束边界时展开 **，光标在闭标记之前', () {
      final state = EditorState(blocks: [
        TextBlock(
          id: 'b0',
          content: EditableTextContent(
            text: 'hello world',
            marks: [
              MarkSpan(start: 6, end: 11, kind: MarkKind.strong),
            ],
          ),
        ),
      ]);

      state.navigateSelection(EditorSelection.collapsed(
        EditorPosition(blockId: 'b0', offset: 11),
      ));

      final block = state.blocks[0] as TextBlock;
      expect(block.content.text, 'hello **world**');
      // 光标应在 "world" 之后、闭标记 ** 之前 (offset=13)
      expect(state.selection!.extent.offset, 13);
    });

    test('光标移离展开区域时折叠回来', () {
      final state = EditorState(blocks: [
        TextBlock(
          id: 'b0',
          content: EditableTextContent(
            text: 'hello world end',
            marks: [
              MarkSpan(start: 6, end: 11, kind: MarkKind.strong),
            ],
          ),
        ),
      ]);

      // 先展开
      state.navigateSelection(EditorSelection.collapsed(
        EditorPosition(blockId: 'b0', offset: 6),
      ));
      expect((state.blocks[0] as TextBlock).content.text, 'hello **world** end');

      // 光标移到展开区域外
      state.navigateSelection(EditorSelection.collapsed(
        EditorPosition(blockId: 'b0', offset: 0),
      ));

      final block = state.blocks[0] as TextBlock;
      expect(block.content.text, 'hello world end');
      expect(block.content.marks.length, 1);
      expect(block.content.marks[0].kind, MarkKind.strong);
      expect(block.content.marks[0].start, 6);
      expect(block.content.marks[0].end, 11);
    });

    test('italic mark 展开为 *', () {
      final state = EditorState(blocks: [
        TextBlock(
          id: 'b0',
          content: EditableTextContent(
            text: 'ab',
            marks: [
              MarkSpan(start: 0, end: 2, kind: MarkKind.em),
            ],
          ),
        ),
      ]);

      state.navigateSelection(EditorSelection.collapsed(
        EditorPosition(blockId: 'b0', offset: 0),
      ));

      final block = state.blocks[0] as TextBlock;
      expect(block.content.text, '*ab*');
      expect(block.content.marks, isEmpty);
    });

    test('inline code mark 展开为 `', () {
      final state = EditorState(blocks: [
        TextBlock(
          id: 'b0',
          content: EditableTextContent(
            text: 'code',
            marks: [
              MarkSpan(start: 0, end: 4, kind: MarkKind.inlineCode),
            ],
          ),
        ),
      ]);

      state.navigateSelection(EditorSelection.collapsed(
        EditorPosition(blockId: 'b0', offset: 0),
      ));

      final block = state.blocks[0] as TextBlock;
      expect(block.content.text, '`code`');
    });

    test('光标不在 mark 边界时不展开', () {
      final state = EditorState(blocks: [
        TextBlock(
          id: 'b0',
          content: EditableTextContent(
            text: 'hello world',
            marks: [
              MarkSpan(start: 6, end: 11, kind: MarkKind.strong),
            ],
          ),
        ),
      ]);

      state.navigateSelection(EditorSelection.collapsed(
        EditorPosition(blockId: 'b0', offset: 8),
      ));

      final block = state.blocks[0] as TextBlock;
      expect(block.content.text, 'hello world');
      expect(block.content.marks.length, 1);
    });

    test('展开后输入文字不应跳光标', () {
      final state = EditorState(blocks: [
        TextBlock(
          id: 'b0',
          content: EditableTextContent(
            text: 'hello world',
            marks: [
              MarkSpan(start: 6, end: 11, kind: MarkKind.strong),
            ],
          ),
        ),
      ]);

      // 展开：光标在 offset 8 (开标记之后)
      state.navigateSelection(EditorSelection.collapsed(
        EditorPosition(blockId: 'b0', offset: 6),
      ));
      expect(state.selection!.extent.offset, 8);
      expect(
          (state.blocks[0] as TextBlock).content.text, 'hello **world**');

      // 模拟 IME 输入"啊"在光标位置 (8)
      state.imeReplace('b0', 8, 8, '啊', caretOffset: 9);
      expect(
          (state.blocks[0] as TextBlock).content.text, 'hello **啊world**');
      // 光标应在"啊"之后 (offset 9)，不应跳走
      expect(state.selection!.extent.offset, 9);
    });
  });
}

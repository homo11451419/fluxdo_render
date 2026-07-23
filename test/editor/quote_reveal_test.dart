/// 引用 reveal 测试:光标到引用块首时 `> ` 前缀显形为普通文本(可直接
/// 编辑/删除引用标记),离开时折叠回帧。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/model/editable_text_content.dart';
import 'package:fluxdo_render/src/editor/model/editor_state.dart';

EditorState quoted({int blockCount = 1}) {
  final gid = nextFrameGroupId();
  final s = EditorState(blocks: [
    for (var i = 0; i < blockCount; i++)
      TextBlock(
        id: 'b$i',
        content: EditableTextContent(text: '引用$i'),
        containers: [QuoteFrame(groupId: gid)],
      ),
  ]);
  addTearDown(s.dispose);
  return s;
}

TextBlock blockOf(EditorState s, String id) => s.textBlockById(id)!;

void main() {
  group('引用 reveal', () {
    test('光标到块首 → `> ` 显形,帧被摘下,光标落前缀后', () {
      final s = quoted();
      s.navigateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'b0', offset: 0)));
      final b = blockOf(s, 'b0');
      expect(b.content.text, '> 引用0');
      expect(b.containers, isEmpty);
      expect(s.selection!.extent.offset, 2);
    });

    test('光标离开前缀区 → 折叠回帧,光标平移', () {
      final s = quoted();
      s.navigateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'b0', offset: 0)));
      // 移到文本中部(offset 4 = "> 引|用0" 之后)
      s.navigateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'b0', offset: 4)));
      final b = blockOf(s, 'b0');
      expect(b.content.text, '引用0');
      expect(b.containers.single, isA<QuoteFrame>());
      expect(s.selection!.extent.offset, 2, reason: '前缀长度已扣除');
    });

    test('折叠放回同一帧实例 → groupId 不变,多块引用组重新聚合', () {
      final s = quoted(blockCount: 2);
      final gid = (blockOf(s, 'b1').containers.single as QuoteFrame).groupId;
      s.navigateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'b0', offset: 0)));
      s.navigateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'b1', offset: 1)));
      final f0 = blockOf(s, 'b0').containers.single as QuoteFrame;
      expect(f0.groupId, gid);
    });

    test('前缀被改掉 → 视为去引用:字面保留、帧不放回', () {
      final s = quoted();
      s.navigateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'b0', offset: 0)));
      // 删掉 '>' → 前缀破坏
      s.imeReplace('b0', 0, 1, '', caretOffset: 0);
      s.navigateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'b0', offset: 3)));
      final b = blockOf(s, 'b0');
      expect(b.content.text, ' 引用0');
      expect(b.containers, isEmpty, reason: '去引用');
    });

    test('标题:`# ` 显形,离开还原为同级标题', () {
      final s = EditorState(blocks: [
        TextBlock(
          id: 'b0',
          content: EditableTextContent(text: '标题'),
          kind: TextBlockKind.heading,
          headingLevel: 3,
        ),
      ]);
      addTearDown(s.dispose);
      s.navigateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'b0', offset: 0)));
      expect(blockOf(s, 'b0').content.text, '### 标题');
      expect(blockOf(s, 'b0').isParagraph, isTrue);
      expect(s.selection!.extent.offset, 4);
      expect(s.markerRangesOf('b0'), contains((0, 4)));

      s.navigateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'b0', offset: 5)));
      final b = blockOf(s, 'b0');
      expect(b.content.text, '标题');
      expect(b.isHeading, isTrue);
      expect(b.headingLevel, 3);
      expect(s.selection!.extent.offset, 1);
    });

    test('列表:无序 `- ` / 有序 `3. ` 显形并还原', () {
      var s = EditorState(blocks: [
        TextBlock(
          id: 'b0',
          content: EditableTextContent(text: '项'),
          kind: TextBlockKind.listItem,
        ),
      ]);
      addTearDown(s.dispose);
      s.navigateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'b0', offset: 0)));
      expect(blockOf(s, 'b0').content.text, '- 项');
      s.navigateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'b0', offset: 3)));
      expect(blockOf(s, 'b0').isListItem, isTrue);
      expect(blockOf(s, 'b0').content.text, '项');

      s = EditorState(blocks: [
        TextBlock(
          id: 'b0',
          content: EditableTextContent(text: '项'),
          kind: TextBlockKind.listItem,
          ordered: true,
          listStart: 3,
        ),
      ]);
      addTearDown(s.dispose);
      s.navigateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'b0', offset: 0)));
      expect(blockOf(s, 'b0').content.text, '3. 项');
      s.navigateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'b0', offset: 4)));
      final b = blockOf(s, 'b0');
      expect(b.ordered, isTrue);
      expect(b.listStart, 3);
    });

    test('标题在引用里:只摘最内层标记,引用帧不动', () {
      final s = EditorState(blocks: [
        TextBlock(
          id: 'b0',
          content: EditableTextContent(text: '标题'),
          kind: TextBlockKind.heading,
          headingLevel: 1,
          containers: [QuoteFrame(groupId: nextFrameGroupId())],
        ),
      ]);
      addTearDown(s.dispose);
      s.navigateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'b0', offset: 0)));
      expect(blockOf(s, 'b0').content.text, '# 标题');
      expect(blockOf(s, 'b0').containers.single, isA<QuoteFrame>(),
          reason: '引用帧还在');
      // 离开 → 标题还原,引用帧全程保持
      s.navigateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'b0', offset: 3)));
      final b = blockOf(s, 'b0');
      expect(b.isHeading, isTrue);
      expect(b.containers.single, isA<QuoteFrame>());
    });

    test('非引用块不展开', () {
      final s = EditorState.fromTexts(['普通']);
      addTearDown(s.dispose);
      final id = s.blocks.first.id;
      s.navigateSelection(EditorSelection.collapsed(
          EditorPosition(blockId: id, offset: 0)));
      expect((s.blocks.first as TextBlock).content.text, '普通');
    });
  });
}

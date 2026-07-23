/// 分割线 reveal:方向键进 `***`/`---` 时显形成字面(可直接改格式符
/// 本身),离开时若字面还是分割线就折叠回渲染态 —— 与加粗等行内标记
/// 同一套心智。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart' show HorizontalRuleNode, CodeBlockNode;

EditorState booted() {
  final s = EditorState(blocks: [
    TextBlock(id: 'b0', content: EditableTextContent(text: 'ab')),
    const IslandBlock(id: 'hr', node: HorizontalRuleNode(id: 'n0')),
    TextBlock(id: 'b1', content: EditableTextContent(text: 'cd')),
  ]);
  addTearDown(s.dispose);
  return s;
}

void main() {
  group('分割线 reveal', () {
    test('从左边向右进 → 显形字面,光标落行首', () {
      final s = booted();
      s.updateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'b0', offset: 2)));
      s.moveCaretHorizontal(1);

      expect(s.isRuleRevealed('hr'), isTrue);
      final b = s.textBlockById('hr');
      expect(b, isNotNull, reason: '岛应已换成可编辑文本块');
      expect(b!.content.text, '---');
      expect(s.selection!.extent.offset, 0);
      expect(s.selection!.isCollapsed, isTrue, reason: '不该是整选态');
    });

    test('从右边向左进 → 光标落行尾', () {
      final s = booted();
      s.updateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'b1', offset: 0)));
      s.moveCaretHorizontal(-1);

      expect(s.isRuleRevealed('hr'), isTrue);
      expect(s.textBlockById('hr')!.content.text, '---');
      expect(s.selection!.extent.offset, 3);
    });

    test('字面没改 → 离开时折叠回岛,节点原件复用', () {
      final s = booted();
      s.updateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'b0', offset: 2)));
      s.moveCaretHorizontal(1);
      s.navigateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'b1', offset: 0)));

      expect(s.isRuleRevealed('hr'), isFalse);
      final blk = s.blocks.firstWhere((b) => b.id == 'hr');
      expect(blk, isA<IslandBlock>());
      expect((blk as IslandBlock).node, isA<HorizontalRuleNode>());
      expect(blk.node.id, 'n0', reason: '应复用原节点,不是新建');
    });

    test('字面改成 `***` → 仍是分割线,照样折叠回岛', () {
      final s = booted();
      s.updateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'b0', offset: 2)));
      s.moveCaretHorizontal(1);

      s.updateSelection(const EditorSelection(
        base: EditorPosition(blockId: 'hr', offset: 0),
        extent: EditorPosition(blockId: 'hr', offset: 3),
      ));
      s.deleteSelection();
      s.insertText('***');
      s.navigateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'b1', offset: 0)));

      expect(s.blocks.firstWhere((b) => b.id == 'hr'), isA<IslandBlock>());
    });

    test('字面改成普通文字 → 不硬还原,留成文本块', () {
      final s = booted();
      s.updateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'b0', offset: 2)));
      s.moveCaretHorizontal(1);

      s.updateSelection(const EditorSelection(
        base: EditorPosition(blockId: 'hr', offset: 0),
        extent: EditorPosition(blockId: 'hr', offset: 3),
      ));
      s.deleteSelection();
      s.insertText('你好');
      s.navigateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'b1', offset: 0)));

      final blk = s.blocks.firstWhere((b) => b.id == 'hr');
      expect(blk, isA<TextBlock>());
      expect((blk as TextBlock).content.text, '你好');
    });

    test('字面删空 → 整块移除', () {
      final s = booted();
      s.updateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'b0', offset: 2)));
      s.moveCaretHorizontal(1);

      s.updateSelection(const EditorSelection(
        base: EditorPosition(blockId: 'hr', offset: 0),
        extent: EditorPosition(blockId: 'hr', offset: 3),
      ));
      s.deleteSelection();
      s.navigateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'b1', offset: 0)));

      expect(s.blocks.any((b) => b.id == 'hr'), isFalse);
    });

    test('commitReveals 收口:提交前不会把字面 `---` 当正文留下', () {
      final s = booted();
      s.updateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'b0', offset: 2)));
      s.moveCaretHorizontal(1);
      s.commitReveals();

      expect(s.blocks.firstWhere((b) => b.id == 'hr'), isA<IslandBlock>());
    });

    test('非分割线的岛不受影响,仍是整选', () {
      final s = EditorState(blocks: [
        TextBlock(id: 'b0', content: EditableTextContent(text: 'ab')),
        const IslandBlock(
          id: 'cb',
          node: CodeBlockNode(id: 'n0', code: 'x', language: null),
        ),
      ]);
      addTearDown(s.dispose);
      s.updateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'b0', offset: 2)));
      s.moveCaretHorizontal(1);

      expect(s.isRuleRevealed('cb'), isFalse);
      expect(s.blocks.firstWhere((b) => b.id == 'cb'), isA<IslandBlock>());
      expect(s.selection!.isCollapsed, isFalse, reason: '应是整选态');
    });
  });
}

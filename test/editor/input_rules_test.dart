/// input rules(markdown 快捷语法)测试:块级/行内规则矩阵、触发排除、
/// undo 语义(一步回字面文本)。
library;

import 'dart:ui' show TextRange;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/input/input_rules.dart';
import 'package:fluxdo_render/src/editor/model/editable_text_content.dart';
import 'package:fluxdo_render/src/editor/model/editor_state.dart';
import 'package:fluxdo_render/src/node/inline_node.dart';

/// 模拟打字:插入文本后触发规则(typedChar = 末字符)。
InputRuleOutcome type(EditorState s, String text) {
  s.insertText(text);
  final blockId = s.selection!.extent.blockId;
  return tryApplyInputRules(s, blockId,
      typedChar: text[text.length - 1]);
}

EditorState empty() {
  final s = EditorState.fromTexts(['']);
  addTearDown(s.dispose);
  s.updateSelection(EditorSelection.collapsed(
      EditorPosition(blockId: s.blocks.first.id, offset: 0)));
  return s;
}

TextBlock first(EditorState s) => s.blocks.first as TextBlock;

void main() {
  group('块级规则', () {
    test('# 空格 → H1;###### → H6;7 个 # 不触发', () {
      var s = empty();
      expect(type(s, '# '), InputRuleOutcome.applied);
      expect(first(s).isHeading, isTrue);
      expect(first(s).headingLevel, 1);
      expect(first(s).content.text, '', reason: '标记已删');
      expect(s.selection!.extent.offset, 0);

      s = empty();
      expect(type(s, '###### '), InputRuleOutcome.applied);
      expect(first(s).headingLevel, 6);

      s = empty();
      expect(type(s, '####### '), InputRuleOutcome.none);
      expect(first(s).isHeading, isFalse);
    });

    test('- / * / 1. / 7) → 列表;> → 引用层', () {
      var s = empty();
      expect(type(s, '- '), InputRuleOutcome.applied);
      expect(first(s).isListItem, isTrue);
      expect(first(s).ordered, isFalse);

      s = empty();
      expect(type(s, '* '), InputRuleOutcome.applied);
      expect(first(s).isListItem, isTrue);

      s = empty();
      expect(type(s, '1. '), InputRuleOutcome.applied);
      expect(first(s).ordered, isTrue);
      expect(first(s).listStart, 1);

      s = empty();
      expect(type(s, '7) '), InputRuleOutcome.applied);
      expect(first(s).listStart, 7);

      s = empty();
      expect(type(s, '> '), InputRuleOutcome.applied);
      expect(first(s).containers.single, isA<QuoteFrame>());
      // 再叠一层
      expect(type(s, '> '), InputRuleOutcome.applied);
      expect(first(s).containers.length, 2);
    });

    test('--- 空格 → hrRequest 且标记清空', () {
      final s = empty();
      expect(type(s, '--- '), InputRuleOutcome.hrRequest);
      expect(first(s).content.text, '');
    });

    test('排除:行中打标记不触发;heading 内不再转换;标记区含原子不触发', () {
      var s = empty();
      s.insertText('文字');
      expect(type(s, '# '), InputRuleOutcome.none, reason: '非行首');

      s = empty();
      type(s, '# ');
      s.insertText('标题');
      expect(type(s, '- '), InputRuleOutcome.none, reason: 'heading 内');

      s = empty();
      s.insertAtom(const EmojiRun(name: 'smile', url: 'u'));
      expect(type(s, '# '), InputRuleOutcome.none, reason: '原子在标记区');
    });

    test('undo 语义:一步回字面文本', () {
      final s = empty();
      type(s, '# ');
      expect(first(s).isHeading, isTrue);
      s.undo();
      expect(first(s).isHeading, isFalse);
      expect(first(s).content.text, '# ', reason: 'undo 回到字面标记');
    });
  });

  group('行内规则', () {
    test('**x** → strong;*x* → em;`x` → code;~~x~~ → del', () {
      var s = empty();
      expect(type(s, '前**粗体**'), InputRuleOutcome.applied);
      var b = first(s);
      expect(b.content.text, '前粗体');
      expect(b.content.marks.single,
          const MarkSpan(start: 1, end: 3, kind: MarkKind.strong));
      expect(s.selection!.extent.offset, 3, reason: '光标落内容尾');

      s = empty();
      expect(type(s, '*斜*'), InputRuleOutcome.applied);
      expect(first(s).content.marks.single.kind, MarkKind.em);

      s = empty();
      expect(type(s, '`code`'), InputRuleOutcome.applied);
      b = first(s);
      expect(b.content.text, 'code');
      expect(b.content.marks.single.kind, MarkKind.inlineCode);

      s = empty();
      expect(type(s, '~~删~~'), InputRuleOutcome.applied);
      expect(first(s).content.marks.single.kind, MarkKind.lineThrough);
    });

    test('排除:** 空内容/带空格边缘不触发;code mark 内不触发', () {
      var s = empty();
      expect(type(s, '****'), InputRuleOutcome.none);

      s = empty();
      expect(type(s, '** x**'), InputRuleOutcome.none, reason: '首空格');

      // 光标在 inlineCode mark 内部:字面量区,不触发。
      // (code 边界之后打 *x* 该触发 —— 新字符不在 code 里。)
      final s2 = EditorState(blocks: [
        TextBlock(
          id: 'e_0',
          content: EditableTextContent(text: 'a*x*', marks: const [
            MarkSpan(start: 0, end: 4, kind: MarkKind.inlineCode),
          ]),
        ),
      ]);
      addTearDown(s2.dispose);
      s2.updateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: 4)));
      expect(
        tryApplyInputRules(s2, 'e_0', typedChar: '*'),
        InputRuleOutcome.none,
      );
    });

    test('undo 语义:一步回字面定界符', () {
      final s = empty();
      type(s, '**粗**');
      expect(first(s).content.text, '粗');
      s.undo();
      expect(first(s).content.text, '**粗**');
      expect(first(s).content.marks, isEmpty);
    });

    test('composing 中不触发', () {
      final s = empty();
      s.insertText('**x**');
      s.updateComposing(const TextRange(start: 0, end: 5));
      expect(
        tryApplyInputRules(s, s.blocks.first.id, typedChar: '*'),
        InputRuleOutcome.none,
      );
    });
  });

  group('填内容匹配(先打定界符再回中间填字)', () {
    test('**|** 中间打 q → 命中但保持字面(光标仍夹在定界符间)', () {
      final s = empty();
      s.insertText('****');
      s.updateSelection(EditorSelection.collapsed(
          EditorPosition(blockId: s.blocks.first.id, offset: 2)));
      expect(type(s, 'q'), InputRuleOutcome.applied);
      expect(first(s).content.text, '**q**', reason: '展开态,可继续输入');
      expect(first(s).content.marks, isEmpty);
      expect(s.selection!.extent.offset, 3, reason: '光标在 q 之后');
    });

    test('光标走出闭定界符 → 折叠渲染(行尾也能渲染)', () {
      final s = empty();
      s.insertText('****');
      s.updateSelection(EditorSelection.collapsed(
          EditorPosition(blockId: s.blocks.first.id, offset: 2)));
      type(s, 'q');
      final id = s.blocks.first.id;
      // 右移到闭定界符之后(文本末尾 5)
      s.navigateSelection(
          EditorSelection.collapsed(EditorPosition(blockId: id, offset: 5)));
      expect(first(s).content.text, 'q');
      expect(first(s).content.marks.single.kind, MarkKind.strong);
      expect(s.selection!.extent.offset, 1);
    });

    test('`|` 中间打 x;~~|~~ → 命中(均为字面展开态)', () {
      var s = empty();
      s.insertText('``');
      s.updateSelection(EditorSelection.collapsed(
          EditorPosition(blockId: s.blocks.first.id, offset: 1)));
      expect(type(s, 'x'), InputRuleOutcome.applied);
      expect(first(s).content.text, '`x`');

      s = empty();
      s.insertText('~~~~');
      s.updateSelection(EditorSelection.collapsed(
          EditorPosition(blockId: s.blocks.first.id, offset: 2)));
      expect(type(s, 'x'), InputRuleOutcome.applied);
      expect(first(s).content.text, '~~x~~');
    });

    test('排除:光标后不是定界符不触发;***q*** 归属不明不触发', () {
      var s = empty();
      s.insertText('**qw**');
      s.updateSelection(EditorSelection.collapsed(
          EditorPosition(blockId: s.blocks.first.id, offset: 3)));
      // 光标在 w 前(后面是 w 不是定界符)
      expect(
        tryApplyInputRules(s, s.blocks.first.id, typedChar: 'q'),
        InputRuleOutcome.none,
      );

      s = empty();
      s.insertText('***q***');
      s.updateSelection(EditorSelection.collapsed(
          EditorPosition(blockId: s.blocks.first.id, offset: 4)));
      expect(
        tryApplyInputRules(s, s.blocks.first.id, typedChar: 'q'),
        InputRuleOutcome.none,
      );
    });

    test('mark 展开区内不触发(展开的 ** 是字面编辑态)', () {
      final s = EditorState(blocks: [
        TextBlock(
          id: 'b0',
          content: EditableTextContent(
            text: 'hello world',
            marks: [MarkSpan(start: 6, end: 11, kind: MarkKind.strong)],
          ),
        ),
      ]);
      addTearDown(s.dispose);
      // 光标到边界 → 展开为 "hello **world**",光标 8
      s.navigateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'b0', offset: 6)));
      expect(first(s).content.text, 'hello **world**');
      // 在展开区内打字(光标后不远处有闭 **)—— 规则必须避让
      s.imeReplace('b0', 13, 13, 'x', caretOffset: 14);
      expect(
        tryApplyInputRules(s, 'b0', typedChar: 'x'),
        InputRuleOutcome.none,
      );
      expect(first(s).content.text, 'hello **worldx**', reason: '保持字面');
    });
  });
}

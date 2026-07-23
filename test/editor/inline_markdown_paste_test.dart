/// 纯文本粘贴的轻量 markdown 解析 + 图片/链接 input rule 测试。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/input/input_rules.dart';
import 'package:fluxdo_render/src/editor/model/editable_text_content.dart';
import 'package:fluxdo_render/src/editor/model/editor_state.dart';
import 'package:fluxdo_render/src/editor/model/inline_markdown_parser.dart';
import 'package:fluxdo_render/src/node/inline_node.dart';

void main() {
  group('行内 markdown 解析', () {
    test('**加粗** / *斜* / ~~删~~ / `码`', () {
      final c = parseInlineMarkdown('前**粗**中*斜*后~~删~~尾`码`');
      expect(c.text, '前粗中斜后删尾码');
      expect(c.marks.map((m) => m.kind).toSet(), {
        MarkKind.strong,
        MarkKind.em,
        MarkKind.lineThrough,
        MarkKind.inlineCode,
      });
    });

    test('链接:文字留下,href 进 attr', () {
      final c = parseInlineMarkdown('看[这里](https://a.b)吧');
      expect(c.text, '看这里吧');
      final m = c.marks.single;
      expect(m.kind, MarkKind.link);
      expect(m.attr, 'https://a.b');
      expect((m.start, m.end), (1, 3));
    });

    test('图片 → 原子;不会被链接规则拆掉', () {
      final c = parseInlineMarkdown('图![alt|10x20](upload://a.png)完');
      expect(c.atoms.length, 1);
      final img = c.atoms.values.single as ImageRun;
      expect(img.src, 'upload://a.png');
      expect(img.alt, 'alt');
      expect(img.origWidth, 10);
      expect(c.text.length, 3, reason: '图 + 哨兵 + 完');
    });

    test('无标记文本原样返回', () {
      final c = parseInlineMarkdown('普通一段话');
      expect(c.text, '普通一段话');
      expect(c.marks, isEmpty);
    });
  });

  group('粘贴', () {
    test('pastePlainText 解析行内标记与块级前缀', () {
      final s = EditorState.fromTexts(['']);
      addTearDown(s.dispose);
      s.updateSelection(EditorSelection.collapsed(
          EditorPosition(blockId: s.blocks.first.id, offset: 0)));
      s.pastePlainText('## 标题\n\n**加粗**段\n\n> 引用\n\n- 项');

      final blocks = s.blocks.whereType<TextBlock>().toList();
      final heading = blocks.firstWhere((b) => b.isHeading);
      expect(heading.headingLevel, 2);
      expect(heading.content.text, '标题');

      final bold = blocks.firstWhere(
          (b) => b.content.marks.any((m) => m.kind == MarkKind.strong));
      expect(bold.content.text, '加粗段');

      expect(blocks.any((b) => b.containers.any((f) => f is QuoteFrame)), isTrue);
      expect(blocks.any((b) => b.isListItem), isTrue);
    });
  });

  group('图片 / 链接 input rule', () {
    EditorState typed(String text) {
      final s = EditorState.fromTexts(['']);
      addTearDown(s.dispose);
      s.updateSelection(EditorSelection.collapsed(
          EditorPosition(blockId: s.blocks.first.id, offset: 0)));
      s.insertText(text);
      return s;
    }

    test('打完 `![a](upload://x.png)` 的 `)` → 图片原子', () {
      final s = typed('![a](upload://x.png)');
      expect(tryApplyInputRules(s, s.blocks.first.id, typedChar: ')'),
          InputRuleOutcome.applied);
      final b = s.blocks.first as TextBlock;
      expect(b.content.atoms.length, 1);
      expect((b.content.atoms.values.single as ImageRun).src, 'upload://x.png');
      expect(s.selection!.extent.offset, 1);
    });

    test('打完 `[文字](href)` 的 `)` → link mark', () {
      final s = typed('[文字](https://a.b)');
      expect(tryApplyInputRules(s, s.blocks.first.id, typedChar: ')'),
          InputRuleOutcome.applied);
      final b = s.blocks.first as TextBlock;
      expect(b.content.text, '文字');
      expect(b.content.marks.single.attr, 'https://a.b');
    });

    test('不完整语法不触发', () {
      final s = typed('(abc)');
      expect(tryApplyInputRules(s, s.blocks.first.id, typedChar: ')'),
          InputRuleOutcome.none);
    });
  });
}

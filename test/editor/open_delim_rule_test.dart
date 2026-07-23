/// 补打**开**定界符也要触发行内规则。
///
/// 回归:先打后半截 `诚邀你测试~~`,再回行首补 `~~` —— 光标停在开定界符
/// 之后,原有规则的 `$` 锚定正则只看光标左边,一条都命中不了,表现为
/// 怎么打都不渲染。用户要求「修完排查其他格式是否有此 bug」,所以这里
/// 把**每一种**行内定界符都过一遍。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/src/editor/input/input_rules.dart';

/// 造出「内容 + 闭定界符」已存在、光标刚补完开定界符的状态。
(EditorState, TextBlock) armed(String delim, String content) {
  final text = '$delim$content$delim';
  final s = EditorState(blocks: [
    TextBlock(id: 'b0', content: EditableTextContent(text: text)),
  ]);
  addTearDown(s.dispose);
  // 光标落在开定界符之后 = 刚把它补完
  s.updateSelection(EditorSelection.collapsed(
    EditorPosition(blockId: 'b0', offset: delim.length),
  ));
  return (s, s.textBlockById('b0')!);
}

void main() {
  // (定界符, 期望的 mark)
  const cases = <(String, MarkKind)>[
    ('**', MarkKind.strong),
    ('__', MarkKind.strong),
    ('~~', MarkKind.lineThrough),
    ('*', MarkKind.em),
    ('_', MarkKind.em),
    ('`', MarkKind.inlineCode),
  ];

  group('补打开定界符触发', () {
    for (final (delim, kind) in cases) {
      test('$delim → $kind', () {
        final (s, _) = armed(delim, '诚邀你测试');
        final out = tryApplyInputRules(s, 'b0', typedChar: delim[delim.length - 1]);

        expect(out, InputRuleOutcome.applied, reason: '$delim 应触发');
        final b = s.textBlockById('b0')!;
        expect(b.content.text, '诚邀你测试', reason: '定界符应被吃掉');
        expect(b.content.marksAt(1), contains(kind));
        expect(s.selection!.extent.offset, 0,
            reason: '光标本来就在内容首,不该被甩到尾巴');
      });
    }
  });

  group('不该误触发', () {
    test('右边没有闭定界符', () {
      final s = EditorState(blocks: [
        TextBlock(id: 'b0', content: EditableTextContent(text: '~~诚邀你测试')),
      ]);
      addTearDown(s.dispose);
      s.updateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'b0', offset: 2)));

      expect(tryApplyInputRules(s, 'b0', typedChar: '~'),
          InputRuleOutcome.none);
      expect(s.textBlockById('b0')!.content.text, '~~诚邀你测试');
    });

    test('内容为空(`~~~~`)', () {
      final s = EditorState(blocks: [
        TextBlock(id: 'b0', content: EditableTextContent(text: '~~~~')),
      ]);
      addTearDown(s.dispose);
      s.updateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'b0', offset: 2)));

      expect(tryApplyInputRules(s, 'b0', typedChar: '~'),
          InputRuleOutcome.none);
    });

    test('闭定界符在下一行(不跨软换行)', () {
      final s = EditorState(blocks: [
        TextBlock(
            id: 'b0', content: EditableTextContent(text: '~~诚邀\n你测试~~')),
      ]);
      addTearDown(s.dispose);
      s.updateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'b0', offset: 2)));

      expect(tryApplyInputRules(s, 'b0', typedChar: '~'),
          InputRuleOutcome.none);
    });

    test('内容首是空格(CommonMark 语义)', () {
      final s = EditorState(blocks: [
        TextBlock(id: 'b0', content: EditableTextContent(text: '~~ 测试~~')),
      ]);
      addTearDown(s.dispose);
      s.updateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'b0', offset: 2)));

      expect(tryApplyInputRules(s, 'b0', typedChar: '~'),
          InputRuleOutcome.none);
    });
  });

  test('原有路径不受影响:打完闭定界符仍然触发,光标在内容尾', () {
    final s = EditorState(blocks: [
      TextBlock(id: 'b0', content: EditableTextContent(text: '~~测试~~')),
    ]);
    addTearDown(s.dispose);
    s.updateSelection(const EditorSelection.collapsed(
        EditorPosition(blockId: 'b0', offset: 6)));

    expect(tryApplyInputRules(s, 'b0', typedChar: '~'),
        InputRuleOutcome.applied);
    final b = s.textBlockById('b0')!;
    expect(b.content.text, '测试');
    expect(s.selection!.extent.offset, 2, reason: '这条路径光标该在内容尾');
  });
}

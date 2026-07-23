/// IME 序列回放测试 —— 把 CJK composing 行为固化下来,不依赖真机。
///
/// 场景:模拟平台侧(输入法)按真实时序回调 updateEditingValue,断言
/// 文档/composing/undo 的最终状态。回放值带 pad 前缀(与运行时平台
/// 回显一致);pad 剥除、diff、事务映射全链路被覆盖。
library;

import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/input/editor_ime_client.dart';
import 'package:fluxdo_render/src/editor/model/editable_text_content.dart';
import 'package:fluxdo_render/src/editor/model/editor_state.dart';
import 'package:fluxdo_render/src/node/inline_node.dart';

// pad \u4e0e\u8fd0\u884c\u65f6\u540c\u6e90(\u7a7a\u683c;\u66fe\u7528 ZWSP \u7591\u88ab macOS \u8f93\u5165\u4e0a\u4e0b\u6587\u5265\u79bb)
final pad = EditorImeClient.padCharForTesting;

void main() {
  _cjkCommitRuleTests();
  _softBreakTests();
  TestWidgetsFlutterBinding.ensureInitialized();

  (EditorState, EditorImeClient) makeAttached({
    List<String> paragraphs = const ['第一段', 'second'],
    int blockIndex = 0,
    int caret = 3,
  }) {
    final state = EditorState.fromTexts(paragraphs);
    final block = state.blocks[blockIndex] as TextBlock;
    state.updateSelection(EditorSelection.collapsed(
      EditorPosition(blockId: block.id, offset: caret),
    ));
    final ime = EditorImeClient(state: state);
    ime.debugAttachToBlock(
      block.id,
      EditorImeClient.debugFormat(
        TextEditingValue(
          text: block.content.text,
          selection: TextSelection.collapsed(offset: caret),
        ),
      ),
    );
    return (state, ime);
  }

  group('拼音 composing 全流程', () {
    test('n → ni → 你 上屏', () {
      final (state, ime) = makeAttached();

      // 打 'n':composing [3,4)(未 pad 坐标)
      ime.updateEditingValue(TextEditingValue(
        text: '$pad第一段n',
        selection: const TextSelection.collapsed(offset: 5),
        composing: const TextRange(start: 4, end: 5),
      ));
      expect((state.blocks[0] as TextBlock).content.text, '第一段n');
      expect(state.composing, const TextRange(start: 3, end: 4));
      expect(state.hasComposing, true);

      // 打 'i'
      ime.updateEditingValue(TextEditingValue(
        text: '$pad第一段ni',
        selection: const TextSelection.collapsed(offset: 6),
        composing: const TextRange(start: 4, end: 6),
      ));
      expect((state.blocks[0] as TextBlock).content.text, '第一段ni');
      expect(state.composing, const TextRange(start: 3, end: 5));

      // 空格上屏 '你':预编辑整段替换,composing 清空
      ime.updateEditingValue(TextEditingValue(
        text: '$pad第一段你',
        selection: const TextSelection.collapsed(offset: 5),
        composing: TextRange.empty,
      ));
      expect((state.blocks[0] as TextBlock).content.text, '第一段你');
      expect(state.hasComposing, false);
      expect(state.selection!.extent.offset, 4);
    });

    test('composing 中退格(ni → n)', () {
      final (state, ime) = makeAttached();
      ime.updateEditingValue(TextEditingValue(
        text: '$pad第一段ni',
        selection: const TextSelection.collapsed(offset: 6),
        composing: const TextRange(start: 4, end: 6),
      ));
      ime.updateEditingValue(TextEditingValue(
        text: '$pad第一段n',
        selection: const TextSelection.collapsed(offset: 5),
        composing: const TextRange(start: 4, end: 5),
      ));
      expect((state.blocks[0] as TextBlock).content.text, '第一段n');
      expect(state.composing, const TextRange(start: 3, end: 4));
    });

    test('一次拼音上屏 = 一个 undo 步(composition 结束 seal)', () {
      final (state, ime) = makeAttached();
      ime.updateEditingValue(TextEditingValue(
        text: '$pad第一段n',
        selection: const TextSelection.collapsed(offset: 5),
        composing: const TextRange(start: 4, end: 5),
      ));
      ime.updateEditingValue(TextEditingValue(
        text: '$pad第一段ni',
        selection: const TextSelection.collapsed(offset: 6),
        composing: const TextRange(start: 4, end: 6),
      ));
      ime.updateEditingValue(TextEditingValue(
        text: '$pad第一段你',
        selection: const TextSelection.collapsed(offset: 5),
        composing: TextRange.empty,
      ));
      expect((state.blocks[0] as TextBlock).content.text, '第一段你');
      state.undo();
      // 整个 n→ni→你 过程一步撤销
      expect((state.blocks[0] as TextBlock).content.text, '第一段');
    });

    test('30 字长句连续上屏不丢字不乱序', () {
      final (state, ime) = makeAttached(paragraphs: [''], caret: 0);
      const sentence = '这是一个用来验证连续中文输入不丢字符也不乱序的完整长句子测试';
      var committed = '';
      for (final ch in sentence.characters) {
        // 每个字:composing 'x' → 上屏 ch
        ime.updateEditingValue(TextEditingValue(
          text: '$pad${committed}x',
          selection: TextSelection.collapsed(offset: committed.length + 2),
          composing: TextRange(
            start: committed.length + 1,
            end: committed.length + 2,
          ),
        ));
        committed += ch;
        ime.updateEditingValue(TextEditingValue(
          text: '$pad$committed',
          selection: TextSelection.collapsed(offset: committed.length + 1),
          composing: TextRange.empty,
        ));
      }
      expect((state.blocks[0] as TextBlock).content.text, sentence);
    });
  });

  group('平台回显防御(macOS 引擎回显 setEditingState)', () {
    test('无 composing 的纯选区回显不得移动编辑器选区(拖选不被折叠)', () {
      final (state, ime) = makeAttached(paragraphs: ['1111111111'], caret: 2);
      // 用户拖选 [3,8](手势路径写入)
      final id = state.blocks[0].id;
      state.updateSelection(EditorSelection(
        base: EditorPosition(blockId: id, offset: 3),
        extent: EditorPosition(blockId: id, offset: 8),
      ));
      // 平台滞后回显旧光标位置(无 composing、文本没变)
      ime.updateEditingValue(TextEditingValue(
        text: '${pad}1111111111',
        selection: const TextSelection.collapsed(offset: 3),
        composing: TextRange.empty,
      ));
      // 选区必须保持 [3,8],不被回显折叠/搬走
      expect(state.selection!.isCollapsed, false);
      expect(state.selection!.base.offset, 3);
      expect(state.selection!.extent.offset, 8);
    });

    test('非回显的全选形状选区 = 菜单 Select All,升格全文档全选', () {
      final (state, ime) = makeAttached(paragraphs: ['abcde', 'fgh'], caret: 2);
      // 平台主动发全段选择(0..len;非 setEditingState 回显 —— 指纹
      // 缓冲里没有这个形状)
      ime.updateEditingValue(TextEditingValue(
        text: '${pad}abcde',
        selection: const TextSelection(baseOffset: 1, extentOffset: 6),
        composing: TextRange.empty,
      ));
      final sel = state.selection!;
      expect(sel.isCollapsed, false);
      expect(sel.base.blockId, state.blocks.first.id);
      expect(sel.extent.blockId, state.blocks.last.id, reason: '跨段全选');
    });

    test('composing 活跃时的光标通知仍被采纳(候选窗交互)', () {
      final (state, ime) = makeAttached();
      ime.updateEditingValue(TextEditingValue(
        text: '$pad第一段ni',
        selection: const TextSelection.collapsed(offset: 6),
        composing: const TextRange(start: 4, end: 6),
      ));
      // composing 中平台移动光标(仍在 composing)
      ime.updateEditingValue(TextEditingValue(
        text: '$pad第一段ni',
        selection: const TextSelection.collapsed(offset: 5),
        composing: const TextRange(start: 4, end: 6),
      ));
      expect(state.selection!.extent.offset, 4);
      expect(state.hasComposing, true);
    });

    test('attach 后的空值/陈旧回显不触发段落合并', () {
      final (state, ime) = makeAttached(
        paragraphs: const ['第一段', 'second'],
        blockIndex: 1,
        caret: 3,
      );
      // 平台回显完全陈旧的值(无 pad 且!= 上次值去 pad,如 attach 竞态)
      ime.updateEditingValue(const TextEditingValue(
        text: 'sec',
        selection: TextSelection.collapsed(offset: 0),
      ));
      // 不得合并段落
      expect(state.blocks.length, 2);
      expect((state.blocks[1] as TextBlock).content.text, 'second');
    });
  });

  group('pad 段首退格', () {
    test('pad 被删 → 与上一段合并', () {
      final (state, ime) = makeAttached(
        paragraphs: const ['第一段', 'second'],
        blockIndex: 1,
        caret: 0,
      );
      // 平台上报的文本不再以 pad 开头 = pad 被退格删掉
      ime.updateEditingValue(const TextEditingValue(
        text: 'second',
        selection: TextSelection.collapsed(offset: 0),
      ));
      expect(state.blocks.length, 1);
      expect((state.blocks[0] as TextBlock).content.text, '第一段second');
      expect(state.selection!.extent.offset, 3);
    });
  });

  group('平台 quirk', () {
    test('macOS composing collapsed → 视为无 composing', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      final (state, ime) = makeAttached();
      ime.updateEditingValue(TextEditingValue(
        text: '$pad第一段n',
        selection: const TextSelection.collapsed(offset: 5),
        // collapsed composing(macOS 中文 IME 删净预编辑时的形态)
        composing: const TextRange(start: 5, end: 5),
      ));
      expect(state.hasComposing, false);
    });

    test('IME 直插 \\n(不走 performAction 的回车)→ 分段', () {
      final (state, ime) = makeAttached();
      ime.updateEditingValue(TextEditingValue(
        text: '$pad第一段\n',
        selection: const TextSelection.collapsed(offset: 5),
        composing: TextRange.empty,
      ));
      expect(state.blocks.length, 3);
      expect((state.blocks[0] as TextBlock).content.text, '第一段');
      expect((state.blocks[1] as TextBlock).content.text, '');
    });
  });

  group('原子(FFFC)在 IME 窗口', () {
    (EditorState, EditorImeClient) makeWithAtom() {
      // "ab￼cd",原子在 2,光标在 3(原子后)
      const emoji = EmojiRun(name: 'heart', url: 'u');
      final state = EditorState(blocks: [
        TextBlock(
          id: 'e_0',
          content: EditableTextContent(
            text: 'ab${kAtomChar}cd',
            atoms: const {2: emoji},
          ),
        ),
      ]);
      state.updateSelection(const EditorSelection.collapsed(
        EditorPosition(blockId: 'e_0', offset: 3),
      ));
      final ime = EditorImeClient(state: state);
      ime.debugAttachToBlock(
        'e_0',
        EditorImeClient.debugFormat(
          TextEditingValue(
            text: 'ab${kAtomChar}cd',
            selection: const TextSelection.collapsed(offset: 3),
          ),
        ),
      );
      return (state, ime);
    }

    test('原子后打拼音上屏:原子身份保留、位置不动', () {
      final (state, ime) = makeWithAtom();
      ime.updateEditingValue(TextEditingValue(
        text: '${pad}ab${kAtomChar}nicd',
        selection: const TextSelection.collapsed(offset: 6),
        composing: const TextRange(start: 4, end: 6),
      ));
      var c = (state.blocks[0] as TextBlock).content;
      expect(c.text, 'ab${kAtomChar}nicd');
      expect(c.atoms[2], isNotNull);
      ime.updateEditingValue(TextEditingValue(
        text: '${pad}ab$kAtomChar你cd',
        selection: const TextSelection.collapsed(offset: 5),
        composing: TextRange.empty,
      ));
      c = (state.blocks[0] as TextBlock).content;
      expect(c.text, 'ab$kAtomChar你cd');
      expect(c.atoms[2], isNotNull);
    });

    test('平台上报少一个 FFFC = 退格删原子:身份同步消失', () {
      final (state, ime) = makeWithAtom();
      ime.updateEditingValue(TextEditingValue(
        text: '${pad}abcd',
        selection: const TextSelection.collapsed(offset: 3),
        composing: TextRange.empty,
      ));
      final c = (state.blocks[0] as TextBlock).content;
      expect(c.text, 'abcd');
      expect(c.atoms, isEmpty);
    });

    test('replacement 携带裸 FFFC:被剥除,不产孤儿哨兵', () {
      final (state, ime) = makeWithAtom();
      // 平台幻造:在光标处"插入"一个裸 FFFC + x
      ime.updateEditingValue(TextEditingValue(
        text: '${pad}ab$kAtomChar${kAtomChar}xcd',
        selection: const TextSelection.collapsed(offset: 5),
        composing: TextRange.empty,
      ));
      final c = (state.blocks[0] as TextBlock).content;
      expect(c.text, 'ab${kAtomChar}xcd');
      expect(c.atoms.length, 1);
      expect(c.atoms[2], isNotNull);
    });
  });

  group('Windows 两步上屏(真机日志固化)', () {
    test('上屏报文选区滞后在组首,收尾通知带最终光标 → 必须采纳', () {
      // 真机日志:
      //   recv " 你好" sel=1..1 comp=1..3   ← 文本落地,选区滞后在组首
      //   recv " 你好" sel=3..3 comp=empty  ← 收尾通知,真实光标
      // 旧实现忽略收尾通知的选区 → 光标停在打的字前面。
      final (state, ime) = makeAttached(paragraphs: [''], caret: 0);
      // 拼音 "ni'h" 预编辑
      ime.updateEditingValue(TextEditingValue(
        text: "${pad}ni'h",
        selection: const TextSelection.collapsed(offset: 5),
        composing: const TextRange(start: 1, end: 5),
      ));
      // 上屏第一步:文本变"你好",选区滞后在组首
      ime.updateEditingValue(TextEditingValue(
        text: '$pad你好',
        selection: const TextSelection.collapsed(offset: 1),
        composing: const TextRange(start: 1, end: 3),
      ));
      // 上屏第二步:收尾通知(无文本变化,composing 清空,最终光标)
      ime.updateEditingValue(TextEditingValue(
        text: '$pad你好',
        selection: const TextSelection.collapsed(offset: 3),
        composing: TextRange.empty,
      ));
      expect((state.blocks[0] as TextBlock).content.text, '你好');
      expect(state.hasComposing, false);
      expect(state.selection!.extent.offset, 2, reason: '光标在"你好"之后');
    });

    test('mark 展开状态下两步上屏:光标落在新字之后', () {
      final state = EditorState(blocks: [
        TextBlock(
          id: 'b0',
          content: EditableTextContent(
            text: 'hello world',
            marks: [MarkSpan(start: 6, end: 11, kind: MarkKind.strong)],
          ),
        ),
      ]);
      // 光标到 bold 起始边界 → 展开为 "hello **world**",光标 8
      state.navigateSelection(const EditorSelection.collapsed(
        EditorPosition(blockId: 'b0', offset: 6),
      ));
      expect((state.blocks[0] as TextBlock).content.text, 'hello **world**');
      expect(state.selection!.extent.offset, 8);

      final ime = EditorImeClient(state: state);
      ime.debugAttachToBlock(
        'b0',
        EditorImeClient.debugFormat(
          const TextEditingValue(
            text: 'hello **world**',
            selection: TextSelection.collapsed(offset: 8),
          ),
        ),
      );
      // 拼音预编辑 "a"
      ime.updateEditingValue(TextEditingValue(
        text: '${pad}hello **aworld**',
        selection: const TextSelection.collapsed(offset: 10),
        composing: const TextRange(start: 9, end: 10),
      ));
      // 上屏第一步:选区滞后在组首
      ime.updateEditingValue(TextEditingValue(
        text: '${pad}hello **啊world**',
        selection: const TextSelection.collapsed(offset: 9),
        composing: const TextRange(start: 9, end: 10),
      ));
      // 上屏第二步:收尾通知带最终光标
      ime.updateEditingValue(TextEditingValue(
        text: '${pad}hello **啊world**',
        selection: const TextSelection.collapsed(offset: 10),
        composing: TextRange.empty,
      ));
      expect(
          (state.blocks[0] as TextBlock).content.text, 'hello **啊world**');
      expect(state.selection!.extent.offset, 9, reason: '光标在"啊"之后');
    });
  });

  group('英文直输', () {
    test('逐字符插入 + 光标跟随', () {
      final (state, ime) = makeAttached(paragraphs: ['ab'], caret: 1);
      ime.updateEditingValue(TextEditingValue(
        text: '${pad}aXb',
        selection: const TextSelection.collapsed(offset: 3),
        composing: TextRange.empty,
      ));
      expect((state.blocks[0] as TextBlock).content.text, 'aXb');
      expect(state.selection!.extent.offset, 2);
    });

    test('选中替换(平台侧一次性替换)', () {
      final (state, ime) = makeAttached(paragraphs: ['hello world'], caret: 5);
      // 平台把 'hello' 换成 'hi'
      ime.updateEditingValue(TextEditingValue(
        text: '${pad}hi world',
        selection: const TextSelection.collapsed(offset: 3),
        composing: TextRange.empty,
      ));
      expect((state.blocks[0] as TextBlock).content.text, 'hi world');
      expect(state.selection!.extent.offset, 2);
    });
  });
}

/// 段内软换行(cook 的 `<br>` 导入形态)必须扛得住 IME 回调。
///
/// 真机回归:网页端带换行的草稿在 fluxdo 打开后,只要打一个字,整段
/// 换行全没、几行并成一行 —— 早先 IME 层无条件 `replaceAll('\n','')`,
/// 把"段内既有软换行"和"平台插入的回车"一起洗了。
void _softBreakTests() {
  final pad = EditorImeClient.padCharForTesting;

  group('段内软换行', () {
    (EditorState, EditorImeClient) attach(String text, {int? caret}) {
      final c = caret ?? text.length;
      final state = EditorState(blocks: [
        TextBlock(id: 'b0', content: EditableTextContent(text: text)),
      ]);
      state.updateSelection(EditorSelection.collapsed(
          EditorPosition(blockId: 'b0', offset: c)));
      final ime = EditorImeClient(state: state);
      ime.debugAttachToBlock(
        'b0',
        EditorImeClient.debugFormat(TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: c),
        )),
      );
      return (state, ime);
    }

    String textOf(EditorState s) => (s.blocks.first as TextBlock).content.text;

    test('末尾打字:既有换行原样保留', () {
      const t = '第一行\n第二行\n第三行';
      final (state, ime) = attach(t);
      ime.updateEditingValue(TextEditingValue(
        text: '$pad$t*',
        selection: TextSelection.collapsed(offset: t.length + 2),
      ));
      expect(textOf(state), '$t*');
    });

    test('中间打字:换行数不变', () {
      const t = '第一行\n第二行';
      final (state, ime) = attach(t, caret: 3);
      ime.updateEditingValue(TextEditingValue(
        text: '$pad第一行X\n第二行',
        selection: const TextSelection.collapsed(offset: 5),
      ));
      expect(textOf(state), '第一行X\n第二行');
    });

    test('平台插入的换行仍然是分段(不进文本)', () {
      const t = '第一行\n第二行';
      final (state, ime) = attach(t);
      ime.updateEditingValue(TextEditingValue(
        text: '$pad$t\n',
        selection: TextSelection.collapsed(offset: t.length + 2),
      ));
      expect(state.blocks.length, 2, reason: '回车 → 分段');
      expect(textOf(state), t, reason: '既有软换行没被吃');
    });
  });
}

/// CJK 上屏收尾补判 input rules(真机日志固化)。
///
/// 失效顺序:先打 `**`,再打拼音,再打闭合 `**`,最后才上屏 —— 敲 `*` 时
/// 拼音还在 composing 里,规则按约定跳过;上屏通知的 diff.inserted 是空的,
/// 普通路径也进不来,于是 `**编辑器**` 永远停在字面星号。
void _cjkCommitRuleTests() {
  final pad = EditorImeClient.padCharForTesting;

  group('CJK 上屏后补判 input rules', () {
    (EditorState, EditorImeClient) attach(String text, int caret) {
      final state = EditorState(blocks: [
        TextBlock(id: 'b0', content: EditableTextContent(text: text)),
      ]);
      state.updateSelection(EditorSelection.collapsed(
          EditorPosition(blockId: 'b0', offset: caret)));
      final ime = EditorImeClient(state: state);
      ime.debugAttachToBlock(
        'b0',
        EditorImeClient.debugFormat(TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: caret),
        )),
      );
      return (state, ime);
    }

    TextBlock blk(EditorState s) => s.blocks.first as TextBlock;

    test('**拼音** 上屏 → 加粗(真机日志回放)', () {
      // lastSent = "**bian'ji'qi**"(拼音在 composing 里,闭合 ** 已敲)
      const typing = "新版fluxdo**bian'ji'qi**";
      final (state, ime) = attach(typing, typing.length);
      // 上屏:拼音段替换成「编辑器」,composing 仍标着新文本
      ime.updateEditingValue(TextEditingValue(
        text: '$pad新版fluxdo**编辑器**',
        selection: const TextSelection.collapsed(offset: 15),
        composing: const TextRange(start: 15, end: 18),
      ));
      // 收尾:composing 清空 —— 补判在这一刻发生
      ime.updateEditingValue(TextEditingValue(
        text: '$pad新版fluxdo**编辑器**',
        selection: const TextSelection.collapsed(offset: 18),
      ));
      expect(blk(state).content.text, '新版fluxdo编辑器');
      expect(blk(state).content.marks.single.kind, MarkKind.strong);
    });

    test('~~拼音~~ 上屏 → 删除线', () {
      const typing = "~~huan'wo~~";
      final (state, ime) = attach(typing, typing.length);
      ime.updateEditingValue(TextEditingValue(
        text: '$pad~~换我~~',
        selection: const TextSelection.collapsed(offset: 5),
        composing: const TextRange(start: 3, end: 5),
      ));
      ime.updateEditingValue(TextEditingValue(
        text: '$pad~~换我~~',
        selection: const TextSelection.collapsed(offset: 7),
      ));
      expect(blk(state).content.text, '换我');
      expect(blk(state).content.marks.single.kind, MarkKind.lineThrough);
    });

    test('上屏后不成对 → 不误触发', () {
      const typing = "**bian'ji";
      final (state, ime) = attach(typing, typing.length);
      ime.updateEditingValue(TextEditingValue(
        text: '$pad**编辑',
        selection: const TextSelection.collapsed(offset: 3),
        composing: const TextRange(start: 3, end: 5),
      ));
      ime.updateEditingValue(TextEditingValue(
        text: '$pad**编辑',
        selection: const TextSelection.collapsed(offset: 5),
      ));
      expect(blk(state).content.text, '**编辑', reason: '没有闭合定界符');
      expect(blk(state).content.marks, isEmpty);
    });
  });
}

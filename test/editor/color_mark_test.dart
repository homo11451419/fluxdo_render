/// 颜色 mark(`[color=…]` / `[bgcolor=…]`)测试。
///
/// 核心诉求:带色文字必须**可编辑**。此前 ColoredRun 不在可编辑白名单,
/// 打一句带色的话整行被岛化成只读岛,光标直接消失(实测复现)。
library;

import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

const _red = Color(0xFFFF0000);

ParagraphNode _colored({Color? fg, Color? bg, String text = '红字'}) =>
    ParagraphNode(id: 'p', inlines: [
      ColoredRun(color: fg, background: bg, children: [TextRun(text)]),
    ]);

void main() {
  group('可编辑性(核心)', () {
    test('ColoredRun 在可编辑白名单里 —— 不再岛化', () {
      expect(
        isEditableInline(
          const ColoredRun(color: _red, children: [TextRun('a')]),
        ),
        isTrue,
      );
    });

    test('带色段落落成 TextBlock 而不是只读岛', () {
      var n = 0;
      final doc = blockNodesToDoc([_colored(fg: _red)], () => 'e_${n++}');
      expect(doc.single, isA<TextBlock>(), reason: '岛化会让光标消失');
      expect((doc.single as TextBlock).content.text, '红字');
    });

    test('带色文字照常可插入编辑', () {
      var n = 0;
      final doc = blockNodesToDoc([_colored(fg: _red)], () => 'e_${n++}');
      final block = doc.single as TextBlock;
      final edited = block.content.insert(block.content.length, '继续打字');
      expect(edited.text, '红字继续打字');
    });
  });

  group('mark 往返', () {
    test('前景色 → mark(带色值 attr)', () {
      var n = 0;
      final doc = blockNodesToDoc([_colored(fg: _red)], () => 'e_${n++}');
      final marks = (doc.single as TextBlock).content.marks;
      final m = marks.singleWhere((m) => m.kind == MarkKind.textColor);
      expect(m.attr, '#ff0000');
      expect(m.start, 0);
      expect(m.end, 2);
    });

    test('背景色走 bgColor', () {
      var n = 0;
      final doc = blockNodesToDoc([_colored(bg: _red)], () => 'e_${n++}');
      final marks = (doc.single as TextBlock).content.marks;
      expect(marks.single.kind, MarkKind.bgColor);
      expect(marks.single.attr, '#ff0000');
    });

    test('序列化成 BBCode', () {
      var n = 0;
      final doc = blockNodesToDoc([_colored(fg: _red)], () => 'e_${n++}');
      expect(docToMarkdown(doc), '[color=#ff0000]红字[/color]');
    });

    test('前景+背景同时存在', () {
      var n = 0;
      final doc = blockNodesToDoc(
        [_colored(fg: _red, bg: const Color(0xFF00FF00))],
        () => 'e_${n++}',
      );
      final raw = docToMarkdown(doc);
      expect(raw, contains('[color=#ff0000]'));
      expect(raw, contains('[bgcolor=#00ff00]'));
    });

    test('toInlines 还原出 ColoredRun', () {
      var n = 0;
      final doc = blockNodesToDoc([_colored(fg: _red)], () => 'e_${n++}');
      final inlines = (doc.single as TextBlock).content.toInlines();
      final colored = inlines.whereType<ColoredRun>().single;
      expect(colored.color, _red);
    });
  });

  _revealTests();

  group('色值解析', () {
    test('#rgb 与 #rrggbb 都认,非法返回 null', () {
      expect(EditableTextContent.parseHex('#f00'), const Color(0xFFFF0000));
      expect(EditableTextContent.parseHex('#ff0000'), const Color(0xFFFF0000));
      expect(EditableTextContent.parseHex('red'), isNull);
      expect(EditableTextContent.parseHex('#12345'), isNull);
      expect(EditableTextContent.parseHex(null), isNull);
    });
  });
}

/// 显形往返:光标进边界 → 展开成 `[color=#xxx]…[/color]` 字面量 →
/// 改完色值 → 折叠回带新颜色的 mark。这是"能像 markdown 一样改格式"
/// 的核心能力(此前颜色被排除在显形之外,只能退格删掉重打)。
void _revealTests() {
  group('显形往返', () {
    EditableTextContent colored() {
      var n = 0;
      final doc = blockNodesToDoc([
        const ParagraphNode(id: 'p', inlines: [
          ColoredRun(color: _red, children: [TextRun('红字')]),
        ]),
      ], () => 'e_${n++}');
      return (doc.single as TextBlock).content;
    }

    test('边界能取到颜色 mark(不再被排除)', () {
      final c = colored();
      expect(c.markAtBoundary(0)?.kind, MarkKind.textColor);
    });

    test('展开成带色值的字面量', () {
      final c = colored();
      final mark = c.markAtBoundary(0)!;
      final (revealed, _) = c.revealMark(mark, 0);
      expect(revealed.text, '[color=#ff0000]红字[/color]');
      expect(revealed.marks.where((m) => m.kind == MarkKind.textColor), isEmpty,
          reason: '展开态没有 mark,只有字面量');
    });

    test('原样折叠回来,颜色不丢', () {
      final c = colored();
      final mark = c.markAtBoundary(0)!;
      final (revealed, _) = c.revealMark(mark, 0);
      final r = revealed.collapseMark(0, MarkKind.textColor, 0);
      expect(r, isNotNull);
      expect(r!.$1.text, '红字');
      expect(r.$3.attr, '#ff0000');
    });

    test('改了色值再折叠 → 新颜色生效', () {
      final c = colored();
      final mark = c.markAtBoundary(0)!;
      var (revealed, _) = c.revealMark(mark, 0);
      // 把 #ff0000 改成 #00ff00(长度相同但值不同)
      revealed = revealed.replace(0, '[color=#ff0000]'.length, '[color=#00ff00]');
      final r = revealed.collapseMark(0, MarkKind.textColor, 0);
      expect(r, isNotNull, reason: '改过色值也要能折叠回去');
      expect(r!.$3.attr, '#00ff00');
    });

    test('色值改成不同长度也能折叠(正则容错,不是定长比对)', () {
      final c = colored();
      final mark = c.markAtBoundary(0)!;
      var (revealed, _) = c.revealMark(mark, 0);
      revealed = revealed.replace(0, '[color=#ff0000]'.length, '[color=red]');
      final r = revealed.collapseMark(0, MarkKind.textColor, 0);
      expect(r, isNotNull);
      expect(r!.$3.attr, 'red');
    });
  });
}

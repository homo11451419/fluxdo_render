/// 大表情(only-emoji)判定测试。
///
/// 规则对齐 cook 引擎实测:整段只有 emoji(空白不算内容)且 ≤3 个 →
/// 全部大号;≥4 个或掺了别的内容 → 全部普通。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

EditableTextContent _content(List<InlineNode> atoms, {String between = ''}) {
  var c = EditableTextContent(text: '');
  for (var i = 0; i < atoms.length; i++) {
    if (i > 0 && between.isNotEmpty) {
      c = c.insert(c.length, between);
    }
    c = c.insertAtom(c.length, atoms[i]);
  }
  return c;
}

EmojiRun _e([String name = 'rofl']) => EmojiRun(name: name, url: '$name.png');

List<bool> _flags(EditableTextContent c) => [
  for (final n in c.toInlines())
    if (n is EmojiRun) n.isOnlyEmoji,
];

void main() {
  group('整段只有 emoji', () {
    test('1 个 → 大', () {
      expect(_flags(_content([_e()])), [true]);
    });

    test('3 个 → 全大(上限)', () {
      expect(_flags(_content([_e(), _e(), _e()], between: ' ')), [
        true,
        true,
        true,
      ]);
    });

    test('4 个 → 全部不大', () {
      expect(_flags(_content([_e(), _e(), _e(), _e()], between: ' ')), [
        false,
        false,
        false,
        false,
      ]);
    });

    test('紧挨着不加空格也算', () {
      expect(_flags(_content([_e(), _e()])), [true, true]);
    });

    test('前后有空白仍算(空白不是内容)', () {
      var c = EditableTextContent(text: '');
      c = c.insert(0, '  ');
      c = c.insertAtom(c.length, _e());
      c = c.insert(c.length, '   ');
      expect(_flags(c), [true]);
    });
  });

  group('掺了别的内容', () {
    test('emoji 前有文字 → 不大', () {
      var c = EditableTextContent(text: '');
      c = c.insert(0, '文字 ');
      c = c.insertAtom(c.length, _e());
      expect(_flags(c), [false]);
    });

    test('emoji 后补文字 → 从大变回不大', () {
      var c = _content([_e()]);
      expect(_flags(c), [true], reason: '先确认是大的');
      c = c.insert(c.length, 'a');
      expect(_flags(c), [false], reason: '补了正文就该缩回去');
    });
  });

  test('没有 emoji 的段落不受影响', () {
    final c = EditableTextContent(text: '').insert(0, '普通文字');
    expect(_flags(c), isEmpty);
    expect(c.toInlines(), isNotEmpty);
  });
}

/// 原子 reveal 测试:光标贴到图片/emoji/mention 边界时显形成字面
/// markdown(可改地址/尺寸),离开时装回原子。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/model/editable_text_content.dart';
import 'package:fluxdo_render/src/editor/model/editor_state.dart';
import 'package:fluxdo_render/src/node/inline_node.dart';

EditorState withAtom(InlineNode atom) {
  final s = EditorState(blocks: [
    TextBlock(
      id: 'b0',
      content: EditableTextContent(text: 'a').insertAtom(1, atom),
    ),
  ]);
  addTearDown(s.dispose);
  return s;
}

TextBlock b(EditorState s) => s.textBlockById('b0')!;

void nav(EditorState s, int offset) => s.navigateSelection(
    EditorSelection.collapsed(EditorPosition(blockId: 'b0', offset: offset)));

void main() {
  const img = ImageRun(
    src: 'upload://abc.png',
    alt: '图',
    origSrc: 'upload://abc.png',
    width: 690,
    height: 52,
    origWidth: 690,
    origHeight: 52,
  );

  group('原子 reveal', () {
    test('光标贴左边界 → 图片显形为字面语法', () {
      final s = withAtom(img);
      nav(s, 1);
      expect(b(s).content.text, 'a![图|690x52](upload://abc.png)');
      expect(b(s).content.atoms, isEmpty);
      expect(s.selection!.extent.offset, 1);
      expect(s.markerRangesOf('b0').single, (1, b(s).content.text.length));
    });

    test('从右边进 → 光标停在末字符前,再右移一步折叠回图片', () {
      final s = withAtom(img);
      nav(s, 2);
      final len = b(s).content.text.length;
      expect(s.selection!.extent.offset, len - 1, reason: '仍在显形区内');
      nav(s, len);
      expect(b(s).content.atoms[1], same(img), reason: '未改动 → 装回原件');
      expect(b(s).content.text.length, 2);
    });

    test('改了地址 → 折叠时按新语法重建图片', () {
      final s = withAtom(img);
      nav(s, 1);
      // 把 upload://abc.png 换成 upload://xyz.png
      final text = b(s).content.text;
      final at = text.indexOf('abc');
      s.imeReplace('b0', at, at + 3, 'xyz', caretOffset: at + 3);
      nav(s, 0);
      final atom = b(s).content.atoms[1] as ImageRun;
      expect(atom.src, 'upload://xyz.png');
      expect(atom.origSrc, 'upload://xyz.png', reason: '短链要写回 raw');
      expect(atom.alt, '图');
      expect(atom.origWidth, 690);
    });

    test('emoji / mention 显形,未改动则原样装回', () {
      var s = withAtom(const EmojiRun(name: 'smile', url: 'u'));
      nav(s, 1);
      expect(b(s).content.text, 'a:smile:');
      nav(s, 8);
      expect(b(s).content.atoms[1], isA<EmojiRun>());

      s = withAtom(const MentionRun(username: 'alice', href: '/u/alice'));
      nav(s, 1);
      expect(b(s).content.text, 'a@alice');
      nav(s, 7);
      expect((b(s).content.atoms[1]! as MentionRun).href, '/u/alice');
    });

    test('emoji 名字被改 → 保持字面(url 字面表达不出来,不瞎造节点)', () {
      final s = withAtom(const EmojiRun(name: 'smile', url: 'u'));
      nav(s, 1);
      final at = b(s).content.text.indexOf('smile');
      s.imeReplace('b0', at, at + 5, 'heart', caretOffset: at + 5);
      nav(s, 0);
      expect(b(s).content.text, 'a:heart:');
      expect(b(s).content.atoms, isEmpty);
    });
  });
}

/// 无状态 emoji 的 mention 走纯 TextSpan 路径(药丸底色 painter 自绘),
/// 渲染占 `@username` 那么多字符,编辑模型里却只是一个 FFFC 原子。
/// 投影的内容宽度必须按 1 算 —— 否则光标被算进药丸内部,且原子之后的
/// 所有偏移全部错位(真机症状:@arch_linux 的光标停在 "ar|ch")。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/model/editable_text_content.dart';
import 'package:fluxdo_render/src/flatten/inline_flattener.dart';
import 'package:fluxdo_render/src/node/inline_node.dart';

void main() {
  const flattener = InlineFlattener();

  ({int contentLength, int renderLength, List<int> map}) probe(
    EditableTextContent content,
  ) {
    final r = flattener.flatten(
      content.toInlines(forEditing: true),
      const TextStyle(),
    );
    return (
      contentLength: r.projection.contentLength,
      renderLength: r.projection.renderLength,
      map: [
        for (var i = 0; i <= content.length; i++)
          r.projection.renderOffsetForContent(i),
      ],
    );
  }

  test('纯文本 mention 原子:内容宽 1,其后偏移不错位', () {
    final c = EditableTextContent(text: 'ab').insertAtom(
      1,
      const MentionRun(username: 'arch_linux', href: '/u/arch_linux'),
    );
    final p = probe(c);
    expect(c.length, 3, reason: 'a + 原子 + b');
    expect(p.contentLength, 3, reason: '药丸整体只占 1 个内容字符');
    expect(p.renderLength, greaterThan(3), reason: '渲染上是完整的 @username');
    // 原子之后的偏移必须落到药丸末尾之后,而不是药丸内部
    expect(p.map[2], greaterThanOrEqualTo(p.renderLength - 1));
    expect(p.map[3], p.renderLength);
  });

  test('带状态 emoji 的 mention(WidgetSpan 版)口径一致', () {
    final c = EditableTextContent(text: 'ab').insertAtom(
      1,
      const MentionRun(
        username: 'someone',
        href: '/u/someone',
        statusEmoji: EmojiRun(name: 'smile', url: 'u'),
      ),
    );
    expect(probe(c).contentLength, 3);
  });

  test('多个 mention 连排:内容长度 = 原子数 + 文本数', () {
    var c = EditableTextContent(text: 'x');
    c = c.insertAtom(1, const MentionRun(username: 'aa', href: '/u/aa'));
    c = c.insertAtom(2, const MentionRun(username: 'bbbbbb', href: '/u/bbbbbb'));
    expect(c.length, 3);
    expect(probe(c).contentLength, 3);
  });
}

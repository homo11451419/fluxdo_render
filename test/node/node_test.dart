import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';

void main() {
  group('TextRun', () {
    test('==/hashCode 按 text 比较', () {
      const a = TextRun('hello');
      const b = TextRun('hello');
      const c = TextRun('world');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == c, isFalse);
    });
  });

  group('EmRun', () {
    test('==/hashCode 按 children listEquals', () {
      const a = EmRun(children: [TextRun('a'), TextRun('b')]);
      const b = EmRun(children: [TextRun('a'), TextRun('b')]);
      const c = EmRun(children: [TextRun('a')]);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == c, isFalse);
    });

    test('children 可嵌套 InlineNode', () {
      const nested = EmRun(
        children: [
          TextRun('outer '),
          StrongRun(children: [TextRun('inner')]),
        ],
      );
      expect(nested.children.length, 2);
      expect(nested.children[1], isA<StrongRun>());
    });
  });

  group('LineBreakRun', () {
    test('所有实例相等', () {
      const a = LineBreakRun();
      const b = LineBreakRun();
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('与其他 InlineNode 不相等', () {
      const br = LineBreakRun();
      const text = TextRun('');
      expect(br == text, isFalse);
    });
  });

  group('ParagraphNode', () {
    test('==/hashCode 按 inlines listEquals(忽略 id)', () {
      const a = ParagraphNode(
        id: 'b_0',
        inlines: [TextRun('hello'), LineBreakRun()],
      );
      const b = ParagraphNode(
        id: 'b_0',
        inlines: [TextRun('hello'), LineBreakRun()],
      );
      const c = ParagraphNode(id: 'b_1', inlines: [TextRun('hello')]);
      // 同 id 同内容 → 相等
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      // 不同内容(id 也可能不同) → 不相等
      expect(a == c, isFalse);
    });

    test('id 不参与 ==,只要内容相同就相等', () {
      const a = ParagraphNode(id: 'b_0', inlines: [TextRun('x')]);
      const b = ParagraphNode(id: 'b_99', inlines: [TextRun('x')]);
      // 不同 id 同内容 → 也相等(让 widget diff 不必要 rebuild)
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('id 字段可访问', () {
      const p = ParagraphNode(id: 'b_7', inlines: []);
      expect(p.id, 'b_7');
    });

    test('toString 含 id 和 inlines 数量', () {
      const p = ParagraphNode(
        id: 'b_2',
        inlines: [TextRun('a'), TextRun('b'), TextRun('c')],
      );
      expect(p.toString(), contains('b_2'));
      expect(p.toString(), contains('3 inlines'));
    });
  });

  group('sealed class exhaustiveness', () {
    test('BlockNode switch 必须覆盖所有 case', () {
      // 这是个编译期检查 — 如果新增 BlockNode 子类没在 switch 里,
      // analyzer 会报 non-exhaustive,这条用例只是 runtime 烟雾测试。
      const BlockNode p = ParagraphNode(id: 'b_0', inlines: []);
      final label = switch (p) {
        ParagraphNode() => 'paragraph',
        HeadingNode() => 'heading',
        ListNode() => 'list',
        BlockquoteNode() => 'blockquote',
        HorizontalRuleNode() => 'hr',
        BlankLineNode() => 'blankLine',
        CodeBlockNode() => 'code',
        QuoteCardNode() => 'quoteCard',
        SpoilerBlockNode() => 'spoiler',
        OneboxNode() => 'onebox',
        DetailsNode() => 'details',
        CalloutNode() => 'callout',
        ImageGridNode() => 'imageGrid',
        FootnotesSectionNode() => 'footnotesSection',
        LazyVideoNode() => 'lazyVideo',
        IframeNode() => 'iframe',
        VideoNode() => 'video',
        AudioNode() => 'audio',
        TableNode() => 'table',
        PolicyNode() => 'policy',
        MathBlockNode() => 'mathBlock',
        SvgNode() => 'svg',
        PollNode() => 'poll',
        ChatTranscriptNode() => 'chatTranscript',
        DefinitionListNode() => 'definitionList',
      };
      expect(label, 'paragraph');
    });

    test('InlineNode switch 必须覆盖所有 case', () {
      const list = <InlineNode>[
        TextRun('a'),
        EmRun(children: []),
        StrongRun(children: []),
        LineBreakRun(),
        LinkRun(href: 'https://example.com', children: [TextRun('x')]),
        InlineCodeRun('c'),
        EmojiRun(name: 'heart', url: 'https://x/heart.png'),
        MentionRun(username: 'alice', href: '/u/alice'),
        ImageRun(src: 'https://x/foo.png'),
        SpoilerRun(children: [TextRun('s')]),
      ];
      final labels = list
          .map(
            (n) => switch (n) {
              TextRun() => 'text',
              EmRun() => 'em',
              StrongRun() => 'strong',
              StyledRun() => 'styled',
              ColoredRun() => 'colored',
              SizedRun() => 'sized',
              LineBreakRun() => 'br',
              LinkRun() => 'link',
              InlineCodeRun() => 'inlineCode',
              EmojiRun() => 'emoji',
              MentionRun() => 'mention',
              ImageRun() => 'image',
              SpoilerRun() => 'spoiler',
              FootnoteRefRun() => 'footnoteRef',
              LocalDateRun() => 'localDate',
              ClickCountRun() => 'clickCount',
              MathInlineRun() => 'mathInline',
            },
          )
          .toList();
      expect(labels, [
        'text', 'em', 'strong', 'br', 'link', 'inlineCode', 'emoji', 'mention', 'image', 'spoiler',
      ]);
    });
  });

  group('InlineCodeRun', () {
    test('==/hashCode 按 text 比较', () {
      const a = InlineCodeRun('hello');
      const b = InlineCodeRun('hello');
      const c = InlineCodeRun('world');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == c, isFalse);
    });

    test('空串也可构造', () {
      const e = InlineCodeRun('');
      expect(e.text, '');
    });

    test('toString 含字符数', () {
      const c = InlineCodeRun('hello');
      expect(c.toString(), contains('5 chars'));
    });
  });

  group('EmojiRun', () {
    test('==/hashCode 按 name+url+isOnlyEmoji 比较', () {
      const a = EmojiRun(name: 'heart', url: 'x.png');
      const b = EmojiRun(name: 'heart', url: 'x.png');
      const c = EmojiRun(name: 'heart', url: 'y.png');
      const d = EmojiRun(name: 'heart', url: 'x.png', isOnlyEmoji: true);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == c, isFalse);
      expect(a == d, isFalse);
    });

    test('isOnlyEmoji 默认 false', () {
      const e = EmojiRun(name: 'x', url: 'y.png');
      expect(e.isOnlyEmoji, isFalse);
    });

    test('toString 含 name + url, only-emoji 时标 only', () {
      const a = EmojiRun(name: 'heart', url: 'x.png');
      expect(a.toString(), allOf(contains('heart'), contains('x.png')));
      expect(a.toString(), isNot(contains('only')));
      const b = EmojiRun(name: 'tada', url: 'y.png', isOnlyEmoji: true);
      expect(b.toString(), contains('only'));
    });
  });

  group('MentionRun', () {
    test('==/hashCode 按 username + href + statusEmoji 比较', () {
      const a = MentionRun(username: 'alice', href: '/u/alice');
      const b = MentionRun(username: 'alice', href: '/u/alice');
      const c = MentionRun(username: 'bob', href: '/u/bob');
      const d = MentionRun(
        username: 'alice',
        href: '/u/alice',
        statusEmoji: EmojiRun(name: 'fire', url: 'x.png'),
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == c, isFalse);
      expect(a == d, isFalse);
    });

    test('statusEmoji 默认 null', () {
      const m = MentionRun(username: 'alice', href: '/u/alice');
      expect(m.statusEmoji, isNull);
    });

    test('toString 含 @username + href, 有 emoji 时标 emoji', () {
      const a = MentionRun(username: 'alice', href: '/u/alice');
      expect(a.toString(), allOf(contains('@alice'), contains('/u/alice')));
      expect(a.toString(), isNot(contains('emoji')));
      const b = MentionRun(
        username: 'bob',
        href: '/u/bob',
        statusEmoji: EmojiRun(name: 'fire', url: 'x.png'),
      );
      expect(b.toString(), contains('emoji'));
    });
  });

  group('ListNode', () {
    test('==/hashCode 按 ordered + depth + items', () {
      const a = ListNode(
        id: 'b_0',
        ordered: false,
        items: [
          ListItem(inlines: [TextRun('x')]),
        ],
      );
      const b = ListNode(
        id: 'b_99',
        ordered: false,
        items: [
          ListItem(inlines: [TextRun('x')]),
        ],
      );
      // id 不参与 ==
      expect(a, b);
      const c = ListNode(
        id: 'b_0',
        ordered: true,
        items: [ListItem(inlines: [TextRun('x')])],
      );
      expect(a == c, isFalse);
    });

    test('depth 默认 0', () {
      const l = ListNode(id: 'b_0', ordered: false, items: []);
      expect(l.depth, 0);
    });

    test('ListItem.children 嵌套子列表正常 ==', () {
      const sub = ListNode(
        id: 'b_1',
        ordered: false,
        depth: 1,
        items: [ListItem(inlines: [TextRun('nested')])],
      );
      const a = ListItem(
        inlines: [TextRun('outer')],
        children: [sub],
      );
      const b = ListItem(
        inlines: [TextRun('outer')],
        children: [sub],
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('叶子项 children = null,toString 不带 sub-lists', () {
      const i = ListItem(inlines: [TextRun('x')]);
      expect(i.children, isNull);
      expect(i.toString(), isNot(contains('sub-lists')));
    });
  });

  group('BlockquoteNode', () {
    test('==/hashCode 按 children 比较(id 不参与)', () {
      const a = BlockquoteNode(id: 'b_0', children: [
        ParagraphNode(id: 'b_1', inlines: [TextRun('x')]),
      ]);
      const b = BlockquoteNode(id: 'b_99', children: [
        ParagraphNode(id: 'b_42', inlines: [TextRun('x')]),
      ]);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      const c = BlockquoteNode(id: 'b_0', children: [
        ParagraphNode(id: 'b_1', inlines: [TextRun('y')]),
      ]);
      expect(a == c, isFalse);
    });

    test('空 children 可构造', () {
      const e = BlockquoteNode(id: 'b_0', children: []);
      expect(e.children, isEmpty);
    });

    test('支持嵌套 BlockquoteNode 作 child', () {
      const inner = BlockquoteNode(id: 'b_1', children: []);
      const outer = BlockquoteNode(id: 'b_0', children: [inner]);
      expect(outer.children[0], isA<BlockquoteNode>());
    });

    test('toString 含 id + child 数', () {
      const b = BlockquoteNode(id: 'b_3', children: [
        ParagraphNode(id: 'b_4', inlines: []),
        ParagraphNode(id: 'b_5', inlines: []),
      ]);
      expect(b.toString(), contains('b_3'));
      expect(b.toString(), contains('2 children'));
    });
  });

  group('HorizontalRuleNode', () {
    test('所有实例(只要 runtimeType 相同)都相等', () {
      const a = HorizontalRuleNode(id: 'b_0');
      const b = HorizontalRuleNode(id: 'b_99'); // id 不参与 ==
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('跟其他 BlockNode 不相等', () {
      const hr = HorizontalRuleNode(id: 'b_0');
      const p = ParagraphNode(id: 'b_0', inlines: []);
      expect(hr == p, isFalse);
    });

    test('id 字段可访问', () {
      const hr = HorizontalRuleNode(id: 'b_7');
      expect(hr.id, 'b_7');
    });

    test('toString 含 id', () {
      const hr = HorizontalRuleNode(id: 'b_3');
      expect(hr.toString(), contains('b_3'));
    });
  });

  group('ImageRun', () {
    test('==/hashCode 按 src + alt + width + height', () {
      const a = ImageRun(src: 'x.png', alt: 'pic', width: 100, height: 50);
      const b = ImageRun(src: 'x.png', alt: 'pic', width: 100, height: 50);
      const c = ImageRun(src: 'y.png', alt: 'pic', width: 100, height: 50);
      const d = ImageRun(src: 'x.png', alt: 'other', width: 100, height: 50);
      const e = ImageRun(src: 'x.png', alt: 'pic', width: 200, height: 50);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == c, isFalse);
      expect(a == d, isFalse);
      expect(a == e, isFalse);
    });

    test('alt 默认空串, width/height 默认 null, lightboxUrl 默认 null', () {
      const i = ImageRun(src: 'x.png');
      expect(i.alt, '');
      expect(i.width, isNull);
      expect(i.height, isNull);
      expect(i.lightboxUrl, isNull);
    });

    test('lightboxUrl 参与 ==', () {
      const a = ImageRun(src: 'thumb.png');
      const b = ImageRun(src: 'thumb.png', lightboxUrl: 'full.png');
      expect(a == b, isFalse);
      const c = ImageRun(src: 'thumb.png', lightboxUrl: 'full.png');
      expect(b, c);
    });

    test('toString 含 src, 有尺寸时标尺寸', () {
      const a = ImageRun(src: 'foo.png');
      expect(a.toString(), contains('foo.png'));
      const b = ImageRun(src: 'foo.png', width: 100, height: 50);
      expect(b.toString(), contains('100'));
    });
  });

  group('CodeBlockNode', () {
    test('==/hashCode 按 code + language(id 不参与)', () {
      const a = CodeBlockNode(id: 'b_0', code: 'x', language: 'dart');
      const b = CodeBlockNode(id: 'b_99', code: 'x', language: 'dart');
      const c = CodeBlockNode(id: 'b_0', code: 'y', language: 'dart');
      const d = CodeBlockNode(id: 'b_0', code: 'x', language: 'python');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == c, isFalse);
      expect(a == d, isFalse);
    });

    test('language 可 null', () {
      const e = CodeBlockNode(id: 'b_0', code: 'x');
      expect(e.language, isNull);
    });

    test('toString 含 id + language + 字符数', () {
      const c = CodeBlockNode(id: 'b_3', code: 'hello', language: 'dart');
      expect(c.toString(), contains('b_3'));
      expect(c.toString(), contains('dart'));
      expect(c.toString(), contains('5 chars'));
    });
  });

  group('QuoteCardNode', () {
    test('==/hashCode 按 username/avatarUrl/title/href/topic/post/children', () {
      const a = QuoteCardNode(
        id: 'b_0',
        username: 'alice',
        topicId: 999,
        postNumber: 3,
        children: [ParagraphNode(id: 'b_1', inlines: [TextRun('x')])],
      );
      const b = QuoteCardNode(
        id: 'b_99',
        username: 'alice',
        topicId: 999,
        postNumber: 3,
        children: [ParagraphNode(id: 'b_2', inlines: [TextRun('x')])],
      );
      expect(a, b);
      const c = QuoteCardNode(id: 'b_0', username: 'bob');
      expect(a == c, isFalse);
    });

    test('avatarUrl / titleText / titleHref / topicId / postNumber 默认 null',
        () {
      const q = QuoteCardNode(id: 'b_0', username: 'a');
      expect(q.avatarUrl, isNull);
      expect(q.titleText, isNull);
      expect(q.titleHref, isNull);
      expect(q.topicId, isNull);
      expect(q.postNumber, isNull);
      expect(q.children, isEmpty);
    });

    test('toString 含 username + topic/post 标记', () {
      const a = QuoteCardNode(id: 'b_0', username: 'alice');
      expect(a.toString(), contains('@alice'));
      expect(a.toString(), isNot(contains('t=')));
      const b = QuoteCardNode(
        id: 'b_0',
        username: 'alice',
        topicId: 999,
        postNumber: 3,
      );
      expect(b.toString(), contains('t=999'));
      expect(b.toString(), contains('p=3'));
    });
  });

  group('SpoilerRun', () {
    test('==/hashCode 按 children', () {
      const a = SpoilerRun(children: [TextRun('x')]);
      const b = SpoilerRun(children: [TextRun('x')]);
      const c = SpoilerRun(children: [TextRun('y')]);
      expect(a, b);
      expect(a == c, isFalse);
    });

    test('children 可嵌套样式 / link / inline_code', () {
      const s = SpoilerRun(children: [
        TextRun('前 '),
        StrongRun(children: [TextRun('粗')]),
        LinkRun(href: '/x', children: [TextRun('link')]),
      ]);
      expect(s.children, hasLength(3));
    });
  });

  group('SpoilerBlockNode', () {
    test('==/hashCode 按 children(id 不参与)', () {
      const a = SpoilerBlockNode(id: 'b_0', children: [
        ParagraphNode(id: 'b_1', inlines: [TextRun('x')]),
      ]);
      const b = SpoilerBlockNode(id: 'b_99', children: [
        ParagraphNode(id: 'b_42', inlines: [TextRun('x')]),
      ]);
      expect(a, b);
      const c = SpoilerBlockNode(id: 'b_0', children: [
        ParagraphNode(id: 'b_1', inlines: [TextRun('y')]),
      ]);
      expect(a == c, isFalse);
    });

    test('toString 含 id + 子数', () {
      const s = SpoilerBlockNode(id: 'b_3', children: [
        ParagraphNode(id: 'b_4', inlines: []),
      ]);
      expect(s.toString(), contains('b_3'));
      expect(s.toString(), contains('1 children'));
    });
  });
}

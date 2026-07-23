/// markdown 序列化器测试:每种块/mark/原子/转义/嵌套的手写期望断言。
library;

import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/model/editable_text_content.dart';
import 'package:fluxdo_render/src/editor/model/editor_block.dart';
import 'package:fluxdo_render/src/editor/model/markdown_serializer.dart';
import 'package:fluxdo_render/src/node/node.dart';

TextBlock tb(
  String text, {
  List<MarkSpan> marks = const [],
  Map<int, InlineNode> atoms = const {},
  TextBlockKind kind = TextBlockKind.paragraph,
  int headingLevel = 1,
  bool ordered = false,
  int depth = 0,
  int listStart = 1,
  int quoteDepth = 0,
}) =>
    TextBlock(
      id: 'e_t',
      content: EditableTextContent(text: text, marks: marks, atoms: atoms),
      kind: kind,
      headingLevel: headingLevel,
      ordered: ordered,
      depth: depth,
      listStart: listStart,
      quoteDepth: quoteDepth,
    );

void main() {
  _bareUrlTests();
  group('行内 mark', () {
    test('粗体/斜体/删除线/行内代码/下划线', () {
      expect(
        docToMarkdown([
          tb('abc', marks: const [
            MarkSpan(start: 0, end: 3, kind: MarkKind.strong)
          ])
        ]),
        '**abc**',
      );
      expect(
        docToMarkdown([
          tb('abc', marks: const [MarkSpan(start: 1, end: 2, kind: MarkKind.em)])
        ]),
        'a*b*c',
      );
      expect(
        docToMarkdown([
          tb('code', marks: const [
            MarkSpan(start: 0, end: 4, kind: MarkKind.inlineCode)
          ])
        ]),
        '`code`',
      );
      expect(
        docToMarkdown([
          tb('del', marks: const [
            MarkSpan(start: 0, end: 3, kind: MarkKind.lineThrough)
          ])
        ]),
        '~~del~~',
      );
      expect(
        docToMarkdown([
          tb('u', marks: const [
            MarkSpan(start: 0, end: 1, kind: MarkKind.underline)
          ])
        ]),
        '[u]u[/u]',
      );
    });

    test('嵌套(同区间 strong+em 固定序)', () {
      expect(
        docToMarkdown([
          tb('x', marks: const [
            MarkSpan(start: 0, end: 1, kind: MarkKind.em),
            MarkSpan(start: 0, end: 1, kind: MarkKind.strong),
          ])
        ]),
        '***x***', // strong 外 em 内:**\*x\***
      );
    });

    test('交错区间:降级 HTML 标签(cook 实测定界符会破)', () {
      // strong [0,2), em [1,3):纯星号输出 **a*b****c* 会被 CommonMark
      // 贪婪匹配破坏(cook 实测出 <strong>a<em>b</em></strong>c*)。
      // 降级 <strong>/<em>(sanitizer 放行,cooked 结构一致)。
      final md = docToMarkdown([
        tb('abc', marks: const [
          MarkSpan(start: 0, end: 2, kind: MarkKind.strong),
          MarkSpan(start: 1, end: 3, kind: MarkKind.em),
        ])
      ]);
      expect(md, '<strong>a<em>b</em></strong><em>c</em>');
    });

    test('code 内不转义元字符', () {
      expect(
        docToMarkdown([
          tb('a*b_c', marks: const [
            MarkSpan(start: 0, end: 5, kind: MarkKind.inlineCode)
          ])
        ]),
        '`a*b_c`',
      );
    });
  });

  group('原子', () {
    test('emoji/mention', () {
      const emoji = EmojiRun(name: 'smile', url: 'u');
      const mention = MentionRun(username: 'sam', href: '/u/sam');
      expect(
        docToMarkdown([
          tb('hi $kAtomChar $kAtomChar',
              atoms: const {3: emoji, 5: mention})
        ]),
        'hi :smile: @sam',
      );
    });
  });

  group('转义', () {
    test('行内元字符', () {
      expect(docToMarkdown([tb('a*b')]), r'a\*b');
      expect(docToMarkdown([tb('a[链接]b')]), r'a\[链接\]b');
      // checklist 例外:[x]/[X]/[ ] 是 Discourse 勾选框语法,不转义
      expect(docToMarkdown([tb('任务 [x] 完成')]), '任务 [x] 完成');
      expect(docToMarkdown([tb('[X] 永久勾选')]), '[X] 永久勾选');
      // 但 [x](...) 是链接形态,仍转义
      expect(docToMarkdown([tb('[x](y)')]), r'\[x\](y)');
      expect(docToMarkdown([tb('波浪~不转义')]), '波浪~不转义');
      expect(docToMarkdown([tb('双波~~转义')]), r'双波\~\~转义');
    });

    test('行首块语法', () {
      expect(docToMarkdown([tb('# 不是标题')]), r'\# 不是标题');
      expect(docToMarkdown([tb('- 不是列表')]), r'\- 不是列表');
      expect(docToMarkdown([tb('1. 不是列表')]), r'\1. 不是列表');
      expect(docToMarkdown([tb('> 不是引用')]), r'\> 不是引用');
    });
  });

  group('块类型', () {
    test('heading', () {
      expect(
        docToMarkdown([tb('标题', kind: TextBlockKind.heading, headingLevel: 2)]),
        '## 标题',
      );
    });

    test('无序/有序/嵌套列表', () {
      final md = docToMarkdown([
        tb('a', kind: TextBlockKind.listItem),
        tb('a1', kind: TextBlockKind.listItem, ordered: true, depth: 1),
        tb('a2', kind: TextBlockKind.listItem, ordered: true, depth: 1),
        tb('b', kind: TextBlockKind.listItem),
      ]);
      expect(md, '- a\n  1. a1\n  2. a2\n- b');
    });

    test('ol start 起算', () {
      final md = docToMarkdown([
        tb('x', kind: TextBlockKind.listItem, ordered: true, listStart: 5),
        tb('y', kind: TextBlockKind.listItem, ordered: true),
      ]);
      expect(md, '5. x\n6. y');
    });

    test('引用(含引用内列表)', () {
      expect(docToMarkdown([tb('quoted', quoteDepth: 1)]), '> quoted');
      expect(docToMarkdown([tb('deep', quoteDepth: 2)]), '> > deep');
      final md = docToMarkdown([
        tb('item', kind: TextBlockKind.listItem, quoteDepth: 1),
      ]);
      expect(md, '> - item');
    });

    test('块间空行连接', () {
      expect(
        docToMarkdown([tb('一'), tb('二')]),
        '一\n\n二',
      );
    });

    test('软换行 → 硬换行', () {
      expect(docToMarkdown([tb('a\nb')]), 'a  \nb');
    });
  });

  group('孤岛', () {
    test('代码块(含 fence 升级)', () {
      expect(
        serializeIslandNode(
            const CodeBlockNode(id: 'b', code: 'x = 1', language: 'py')),
        '```py\nx = 1\n```',
      );
      expect(
        serializeIslandNode(
            const CodeBlockNode(id: 'b', code: 'a```b')),
        '````\na```b\n````',
      );
    });

    test('图片段落(含尺寸)', () {
      expect(
        serializeIslandNode(const ParagraphNode(id: 'b', inlines: [
          ImageRun(src: 'upload://x.png', alt: '截图', width: 690, height: 400),
        ])),
        '![截图|690x400](upload://x.png)',
      );
    });

    test('链接段落', () {
      expect(
        serializeIslandNode(const ParagraphNode(id: 'b', inlines: [
          TextRun('看 '),
          LinkRun(href: 'https://x.com', children: [TextRun('这里')]),
        ])),
        '看 [这里](https://x.com)',
      );
    });

    test('hr/math/onebox', () {
      expect(serializeIslandNode(const HorizontalRuleNode(id: 'b')), '---');
      expect(
        serializeIslandNode(const MathBlockNode(id: 'b', latex: 'E=mc^2')),
        '\$\$\nE=mc^2\n\$\$',
      );
      expect(
        serializeIslandNode(const OneboxNode(
            id: 'b', kind: OneboxKind.defaultKind, url: 'https://x.com/a')),
        'https://x.com/a',
      );
    });

    test('表格', () {
      const cell = TableCellData(
          children: [ParagraphNode(id: 'c', inlines: [TextRun('x')])]);
      final md = serializeIslandNode(const TableNode(
        id: 'b',
        rows: [
          [cell, cell],
          [cell, cell],
        ],
        columnCount: 2,
        hasHeader: true,
      ));
      expect(md, '| x | x |\n| --- | --- |\n| x | x |');
    });

    test('不可序列化类型(poll)→ 空串不崩,islandSerializable=false', () {
      const poll = PollNode(id: 'b', pollName: 'poll');
      expect(serializeIslandNode(poll), '');
      expect(islandSerializable(poll), isFalse);
      expect(
        islandSerializable(const IframeNode(
            id: 'b', src: 'https://e.com', width: null, height: null)),
        isTrue,
      );
    });

    test('文档级:文本块与岛混排', () {
      final md = docToMarkdown([
        tb('前文'),
        const IslandBlock(
          id: 'e_i',
          node: CodeBlockNode(id: 'b', code: 'x', language: null),
        ),
        tb('后文'),
      ]);
      expect(md, '前文\n\n```\nx\n```\n\n后文');
    });
  });

  group('岛覆盖面(M4 编辑已有帖子)', () {
    test('quote card:username/post/topic/full/displayName', () {
      expect(
        serializeIslandNode(const QuoteCardNode(
          id: 'b',
          username: 'sam',
          postNumber: 2,
          topicId: 123,
          children: [
            ParagraphNode(id: 'c', inlines: [TextRun('引用内容')]),
          ],
        )),
        '[quote="sam, post:2, topic:123"]\n引用内容\n[/quote]',
      );
      expect(
        serializeIslandNode(const QuoteCardNode(
          id: 'b',
          username: 'sam',
          displayName: '张三',
          postNumber: 2,
          topicId: 123,
          full: true,
          children: [
            ParagraphNode(id: 'c', inlines: [TextRun('x')]),
          ],
        )),
        '[quote="张三, post:2, topic:123, username:sam, full:true"]\nx\n[/quote]',
      );
      // 无名引用
      expect(
        serializeIslandNode(const QuoteCardNode(
          id: 'b',
          username: '',
          children: [
            ParagraphNode(id: 'c', inlines: [TextRun('y')]),
          ],
        )),
        '[quote]\ny\n[/quote]',
      );
    });

    test('spoiler 块 / details / callout', () {
      expect(
        serializeIslandNode(const SpoilerBlockNode(id: 'b', children: [
          ParagraphNode(id: 'c', inlines: [TextRun('秘密')]),
        ])),
        '[spoiler]\n秘密\n[/spoiler]',
      );
      expect(
        serializeIslandNode(const DetailsNode(
          id: 'b',
          summary: '摘要',
          initiallyOpen: true,
          children: [
            ParagraphNode(id: 'c', inlines: [TextRun('内容')]),
          ],
        )),
        '[details="摘要" open]\n内容\n[/details]',
      );
      expect(
        serializeIslandNode(const CalloutNode(
          id: 'b',
          kind: CalloutKind.note,
          typeRaw: 'note',
          title: '提示标题',
          foldable: true,
          children: [
            ParagraphNode(id: 'c', inlines: [TextRun('正文')]),
          ],
        )),
        '> [!note]+ 提示标题\n> 正文',
      );
    });

    test('image grid / footnotes section', () {
      expect(
        serializeIslandNode(const ImageGridNode(
          id: 'b',
          images: [
            ImageRun(src: 'upload://a.png', alt: 'a', width: 100, height: 100),
            ImageRun(src: 'upload://b.png', alt: 'b', width: 100, height: 100),
          ],
          mode: ImageGridMode.carousel,
        )),
        '[grid mode=carousel]\n'
        '![a|100x100](upload://a.png)\n'
        '![b|100x100](upload://b.png)\n'
        '[/grid]',
      );
      expect(
        serializeIslandNode(const FootnotesSectionNode(id: 'b', entries: [
          FootnoteEntry(id: 'fn1', number: '1', inlines: [TextRun('脚注正文')]),
        ])),
        '[^1]: 脚注正文',
      );
    });

    test('video/audio:upload 短链优先,直链裸 URL', () {
      expect(
        serializeIslandNode(const VideoNode(
            id: 'b', src: '/uploads/x.mp4', origSrc: 'upload://x.mp4')),
        '![|video](upload://x.mp4)',
      );
      expect(
        serializeIslandNode(
            const VideoNode(id: 'b', src: 'https://e.com/v.mp4')),
        'https://e.com/v.mp4',
      );
      expect(
        serializeIslandNode(
            const AudioNode(id: 'b', src: 'upload://y.mp3')),
        '![|audio](upload://y.mp3)',
      );
    });

    test('iframe / dl 白名单 HTML 重建', () {
      expect(
        serializeIslandNode(const IframeNode(
          id: 'b',
          src: 'https://www.youtube.com/embed/abc',
          width: 560,
          height: 315,
        )),
        '<iframe src="https://www.youtube.com/embed/abc" '
        'width="560" height="315"></iframe>',
      );
      expect(
        serializeIslandNode(const DefinitionListNode(id: 'b', items: [
          DefinitionItem(term: [
            TextRun('术语')
          ], definitions: [
            [
              ParagraphNode(id: 'c', inlines: [TextRun('释义')])
            ],
          ]),
        ])),
        '<dl><dt>术语</dt><dd>释义</dd></dl>',
      );
    });

    test('行内:attachment/hashtag/inline-onebox/date/行内公式/spoiler', () {
      expect(
        serializeIslandNode(const ParagraphNode(id: 'b', inlines: [
          LinkRun(
            href: '/404',
            children: [TextRun('report.pdf')],
            isAttachment: true,
            filename: 'report.pdf',
            origHref: 'upload://def.pdf',
          ),
        ])),
        '[report.pdf|attachment](upload://def.pdf)',
      );
      expect(
        serializeIslandNode(const ParagraphNode(id: 'b', inlines: [
          LinkRun(
            href: '/c/develop/sub/9',
            children: [TextRun('子分类')],
            hashtagRef: 'develop:sub',
          ),
        ])),
        '#develop:sub',
      );
      expect(
        serializeIslandNode(const ParagraphNode(id: 'b', inlines: [
          LinkRun(
            href: 'https://x.com/page',
            children: [TextRun('页面标题固化')],
            isOneboxLink: true,
          ),
        ])),
        'https://x.com/page',
      );
      expect(
        serializeIslandNode(const ParagraphNode(id: 'b', inlines: [
          LocalDateRun(
            date: '2026-08-15',
            time: '14:30',
            timezone: 'Asia/Shanghai',
            fallbackText: 'x',
          ),
        ])),
        '[date=2026-08-15 time=14:30 timezone="Asia/Shanghai"]',
      );
      expect(
        serializeIslandNode(const ParagraphNode(id: 'b', inlines: [
          MathInlineRun('x^2'),
        ])),
        '\$x^2\$',
      );
      expect(
        serializeIslandNode(const ParagraphNode(id: 'b', inlines: [
          SpoilerRun(children: [TextRun('秘密')]),
        ])),
        '[spoiler]秘密[/spoiler]',
      );
      expect(
        serializeIslandNode(const ParagraphNode(id: 'b', inlines: [
          FootnoteRefRun(number: '1', fnId: 'fn1'),
        ])),
        '[^1]',
      );
    });

    test('行内 styled/colored HTML 形态', () {
      expect(
        serializeIslandNode(const ParagraphNode(id: 'b', inlines: [
          StyledRun(kind: InlineStyleKind.superscript, children: [TextRun('2')]),
          StyledRun(kind: InlineStyleKind.mark, children: [TextRun('高亮')]),
          StyledRun(kind: InlineStyleKind.monospace, children: [TextRun('K')]),
        ])),
        '<sup>2</sup><mark>高亮</mark><kbd>K</kbd>',
      );
      expect(
        serializeIslandNode(const ParagraphNode(id: 'b', inlines: [
          ColoredRun(color: Color(0xFFE03E2D), children: [TextRun('红')]),
        ])),
        // BBCode 而非 span[style]:后者的 style 会被消毒器剥掉,
        // 客户端 cook 往返门禁过不了(见 _serializeColored 注释)
        '[color=#e03e2d]红[/color]',
      );
    });

    test('嵌套 quote(quote 内 blockquote 空行前缀)', () {
      expect(
        serializeIslandNode(const BlockquoteNode(id: 'b', children: [
          ParagraphNode(id: 'c', inlines: [TextRun('段一')]),
          ParagraphNode(id: 'd', inlines: [TextRun('段二')]),
        ])),
        '> 段一\n>\n> 段二',
      );
    });

    test('裸 <audio> 标签帖(短链路径 src)写回标签而非裸 URL', () {
      expect(
        serializeIslandNode(const AudioNode(
          id: 'b',
          src: '/uploads/short-url/abc123.xz',
          mime: 'audio/mp4',
        )),
        '<audio controls>\n'
        '  <source src="/uploads/short-url/abc123.xz" type="audio/mp4">\n'
        '</audio>',
      );
    });

    test('语音消息 AudioNode(voice)带 [wrap=voice] 壳', () {
      expect(
        serializeIslandNode(const AudioNode(
          id: 'b',
          src: '/uploads/short-url/abc123.xz',
          mime: 'audio/mp4',
          voice: true,
        )),
        '[wrap=voice]\n'
        '<audio controls>\n'
        '  <source src="/uploads/short-url/abc123.xz" type="audio/mp4">\n'
        '</audio>\n'
        '[/wrap]',
      );
    });

    test('upload:// 音频仍走官方短链形态(不受标签写回影响)', () {
      expect(
        serializeIslandNode(const AudioNode(
          id: 'b',
          src: '/uploads/x.mp3',
          origSrc: 'upload://abc.mp3',
        )),
        '![|audio](upload://abc.mp3)',
      );
    });

    test('裸 <video> 标签帖写回标签(含宽高)', () {
      expect(
        serializeIslandNode(const VideoNode(
          id: 'b',
          src: '/uploads/short-url/xyz.xz',
          mime: 'video/mp4',
          width: 640,
          height: 360,
        )),
        '<video width="640" height="360" controls>\n'
        '  <source src="/uploads/short-url/xyz.xz" type="video/mp4">\n'
        '</video>',
      );
    });
  });
}

/// 裸 URL 往返:cook 给裸 URL linkify 时会补 scheme(锚文本无 scheme、
/// href 有),锚文本与 href 只差 scheme 时仍应写回裸 URL —— 否则用户写的
/// `dl.google.com` 打开一次就被改写成 `[dl.google.com](http://dl.google.com)`。
void _bareUrlTests() {
  MarkSpan link(int s, int e, String href) =>
      MarkSpan(start: s, end: e, kind: MarkKind.link, attr: href);

  String md(String text, MarkSpan m) => docToMarkdown([
        TextBlock(id: 'b0', content: EditableTextContent(text: text, marks: [m])),
      ]);

  group('裸 URL 序列化', () {
    test('锚文本与 href 只差 scheme → 写回裸 URL', () {
      expect(md('看 dl.google.com 吧', link(2, 15, 'http://dl.google.com')),
          '看 dl.google.com 吧');
      expect(md('看 dl.google.com 吧', link(2, 15, 'https://dl.google.com')),
          '看 dl.google.com 吧');
    });

    test('锚文本与 href 完全相同 → 仍写回裸 URL(原有行为)', () {
      expect(
        md('看 https://a.b 吧', link(2, 13, 'https://a.b')),
        '看 https://a.b 吧',
      );
    });

    test('真·带文字的链接不受影响', () {
      expect(md('看 这里 吧', link(2, 4, 'https://a.b')),
          '看 [这里](https://a.b) 吧');
      // 锚文本是另一个地址(不是同一 URL 的裸形态)→ 不能当裸 URL
      expect(md('看 a.com 吧', link(2, 7, 'https://b.com')),
          '看 [a.com](https://b.com) 吧');
    });
  });
}

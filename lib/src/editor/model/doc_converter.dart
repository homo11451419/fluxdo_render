/// 编辑文档 ↔ 阅读端 BlockNode 树 双向互转。
///
/// **零丢失原则**:
/// - 不可编辑的 inline(image/footnote/... 白名单外)→ 所在块**整体
///   岛化**(IslandBlock 原引用直存),不做有损降级;
/// - 列表含块级子节点 → 整棵树岛化(不拆半棵);
/// - IslandBlock 导出时原 node 引用直出(identity 保真)。
///
/// **容器化(M5-B,对齐官方 ProseMirror composer)**:
/// blockquote / quote 卡 / 块级 spoiler / details / callout 是**可进入
/// 容器**而非岛 —— 展平为子块的 [TextBlock.containers] 栈帧;光标直接
/// 进去编辑。容器内出现不可编辑块(岛)时整棵容器岛化(M5-B 范围:
/// 容器内容全可编辑才容器化;混合内容留给岛 + 源码编辑兜底)。
///
/// 列表/容器的树 ↔ 扁平转换:
/// - 导入:ListNode DFS 展平为连续 `TextBlock(listItem, depth)` run;
///   容器节点递归展平,途经块 containers 头部压帧;
/// - 导出:相邻块 containers 公共前缀分组,逐层重建容器节点树;连续
///   listItem run 深度栈重建 ListNode 树。
library;

import '../../node/node.dart';
import 'editable_text_content.dart';
import 'editor_block.dart';

/// M2 编辑白名单:能进 TextBlock 的 inline 类型。
///
/// M5 扩容:行内 SpoilerRun / **普通** LinkRun 进入白名单(mark 化,
/// 内容可编辑)。特种链接除外 —— attachment(`[name|attachment](短链)`)、
/// hashtag(`#ref`)、inline-onebox(裸 URL)的序列化语义都不是
/// `[text](href)`,mark 化会毁写法,保持岛化。
bool isEditableInline(InlineNode n) => switch (n) {
      TextRun() || LineBreakRun() || EmojiRun() || MentionRun() => true,
      // local date chip:行内原子(emoji/mention 同机制),编辑态显示
      // 服务端预渲染文本,序列化写回 [date=…] BBCode
      LocalDateRun() => true,
      // 图片 = 行内原子,无条件(官方 ProseMirror image 就是 inline:true,
      // 无图片块级概念)。upload 可缩放图/lightbox 大图也原子化 —— 选中
      // 后的工具条(缩放/删除/alt/加网格)由宿主浮层承载,查看器在
      // 「已选中再点」时打开。
      ImageRun() => true,
      // `[size=N]` **刻意不放行** → 所在段落整体岛化成块(与分割线同款)。
      //
      // 试过行内原子:原子在编辑文本里只占 1 个哨兵字符,但投影要按里面
      // 真实字符数走(阅读端要逐字选中),两套坐标对不上 —— 光标定位、
      // 命中、宽度全偏,放大后顶出边界。块级岛没这个问题(本来就占 1 个
      // 单位),而且现成的双击/回车进岛改源码(_tryEditSelectedIsland)
      // 直接可用,体验与分割线一致。
      EmRun(:final children) => children.every(isEditableInline),
      StrongRun(:final children) => children.every(isEditableInline),
      InlineCodeRun() => true,
      SpoilerRun(:final children) => children.every(isEditableInline),
      LinkRun(
        :final href,
        :final children,
        :final isAttachment,
        :final hashtagRef,
        :final isOneboxLink,
      ) =>
        !isAttachment &&
            hashtagRef == null &&
            // onebox 系链接(裸 URL 的 linkify 产物)可编辑:flatten 时
            // 文本替换为 href(官方 linkify 语义 —— 编辑器里显示 URL
            // 本身),序列化 text==href 走裸 URL 规则,往返无损
            (isOneboxLink
                ? href.isNotEmpty
                : children.every(isEditableInline)),
      // 颜色:mark 化(MarkKind.textColor/bgColor),内容照常可编辑 ——
      // 不放行的话带色的整行会被岛化成只读,光标直接消失。
      ColoredRun(:final children) => children.every(isEditableInline),
      StyledRun(:final kind, :final children) => switch (kind) {
          InlineStyleKind.underline ||
          InlineStyleKind.lineThrough =>
            children.every(isEditableInline),
          _ => false,
        },
      _ => false,
    };

bool _allEditable(List<InlineNode> inlines) => inlines.every(isEditableInline);

/// 阅读端节点树 → 编辑文档。
///
/// [nextId]:块 id 分配器(EditorState 侧惯例 `e_N`)。
List<EditorBlock> blockNodesToDoc(
  List<BlockNode> nodes,
  String Function() nextId,
) {
  final out = <EditorBlock>[];

  void addIsland(BlockNode node) => out.add(IslandBlock(id: nextId(), node: node));

  void addText(
    EditableTextContent content, {
    TextBlockKind kind = TextBlockKind.paragraph,
    int headingLevel = 1,
    bool ordered = false,
    int depth = 0,
    int listStart = 1,
    List<ContainerFrame> containers = const [],
  }) {
    out.add(TextBlock(
      id: nextId(),
      content: content,
      kind: kind,
      headingLevel: headingLevel,
      ordered: ordered,
      depth: depth,
      listStart: listStart,
      containers: containers,
    ));
  }

  /// 列表整树可编辑性:所有(递归)item 无块级子节点且 inlines 全过白名单。
  bool listEditable(ListNode list) {
    for (final item in list.items) {
      if (item.blocks != null) return false;
      if (!_allEditable(item.inlines)) return false;
      for (final sub in item.children ?? const <ListNode>[]) {
        if (!listEditable(sub)) return false;
      }
    }
    return true;
  }

  /// 展平列表(已验证可编辑)。首项带 listStart。
  void flattenList(ListNode list, int depth, List<ContainerFrame> containers) {
    for (var i = 0; i < list.items.length; i++) {
      final item = list.items[i];
      addText(
        EditableTextContent.fromInlines(item.inlines),
        kind: TextBlockKind.listItem,
        ordered: list.ordered,
        depth: depth,
        listStart: i == 0 && depth == 0 ? list.start : 1,
        containers: containers,
      );
      for (final sub in item.children ?? const <ListNode>[]) {
        flattenList(sub, depth + 1, containers);
      }
    }
  }

  /// 子节点序列是否全部可编辑(容器可进入化判据:段落/标题/列表/空行/
  /// 嵌套可编辑容器)。
  bool blocksEditable(List<BlockNode> children) {
    for (final child in children) {
      final ok = switch (child) {
        ParagraphNode(:final inlines) => _allEditable(inlines),
        HeadingNode(:final inlines) => _allEditable(inlines),
        final ListNode list => listEditable(list),
        BlockquoteNode(:final children) => blocksEditable(children),
        QuoteCardNode(:final children) => blocksEditable(children),
        SpoilerBlockNode(:final children) => blocksEditable(children),
        DetailsNode(:final children) => blocksEditable(children),
        CalloutNode(:final children) => blocksEditable(children),
        BlankLineNode() => true,
        _ => false,
      };
      if (!ok) return false;
    }
    return true;
  }

  void walk(BlockNode node, List<ContainerFrame> containers) {
    switch (node) {
      case ParagraphNode(:final inlines):
        if (_allEditable(inlines)) {
          addText(EditableTextContent.fromInlines(inlines),
              containers: containers);
        } else {
          addIsland(node);
        }
      case HeadingNode(:final level, :final inlines):
        if (_allEditable(inlines)) {
          addText(
            EditableTextContent.fromInlines(inlines),
            kind: TextBlockKind.heading,
            headingLevel: level,
            containers: containers,
          );
        } else {
          addIsland(node);
        }
      case ListNode():
        if (listEditable(node)) {
          flattenList(node, node.depth, containers);
        } else {
          addIsland(node);
        }
      case BlockquoteNode(:final children):
        if (blocksEditable(children)) {
          final frame = [
            ...containers,
            QuoteFrame(groupId: nextFrameGroupId()),
          ];
          for (final child in children) {
            walk(child, frame);
          }
        } else {
          addIsland(node);
        }
      case QuoteCardNode(:final children):
        // onebox 展开物(编辑器预览 cook 的 data-fluxdo-onebox-url
        // 标记):raw 是裸 URL,不容器化 —— 岛化保只读 + 序列化走
        // oneboxUrl 裸 URL 规则(容器化会把它当真引用卡写 [quote] 块,
        // 毁帖:静态引用不跟随原帖)。官方里 onebox 同样是原子节点。
        if (node.oneboxUrl != null && node.oneboxUrl!.isNotEmpty) {
          addIsland(node);
          return;
        }
        if (blocksEditable(children)) {
          final frame = [
            ...containers,
            QuoteCardFrame(
              groupId: nextFrameGroupId(),
              username: node.username,
              displayName: node.displayName,
              postNumber: node.postNumber,
              topicId: node.topicId,
              full: node.full,
            ),
          ];
          // 空引用卡:补一个空段(容器可进入的最小内容)
          if (children.isEmpty) {
            addText(EditableTextContent.empty, containers: frame);
          }
          for (final child in children) {
            walk(child, frame);
          }
        } else {
          addIsland(node);
        }
      case SpoilerBlockNode(:final children):
        if (blocksEditable(children)) {
          final frame = [
            ...containers,
            SpoilerFrame(groupId: nextFrameGroupId()),
          ];
          if (children.isEmpty) {
            addText(EditableTextContent.empty, containers: frame);
          }
          for (final child in children) {
            walk(child, frame);
          }
        } else {
          addIsland(node);
        }
      case DetailsNode(:final summary, :final children, :final initiallyOpen):
        if (blocksEditable(children)) {
          final frame = [
            ...containers,
            DetailsFrame(
              groupId: nextFrameGroupId(),
              summary: summary,
              open: initiallyOpen,
            ),
          ];
          if (children.isEmpty) {
            addText(EditableTextContent.empty, containers: frame);
          }
          for (final child in children) {
            walk(child, frame);
          }
        } else {
          addIsland(node);
        }
      case CalloutNode():
        if (blocksEditable(node.children)) {
          final frame = [
            ...containers,
            CalloutFrame(
              groupId: nextFrameGroupId(),
              kind: node.kind,
              typeRaw: node.typeRaw,
              title: node.title,
              foldable: node.foldable,
            ),
          ];
          if (node.children.isEmpty) {
            addText(EditableTextContent.empty, containers: frame);
          }
          for (final child in node.children) {
            walk(child, frame);
          }
        } else {
          addIsland(node);
        }
      case BlankLineNode():
        addText(EditableTextContent.empty, containers: containers);
      default:
        addIsland(node);
    }
  }

  for (final node in nodes) {
    walk(node, const []);
  }
  // 注意:不在此补"至少一个 TextBlock"—— 那是 EditorState 的文档不变量
  // (其构造器自动补空段);converter 保持纯转换,否则全岛输入的往返
  // 会多出幽灵 BlankLineNode,破坏投影守恒。
  return out;
}

// ---------------------------------------------------------------------
// 逃生口空段(escape gaps)
// ---------------------------------------------------------------------
//
// 「困住区」= 容器内块(引用/引用卡/剧透/details/callout)或只读岛:
// 光标无法在顶层自然地跟在它后面继续输入。若这样的块处在文档**尾部**、
// 或**紧邻另一个困住区**(上下相邻的引用等),用户就没有落点跳出/夹在
// 中间输入。对齐官方 ProseMirror composer 的 gap 语义,这里在这些位置
// 自动补一个**顶层普通空段**当逃生口;发送/序列化时若空段没被填过再
// 回收掉,避免给帖子留多余空行。

/// 块的「困住区」标识:同一容器实例 / 同一岛 = 同区;非困住块 = null。
String? _trapRegionId(EditorBlock b) {
  if (b is IslandBlock) return 'island:${b.id}';
  if (b is TextBlock && b.containers.isNotEmpty) {
    return 'ctr:${b.containers.first.groupId}';
  }
  return null;
}

/// 顶层普通空段(可作逃生口 / 被回收的候选)。
bool _isFreeEmptyParagraph(EditorBlock b) =>
    b is TextBlock &&
    b.containers.isEmpty &&
    b.kind == TextBlockKind.paragraph &&
    b.content.length == 0;

/// 在**非空**困住区尾部 / 两个相邻困住区之间补顶层空段。**幂等**
/// (补出的自由空段会打断相邻性,重跑不会重复补)。[nextId] 复用
/// EditorState 的发号器,避免 id 碰撞。
///
/// 「非空」限定:空容器(刚插入的引用/剧透模板,内部只有一个空段)本身
/// 就是可编辑空行、回车即可退出,不需要额外逃生口 —— 只有装了内容的
/// 引用/岛才会把光标困在末尾。
List<EditorBlock> insertEscapeGaps(
  List<EditorBlock> blocks,
  String Function() nextId,
) {
  if (blocks.isEmpty) return blocks;
  final out = <EditorBlock>[];
  var i = 0;
  while (i < blocks.length) {
    final region = _trapRegionId(blocks[i]);
    if (region == null) {
      out.add(blocks[i]);
      i++;
      continue;
    }
    // 收集同一困住区的连续 run,途中判断是否有实际内容
    var nonEmpty = false;
    while (i < blocks.length && _trapRegionId(blocks[i]) == region) {
      final b = blocks[i];
      out.add(b);
      if (b is IslandBlock || (b is TextBlock && b.content.length > 0)) {
        nonEmpty = true;
      }
      i++;
    }
    // run 之后:非空 且(到文末 或 紧邻另一个困住区)→ 补逃生空段
    final nextRegion = i < blocks.length ? _trapRegionId(blocks[i]) : null;
    final atEndOrBeforeTrap = i >= blocks.length || nextRegion != null;
    if (nonEmpty && atEndOrBeforeTrap) {
      out.add(TextBlock(id: nextId(), content: EditableTextContent.empty));
    }
  }
  return out;
}

/// 回收未被填过的逃生空段:紧跟困住区、且处在尾部或另一困住区之前的
/// 顶层空段 —— 用户没在里面输入就撤掉,避免序列化出多余空行。
List<EditorBlock> stripUnusedEscapeGaps(List<EditorBlock> blocks) {
  if (blocks.isEmpty) return blocks;
  final out = <EditorBlock>[];
  for (var i = 0; i < blocks.length; i++) {
    final b = blocks[i];
    if (_isFreeEmptyParagraph(b)) {
      final prev = out.isNotEmpty ? out.last : null;
      final next = i + 1 < blocks.length ? blocks[i + 1] : null;
      final prevTrap = prev != null && _trapRegionId(prev) != null;
      final nextTrap = next != null && _trapRegionId(next) != null;
      if (prevTrap && (next == null || nextTrap)) {
        continue; // 未用逃生口 → 回收
      }
    }
    out.add(b);
  }
  return out;
}

/// 编辑文档 → 阅读端节点树(给阅读端渲染/markdown 序列化)。
List<BlockNode> docToBlockNodes(List<EditorBlock> doc) {
  var idCounter = 0;
  String nextId() => 'b_${idCounter++}';
  return _buildLevel(doc, 0, nextId);
}

/// 递归重建:处理 [doc] 中所有块在容器栈深度 [level] 上的分组。
///
/// 相邻块 containers[level] 相等(且都有该层)→ 同一容器实例,递归
/// 包装;无该层 → 顶层内容(列表 run / 单块)。
List<BlockNode> _buildLevel(
  List<EditorBlock> doc,
  int level,
  String Function() nextId,
) {
  final out = <BlockNode>[];
  var i = 0;

  while (i < doc.length) {
    final block = doc[i];

    if (block is IslandBlock) {
      out.add(block.node); // identity 直出
      i++;
      continue;
    }
    block as TextBlock;

    if (block.containers.length > level) {
      // 收集相同容器帧的连续 run,递归下一层
      final frame = block.containers[level];
      final run = <EditorBlock>[];
      while (i < doc.length) {
        final b = doc[i];
        if (b is TextBlock &&
            b.containers.length > level &&
            b.containers[level] == frame) {
          run.add(b);
          i++;
        } else {
          break;
        }
      }
      final children = _buildLevel(run, level + 1, nextId);
      out.add(_wrapInFrame(frame, children, nextId));
      continue;
    }

    if (block.isListItem) {
      final run = <TextBlock>[];
      while (i < doc.length) {
        final b = doc[i];
        if (b is TextBlock &&
            b.isListItem &&
            b.containers.length <= level) {
          run.add(b);
          i++;
        } else {
          break;
        }
      }
      out.addAll(_buildLists(run, 0, nextId));
      continue;
    }

    out.add(_textBlockToNode(block, nextId));
    i++;
  }
  return out;
}

/// 容器帧 → 对应的阅读端容器节点。
BlockNode _wrapInFrame(
  ContainerFrame frame,
  List<BlockNode> children,
  String Function() nextId,
) =>
    switch (frame) {
      QuoteFrame() => BlockquoteNode(id: nextId(), children: children),
      QuoteCardFrame(
        :final username,
        :final displayName,
        :final postNumber,
        :final topicId,
        :final full,
      ) =>
        QuoteCardNode(
          id: nextId(),
          username: username,
          displayName: displayName,
          postNumber: postNumber,
          topicId: topicId,
          full: full,
          children: children,
        ),
      SpoilerFrame() => SpoilerBlockNode(id: nextId(), children: children),
      DetailsFrame(:final summary, :final open) => DetailsNode(
          id: nextId(),
          summary: summary,
          children: children,
          initiallyOpen: open,
        ),
      CalloutFrame(:final kind, :final typeRaw, :final title, :final foldable) =>
        CalloutNode(
          id: nextId(),
          kind: kind,
          typeRaw: typeRaw,
          title: title,
          foldable: foldable,
          children: children,
        ),
    };

/// 单个非列表文本块 → 节点。
BlockNode _textBlockToNode(TextBlock block, String Function() nextId) {
  if (block.isHeading) {
    return HeadingNode(
      id: nextId(),
      level: block.headingLevel,
      inlines: _exportInlines(block),
    );
  }
  if (block.content.length == 0) {
    return BlankLineNode(id: nextId());
  }
  return ParagraphNode(id: nextId(), inlines: _exportInlines(block));
}

/// toInlines 即可 —— only-emoji(Discourse 大表情)由
/// [EditableTextContent.toInlines] 统一判定,编辑态渲染与导出共用同一
/// 套规则(此前只在导出侧标,导致实时插入的 emoji 不变大)。
List<InlineNode> _exportInlines(TextBlock block) => block.content.toInlines();

/// 连续 listItem run(同容器层)→ ListNode 树(深度栈重建)。
///
/// 相邻同 depth 且 ordered 不同 → 关组开新列表(对齐 HTML ul/ol 分家)。
List<ListNode> _buildLists(
  List<TextBlock> run,
  int baseDepth,
  String Function() nextId,
) {
  final out = <ListNode>[];
  var i = 0;
  while (i < run.length) {
    final first = run[i];
    final ordered = first.ordered;
    final items = <ListItem>[];
    final start = first.listStart;

    while (i < run.length) {
      final b = run[i];
      if (b.depth < baseDepth) break;
      if (b.depth == baseDepth) {
        if (b.ordered != ordered) break; // ul/ol 分家
        i++;
        // 吞掉紧随其后的更深层(挂为本 item 的子列表)
        final deeper = <TextBlock>[];
        while (i < run.length && run[i].depth > baseDepth) {
          deeper.add(run[i]);
          i++;
        }
        items.add(ListItem(
          inlines: b.content.toInlines(),
          children: deeper.isEmpty
              ? null
              : _buildLists(deeper, baseDepth + 1, nextId),
        ));
      } else {
        // run 以更深层开头(缩进悬空):按提升到本层处理
        final deeper = <TextBlock>[];
        while (i < run.length && run[i].depth > baseDepth) {
          deeper.add(run[i]);
          i++;
        }
        final sublists = _buildLists(deeper, baseDepth + 1, nextId);
        items.add(ListItem(inlines: const [], children: sublists));
      }
    }

    out.add(ListNode(
      id: nextId(),
      ordered: ordered,
      items: items,
      depth: baseDepth,
      start: start,
    ));
  }
  return out;
}

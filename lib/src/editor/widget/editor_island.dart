/// 只读孤岛块 widget。
///
/// 渲染 = NodeFactory.build(与阅读端同一渲染出口)包三层:
/// 1. **inert SelectionScope**:独立 SelectionController —— 岛内块
///    (codeblock/表格里的 SelectableTextBox)就近注册到这个哑控制器,
///    不进编辑器的 registry(否则命中/选区会漏进岛内部);
/// 2. **AbsorbPointer**:冻结岛内交互(链接点击/poll 投票/spoiler 揭示),
///    点击事件交给外层 GestureDetector 做「整选岛」;
/// 3. **选中态**:primary 描边 + 低透明度罩(选中时)。
///
/// 图片不再走岛(全图原子化,官方 ProseMirror image 是 inline:true):
/// 选中/缩放/alt/删除交互由 FluxdoEditor 的 ImageAtomSelection 事件 +
/// 宿主浮层承载。[EditorImageScaleBar] 保留 —— 主项目源码模式预览
/// (fluxdo_render_callbacks)仍用它做可缩放图的 100/75/50 胶囊。
///
/// grid 岛的交互(模式切换/移除/瓦片子选中)已整体内聚在
/// EditorImageGrid(经 [contentOverride] 注入),此处不再有 grid 专属逻辑。
library;

import 'package:flutter/material.dart';

import '../../node/node.dart';
import '../../render/node_factory.dart';
import '../../selection/selection_registry.dart';
import '../../selection/selection_scope.dart';
import 'editor_table_grid.dart' show kEditorIslandRegion;

/// 官方 SCALES 同款档位。
const kEditorImageScales = [100, 75, 50];

class EditorIsland extends StatefulWidget {
  const EditorIsland({
    super.key,
    required this.node,
    required this.nodeFactory,
    required this.selected,
    required this.onTapSelect,
    this.onEditRequest,
    this.onInsertParagraph,
    this.contentOverride,
  });

  final BlockNode node;

  final NodeFactory nodeFactory;

  final bool selected;

  /// 点击 → 编辑器整选本岛。
  final VoidCallback onTapSelect;

  /// 双击 → 请求编辑本岛(宿主弹源码对话框;null = 岛不可编辑)。
  final VoidCallback? onEditRequest;

  /// 选中态上下缘「加段」把手(gapcursor 的移动端等价物:首块是岛/
  /// 岛在文档尾时,没有可点的间隙落光标 —— 桌面还能靠选中回车,
  /// 移动端软键盘够不着该链)。[before] = 在岛前建段。null 不显示。
  final void Function({required bool before})? onInsertParagraph;

  /// 岛内容替换(grid 岛的可交互瓦片视图 EditorImageGrid 由编辑器注入;
  /// null 用默认 NodeFactory.build + AbsorbPointer 只读渲染)。
  /// 注入内容自带自管区标记/手势,不再包 AbsorbPointer。
  final Widget? contentOverride;

  @override
  State<EditorIsland> createState() => _EditorIslandState();
}

/// 节点里是否含 0 倍字号([SizedRun] scale == 0,即 `[size=0]`)。
///
/// 这种内容渲染出来完全不可见,编辑态必须另给提示 —— 阅读端保持隐藏
/// (对齐网页端),两边诉求不同。
bool _hasZeroSize(BlockNode node) {
  var found = false;
  void scan(List<InlineNode> inlines) {
    for (final n in inlines) {
      if (found) return;
      switch (n) {
        case SizedRun(:final scale, :final children):
          if (scale == 0) {
            found = true;
            return;
          }
          scan(children);
        case EmRun(:final children):
        case StrongRun(:final children):
        case StyledRun(:final children):
        case ColoredRun(:final children):
        case LinkRun(:final children):
        case SpoilerRun(:final children):
          scan(children);
        default:
          break;
      }
    }
  }

  switch (node) {
    case ParagraphNode(:final inlines):
      scan(inlines);
    case HeadingNode(:final inlines):
      scan(inlines);
    default:
      break;
  }
  return found;
}

class _EditorIslandState extends State<EditorIsland> {
  /// 哑选区控制器:吞掉岛内块的注册,与编辑器 registry 隔离。
  late final SelectionController _inertController =
      SelectionController(SelectionRegistry());

  @override
  void dispose() {
    _inertController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    Widget content = widget.contentOverride ??
        SelectionScope(
          controller: _inertController,
          child: AbsorbPointer(
            child: widget.nodeFactory.build(context, widget.node),
          ),
        );

    // `[size=0]` 这类 0 倍字号在编辑态渲染出来是**完全不可见**的 ——
    // 块画在那儿却什么都看不到,用户既不知道有东西、也点不着。补一行
    // 灰字说明,并给整块一个最小高度保证可点。
    if (_hasZeroSize(widget.node)) {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          content,
          Text(
            '当前区域大小 = 0',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
        ],
      );
    }

    // 最小高度:块太薄不好点(尤其内容本身不可见时)
    content = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 28),
      child: Align(alignment: Alignment.centerLeft, child: content),
    );

    content = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: widget.selected ? scheme.primary : Colors.transparent,
          width: 2,
        ),
        color: widget.selected
            ? scheme.primary.withValues(alpha: 0.08)
            : Colors.transparent,
      ),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: content,
      ),
    );

    // 选中态:上下缘悬挂「加段」把手(挂块边界外,根 Stack Clip.none
    // 承接 —— 表格选择柄同款悬挂惯例)
    if (widget.selected && widget.onInsertParagraph != null) {
      // 半悬挂(-12 + 高 28 → 中心在界内):Stack 命中只认自身 bounds,
      // 全悬挂画得出来点不到(根 Stack Clip.none 只救绘制不救命中)
      Widget handle({required bool before}) => Positioned(
            top: before ? -12 : null,
            bottom: before ? null : -12,
            left: 0,
            right: 0,
            child: Center(
              child: _InsertParagraphHandle(
                key: ValueKey(before
                    ? 'island-insert-before'
                    : 'island-insert-after'),
                onTap: () => widget.onInsertParagraph!(before: before),
              ),
            ),
          );
      content = Stack(
        clipBehavior: Clip.none,
        children: [
          content,
          handle(before: true),
          handle(before: false),
        ],
      );
    }

    // (grid 岛工具条已内聚进 EditorImageGrid —— 官方 composer 布局:
    // [网格|轮播] 容器右上、[移除网格] 容器右下、瓦片工具条叠图上。)

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTapSelect,
      onDoubleTap: widget.onEditRequest,
      child: MouseRegion(
        cursor: SystemMouseCursors.basic,
        // 岛区域标记:编辑器长按选词让路(岛无 RenderParagraph,长按
        // 会被最近块兜底吸到邻段);translucent 不挡岛内已有手势。
        child: MetaData(
          metaData: kEditorIslandRegion,
          behavior: HitTestBehavior.translucent,
          child: content,
        ),
      ),
    );
  }
}


/// 100%/75%/50% 缩放胶囊条(浮层统一规格:圆角 + outlineVariant 细边 +
/// surfaceContainerLow 底 + 柔和投影)。主项目源码模式预览的可缩放图
/// 使用(编辑器内图片缩放已改走宿主浮层工具条)。
class EditorImageScaleBar extends StatelessWidget {
  const EditorImageScaleBar({
    super.key,
    required this.current,
    required this.onSelect,
  });

  final int current;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.5),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.10),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final s in kEditorImageScales)
              _ScalePill(
                label: '$s%',
                active: s == current,
                onTap: s == current ? null : () => onSelect(s),
              ),
          ],
        ),
      ),
    );
  }
}

class _ScalePill extends StatelessWidget {
  const _ScalePill({required this.label, required this.active, this.onTap});

  final String label;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Listener 原始指针事件,不进手势竞技场:源码预览的图片外层可能有
    // 查看器 tap 手势,原始 down 即触发零等待。InkWell 仅留视觉水波。
    return Listener(
      onPointerDown: onTap == null ? null : (_) => onTap!(),
      child: InkWell(
        onTap: onTap == null ? null : () {},
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: active ? scheme.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              height: 1.2,
              fontWeight: FontWeight.w500,
              color: active ? scheme.onPrimary : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// 岛选中态的「加段」小把手(28px 圆钮,+ 图标;触控余量靠 padding)。
class _InsertParagraphHandle extends StatelessWidget {
  const _InsertParagraphHandle({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Container(
          width: 28,
          height: 20,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: scheme.primary,
            borderRadius: BorderRadius.circular(10),
            boxShadow: const [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 4,
                offset: Offset(0, 1),
              ),
            ],
          ),
          child: Icon(Icons.add_rounded, size: 15, color: scheme.onPrimary),
        ),
      ),
    );
  }
}

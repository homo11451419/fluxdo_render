/// 编辑器组装件 —— M1 顶层 widget。
///
/// 职责:
/// - 持有编辑器**自己的** SelectionController/Registry(不走只读全局
///   coordinator 的手势层;高亮/命中/caret 几何复用同一套基建);
/// - 坐标桥接:EditorState 的 (blockId, 编辑文本偏移) ↔ 选区系统的
///   (SelectableBlockId(docOrder), 渲染偏移),经逻辑块表 projection 换算;
/// - 手势:tap 定位光标、拖动扩选;
/// - Focus + IME client 生命周期,帧后回喂光标几何;
/// - 光标 overlay(EditorCaret)。
library;

import 'dart:ui' as ui show BoxHeightStyle;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/gestures.dart'
    show
        LongPressGestureRecognizer,
        PanGestureRecognizer,
        PointerDeviceKind,
        TapGestureRecognizer,
        kDoubleTapTimeout,
        kDoubleTapSlop;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show BoxHitTestResult, RenderMetaData;
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';

import '../../node/node.dart'
    show
        CodeBlockNode,
        ImageGridNode,
        ImageRun,
        InlineNode,
        LocalDateRun,
        TableNode;
import '../../render/block_text_styles.dart';
import '../../render/node_factory.dart';
import '../../selection/hit_tester.dart';
import '../../selection/selection_exporter.dart';
import '../../selection/selection_geometry.dart';
import '../../selection/selection_handles.dart';
import '../../selection/selection_magnifier.dart';
import '../../selection/selection_registry.dart';
import '../../selection/selection_scope.dart';
import '../input/editor_ime_client.dart';
import '../input/editor_key_handler.dart';
import '../model/editor_image_commands.dart';
import '../model/editor_state.dart';
import 'editable_paragraph.dart';
import 'editor_caret.dart';
import 'editor_code_block.dart';
import 'editor_collapsed_handle.dart';
import 'editor_container_shell.dart';
import 'editor_context_bar.dart';
import 'editor_image_grid.dart';
import 'editor_island.dart';
import 'editor_table_grid.dart';

/// 图片原子选中态(官方 ProseMirror NodeSelection 对应物)。
///
/// [globalRect] 帧后计算(_afterFrame),跟随滚动/重排更新 —— 宿主浮层
/// (工具条/alt 输入条)锚定用。==/hashCode 四字段全参与:rect 变化也
/// 要通知(浮层跟随),宿主按值比较跳过冗余重建。
@immutable
class ImageAtomSelection {
  const ImageAtomSelection({
    required this.blockId,
    required this.offset,
    required this.image,
    required this.globalRect,
  });

  /// 所在文本块 id(动作回调 replaceAtomAt/addImageAtomToGrid 直接用)。
  final String blockId;

  /// 原子在块内的内容偏移。
  final int offset;

  /// 图片原子(宿主算 disabled 态与 copyWith 基底)。
  final ImageRun image;

  /// 图片渲染矩形(全局坐标)。
  final Rect globalRect;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ImageAtomSelection &&
          blockId == other.blockId &&
          offset == other.offset &&
          image == other.image &&
          globalRect == other.globalRect;

  @override
  int get hashCode => Object.hash(blockId, offset, image, globalRect);
}

/// 浮动幽灵光标定位用(widget test;iOS 长按空格 trackpad 模式)。
const Key kFloatingCursorGhostKey = ValueKey('editor-floating-cursor-ghost');

/// 岛整选上下文(宿主 onebox 工具条等锚定用;帧后回报,滚动跟随)。
@immutable
class IslandSelection {
  const IslandSelection({required this.island, required this.globalRect});

  final IslandBlock island;
  final Rect globalRect;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is IslandSelection &&
          island == other.island &&
          globalRect == other.globalRect;

  @override
  int get hashCode => Object.hash(island, globalRect);
}

/// collapsed 光标落在链接内的上下文(宿主链接工具条锚定/编辑用)。
///
/// [rangeGlobal] = 链接文本区间的全局包围矩形(帧后计算,跟随滚动
/// 刷新);[start]/[end] = 块内编辑偏移(原位替换用)。
@immutable
class LinkCaretInfo {
  const LinkCaretInfo({
    required this.blockId,
    required this.start,
    required this.end,
    required this.href,
    required this.text,
    required this.rangeGlobal,
  });

  final String blockId;
  final int start;
  final int end;
  final String? href;

  /// 链接区间纯文本(编辑对话框预填;含原子哨兵时由宿主自行取舍)。
  final String text;

  final Rect rangeGlobal;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LinkCaretInfo &&
          blockId == other.blockId &&
          start == other.start &&
          end == other.end &&
          href == other.href &&
          text == other.text &&
          rangeGlobal == other.rangeGlobal;

  @override
  int get hashCode => Object.hash(blockId, start, end, href, text, rangeGlobal);
}

/// 编程式虚拟指针:宿主"手势光标"的二维形态 —— 复用 iOS 浮动光标链
/// (幽灵光标跟手 + 实光标命中吸附 + 贴边自动滚)。宿主滑钮 pan 手势
/// 驱动:按下 [start] → 拖动 [moveBy] 累计位移 → 松手 [end]。
///
/// 经 [FluxdoEditor.virtualPointer] 绑定;编辑器未挂载/无光标时
/// [start] 返回 false(宿主应忽略本次拖动)。
class FluxdoEditorVirtualPointer {
  _FluxdoEditorState? _state;
  Offset _acc = Offset.zero;
  bool _active = false;

  bool get isActive => _active;

  /// 从当前光标处起漂。[extend] = 扩选(选区 base 固定,指针驱动 extent)。
  bool start({bool extend = false}) {
    final s = _state;
    if (s == null || !s.mounted) return false;
    _acc = Offset.zero;
    _active = s._floatingStart(extend: extend);
    return _active;
  }

  void moveBy(Offset delta) {
    if (!_active) return;
    _acc += delta;
    _state?._floatingUpdate(_acc);
  }

  void end() {
    if (!_active) return;
    _active = false;
    _state?._floatingEnd();
  }
}

class FluxdoEditor extends StatefulWidget {
  const FluxdoEditor({
    super.key,
    required this.state,
    this.baseTextStyle,
    this.autofocus = false,
    this.focusNode,
    this.nodeFactory,
    this.markdownImporter,
    this.richPasteImporter,
    this.onIslandEditRequest,
    this.onContainerTitleEdit,
    this.onTableEdited,
    this.onCodeBlockEdited,
    this.onAtomTap,
    this.onImageAtomSelectionChanged,
    this.onImageAtomOpenRequest,
    this.onGridImageSelectionChanged,
    this.onGridImageOpenRequest,
    this.onCaretRectChanged,
    this.onLinkCaret,
    this.onIslandSelected,
    this.keyEventInterceptor,
    this.virtualPointer,
  });

  final EditorState state;

  final TextStyle? baseTextStyle;

  final bool autofocus;

  /// 外部焦点节点(宿主监听焦点态做键盘/面板联动;null 内部自建)。
  final FocusNode? focusNode;

  /// 孤岛块的渲染工厂(主项目注入带 emoji/image builder 的实例;
  /// null 用子包默认 fallback —— demo/测试可用)。
  final NodeFactory? nodeFactory;

  /// 粘贴的 markdown → 编辑块导入器(主项目注入 cook 链路:
  /// markdown → cook → parse → blockNodesToDoc)。null / 返回 null 时
  /// 粘贴降级为纯文本(pastePlainText)。
  ///
  /// 剪贴板策略:复制/剪切写 markdown 文本(跨 app 通用、粘回自身经
  /// cook 还原富内容 —— Discourse 官方富文本 composer 同款语义)。
  final Future<List<EditorBlock>?> Function(String markdown)? markdownImporter;

  /// 富粘贴导入器:粘贴时**先**问它 —— 宿主自行读系统剪贴板的富格式
  /// (text/html 等,子包不背平台剪贴板依赖)并转成编辑块。返回 null /
  /// 空 = 剪贴板无富内容或转换失败,回落 [markdownImporter] 纯文本路径;
  /// 抛异常同回落。null = 不启用富粘贴。
  final Future<List<EditorBlock>?> Function()? richPasteImporter;

  /// 双击岛 → 请求编辑(宿主弹源码对话框,改完调 state.replaceIsland)。
  /// null = 岛只读不可编辑。
  final void Function(IslandBlock island)? onIslandEditRequest;

  /// 点容器壳标题(details summary / callout 标题)→ 请求改标题
  /// (宿主弹输入框,改完调 state.updateContainerFrame)。null = 不可改。
  final void Function(ContainerFrame frame)? onContainerTitleEdit;

  /// 表格 cell 编辑确认 → 新 markdown 表格文本(宿主 cook 后
  /// state.replaceIsland)。null = 表格走通用只读岛。
  final void Function(IslandBlock island, String markdown)? onTableEdited;

  /// 代码块岛内编辑提交 → 新 code/language(宿主直接
  /// state.updateIslandNode(CodeBlockNode(...)),结构化形变不经 cook)。
  /// null = 代码块走通用只读岛(双击源码编辑)。
  final void Function(IslandBlock island, String code, String? language)?
  onCodeBlockEdited;

  /// 单击可编辑原子(date chip)→ 请求编辑(宿主弹属性对话框,确认后
  /// state.replaceAtomAt)。null = 原子只读。
  final void Function(String blockId, int offset, InlineNode atom)? onAtomTap;

  /// 图片原子选中态变化(帧后回报,含全局矩形,跟随滚动/重排;null =
  /// 取消选中)。宿主浮层(缩放/删除/加网格工具条 + alt 输入条)锚定用。
  final ValueChanged<ImageAtomSelection?>? onImageAtomSelectionChanged;

  /// 已选中的图片原子再次单击 → 请求打开(宿主开图片查看器,官方
  /// 「选中态再点开灯箱」同语义)。
  final ValueChanged<ImageAtomSelection>? onImageAtomOpenRequest;

  /// grid 岛内图片子选中变化(官方 grid 内图 NodeSelection 的等价物;
  /// null = 取消)。宿主浮层出官方 isInGrid 工具条([删除|移出网格] +
  /// alt 条,无缩放按钮)。
  final ValueChanged<GridImageSelection?>? onGridImageSelectionChanged;

  /// 已子选中的 grid 内图再点 → 请求打开查看器。
  final ValueChanged<GridImageSelection>? onGridImageOpenRequest;

  /// 光标全局矩形变化(帧后回报;null = 光标不可见)。宿主用于锚定
  /// 斜杠菜单/mention 面板到光标位置。
  final ValueChanged<Rect?>? onCaretRectChanged;

  /// collapsed 光标进入/离开链接(帧后回报;null = 不在链接内/失焦/
  /// range 选区)。宿主链接工具条(编辑/复制/取消链接/预览/访问)
  /// 锚定用 —— 官方 link-toolbar 的 getMarkRange 检测同语义。
  final ValueChanged<LinkCaretInfo?>? onLinkCaret;

  /// 岛整选态变化(帧后回报,含全局矩形跟随滚动;null = 取消)。宿主
  /// 按 island.node 类型出对应工具条(官方 onebox-toolbar 的
  /// NodeSelection 检测同语义)。
  final ValueChanged<IslandSelection?>? onIslandSelected;

  /// 虚拟指针控制器(宿主手势光标驱动浮动光标链);null 不启用。
  final FluxdoEditorVirtualPointer? virtualPointer;

  /// 按键拦截器:编辑器处理按键**之前**先问它(返回 true = 已消费,
  /// 编辑器不再处理)。宿主的浮层(斜杠菜单/mention)激活时借此接管
  /// 上下键/回车/Esc —— 否则方向键被编辑器拿去移光标,菜单无法导航。
  final bool Function(KeyEvent event)? keyEventInterceptor;

  @override
  State<FluxdoEditor> createState() => _FluxdoEditorState();
}

class _FluxdoEditorState extends State<FluxdoEditor>
    with SingleTickerProviderStateMixin {
  late final SelectionController _controller;
  late final SelectionHitTester _hitTester;
  late final EditorImeClient _ime;
  late final NodeFactory _islandFactory;
  late final FocusNode _focusNode =
      widget.focusNode ?? FocusNode(debugLabel: 'FluxdoEditor');
  bool get _ownsFocusNode => widget.focusNode == null;
  final GlobalKey _rootKey = GlobalKey();

  /// 岛容器 key(整选矩形上抛用;按块 id 稳定)。
  final Map<String, GlobalKey> _islandKeys = {};

  /// 编辑器局部坐标系的光标矩形 + 配对修订号(帧后由 hit_tester 计算)。
  ///
  /// 用 ValueNotifier 而非 setState:光标位置每键都变,走整树 setState
  /// 会造成"每键两帧全量 build"(JANK 日志的第二帧 vsyncOverhead 20ms+
  /// 就是它);Notifier 只重建 caret overlay 一个叶子。修订号语义见
  /// EditorCaret.moveGeneration。
  final ValueNotifier<(Rect?, int)> _caretInfo = ValueNotifier((null, 0));

  @override
  void initState() {
    super.initState();
    _controller = SelectionController(SelectionRegistry());
    _hitTester = SelectionHitTester(_controller.registry);
    _ime = EditorImeClient(state: widget.state);
    // input rule `--- ` → 分隔线岛(经 cook 链路;importer 未注入时用
    // markdown 纯文本兜底 —— 至少不静默)
    _ime.onHorizontalRuleRequest = _insertHorizontalRule;
    // iOS 浮动光标(长按空格 trackpad 模式)
    _ime.onFloatingCursor = _onFloatingCursor;
    // macOS selector 快捷键(自管 IME 激活时 Cmd+A/C/V/X 走 selector)
    _ime.onSelector = _onImeSelector;
    widget.virtualPointer?._state = this;
    _islandFactory = widget.nodeFactory ?? NodeFactory();
    widget.state.addListener(_onStateChanged);
    _focusNode.addListener(_onFocusChanged);
    // 手柄拖动的反向回写(controller → state;仅 _handleDragging 期间)
    _controller.addListener(_onSelectionControllerChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _afterFrame());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ime.updateViewId(View.of(context).viewId);
    _bindScrollPosition();
    // 键盘 inset 变化(弹出/收起动画每帧):清 ensure key + 帧后重算,
    // 光标跟着键盘上沿浮起(MediaQuery 依赖由这次读取建立)。
    final inset = MediaQuery.maybeOf(context)?.viewInsets.bottom ?? 0;
    if (inset != _lastViewInsetBottom) {
      _lastViewInsetBottom = inset;
      _lastEnsuredKey = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _afterFrame();
      });
    }
  }

  @override
  void dispose() {
    if (widget.virtualPointer?._state == this) {
      widget.virtualPointer!._active = false;
      widget.virtualPointer!._state = null;
    }
    _handles?.hide();
    _collapsedHandle?.hide();
    _contextBar?.hide();
    _magnifier?.hide();
    _removeFloatingGhost();
    _autoScrollTicker?.dispose();
    _scrollPosition?.removeListener(_onScrolled);
    _caretInfo.dispose();
    widget.state.removeListener(_onStateChanged);
    _controller.removeListener(_onSelectionControllerChanged);
    _ime.detach();
    _focusNode.removeListener(_onFocusChanged);
    // Focus(onKeyEvent:) 会把处理器写进 FocusNode 对象本身;外部共享
    // 节点在本编辑器亡后仍存活 —— 不清的话宿主把同一节点交给 TextField
    // (双模切换),每个按键先过本编辑器的亡灵处理器:Cmd+A 命中
    // keyA 分支对已 dispose 的 state 空操作后 handled 吞键 = 切到源码
    // 后全选/快捷键全废。
    // == 而非 identical:方法 tearoff 每次取都是新闭包对象(identical
    // 恒 false),同对象同方法的 tearoff 相等性走 ==
    if (_focusNode.onKeyEvent == _editorOnKeyEvent) {
      _focusNode.onKeyEvent = null;
    }
    if (_ownsFocusNode) _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  // -----------------------------------------------------------------
  // 状态联动
  // -----------------------------------------------------------------

  /// 编辑帧耗时插桩(debug;>8ms 打印,定位打字卡顿)。
  Stopwatch? _editFrameWatch;

  void _onStateChanged() {
    if (!mounted) return;
    if (kDebugMode) _editFrameWatch = Stopwatch()..start();
    // 打字/退格(IME 平台增量应用中)→ 收触摸选区 UI(系统同款:输入
    // 即隐手柄;实际显隐由帧后 _syncHandlesAndContextBar 收敛)。
    if (_ime.isApplyingPlatformUpdate) {
      _touchSelection = false;
      _wantCollapsedBar = false;
    }
    // 外部变更(undo/redo 按钮、程序化改文档)→ IME 的 diff 基准已过期,
    // 必须重喂;IME 自身回调引发的通知、以及拖选/长按扩选/手柄拖动进行
    // 中(高频选区变化,end 时统一喂)除外。
    // hasPrimaryFocus(非 hasFocus):焦点在子输入框(表格 cell)时
    // 编辑器 IME 必须闭嘴 —— 重喂会跟 TextField 抢输入连接。
    if (!_ime.isApplyingPlatformUpdate &&
        _dragBase == null &&
        !_longPressing &&
        !_handleDragging &&
        !_floatingCursor &&
        _focusNode.hasPrimaryFocus) {
      _ime.syncFromState(show: false);
    }
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) => _afterFrame());
  }

  /// 上一次观察到的 primary 焦点态(区分三态迁移用)。
  bool _hadPrimaryFocus = false;

  void _onFocusChanged() {
    final primary = _focusNode.hasPrimaryFocus;
    // 临时探针(Win+V 排查):剪贴板面板抢焦点后编辑器是否掉了主焦点
    // (掉了就会 _ime.detach(),回来时注入的按键无处可去)。
    if (kDebugMode) {
      debugPrint('[Focus] primary=$primary hasFocus=${_focusNode.hasFocus}');
    }
    if (primary) {
      // 聚焦编辑器正文(Tab / 点击 / 从 cell 输入框回来):恢复光标可编辑。
      // 无选区时落到文档末尾(常规编辑器语义)。
      if (widget.state.selection == null) {
        final last = widget.state.blocks.last;
        widget.state.updateSelection(
          EditorSelection.collapsed(
            EditorPosition(blockId: last.id, offset: last.selectionLength),
          ),
        );
      }
      _ime.syncFromState();
    } else if (_hadPrimaryFocus) {
      // 焦点离开编辑器正文(→ 子输入框如表格 cell,或 → 编辑器外):
      // 关编辑器 IME + 封历史口;光标随 hasPrimaryFocus 消失(见
      // _computeLocalCaretRect),否则与 cell TextField 双光标。
      // 焦点离开编辑器(点「发送」/切到别处):先把显形的字面标记收回
      // 结构,否则 `**粗**` 会原样被序列化提交。
      widget.state.commitReveals();
      _ime.detach();
      widget.state.sealHistory();
    }
    _hadPrimaryFocus = primary;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) => _afterFrame());
  }

  /// 帧后:镜像选区给高亮层 + 重算光标矩形 + 回喂 IME 几何。
  void _afterFrame() {
    if (!mounted) return;
    final w = _editFrameWatch;
    if (w != null) {
      _editFrameWatch = null;
      w.stop();
      if (w.elapsedMilliseconds > 8) {
        debugPrint(
          '[EditorPerf] edit frame ${w.elapsedMilliseconds}ms '
          '(blocks=${widget.state.blocks.length})',
        );
      }
    }
    // 失焦时高亮层也清掉(选区数据保留在 EditorState,聚焦回来即恢复);
    // 焦点在 cell 输入框时同理(hasPrimaryFocus)。
    _controller.selection = _focusNode.hasPrimaryFocus
        ? _toDocumentSelection(widget.state.selection)
        : null;

    final newCaret = _computeLocalCaretRect();
    if (newCaret != _caretInfo.value.$1) {
      _caretInfo.value = (newCaret, widget.state.docRevision);
    }

    final rootBox = _rootKey.currentContext?.findRenderObject();
    if (newCaret != null && rootBox is RenderBox && rootBox.hasSize) {
      _ime.updateEditableGeometry(
        size: rootBox.size,
        transform: rootBox.getTransformTo(null),
        caretRect: newCaret,
      );
      // 光标全局矩形上抛(斜杠菜单/mention 面板锚定光标,而非编辑器角)
      final caretGlobal =
          rootBox.localToGlobal(newCaret.topLeft) & newCaret.size;
      widget.onCaretRectChanged?.call(caretGlobal);
      _ensureCaretVisible(caretGlobal);
      _notifyLinkCaret();
    } else if (newCaret == null) {
      widget.onCaretRectChanged?.call(null);
      _notifyLinkCaret();
    }

    // 图片原子选中态上抛(变化才通知;rect 变化也算 —— 浮层跟随)
    final imgSel = _computeImageAtomSelection();
    if (imgSel != _lastImageAtomSel) {
      _lastImageAtomSel = imgSel;
      widget.onImageAtomSelectionChanged?.call(imgSel);
    }

    // 岛整选态上抛(onebox 工具条等;变化才通知,rect 变化跟随滚动)
    if (widget.onIslandSelected != null) {
      final islSel = _computeIslandSelection();
      if (islSel != _lastIslandSel) {
        _lastIslandSel = islSel;
        widget.onIslandSelected!(islSel);
      }
    }

    // grid 子选中失效检查:岛没了/图删了/主选区**后续**移动(基线对比)
    // → 清。点瓦片在自管区内不动主选区,基线恒等不误清。
    final gsel = _gridImageSel;
    if (gsel != null) {
      final blockIdx = widget.state.indexOfBlock(gsel.$1);
      final stillIsland =
          blockIdx >= 0 &&
          widget.state.blocks[blockIdx] is IslandBlock &&
          (widget.state.blocks[blockIdx] as IslandBlock).node is ImageGridNode;
      final imagesLen = stillIsland
          ? ((widget.state.blocks[blockIdx] as IslandBlock).node
                    as ImageGridNode)
                .images
                .length
          : 0;
      final selectionMoved = widget.state.selection != _gridSelBaseline;
      if (!stillIsland || gsel.$2 >= imagesLen || selectionMoved) {
        _setGridImageSelection(null);
      }
    }

    _syncHandlesAndContextBar();
  }

  // -----------------------------------------------------------------
  // 移动端选区手柄 + 上下文动作条(S3/S4 桥接)
  // -----------------------------------------------------------------

  SelectionHandlesController? _handles;
  CollapsedHandleController? _collapsedHandle;
  EditorContextBar? _contextBar;

  /// 手柄拖动进行中(高频选区变化不逐帧重喂 IME;controller → state 的
  /// 反向回写只在此期间开启)。collapsed 单手柄拖动同样复用此门。
  bool _handleDragging = false;

  /// 手柄拖动:_controller(DocumentSelection)→ EditorState 回写。
  /// 平时是 state → controller 单向镜像(_afterFrame),环由 == 短路。
  void _onSelectionControllerChanged() {
    if (!_handleDragging) return;
    final sel = _controller.selection;
    if (sel == null) return;
    final base = _toEditorPosition(sel.base);
    final extent = _toEditorPosition(sel.extent);
    if (base == null || extent == null) return;
    widget.state.updateSelection(EditorSelection(base: base, extent: extent));
  }

  /// 帧后统一收敛手柄/动作条显隐(唯一真源:state.selection + 触摸来源)。
  void _syncHandlesAndContextBar() {
    final sel = widget.state.selection;
    final touchReady = _touchSelection && _focusNode.hasPrimaryFocus;
    final showRange =
        touchReady &&
        sel != null &&
        !sel.isCollapsed &&
        _lastImageAtomSel == null && // 图原子选中走宿主工具条
        _controller.selection != null; // 文档几何可得(失焦已清)
    if (showRange) {
      (_handles ??= SelectionHandlesController(
        context: context,
        controller: _controller,
        onDragStart: () {
          _handleDragging = true;
          _contextBar?.hide();
        },
        onDragMove: _onRangeHandleDragMoved,
        onDragEnd: _onHandleDragFinished,
      )).show();
      if (!_handleDragging && !_longPressing) {
        _showContextBarForSelection();
      }
    } else {
      _handles?.hide();
      _contextBar?.hide();
    }

    // collapsed 单手柄:触摸落光标后可拖动微调(Android 系统同款;
    // iOS 无此形态 —— 系统绘制即空盒,platformHasHandle 挡掉)。
    final caretLocal = _caretInfo.value.$1;
    final rootBox = _rootKey.currentContext?.findRenderObject();
    final showCollapsed =
        !showRange &&
        touchReady &&
        sel != null &&
        sel.isCollapsed &&
        caretLocal != null &&
        rootBox is RenderBox &&
        rootBox.attached &&
        CollapsedHandleController.platformHasHandle(context);
    if (showCollapsed) {
      final caretGlobal =
          rootBox.localToGlobal(caretLocal.topLeft) & caretLocal.size;
      // 长按落光标那次:配「粘贴 | 全选」动作条(拖手柄中不显示)
      if (_wantCollapsedBar && !_handleDragging) {
        _showCollapsedContextBar(caretGlobal);
      }
      (_collapsedHandle ??= CollapsedHandleController(
        context: context,
        tapRegionGroupId: _controller,
        onDragStart: () {
          _handleDragging = true; // IME 三门复用(拖动高频变化 end 时统一喂)
          _wantCollapsedBar = false;
          _contextBar?.hide();
          widget.state.sealHistory();
        },
        onDragMove: _onCollapsedHandleDragMoved,
        onDragEnd: _onHandleDragFinished,
      )).show(caretGlobal);
    } else {
      _collapsedHandle?.hide();
    }
  }

  /// 双手柄拖拽点移动:记录拖拽点 + 驱动边缘自动滚(选区更新由
  /// SelectionHandlesController 内部完成)。
  void _onRangeHandleDragMoved(Offset dragGlobal) {
    _handleDragPoint = dragGlobal;
    _updateAutoScroll(dragGlobal);
  }

  /// collapsed 手柄拖拽点移动:半行上移命中行中心 → 移光标 + 放大镜 +
  /// 边缘自动滚(与双手柄/长按同口径)。
  void _onCollapsedHandleDragMoved(Offset dragGlobal) {
    _handleDragPoint = dragGlobal;
    final docPos = _hitTester.positionAt(
      dragGlobal - Offset(0, _caretLineHeight / 2),
      hitTestRoot: _rootKey.currentContext?.findRenderObject(),
    );
    if (docPos != null) {
      final editorPos = _toEditorPosition(docPos);
      if (editorPos != null && editorPos != widget.state.selection?.extent) {
        _caretAffinity = docPos.affinity;
        _verticalGoalX = null;
        widget.state.updateSelection(EditorSelection.collapsed(editorPos));
        HapticFeedback.selectionClick();
      }
      // 放大镜:X 跟拖拽点、Y 锁光标行(长按/双手柄同口径)
      final caret = _hitTester.editingCaretRectAt(
        docPos,
        lineHeight: _caretLineHeight,
      );
      if (caret != null) {
        _showEditorMagnifier(
          gestureGlobal: dragGlobal,
          caret: caret,
          docPos: docPos,
        );
      }
    }
    _updateAutoScroll(dragGlobal);
  }

  /// 放大镜四字段喂给(SDK MagnifierInfo 口径,SelectionHandles 同款):
  /// fieldBounds = 编辑器根;lineBoundaries = caret 行横向扩到段落宽。
  void _showEditorMagnifier({
    required Offset gestureGlobal,
    required Rect caret,
    DocumentPosition? docPos,
  }) {
    Rect fieldBounds = caret;
    final rootBox = _rootKey.currentContext?.findRenderObject();
    if (rootBox is RenderBox && rootBox.attached && rootBox.hasSize) {
      final tl = rootBox.localToGlobal(Offset.zero);
      if (tl.dx.isFinite && tl.dy.isFinite) fieldBounds = tl & rootBox.size;
    }
    Rect lineBoundaries = Rect.fromLTRB(
      fieldBounds.left,
      caret.top,
      fieldBounds.right,
      caret.bottom,
    );
    final paragraph = docPos == null
        ? null
        : _controller.registry.byId(docPos.blockId)?.paragraph;
    if (paragraph != null && paragraph.attached && paragraph.hasSize) {
      final tl = paragraph.localToGlobal(Offset.zero);
      if (tl.dx.isFinite && tl.dy.isFinite) {
        lineBoundaries = Rect.fromLTRB(
          tl.dx,
          caret.top,
          tl.dx + paragraph.size.width,
          caret.bottom,
        );
      }
    }
    (_magnifier ??= SelectionMagnifier(context)).show(
      gestureGlobal: gestureGlobal,
      caretRect: caret,
      currentLineBoundaries: lineBoundaries,
      fieldBounds: fieldBounds,
    );
  }

  /// 手柄(双/单)拖动结束的统一收尾。
  void _onHandleDragFinished() {
    _handleDragging = false;
    _handleDragPoint = null;
    _stopAutoScroll();
    _magnifier?.hide();
    _ime.syncFromState(show: false);
    // 双手柄:按新选区重新定位显示动作条;collapsed 无区间几何,内部早退。
    _showContextBarForSelection();
  }

  // -----------------------------------------------------------------
  // iOS 浮动光标(长按空格 trackpad 模式)
  // -----------------------------------------------------------------

  /// 浮动光标进行中(IME 门之一:平台在拖光标,选区高频变化,End 时
  /// 统一回喂;期间 setEditingState 会打断系统手势)。
  bool _floatingCursor = false;

  /// Start 时的光标中心(全局;Update 的 offset 以此为基准累加)。
  Offset? _floatingBase;
  Offset _floatingPos = Offset.zero;
  OverlayEntry? _floatingGhost;

  /// 扩选模式的固定端(虚拟指针 extend;null = collapsed 移动)。
  EditorPosition? _floatingExtendBase;

  void _onFloatingCursor(RawFloatingCursorPoint point) {
    if (!mounted) return;
    switch (point.state) {
      case FloatingCursorDragState.Start:
        _floatingStart(initialOffset: point.offset ?? Offset.zero);
      case FloatingCursorDragState.Update:
        _floatingUpdate(point.offset ?? Offset.zero);
      case FloatingCursorDragState.End:
        _floatingEnd();
    }
  }

  /// 浮动/虚拟指针起步(基准 = 当前光标中心)。[extend] = 扩选模式
  /// (base 固定,幽灵驱动 extent;IME 路径恒 false)。
  /// 返回 false = 无光标可起步(未聚焦/岛上无文本光标)。
  bool _floatingStart({
    Offset initialOffset = Offset.zero,
    bool extend = false,
  }) {
    var sel = widget.state.selection;
    // 可视区(键盘裁剪后;无滚动宿主退编辑器根矩形)
    var vp = _visibleViewportRect();
    if (vp == null) {
      final rootBox = _rootKey.currentContext?.findRenderObject();
      if (rootBox is RenderBox && rootBox.attached && rootBox.hasSize) {
        vp = rootBox.localToGlobal(Offset.zero) & rootBox.size;
      }
    }

    // 视口中心命中一个文档位并落光标(虚拟指针"随时可拖"的起步锚:
    // 无光标、或光标在屏外时,都从看得见的地方开始 —— 否则幽灵生成
    // 在视口外,Update 钳回边缘还会触发边缘自动滚狂滚)。
    bool anchorAtViewportCenter() {
      final v = vp;
      if (v == null || v.isEmpty) return false;
      final docPos = _hitTester.positionAt(
        v.center,
        hitTestRoot: _rootKey.currentContext?.findRenderObject(),
      );
      if (docPos == null) return false;
      final pos = _toEditorPosition(docPos);
      if (pos == null) return false;
      _caretAffinity = docPos.affinity;
      widget.state.updateSelection(EditorSelection.collapsed(pos));
      return true;
    }

    if (sel == null) {
      if (!anchorAtViewportCenter()) return false;
      sel = widget.state.selection;
      if (sel == null) return false;
    }
    if (!extend && !sel.isCollapsed) return false;
    var docPos = _toDocumentPosition(sel.extent, affinity: _caretAffinity);
    var rect = docPos == null
        ? null
        : _hitTester.editingCaretRectAt(docPos, lineHeight: _caretLineHeight);
    if (rect == null) return false;
    // 光标在视口外(如上次编辑位已滚走):改从视口中心起步
    if (!extend && vp != null && !vp.isEmpty && !vp.contains(rect.center)) {
      if (anchorAtViewportCenter()) {
        sel = widget.state.selection;
        docPos = sel == null
            ? null
            : _toDocumentPosition(sel.extent, affinity: _caretAffinity);
        final r2 = docPos == null
            ? null
            : _hitTester.editingCaretRectAt(
                docPos,
                lineHeight: _caretLineHeight,
              );
        if (r2 != null) rect = r2;
      }
    }
    if (sel == null) return false;
    _floatingCursor = true;
    _floatingExtendBase = extend ? sel.base : null;
    _floatingBase = rect.center;
    _floatingPos = rect.center + initialOffset;
    widget.state.sealHistory();
    _collapsedHandle?.hide();
    _contextBar?.hide();
    _showFloatingGhost();
    setState(() {}); // 实光标切灰色残影态
    return true;
  }

  /// 浮动位置更新([accumulated] = 相对起步点的累计位移)。
  void _floatingUpdate(Offset accumulated) {
    final base = _floatingBase;
    if (!_floatingCursor || base == null) return;
    var pos = base + accumulated;
    // 钳到可视视口内(编辑区上缘/键盘上缘;半行余量让幽灵整条可见)。
    // 无滚动宿主(demo/测试)退回编辑器根矩形。
    var vp = _visibleViewportRect();
    if (vp == null) {
      final rootBox = _rootKey.currentContext?.findRenderObject();
      if (rootBox is RenderBox && rootBox.attached && rootBox.hasSize) {
        vp = rootBox.localToGlobal(Offset.zero) & rootBox.size;
      }
    }
    if (vp != null && !vp.isEmpty) {
      final half = _caretLineHeight / 2;
      // x 留幽灵条半宽(1.25),整条不出界
      pos = Offset(
        pos.dx.clamp(vp.left + 1.25, vp.right - 1.25),
        pos.dy.clamp(vp.top + half, vp.bottom - half),
      );
    }
    _floatingPos = pos;
    _floatingGhost?.markNeedsBuild();
    // 实光标就近吸附(EditableText 的灰色残影等价物:吸附位即落点)
    _applyFloatingHit(pos);
    // 贴视口上下缘 → 边缘自动滚(键盘态可视区小,长文档必需;
    // tick 每帧滚动后按幽灵位置重命中,吸附点随内容继续走)
    _updateAutoScroll(pos);
  }

  void _floatingEnd() {
    if (!_floatingCursor) return;
    _floatingCursor = false;
    _floatingBase = null;
    _floatingExtendBase = null;
    _stopAutoScroll();
    _removeFloatingGhost();
    // 拖完把焦点还给编辑器:落点即编辑位,实光标立即可见(失焦态
    // 光标不渲染),键盘按平台惯例自然弹出。
    if (!_focusNode.hasPrimaryFocus) _focusNode.requestFocus();
    _ime.syncFromState(show: false);
    setState(() {}); // 实光标恢复主题色
  }

  /// 浮动点 → 实光标吸附(Update 与自动滚 tick 共用;无半行补偿 ——
  /// 浮动点即文本行内坐标,与手柄"手指在行下方"不同)。
  void _applyFloatingHit(Offset pos) {
    final docPos = _hitTester.positionAt(
      pos,
      hitTestRoot: _rootKey.currentContext?.findRenderObject(),
    );
    if (docPos == null) return;
    final editorPos = _toEditorPosition(docPos);
    if (editorPos != null && editorPos != widget.state.selection?.extent) {
      _caretAffinity = docPos.affinity;
      _verticalGoalX = null;
      final extendBase = _floatingExtendBase;
      widget.state.updateSelection(
        extendBase == null
            ? EditorSelection.collapsed(editorPos)
            : EditorSelection(base: extendBase, extent: editorPos),
      );
    }
  }

  /// 浮动幽灵光标:主题色圆角条 + 轻阴影,Overlay 顶层跟手平滑移动
  /// (实光标按字符格吸附,幽灵负责"浮动"体感)。
  void _showFloatingGhost() {
    if (_floatingGhost != null) {
      _floatingGhost!.markNeedsBuild();
      return;
    }
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    _floatingGhost = OverlayEntry(
      builder: (ctx) {
        final overlayBox =
            Overlay.of(context).context.findRenderObject() as RenderBox?;
        final local = overlayBox == null
            ? _floatingPos
            : overlayBox.globalToLocal(_floatingPos);
        return Positioned(
          left: local.dx - 1.25,
          top: local.dy - _caretLineHeight / 2,
          child: IgnorePointer(
            child: Container(
              key: kFloatingCursorGhostKey,
              width: 2.5,
              height: _caretLineHeight,
              decoration: BoxDecoration(
                color: Theme.of(ctx).colorScheme.primary,
                borderRadius: BorderRadius.circular(1.25),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black26,
                    blurRadius: 3,
                    offset: Offset(0, 1),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    overlay.insert(_floatingGhost!);
  }

  void _removeFloatingGhost() {
    _floatingGhost?.remove();
    _floatingGhost = null;
  }

  /// 按当前选区几何弹动作条(复制/剪切/粘贴/全选)。
  void _showContextBarForSelection() {
    final docSel = _controller.selection;
    if (docSel == null) return;
    final data = SelectionExporter(_controller.registry).export(docSel);
    if (data == null || data.globalRects.isEmpty) return;
    (_contextBar ??= EditorContextBar(
      context: context,
      tapRegionGroupId: _controller,
    )).show(
      selectionBounds: data.globalBounds,
      items: [
        ContextMenuButtonItem(
          type: ContextMenuButtonType.copy,
          onPressed: () {
            _clipboardCopy();
            _dismissTouchSelection();
          },
        ),
        ContextMenuButtonItem(
          type: ContextMenuButtonType.cut,
          onPressed: () {
            _clipboardCut();
            _dismissTouchSelection();
          },
        ),
        ContextMenuButtonItem(
          type: ContextMenuButtonType.paste,
          onPressed: () {
            _clipboardPaste();
            _dismissTouchSelection();
          },
        ),
        ContextMenuButtonItem(
          type: ContextMenuButtonType.selectAll,
          onPressed: () {
            widget.state.selectAll();
            // 全选后保持触摸态,手柄/动作条按新选区重弹
          },
        ),
      ],
    );
  }

  /// collapsed 光标(无选区)的动作条:仅「粘贴 | 全选」,锚光标矩形。
  void _showCollapsedContextBar(Rect caretGlobal) {
    (_contextBar ??= EditorContextBar(
      context: context,
      tapRegionGroupId: _controller,
    )).show(
      selectionBounds: caretGlobal,
      items: [
        ContextMenuButtonItem(
          type: ContextMenuButtonType.paste,
          onPressed: () {
            _clipboardPaste();
            _dismissTouchSelection();
          },
        ),
        ContextMenuButtonItem(
          type: ContextMenuButtonType.selectAll,
          onPressed: () {
            widget.state.selectAll();
            _wantCollapsedBar = false;
          },
        ),
      ],
    );
  }

  /// 动作执行后收触摸选区 UI(复制后折叠选区 = 移动惯例)。
  void _dismissTouchSelection() {
    _touchSelection = false;
    _wantCollapsedBar = false;
    _contextBar?.hide();
    _handles?.hide();
    _collapsedHandle?.hide();
  }

  /// 滚动跟随:编辑器在宿主滚动容器内,纯滚动不触发 _onStateChanged →
  /// 帧后矩形(caret/图片选中)不重算 → 浮层脱锚。挂最近 Scrollable 的
  /// position listener,滚动时帧后重报(仅有上报对象时,listener 早退)。
  ScrollPosition? _scrollPosition;

  bool _scrollRecomputeQueued = false;
  double _lastScrollPixels = 0;

  void _onScrolled() {
    // 手柄/动作条滚动跟随:算本帧 delta 做滞后补偿(阅读端同款消抖)
    final pixels = _scrollPosition?.pixels ?? 0;
    final delta = pixels - _lastScrollPixels;
    _lastScrollPixels = pixels;
    if (_handles?.isShowing ?? false) {
      _handles!.update(yCompensation: delta);
      _contextBar?.reposition(yCompensation: delta);
    }
    if (_collapsedHandle?.isShowing ?? false) {
      _collapsedHandle!.translate(delta);
    }
    if (_lastImageAtomSel == null && _caretInfo.value.$1 == null) return;
    // coalesce:滚动一帧内 position listener 可触发多次,每次都排
    // postFrame 会让 _afterFrame(getBoxesForSelection + 事件比对)一帧
    // 跑 N 遍 —— 拖选/惯性滚动时白耗 CPU。
    if (_scrollRecomputeQueued) return;
    _scrollRecomputeQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollRecomputeQueued = false;
      if (mounted) _afterFrame();
    });
  }

  void _bindScrollPosition() {
    final next = Scrollable.maybeOf(context)?.position;
    if (identical(next, _scrollPosition)) return;
    _scrollPosition?.removeListener(_onScrolled);
    _scrollPosition = next;
    _lastScrollPixels = next?.pixels ?? 0;
    _scrollPosition?.addListener(_onScrolled);
  }

  // -----------------------------------------------------------------
  // 软键盘 ensureVisible(S5)
  // -----------------------------------------------------------------

  /// 上次 ensure 的 (docRevision, selection) —— 同 key 不重滚(纯滚动帧
  /// 不产生新 key,无"用户滚走又被拉回"的反馈环)。
  (int, EditorSelection?)? _lastEnsuredKey;

  /// 记录的键盘 inset —— 键盘弹出动画期间变化,清 key 让光标跟着键盘
  /// 上沿浮起。
  double _lastViewInsetBottom = 0;

  /// 光标越出可见区(视口 ∩ 键盘上方)时滚动到可见。仅折叠光标态
  /// (打字/点击);非折叠选区(手柄态)不自动滚 —— 用户在看选区。
  ///
  /// 不用 Scrollable.ensureVisible:它按**整个 RenderObject**(编辑器是
  /// 一整块巨型 child)对齐,会瞬移到块顶。position.animateTo 按光标
  /// 矩形精确滚(宿主 markdown_editor 同构做法)。
  void _ensureCaretVisible(Rect caretGlobal) {
    final pos = _scrollPosition;
    if (pos == null || !pos.hasContentDimensions) return;
    // 手柄拖动/浮动光标中光标由手指驱动,滚动交给边缘自动滚 —— ensure
    // 的 animateTo 会与 tick 的 jumpTo(或幽灵跟手)抢滚动位置(来回抖)。
    if (_handleDragging || _floatingCursor) return;
    final sel = widget.state.selection;
    if (sel == null || !sel.isCollapsed) return;
    final key = (widget.state.docRevision, sel);
    if (key == _lastEnsuredKey) return;
    _lastEnsuredKey = key;

    final visible = _visibleViewportRect();
    if (visible == null) return;
    const pad = 24.0;
    final visBottom = visible.bottom - pad;
    final visTop = visible.top + pad;
    if (visBottom <= visTop) return;

    double? delta;
    if (caretGlobal.bottom > visBottom) {
      delta = caretGlobal.bottom - visBottom;
    } else if (caretGlobal.top < visTop) {
      delta = caretGlobal.top - visTop;
    }
    if (delta == null) return;
    final target = (pos.pixels + delta).clamp(
      pos.minScrollExtent,
      pos.maxScrollExtent,
    );
    if ((target - pos.pixels).abs() < 1) return;
    pos.animateTo(
      target,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
    );
  }

  /// 宿主滚动视口的全局矩形(键盘遮挡部分已截掉)。
  Rect? _visibleViewportRect() {
    final scrollableCtx = Scrollable.maybeOf(context)?.context;
    final vpBox = scrollableCtx?.findRenderObject();
    if (vpBox is! RenderBox || !vpBox.attached || !vpBox.hasSize) return null;
    final vpRect = vpBox.localToGlobal(Offset.zero) & vpBox.size;
    final mq = MediaQuery.maybeOf(context);
    final screenH = mq?.size.height ?? vpRect.bottom;
    final kbTop = screenH - (mq?.viewInsets.bottom ?? 0);
    final bottom = vpRect.bottom < kbTop ? vpRect.bottom : kbTop;
    if (bottom <= vpRect.top) return null;
    return Rect.fromLTRB(vpRect.left, vpRect.top, vpRect.right, bottom);
  }

  // -----------------------------------------------------------------
  // 手柄拖动边缘自动滚
  // -----------------------------------------------------------------

  /// 拖拽点距可视区上/下沿多近开始自动滚。
  static const double _kAutoScrollEdge = 56.0;

  /// 每帧最大滚动步长(px,≈900px/s@60fps;越贴边越快,线性)。
  static const double _kAutoScrollMaxStep = 15.0;

  /// 手柄拖拽点(双手柄/collapsed 共用,全局坐标):自动滚每帧滚动后
  /// 按它重新命中,让被拖端随内容滚动继续走。
  Offset? _handleDragPoint;

  Ticker? _autoScrollTicker;
  double _autoScrollStep = 0;

  void _updateAutoScroll(Offset dragGlobal) {
    final visible = _visibleViewportRect();
    if (_scrollPosition == null || visible == null) {
      _stopAutoScroll();
      return;
    }
    final topDist = dragGlobal.dy - visible.top;
    final bottomDist = visible.bottom - dragGlobal.dy;
    double step = 0;
    if (topDist < _kAutoScrollEdge) {
      step =
          -_kAutoScrollMaxStep *
          (1 - topDist / _kAutoScrollEdge).clamp(0.0, 1.0);
    } else if (bottomDist < _kAutoScrollEdge) {
      step =
          _kAutoScrollMaxStep *
          (1 - bottomDist / _kAutoScrollEdge).clamp(0.0, 1.0);
    }
    _autoScrollStep = step;
    if (step != 0) {
      final ticker = _autoScrollTicker ??= createTicker(_onAutoScrollTick);
      if (!ticker.isActive) ticker.start();
    } else {
      _autoScrollTicker?.stop();
    }
  }

  void _onAutoScrollTick(Duration _) {
    final pos = _scrollPosition;
    // 拖拽点:手柄用 pan 上报的 _handleDragPoint,浮动光标用幽灵位置。
    final drag = _floatingCursor ? _floatingPos : _handleDragPoint;
    final dragging = _handleDragging || _floatingCursor;
    if (pos == null || drag == null || _autoScrollStep == 0 || !dragging) {
      _stopAutoScroll();
      return;
    }
    final target = (pos.pixels + _autoScrollStep).clamp(
      pos.minScrollExtent,
      pos.maxScrollExtent,
    );
    if (target == pos.pixels) {
      // 滚到头:停表等待反向拖动(方向反转会有新的 pan update 重启)
      _autoScrollTicker?.stop();
      return;
    }
    pos.jumpTo(target);
    // 拖拽点全局没动、内容滚过去了 → 用当前拖拽点重新命中,让被拖端
    // (或 collapsed 光标/浮动吸附点)随滚动继续走;否则只滚屏不扩选。
    if (_floatingCursor) {
      _applyFloatingHit(drag);
    } else if (_handles?.isShowing ?? false) {
      _handles!.reapplyDrag();
    } else if (_collapsedHandle?.isShowing ?? false) {
      _onCollapsedHandleDragMoved(drag);
    }
  }

  void _stopAutoScroll() {
    _autoScrollStep = 0;
    _autoScrollTicker?.stop();
  }

  IslandSelection? _lastIslandSel;

  /// 当前恰好整选的单岛(选区 = 岛 0..1)→ 岛块 + 全局矩形;其余 null。
  IslandSelection? _computeIslandSelection() {
    final norm = widget.state.normalizedSelection();
    if (norm == null || !_focusNode.hasPrimaryFocus) return null;
    final (from, to) = norm;
    if (from.blockId != to.blockId) return null;
    if (from.offset != 0 || to.offset != 1) return null;
    final idx = widget.state.indexOfBlock(from.blockId);
    if (idx < 0) return null;
    final block = widget.state.blocks[idx];
    if (block is! IslandBlock) return null;
    final box = _islandKeys[block.id]?.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    final tl = box.localToGlobal(Offset.zero);
    if (!tl.dx.isFinite || !tl.dy.isFinite) return null;
    return IslandSelection(island: block, globalRect: tl & box.size);
  }

  /// 岛是否处于「整选」态(选区恰覆盖该岛 0..1)。
  bool _isIslandSelected(String islandId) {
    final norm = widget.state.normalizedSelection();
    if (norm == null) return false;
    final (from, to) = norm;
    final fi = widget.state.indexOfBlock(from.blockId);
    final ti = widget.state.indexOfBlock(to.blockId);
    final ii = widget.state.indexOfBlock(islandId);
    if (fi < 0 || ti < 0 || ii < 0) return false;
    // 岛在选区块区间内;端点在岛上时按四象限(0=含,1=起于岛后)
    if (ii < fi || ii > ti) return false;
    if (ii == fi && from.blockId == islandId && from.offset >= 1) return false;
    if (ii == ti && to.blockId == islandId && to.offset <= 0) return false;
    return true;
  }

  // -----------------------------------------------------------------
  // 坐标桥接
  // -----------------------------------------------------------------

  SelectableBlockId _renderIdOf(int index) => SelectableBlockId(index);

  DocumentPosition? _toDocumentPosition(
    EditorPosition pos, {
    TextAffinity affinity = TextAffinity.downstream,
  }) {
    final index = widget.state.indexOfBlock(pos.blockId);
    if (index < 0) return null;
    // 岛不注册 RenderParagraph → 无 DocumentPosition(高亮/caret 均由
    // EditorIsland 自绘选中态,不走选区几何)。
    if (widget.state.blocks[index] is IslandBlock) return null;
    final id = _renderIdOf(index);
    final proj = _controller.registry.logicalById(id)?.projection;
    final renderOffset = proj?.renderOffsetForContent(pos.offset) ?? pos.offset;
    return DocumentPosition(
      blockId: id,
      renderOffset: renderOffset,
      affinity: affinity,
    );
  }

  /// 跨岛选区的高亮镜像:端点在岛上时收缩到岛外邻文本块(文本部分高亮,
  /// 岛的选中态由 EditorIsland 自绘)。
  DocumentSelection? _toDocumentSelection(EditorSelection? sel) {
    if (sel == null || sel.isCollapsed) return null;
    final norm = widget.state.normalizedSelection();
    if (norm == null) return null;
    var (from, to) = norm;

    final blocks = widget.state.blocks;
    var fi = widget.state.indexOfBlock(from.blockId);
    var ti = widget.state.indexOfBlock(to.blockId);
    if (fi < 0 || ti < 0) return null;

    // from 端在岛上 → 前进到下一个文本块头
    while (fi <= ti && blocks[fi] is IslandBlock) {
      fi++;
      if (fi > ti) return null; // 纯岛选区:无文本高亮
      from = EditorPosition(blockId: blocks[fi].id, offset: 0);
    }
    // to 端在岛上 → 回退到上一个文本块尾
    while (ti >= fi && blocks[ti] is IslandBlock) {
      ti--;
      if (ti < fi) return null;
      to = EditorPosition(
        blockId: blocks[ti].id,
        offset: blocks[ti].selectionLength,
      );
    }

    final base = _toDocumentPosition(from);
    final extent = _toDocumentPosition(to);
    if (base == null || extent == null) return null;
    return DocumentSelection(base: base, extent: extent);
  }

  EditorPosition? _toEditorPosition(DocumentPosition pos) {
    final index = pos.blockId.docOrder;
    final blocks = widget.state.blocks;
    if (index < 0 || index >= blocks.length) return null;
    final proj = _controller.registry.logicalById(pos.blockId)?.projection;
    final offset =
        proj?.contentOffsetForRender(pos.renderOffset) ?? pos.renderOffset;
    return EditorPosition(blockId: blocks[index].id, offset: offset);
  }

  /// 编辑光标固定行高:按**光标所在块的有效样式**取 preferredLineHeight
  /// (heading 块光标更高)。缓存键 = (baseStyle, kind, level)。
  double _caretLineHeight = 16;
  (TextStyle, TextBlockKind, int)? _caretHeightKey;

  void _ensureCaretLineHeight(TextStyle base) {
    final sel = widget.state.selection;
    final block = sel == null
        ? null
        : widget.state.textBlockById(sel.extent.blockId);
    final kind = block?.kind ?? TextBlockKind.paragraph;
    final level = block?.headingLevel ?? 1;
    final key = (base, kind, level);
    if (_caretHeightKey == key) return;
    _caretHeightKey = key;
    final style = kind == TextBlockKind.heading
        ? headingStyleFor(base, level)
        : base;
    final painter = TextPainter(
      text: TextSpan(text: ' ', style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    _caretLineHeight = painter.preferredLineHeight;
    painter.dispose();
  }

  /// 光标位置的软换行归属侧:点击时取命中结果的 affinity(点第一行行末
  /// 就显示在行末,而不是跳到第二行行首);键盘移动/编辑后重置 downstream。
  TextAffinity _caretAffinity = TextAffinity.downstream;

  Rect? _computeLocalCaretRect() {
    final sel = widget.state.selection;
    // hasPrimaryFocus:焦点在表格 cell 等子输入框时编辑器光标必须消失
    // (否则与 TextField 自己的光标形成双光标)。浮动/虚拟指针进行中
    // 例外 —— 失焦也要能看到吸附残影(工具栏滑钮随时可拖)。
    if (sel == null ||
        !sel.isCollapsed ||
        (!_focusNode.hasPrimaryFocus && !_floatingCursor)) {
      return null;
    }
    final docPos = _toDocumentPosition(sel.extent, affinity: _caretAffinity);
    if (docPos == null) return null;
    final globalRect = _hitTester.editingCaretRectAt(
      docPos,
      lineHeight: _caretLineHeight,
    );
    if (globalRect == null) return null;
    final rootBox = _rootKey.currentContext?.findRenderObject();
    if (rootBox is! RenderBox || !rootBox.attached) return null;
    final topLeft = rootBox.globalToLocal(globalRect.topLeft);
    return topLeft & globalRect.size;
  }

  LinkCaretInfo? _lastLinkCaret;

  /// collapsed 光标 ↔ 链接 mark 的进出检测(帧后;变化才通知)。
  /// 手势进行中(长按/拖手柄/浮动)不更新 —— end 后帧收敛时补。
  void _notifyLinkCaret() {
    final cb = widget.onLinkCaret;
    if (cb == null) return;
    LinkCaretInfo? info;
    final sel = widget.state.selection;
    if (sel != null &&
        sel.isCollapsed &&
        _focusNode.hasPrimaryFocus &&
        !_longPressing &&
        !_handleDragging &&
        !_floatingCursor) {
      final block = widget.state.textBlockById(sel.extent.blockId);
      final range = block?.content.linkRangeAt(sel.extent.offset);
      if (block != null && range != null) {
        final (start, end, href) = range;
        final rect = _linkRangeGlobalRect(sel.extent.blockId, start, end);
        if (rect != null) {
          info = LinkCaretInfo(
            blockId: sel.extent.blockId,
            start: start,
            end: end,
            href: href,
            text: block.content.text.substring(start, end),
            rangeGlobal: rect,
          );
        }
      }
    }
    if (info != _lastLinkCaret) {
      _lastLinkCaret = info;
      cb(info);
    }
  }

  /// 链接区间(编辑偏移)的全局包围矩形:首尾光标矩形并集(单行即
  /// 精确;跨软换行取包围盒,工具条锚定够用)。
  Rect? _linkRangeGlobalRect(String blockId, int start, int end) {
    final from = _toDocumentPosition(
      EditorPosition(blockId: blockId, offset: start),
    );
    final to = _toDocumentPosition(
      EditorPosition(blockId: blockId, offset: end),
      affinity: TextAffinity.upstream,
    );
    if (from == null || to == null) return null;
    final a = _hitTester.editingCaretRectAt(from, lineHeight: _caretLineHeight);
    final b = _hitTester.editingCaretRectAt(to, lineHeight: _caretLineHeight);
    if (a == null || b == null) return null;
    return a.expandToInclude(b);
  }

  /// macOS AppKit selector 快捷键 → 编辑器命令(键事件路径的镜像;
  /// 两条路径幂等,重复触发无害:selectAll 幂等、剪贴板由 ticket 防重)。
  bool _onImeSelector(String name) {
    switch (name) {
      case 'selectAll:':
        widget.state.selectAll();
        return true;
      case 'copy:':
        _clipboardCopy();
        return true;
      case 'cut:':
        _clipboardCut();
        return true;
      case 'paste:':
        _clipboardPaste();
        return true;
    }
    return false;
  }

  // -----------------------------------------------------------------
  // 剪贴板
  // -----------------------------------------------------------------

  /// 复制:选区 → markdown 写系统剪贴板(跨 app 通用;粘回自身经
  /// markdownImporter 还原富内容)。
  void _clipboardCopy() {
    final md = widget.state.copySelectionAsMarkdown();
    if (md.isEmpty) return;
    Clipboard.setData(ClipboardData(text: md));
  }

  void _clipboardCut() {
    final md = widget.state.copySelectionAsMarkdown();
    if (md.isEmpty) return;
    Clipboard.setData(ClipboardData(text: md));
    widget.state.deleteSelection();
    _ime.syncFromState(show: false);
  }

  /// 粘贴序号:异步 cook 期间用户再按一次 Cmd+V / 继续打字时,旧结果
  /// 作废(防乱序插入)。
  int _pasteTicket = 0;

  /// input rule `--- ` 命中:插分隔线岛。经 markdownImporter(cook)产
  /// HorizontalRuleNode;importer 缺席时无操作(标记文本已被规则清空,
  /// 用户可用插入菜单)。
  Future<void> _insertHorizontalRule(String blockId) async {
    final importer = widget.markdownImporter;
    if (importer == null) return;
    List<EditorBlock>? frag;
    try {
      frag = await importer('---');
    } catch (_) {
      return;
    }
    if (!mounted || frag == null || frag.isEmpty) return;
    // 光标已在触发块(规则清空后 offset 0),粘贴语义插入
    widget.state.pasteBlocks(frag);
    _ime.syncFromState(show: false);
  }

  Future<void> _clipboardPaste() async {
    final ticket = ++_pasteTicket;

    // 富格式优先(text/html 等):宿主读剪贴板+转换,拿到块直接插;
    // 任何一步落空回落纯文本路径(不叠加插入)。
    final rich = widget.richPasteImporter;
    if (rich != null) {
      List<EditorBlock>? frag;
      try {
        frag = await rich();
      } catch (_) {
        frag = null;
      }
      if (!mounted || ticket != _pasteTicket) return;
      if (frag != null && frag.isNotEmpty) {
        widget.state.pasteBlocks(frag);
        _ime.syncFromState(show: false);
        return;
      }
    }

    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    if (!mounted || ticket != _pasteTicket) return;

    final importer = widget.markdownImporter;
    List<EditorBlock>? fragment;
    if (importer != null) {
      try {
        fragment = await importer(text);
      } catch (_) {
        fragment = null; // 导入失败降级纯文本
      }
      if (!mounted || ticket != _pasteTicket) return;
    }

    if (fragment != null && fragment.isNotEmpty) {
      widget.state.pasteBlocks(fragment);
    } else {
      widget.state.pastePlainText(text);
    }
    _ime.syncFromState(show: false);
  }

  // -----------------------------------------------------------------
  // 垂直光标移动(上下键)
  // -----------------------------------------------------------------

  /// goal column:连续上下移动时记住起始 x,途经短行不丢列位
  /// (所有编辑器的标准行为)。横向移动/点击/编辑时清空。
  double? _verticalGoalX;

  void _moveCaretVertical(int direction, {required bool extend}) {
    final sel = widget.state.selection;
    if (sel == null) return;
    final docPos = _toDocumentPosition(sel.extent);
    if (docPos == null) return;
    final caret = _hitTester.editingCaretRectAt(
      docPos,
      lineHeight: _caretLineHeight,
    );
    if (caret == null) return;

    final goalX = _verticalGoalX ??= caret.center.dx;
    // 目标点:上一行/下一行的行内(半行高步进;positionAt 有最近块兜底,
    // 文档首尾越界会停在首/末行 —— 此时若位置没变说明到顶/到底)。
    final targetY = direction < 0
        ? caret.top - caret.height / 2
        : caret.bottom + caret.height / 2;
    final hit = _hitTester.positionAt(
      Offset(goalX, targetY),
      hitTestRoot: _rootKey.currentContext?.findRenderObject(),
    );
    if (hit == null) return;
    final next = _toEditorPosition(hit);
    if (next == null) return;

    // 到顶/到底:位置不变 → 跳到段首/文档端点(对齐系统编辑器)。
    if (next == sel.extent) {
      final blocks = widget.state.blocks;
      final idx = widget.state.indexOfBlock(sel.extent.blockId);
      if (idx < 0) return;
      final EditorPosition endpoint = direction < 0
          ? EditorPosition(blockId: blocks.first.id, offset: 0)
          : EditorPosition(
              blockId: blocks.last.id,
              offset: blocks.last.selectionLength,
            );
      if (endpoint == sel.extent) return;
      widget.state.updateSelection(
        extend
            ? EditorSelection(base: sel.base, extent: endpoint)
            : EditorSelection.collapsed(endpoint),
      );
      _ime.syncFromState(show: false);
      return;
    }

    widget.state.updateSelection(
      extend
          ? EditorSelection(base: sel.base, extent: next)
          : EditorSelection.collapsed(next),
    );
    _ime.syncFromState(show: false);
  }

  // -----------------------------------------------------------------
  // 手势
  // -----------------------------------------------------------------

  /// 命中 → 编辑位置;顺带带出命中侧 affinity(软换行行末/行首)。
  (EditorPosition, TextAffinity)? _hitAtGlobal(Offset global) {
    final pos = _hitTester.positionAt(
      global,
      hitTestRoot: _rootKey.currentContext?.findRenderObject(),
    );
    if (pos == null) return null;
    final editor = _toEditorPosition(pos);
    if (editor == null) return null;
    return (editor, pos.affinity);
  }

  EditorPosition? _positionAtGlobal(Offset global) => _hitAtGlobal(global)?.$1;

  /// 双击选词的连击检测(D3:不用 DoubleTapGestureRecognizer —— 它会让
  /// 单击等 ~300ms 竞技场,落光标手感变肉;手动记时间/位置判连击)。
  DateTime? _lastTapTime;
  Offset? _lastTapGlobal;

  void _onTapDown(TapDownDetails details) {
    // 点在表格网格等自管交互区:编辑器手势完全让路 —— 抢焦点/设选区/
    // 弹 IME 都不做(否则:选区兜底跳到邻块 + 编辑器光标与 cell
    // TextField 光标并存 = 双光标,焦点还来回闪)。
    if (_hitsSelfManagedRegion(details.globalPosition)) return;
    // 岛区域同样让路(整选由岛自己的 GestureDetector.onTap 负责):
    // onTapDown 在 down+deadline 就 fire、不等竞技场 —— 不让路的话
    // 长按岛时编辑器先把光标落到**邻段**(岛无 RenderParagraph,命中
    // 兜底到最近文本块),岛的 onTap 又不会跟着 fire(长按不是 tap),
    // 光标就错停邻段。单击岛此前没暴露只是因为岛 onTap 随后覆盖了中间态。
    if (_hitsIslandRegion(details.globalPosition)) return;
    _wantCollapsedBar = false; // 新 tap:收 collapsed 粘贴条
    final hit = _hitAtGlobal(details.globalPosition);
    _focusNode.requestFocus();
    if (hit == null) return;

    // 图片原子探测(**先于落光标**,官方 NodeSelection 语义)
    if (_trySelectImageAtomAt(hit.$1, details.globalPosition)) return;

    // 双击选词(触摸类连击;鼠标双击桌面惯例同样适用)
    final now = DateTime.now();
    final isDoubleTap =
        _lastTapTime != null &&
        _lastTapGlobal != null &&
        now.difference(_lastTapTime!) < kDoubleTapTimeout &&
        (details.globalPosition - _lastTapGlobal!).distance < kDoubleTapSlop;
    _lastTapTime = now;
    _lastTapGlobal = details.globalPosition;
    if (isDoubleTap && _selectWordAtGlobal(details.globalPosition)) {
      _touchSelection =
          details.kind == PointerDeviceKind.touch ||
          details.kind == PointerDeviceKind.stylus;
      _ime.syncFromState(show: false);
      return;
    }

    // 触摸落光标 → collapsed 单手柄显示依据(鼠标/触控板点击不出手柄)
    _touchSelection =
        details.kind == PointerDeviceKind.touch ||
        details.kind == PointerDeviceKind.stylus;
    _verticalGoalX = null;
    _caretAffinity = hit.$2;
    widget.state.sealHistory();
    widget.state.navigateSelection(EditorSelection.collapsed(hit.$1));
    _ime.syncFromState();

    // 可编辑原子(date chip)单击 → 请求编辑(对齐官方:chip 是节点,
    // 点击/工具栏弹 modal 改属性)。命中位置左右各探一格:tap 落点在
    // 原子字符两侧边界都算点中它。
    final onAtomTap = widget.onAtomTap;
    if (onAtomTap == null) return;
    final block = widget.state.textBlockById(hit.$1.blockId);
    if (block == null) return;
    for (final off in [hit.$1.offset, hit.$1.offset - 1]) {
      if (off < 0) continue;
      final atom = block.content.atoms[off];
      if (atom is LocalDateRun) {
        onAtomTap(hit.$1.blockId, off, atom);
        return;
      }
    }
  }

  /// [pos] 附近若命中图片原子(渲染盒内)→ 整选/打开,返回 true。
  /// tap 与长按共用(长按图片 = tap 同款 NodeSelection 语义)。
  ///
  /// 命中判定 = tap 点**落在图的渲染盒内**(getBoxesForSelection):
  /// 只按"最近文本位置左右一格"判会把图片行右侧整片空白都当图 ——
  /// 点空白误选图/误开查看器。
  bool _trySelectImageAtomAt(EditorPosition pos, Offset global) {
    final tapBlock = widget.state.textBlockById(pos.blockId);
    if (tapBlock == null) return false;
    for (final off in [pos.offset, pos.offset - 1]) {
      if (off < 0) continue;
      final atom = tapBlock.content.atoms[off];
      if (atom is! ImageRun) continue;
      if (!_tapInsideAtomBox(tapBlock.id, off, global)) continue;
      final already = _imageAtomSelectionAt(tapBlock.id, off) != null;
      if (already) {
        final sel = _lastImageAtomSel;
        if (sel != null) widget.onImageAtomOpenRequest?.call(sel);
      } else {
        widget.state.sealHistory();
        widget.state.updateSelection(
          EditorSelection(
            base: EditorPosition(blockId: tapBlock.id, offset: off),
            extent: EditorPosition(blockId: tapBlock.id, offset: off + 1),
          ),
        );
        _ime.syncFromState(show: false); // 选中图不弹软键盘
      }
      return true;
    }
    return false;
  }

  /// [global] 处按词边界选词。命中失败/空词返回 false。
  bool _selectWordAtGlobal(Offset global) {
    final docPos = _hitTester.positionAt(
      global,
      hitTestRoot: _rootKey.currentContext?.findRenderObject(),
    );
    if (docPos == null) return false;
    final wb = _hitTester.wordBoundaryAt(docPos);
    if (wb == null || wb.start >= wb.end) return false;
    final base = _toEditorPosition(
      DocumentPosition(blockId: docPos.blockId, renderOffset: wb.start),
    );
    final extent = _toEditorPosition(
      DocumentPosition(blockId: docPos.blockId, renderOffset: wb.end),
    );
    if (base == null || extent == null) return false;
    widget.state.sealHistory();
    widget.state.updateSelection(EditorSelection(base: base, extent: extent));
    return true;
  }

  // -----------------------------------------------------------------
  // 长按选词(触摸/触控笔;S2)
  // -----------------------------------------------------------------

  /// 长按进行中(选区高频变化不逐帧重喂 IME,end 统一 sync)。
  bool _longPressing = false;

  /// 本次 collapsed 光标是否该配动作条(仅"长按空白落光标"那次 true;
  /// 普通点击/打字/移动光标一概 false —— 否则每次点击都弹粘贴条)。
  /// 移动端惯例:长按无选中处 → 出「粘贴 | 全选」。
  bool _wantCollapsedBar = false;

  /// 最近一次选区变化来自触摸(长按/双击/拖手柄)→ 手柄显示依据。
  bool _touchSelection = false;

  SelectionMagnifier? _magnifier;

  void _onLongPressStart(LongPressStartDetails details) {
    // 长按序列不参与连击:TapGestureRecognizer 的 onTapDown 在 deadline
    // 后即使输了竞技场也会 fire,已把本次 down 记进 _lastTapTime ——
    // 不清的话长按松手后短时间内 tap 附近会被误判双击选词。
    _lastTapTime = null;
    _lastTapGlobal = null;
    final global = details.globalPosition;
    if (_hitsSelfManagedRegion(global) || _hitsIslandRegion(global)) return;
    final docPos = _hitTester.positionAt(
      global,
      hitTestRoot: _rootKey.currentContext?.findRenderObject(),
    );
    if (docPos == null) return;
    _focusNode.requestFocus();

    // 图片原子:长按 = tap 同款整选(不选词)
    final editorPos = _toEditorPosition(docPos);
    if (editorPos != null && _trySelectImageAtomAt(editorPos, global)) {
      _touchSelection = true;
      return;
    }

    widget.state.sealHistory();
    if (_selectWordAtGlobal(global)) {
      HapticFeedback.selectionClick();
    } else if (editorPos != null) {
      // 空白/空段:落光标(系统长按空白同款)
      widget.state.updateSelection(EditorSelection.collapsed(editorPos));
    }
    _touchSelection = true;
    _longPressing = true;
  }

  void _onLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    if (!_longPressing) return;
    final docPos = _hitTester.positionAt(
      details.globalPosition,
      hitTestRoot: _rootKey.currentContext?.findRenderObject(),
    );
    if (docPos == null) return;
    final extent = _toEditorPosition(docPos);
    final sel = widget.state.selection;
    if (extent == null || sel == null) return;
    // 按住直接拖 = 扩选(字符粒度,base 不动;阅读端长按拖同语义)
    widget.state.updateSelection(
      EditorSelection(base: sel.base, extent: extent),
    );
    // 放大镜跟手
    final caret = _hitTester.editingCaretRectAt(
      docPos,
      lineHeight: _caretLineHeight,
    );
    if (caret != null) {
      _showEditorMagnifier(
        gestureGlobal: details.globalPosition,
        caret: caret,
        docPos: docPos,
      );
    }
  }

  void _onLongPressEnd(LongPressEndDetails details) {
    if (!_longPressing) {
      _magnifier?.hide();
      return;
    }
    _longPressing = false;
    _magnifier?.hide();
    // 长按落在空白/空段(collapsed)→ 松手配「粘贴 | 全选」动作条
    // (长按选词是 range,走 showRange 分支,与此无关)
    final sel = widget.state.selection;
    _wantCollapsedBar = sel != null && sel.isCollapsed;
    _ime.syncFromState(show: false);
    // end 无状态变化不触发 _onStateChanged → 帧后手动收敛一次
    // (动作条在 _longPressing 期间被压着,此刻弹出)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _afterFrame();
    });
  }

  /// [global] 是否落在孤岛区域内(EditorIsland 的 MetaData 标记)。
  /// 长按让路用:岛不注册 RenderParagraph,positionAt 的最近块兜底会把
  /// 岛上的长按吸到**邻段文本**选词 —— 必须在命中前挡掉。
  bool _hitsIslandRegion(Offset global) {
    final rootBox = _rootKey.currentContext?.findRenderObject();
    if (rootBox is! RenderBox || !rootBox.attached) return false;
    final result = BoxHitTestResult();
    rootBox.hitTest(result, position: rootBox.globalToLocal(global));
    for (final entry in result.path) {
      final t = entry.target;
      if (t is RenderMetaData && t.metaData == kEditorIslandRegion) {
        return true;
      }
    }
    return false;
  }

  /// 当前选区是否恰好整选 [blockId] 块 [offset] 处的图片原子。
  /// 是则返回 (blockId, offset),否则 null。
  (String, int)? _imageAtomSelectionAt(String blockId, int offset) {
    final norm = widget.state.normalizedSelection();
    if (norm == null) return null;
    final (from, to) = norm;
    if (from.blockId != blockId || to.blockId != blockId) return null;
    if (from.offset != offset || to.offset != offset + 1) return null;
    return (blockId, offset);
  }

  /// tap 全局坐标是否落在 [blockId] 块 [offset] 原子的渲染盒内。
  /// 横向命中即可(纵向放 4px 容差):FFFC 的 selection box 覆盖整行高,
  /// 图旁小字行的纵向空白仍算图列范围,与直觉一致。
  bool _tapInsideAtomBox(String blockId, int offset, Offset global) {
    final index = widget.state.indexOfBlock(blockId);
    if (index < 0) return false;
    final id = _renderIdOf(index);
    final proj = _controller.registry.logicalById(id)?.projection;
    final p = _controller.registry.byId(id)?.paragraph;
    if (proj == null || p == null || !p.attached) return false;
    final rs = proj.renderOffsetForContent(offset);
    final re = proj.renderOffsetForContent(offset + 1);
    final boxes = p.getBoxesForSelection(
      TextSelection(baseOffset: rs, extentOffset: re),
      boxHeightStyle: ui.BoxHeightStyle.tight,
    );
    final local = p.globalToLocal(global);
    for (final b in boxes) {
      if (b.toRect().inflate(4).contains(local)) return true;
    }
    return false;
  }

  /// 当前文档选区若恰覆盖单个图片原子,返回其选中态(矩形帧后算)。
  ImageAtomSelection? _lastImageAtomSel;

  /// grid 岛内图片子选中(islandId, imageIndex)。与编辑器主选区独立
  /// (点瓦片在自管区内不动主选区);主选区**后续变化**即清(基线快照
  /// 对比 —— 不能用「选区不在岛上」判,点瓦片时主选区本就停在别处)。
  (String, int)? _gridImageSel;
  GridImageSelection? _lastGridImageSel;
  EditorSelection? _gridSelBaseline;

  void _setGridImageSelection(GridImageSelection? sel) {
    _gridImageSel = sel == null ? null : (sel.islandId, sel.imageIndex);
    _gridSelBaseline = sel == null ? null : widget.state.selection;
    if (sel != _lastGridImageSel) {
      _lastGridImageSel = sel;
      widget.onGridImageSelectionChanged?.call(sel);
    }
    if (sel != null) setState(() {}); // 瓦片描边
  }

  /// grid 内瓦片 alt 原位编辑保存:images[index] copyWith(alt) 后
  /// updateIslandNode 原位换。
  void _setGridImageAlt(String islandId, int index, String alt) {
    final i = widget.state.indexOfBlock(islandId);
    if (i < 0) return;
    final block = widget.state.blocks[i];
    if (block is! IslandBlock || block.node is! ImageGridNode) return;
    final grid = block.node as ImageGridNode;
    if (index < 0 || index >= grid.images.length) return;
    final images = [...grid.images];
    images[index] = images[index].copyWith(alt: alt);
    widget.state.updateIslandNode(
      islandId,
      ImageGridNode(
        id: grid.id,
        images: images,
        columns: grid.columns,
        mode: grid.mode,
      ),
    );
  }

  /// grid 内瓦片拖拽排序落地:结构命令重排 + 子选中下标跟随(被拖图
  /// 落位 to;from→to 之间的图让位漂移一格)。
  void _onGridReorder(String islandId, int from, int to) {
    if (!reorderImageInGrid(widget.state, islandId, from, to)) return;
    final sel = _gridImageSel;
    if (sel == null || sel.$1 != islandId) return;
    var s = sel.$2;
    if (s == from) {
      s = to;
    } else if (from < s && s <= to) {
      s -= 1;
    } else if (to <= s && s < from) {
      s += 1;
    }
    if (s != sel.$2) _gridImageSel = (islandId, s);
  }

  ImageAtomSelection? _computeImageAtomSelection() {
    final norm = widget.state.normalizedSelection();
    if (norm == null) return null;
    final (from, to) = norm;
    if (from.blockId != to.blockId) return null;
    if (to.offset != from.offset + 1) return null;
    final block = widget.state.textBlockById(from.blockId);
    if (block == null) return null;
    final atom = block.content.atoms[from.offset];
    if (atom is! ImageRun) return null;

    final index = widget.state.indexOfBlock(from.blockId);
    if (index < 0) return null;
    final id = _renderIdOf(index);
    final proj = _controller.registry.logicalById(id)?.projection;
    final p = _controller.registry.byId(id)?.paragraph;
    if (proj == null || p == null || !p.attached) return null;

    final rs = proj.renderOffsetForContent(from.offset);
    final re = proj.renderOffsetForContent(to.offset);
    final boxes = p.getBoxesForSelection(
      TextSelection(baseOffset: rs, extentOffset: re),
      boxHeightStyle: ui.BoxHeightStyle.tight,
    );
    Rect? rect;
    for (final b in boxes) {
      final tl = p.localToGlobal(Offset(b.left, b.top));
      final br = p.localToGlobal(Offset(b.right, b.bottom));
      if (!tl.dx.isFinite || !br.dx.isFinite) continue;
      final r = Rect.fromPoints(tl, br);
      rect = rect == null ? r : rect.expandToInclude(r);
    }
    if (rect == null) return null;
    return ImageAtomSelection(
      blockId: from.blockId,
      offset: from.offset,
      image: atom,
      globalRect: rect,
    );
  }

  /// [global] 是否落在自管交互区(表格网格)内 —— 命中路径上找
  /// 区域标记 RenderMetaData。
  bool _hitsSelfManagedRegion(Offset global) {
    final rootBox = _rootKey.currentContext?.findRenderObject();
    if (rootBox is! RenderBox || !rootBox.attached) return false;
    final result = BoxHitTestResult();
    rootBox.hitTest(result, position: rootBox.globalToLocal(global));
    for (final entry in result.path) {
      final t = entry.target;
      if (t is RenderMetaData && t.metaData == kEditorSelfManagedRegion) {
        return true;
      }
    }
    return false;
  }

  EditorPosition? _dragBase;

  void _onPanStart(DragStartDetails details) {
    // 自管交互区(表格网格)内不启动编辑器拖选
    if (_hitsSelfManagedRegion(details.globalPosition)) return;
    _touchSelection = false; // 鼠标路径:收触摸选区 UI
    _dragBase = _positionAtGlobal(details.globalPosition);
    _focusNode.requestFocus();
  }

  void _onPanUpdate(DragUpdateDetails details) {
    final base = _dragBase;
    if (base == null) return;
    final extent = _positionAtGlobal(details.globalPosition);
    if (extent == null) return;
    widget.state.updateSelection(EditorSelection(base: base, extent: extent));
  }

  void _onPanEnd(DragEndDetails details) {
    _dragBase = null;
    _ime.syncFromState(show: false);
  }

  // -----------------------------------------------------------------
  // build
  // -----------------------------------------------------------------

  /// 编辑器键盘处理器。命名方法而非闭包:dispose 时需 identical 比对
  /// 后从共享 FocusNode 上摘除(见 dispose 注释)。
  KeyEventResult _editorOnKeyEvent(FocusNode node, KeyEvent event) {
    // 焦点在子树内其他可聚焦组件(表格 cell TextField / 壳内输入)
    // 时**完全让路**:此时 primaryFocus 是那个组件,事件只是沿焦点
    // 链冒泡经过本编辑器 —— 拦截会把退格/方向键/回车吞掉,cell
    // 变成"只能覆盖不能编辑"。
    if (!node.hasPrimaryFocus) return KeyEventResult.ignored;
    // 宿主浮层(斜杠菜单/mention)激活时优先:上下/回车/Esc 归它
    if (widget.keyEventInterceptor?.call(event) ?? false) {
      return KeyEventResult.handled;
    }
    // 非上下键的任何按键动作都终结 goal column 记忆
    if (event is KeyDownEvent &&
        event.logicalKey != LogicalKeyboardKey.arrowUp &&
        event.logicalKey != LogicalKeyboardKey.arrowDown) {
      _verticalGoalX = null;
    }
    // 键盘操作后光标回 downstream(点击行末的 upstream 只对那次点击有效)
    if (event is KeyDownEvent) {
      _caretAffinity = TextAffinity.downstream;
      _touchSelection = false; // 物理键盘操作 → 收触摸选区 UI
    }
    return handleEditorKeyEvent(
      widget.state,
      event,
      onEdited: () => _ime.syncFromState(show: false),
      onMoveVertical: _moveCaretVertical,
      onClipboardCopy: _clipboardCopy,
      onClipboardCut: _clipboardCut,
      onClipboardPaste: _clipboardPaste,
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final baseStyle =
        widget.baseTextStyle ??
        Theme.of(context).textTheme.bodyMedium ??
        const TextStyle(fontSize: 14);
    _ensureCaretLineHeight(baseStyle);

    final composingBlockId = state.hasComposing
        ? state.selection?.extent.blockId
        : null;

    // 有序列表序号(派生渲染态):连续 listItem run 内扫描,run 首项取
    // listStart;ordered/depth 切换重新起算(同 depth 的 ol 连续编号)。
    final ordinals = List<int>.filled(state.blocks.length, 1);
    final counters = <(bool, int), int>{}; // (ordered,depth) → 下一序号
    for (var i = 0; i < state.blocks.length; i++) {
      final b = state.blocks[i];
      if (b is! TextBlock || !b.isListItem) {
        counters.clear();
        continue;
      }
      final key = (b.ordered, b.depth);
      final next = counters[key] ?? b.listStart;
      ordinals[i] = next;
      counters[key] = next + 1;
      // 更浅层计数不清(嵌套子列表结束回到父层继续编号);更深层清零
      counters.removeWhere((k, _) => k.$2 > b.depth);
    }

    /// 单块 → widget(文本段落/岛)。
    ///
    /// 外层 Padding **必须带 key**:顶层/壳内 Column 的 children 是
    /// keyed(壳)与块混合列表,unkeyed 块会被 updateChildren 按位置
    /// 配对 —— 弹层/插块后旧岛 Padding 与新位置段落 Padding 错配,
    /// child 类型不同导致岛整棵 deactivate 重建(真机 hover/滚动态下
    /// 深层 InheritedElement dependents 清理时序炸 _dependents 断言,
    /// 红屏)。全 keyed 后 diff 恒按身份匹配,块只随真实删除而摘除。
    Widget buildBlock(int i) {
      final block = state.blocks[i];
      // 表格岛 + 宿主接了 onTableEdited:cell 级原位编辑网格
      // (不走 EditorIsland 的 AbsorbPointer 只读壳)
      if (block is IslandBlock &&
          block.node is TableNode &&
          widget.onTableEdited != null) {
        return Padding(
          key: ValueKey('blk_${block.id}'),
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: EditorTableGrid(
            key: ValueKey('table_${block.id}'),
            node: block.node as TableNode,
            onChanged: (md) => widget.onTableEdited!(block, md),
            selected: _isIslandSelected(block.id),
            // 左上角选择柄:整选表格块(选中后退格/Delete 删整表)。
            // cell 区自管让路后,这是表格作为"块"的唯一选择入口。
            onSelectRequest: () {
              _focusNode.requestFocus();
              widget.state.sealHistory();
              widget.state.updateSelection(
                EditorSelection(
                  base: EditorPosition(blockId: block.id, offset: 0),
                  extent: EditorPosition(blockId: block.id, offset: 1),
                ),
              );
              _ime.syncFromState(show: false);
            },
          ),
        );
      }
      // 代码块岛 + 宿主接了 onCodeBlockEdited:岛内原位编辑
      // (mermaid 除外 —— 图表块有自己的整块 override 视觉,原位编辑的
      // 展示态会与图表壳冲突,仍走通用岛 + 双击源码)
      if (block is IslandBlock &&
          block.node is CodeBlockNode &&
          (block.node as CodeBlockNode).language != 'mermaid' &&
          widget.onCodeBlockEdited != null) {
        return Padding(
          key: ValueKey('blk_${block.id}'),
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: EditorCodeBlock(
            key: ValueKey('code_${block.id}'),
            node: block.node as CodeBlockNode,
            onChanged: (code, lang) =>
                widget.onCodeBlockEdited!(block, code, lang),
            selected: _isIslandSelected(block.id),
            autoEdit: widget.state.consumeIslandEditRequest(block.id),
            highlightBuilder: _islandFactory.codeBlockHighlighter,
            onSelectRequest: () {
              _focusNode.requestFocus();
              widget.state.sealHistory();
              widget.state.updateSelection(
                EditorSelection(
                  base: EditorPosition(blockId: block.id, offset: 0),
                  extent: EditorPosition(blockId: block.id, offset: 1),
                ),
              );
              _ime.syncFromState(show: false);
            },
          ),
        );
      }
      return Padding(
        key: ValueKey('blk_${state.blocks[i].id}'),
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: switch (state.blocks[i]) {
          // key 绑块 id:分段/合并时 Element 正确复用/重建
          final TextBlock tb => EditableParagraph(
            key: ValueKey(tb.id),
            block: tb,
            documentOrder: i,
            baseStyle: baseStyle,
            composing: tb.id == composingBlockId
                ? state.composing
                : TextRange.empty,
            listMarkerOrdinal: ordinals[i],
            markerRanges: state.markerRangesOf(tb.id),
            // 行内图片原子走岛同一图片管线(upload 解析/解码上限);
            // hover=click(可点选)。注意:builder 产物进 flatten 缓存
            // (content 不变不重跑),不能在闭包里读选中态等易变状态
            // ——不会刷新,还误导性能分析。
            imageContentBuilder: _islandFactory.imageContentBuilder == null
                ? null
                : (ctx, img, total) => MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: _islandFactory.imageContentBuilder!(ctx, img, total),
                  ),
            // emoji 原子同走宿主管线(CDN 重写/缓存池;不接的话编辑
            // 已有帖的相对 URL emoji 全裂成 :name: 占位胶囊)
            emojiImageBuilder: _islandFactory.emojiImageBuilder,
          ),
          // 孤岛:NodeFactory 渲染,tap 整选,双击请求编辑,选中态描边
          final IslandBlock ib => EditorIsland(
            key: _islandKeys.putIfAbsent(ib.id, GlobalKey.new),
            node: ib.node,
            nodeFactory: _islandFactory,
            selected: _isIslandSelected(ib.id),
            onTapSelect: () {
              _focusNode.requestFocus();
              widget.state.sealHistory();
              widget.state.updateSelection(
                EditorSelection(
                  base: EditorPosition(blockId: ib.id, offset: 0),
                  extent: EditorPosition(blockId: ib.id, offset: 1),
                ),
              );
              _ime.syncFromState(show: false);
            },
            onEditRequest: widget.onIslandEditRequest == null
                ? null
                : () => widget.onIslandEditRequest!(ib),
            // 选中态上下缘「加段」把手:岛前/后建空段落光标(首块是
            // 岛/岛在尾时移动端唯一的加段途径;状态层已有同语义命令)
            onInsertParagraph: ({required bool before}) {
              final idx = widget.state.indexOfBlock(ib.id);
              if (idx < 0) return;
              widget.state.insertParagraphNearIsland(ib.id, after: !before);
              _ime.syncFromState();
            },
            // grid 岛内容换官方 composer 内聚交互视图:模式切换/移除
            // 网格/瓦片删除/移出/alt 全内聚(纯结构命令,宿主只管
            // 查看器);瓦片单击子选中
            contentOverride: ib.node is ImageGridNode
                ? EditorImageGrid(
                    node: ib.node as ImageGridNode,
                    islandId: ib.id,
                    nodeFactory: _islandFactory,
                    selectedIndex: (_gridImageSel?.$1 == ib.id)
                        ? _gridImageSel!.$2
                        : null,
                    onImageTap: _setGridImageSelection,
                    onImageOpen: (sel) =>
                        widget.onGridImageOpenRequest?.call(sel),
                    onModeChange: (mode) =>
                        setImageGridMode(widget.state, ib.id, mode),
                    onRemoveGrid: () => removeImageGrid(widget.state, ib.id),
                    onRemoveImage: (index) =>
                        removeImageFromGrid(widget.state, ib.id, index),
                    onMoveImageOut: (index) =>
                        moveImageOutsideGrid(widget.state, ib.id, index),
                    onAltChanged: (index, alt) =>
                        _setGridImageAlt(ib.id, index, alt),
                    onReorder: (from, to) => _onGridReorder(ib.id, from, to),
                  )
                : null,
          ),
        },
      );
    }

    /// 递归分组(M5-B):`[from, to)` 内容器栈深度 [level] 上的分组渲染。
    /// 相邻块 containers[level] 相等 → 同容器实例,包 EditorContainerShell
    /// 后递归下一层;无该层帧 → 直接渲染块本体。
    List<Widget> buildLevel(int from, int to, int level) {
      final out = <Widget>[];
      var i = from;
      while (i < to) {
        final b = state.blocks[i];
        final frames = b is TextBlock ? b.containers : const <ContainerFrame>[];
        if (frames.length > level) {
          final frame = frames[level];
          final runStart = i;
          while (i < to) {
            final c = state.blocks[i];
            final cf = c is TextBlock ? c.containers : const <ContainerFrame>[];
            if (cf.length > level && cf[level] == frame) {
              i++;
            } else {
              break;
            }
          }
          out.add(
            Padding(
              // 容器壳自身与外界的间距(块本体的 vertical 4 在壳内)。
              // key 在 Padding 上(children 列表的直接成员必须 keyed,
              // 见 buildBlock 注释)。
              key: ValueKey('shell_${frame.groupId}_$level'),
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: EditorContainerShell(
                frame: frame,
                onTitleTap:
                    widget.onContainerTitleEdit != null &&
                        (frame is DetailsFrame || frame is CalloutFrame)
                    ? () => widget.onContainerTitleEdit!(frame)
                    : null,
                children: buildLevel(runStart, i, level + 1),
              ),
            ),
          );
          continue;
        }
        out.add(buildBlock(i));
        i++;
      }
      return out;
    }

    final children = buildLevel(0, state.blocks.length, 0);

    return Focus(
      focusNode: _focusNode,
      autofocus: widget.autofocus,
      onKeyEvent: _editorOnKeyEvent,
      child: MouseRegion(
        cursor: SystemMouseCursors.text,
        // RawGestureDetector 按输入设备分流(阅读端 selection_gesture_layer
        // 同款口径):
        // - tap:全设备(落光标/图原子选中/双击选词);
        // - pan 拖选:**仅鼠标/触控板** —— 触摸的 pan 根本不进竞技场,
        //   竖向滑动完全让给宿主滚动(此前触屏滚页面被编辑器拦成拖选);
        //   回调里判 kind 早退没用,recognizer 赢了竞技场滚动照样被劫持,
        //   必须构造期 supportedDevices 分流;
        // - 长按:仅触摸/触控笔(选词 + 放大镜 + 手柄,系统编辑器惯例)。
        child: RawGestureDetector(
          behavior: HitTestBehavior.opaque,
          gestures: {
            TapGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                  () => TapGestureRecognizer(debugOwner: this),
                  (r) => r.onTapDown = _onTapDown,
                ),
            PanGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<PanGestureRecognizer>(
                  () => PanGestureRecognizer(
                    debugOwner: this,
                    supportedDevices: const {
                      PointerDeviceKind.mouse,
                      PointerDeviceKind.trackpad,
                    },
                  ),
                  (r) => r
                    ..onStart = _onPanStart
                    ..onUpdate = _onPanUpdate
                    ..onEnd = _onPanEnd,
                ),
            LongPressGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<
                  LongPressGestureRecognizer
                >(
                  () => LongPressGestureRecognizer(
                    debugOwner: this,
                    supportedDevices: const {
                      PointerDeviceKind.touch,
                      PointerDeviceKind.stylus,
                      PointerDeviceKind.invertedStylus,
                    },
                  ),
                  (r) => r
                    ..onLongPressStart = _onLongPressStart
                    ..onLongPressMoveUpdate = _onLongPressMoveUpdate
                    ..onLongPressEnd = _onLongPressEnd,
                ),
          },
          child: SelectionScope(
            controller: _controller,
            child: Stack(
              key: _rootKey,
              // Clip.none:表格块选择柄/列柄等悬挂装饰 top:-6/left:-2 挂在
              // 块边界外(不同于列表圆点在块内左 padding 区),hardEdge 会
              // 把它们裁掉(被切)。外层滚动区 12px padding 吸收溢出;宽
              // 表格由自身横向 scroll 裁剪,不会外溢盖工具栏。
              clipBehavior: Clip.none,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                ),
                ValueListenableBuilder<(Rect?, int)>(
                  valueListenable: _caretInfo,
                  builder: (context, info, _) => EditorCaret(
                    caretRect: info.$1,
                    // 浮动光标期间 = 灰色吸附残影、常亮不闪(iOS 系统
                    // 同款:浮动 caret 跟手,原位灰 caret 停在吸附位;
                    // EditableText backgroundCursorColor 同语义)。
                    color: _floatingCursor
                        ? Theme.of(context).colorScheme.outline
                        : Theme.of(context).colorScheme.primary,
                    alwaysVisible: state.hasComposing || _floatingCursor,
                    moveGeneration: info.$2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

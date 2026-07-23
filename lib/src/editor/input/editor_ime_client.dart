/// 编辑器 IME 客户端 —— 自研 TextInputClient(non-delta 模型)。
///
/// ## 设计(见计划文档,决策由 appflowy/EditableText 源码调研支撑)
///
/// - **non-delta**:`enableDeltaModel: false`,收全量 [updateEditingValue],
///   与上次喂给平台的值做三段式 diff(公共前缀/后缀)得出变更。这是
///   Flutter EditableText 自身的路径,各平台 CJK 修复最充分。
/// - **IME 窗口 = 当前段落**:attach/setEditingState 只喂光标所在段落,
///   跨段操作(合并/跨段删)走键盘/手势,不走 IME。
/// - **pad 前缀**:移动端 IME 不上报 offset 0 的退格 —— 喂给平台的文本
///   前垫 [_padChar],全部坐标 +1;收到的值先 [_unformat] 剥掉再进文档。
///   检测到 pad 被删 = 段首退格 → 触发与上段合并。坐标换算**只**存在于
///   [_format]/[_unformat] 两个函数(appflowy 的教训:散落即 off-by-one)。
/// - **composing 直接进文档**:每次 update 立即应用,composing 区间只是
///   EditorState 上的标记(下划线渲染用)。
///
/// ## 平台 quirk 集中地
///
/// 所有 `defaultTargetPlatform` 分支只允许出现在本文件,并附注来源。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../model/editable_text_content.dart';
import '../model/editor_state.dart';
import 'input_rules.dart';

/// pad 前缀字符。**必须用普通空格**(对齐 appflowy 生产实现
/// non_delta_input_service.dart 的 _whitespace):曾用 ZWSP(U+200B),
/// 疑被 macOS 输入上下文归一化/剥离,导致回调 unformat 失败走异常路径
/// 反复强制重喂 → 光标错乱、选区被打断。
const String _padChar = ' ';

class EditorImeClient with TextInputClient {
  EditorImeClient({required this.state});

  /// IME 通道日志(定位真机行为用;demo 页开启)。
  static bool debugLogging = false;

  /// 测试用:pad 字符(与运行时同一常量)。
  @visibleForTesting
  static const String padCharForTesting = _padChar;

  static void _log(String msg) {
    if (debugLogging) debugPrint('[IME] $msg');
  }

  final EditorState state;

  int? _viewId;

  /// Text input must be attached to the Flutter view that owns the editor.
  /// Windows rejects `TextInput.setClient` when this is null.
  void updateViewId(int viewId) {
    if (_viewId == viewId) return;
    _viewId = viewId;
    if (attached) {
      detach();
      syncFromState(show: false);
    }
  }

  /// input rule `--- ` 命中时的分隔线插入请求(岛节点由视图层经 cook
  /// 链路产,状态层不造岛)。参数 = 触发块 id(标记文本已清空)。
  void Function(String blockId)? onHorizontalRuleRequest;

  /// iOS 浮动光标报文(长按空格 trackpad 模式)。IME 客户端只转发 ——
  /// 几何(基准光标矩形/命中/幽灵绘制)全在视图层。
  void Function(RawFloatingCursorPoint point)? onFloatingCursor;

  /// macOS AppKit selector 快捷键(自管 IME 连接激活时,Cmd+A/C/V/X
  /// 可能以 selector 形式到达而非键事件 —— 只接 deleteBackward: 会把
  /// 全选/复制/粘贴静默吞掉)。返回 true = 已处理。
  bool Function(String selectorName)? onSelector;

  TextInputConnection? _connection;

  /// 当前 attach 的段落 id(IME 窗口)。
  String? _attachedBlockId;

  /// 上次喂给平台的值(**pad 后**坐标;diff 基准)。
  TextEditingValue _lastSent = TextEditingValue.empty;

  /// 最近发出的值指纹(text+selection;容量 8)。macOS 引擎会把
  /// setEditingState 滞后回显成 updateEditingValue —— 回显必然命中
  /// 本缓冲;**未命中的纯选区通知 = 平台主动行为**(菜单栏 Edit >
  /// Select All 直接操作引擎 NSTextView 后发回的新选区),必须采纳,
  /// 否则 macOS Cmd+A 被菜单拦截后全选永远无效。
  final List<(String, int, int)> _recentSent = [];

  void _rememberSent(TextEditingValue v) {
    _recentSent.add((v.text, v.selection.baseOffset, v.selection.extentOffset));
    if (_recentSent.length > 8) _recentSent.removeAt(0);
  }

  bool _isRecentEcho(TextEditingValue v) => _recentSent.contains((
    v.text,
    v.selection.baseOffset,
    v.selection.extentOffset,
  ));

  /// 正在处理平台回调(updateEditingValue/performAction/...)。
  ///
  /// FluxdoEditor 监听 EditorState 做「外部变更 → 重喂 IME」(undo 按钮、
  /// 程序化改文档),用本标志排除 IME 自身引发的状态通知,避免回环。
  bool _applyingPlatformUpdate = false;
  bool get isApplyingPlatformUpdate => _applyingPlatformUpdate;

  bool get attached => _connection?.attached ?? false;

  String? get attachedBlockId => _attachedBlockId;

  /// 测试注入:模拟"已 attach 到某段"状态(单测直接回放
  /// updateEditingValue 序列,不建真实平台连接)。
  @visibleForTesting
  void debugAttachToBlock(String blockId, TextEditingValue lastSent) {
    _attachedBlockId = blockId;
    _lastSent = lastSent;
  }

  /// 测试读取:当前 diff 基准(pad 后坐标)。
  @visibleForTesting
  TextEditingValue get debugLastSent => _lastSent;

  /// 测试用 pad 工具(与运行时同一实现)。
  @visibleForTesting
  static TextEditingValue debugFormat(TextEditingValue v) => _format(v);

  // -----------------------------------------------------------------
  // 生命周期
  // -----------------------------------------------------------------

  /// 光标进入段落(或选区变化)时调用:必要时 attach + 同步编辑值。
  ///
  /// [show] = 是否唤起软键盘(桌面无感)。
  /// [force] = 无条件 setEditingState:异常纠偏路径用(平台侧状态可能已
  /// 偏离我们发出的 _lastSent,`value != _lastSent` 判不出来)。
  void syncFromState({bool show = true, bool force = false}) {
    final sel = state.selection;
    if (sel == null || !sel.isSingleBlock) {
      // 无光标/跨段选区:M1 简化 —— 保持连接但不喂值更新;
      // 跨段删除由键盘路径处理后回到单段,再走这里同步。
      return;
    }
    final block = state.textBlockById(sel.extent.blockId);
    if (block == null) return; // 岛/幽灵块:IME 窗口不喂值

    final value = _format(
      TextEditingValue(
        text: block.content.text,
        selection: TextSelection(
          baseOffset: sel.base.blockId == sel.extent.blockId
              ? sel.base.offset
              : sel.extent.offset,
          extentOffset: sel.extent.offset,
        ),
        composing: state.composing,
      ),
    );

    if (_connection == null || !_connection!.attached) {
      _connection = TextInput.attach(
        this,
        TextInputConfiguration(
          viewId: _viewId,
          inputType: TextInputType.multiline,
          // 回车键语义:编辑器自己分段,不让平台插 '\n'
          inputAction: TextInputAction.newline,
          enableDeltaModel: false,
          autocorrect: false,
          enableSuggestions: true,
          textCapitalization: TextCapitalization.none,
          keyboardAppearance: Brightness.light,
        ),
      );
      _attachedBlockId = sel.extent.blockId;
      _connection!.setEditingState(value);
      _lastSent = value;
      _rememberSent(value);
      if (show) _connection!.show();
      return;
    }

    // 已连接:段落切换 or 文档/选区外部变化 → 重新喂值。
    final blockChanged = _attachedBlockId != sel.extent.blockId;
    if (force || blockChanged || value != _lastSent) {
      _attachedBlockId = sel.extent.blockId;
      _log(
        'send text="${value.text}" sel=${value.selection.baseOffset}'
        '..${value.selection.extentOffset} comp=${value.composing}'
        '${force ? " (force)" : ""}${blockChanged ? " (blockChanged)" : ""}',
      );
      _connection!.setEditingState(value);
      _lastSent = value;
      _rememberSent(value);
    }
    if (show) _connection!.show();
  }

  void detach() {
    _connection?.close();
    _connection = null;
    _attachedBlockId = null;
    _lastSent = TextEditingValue.empty;
    _recentSent.clear();
  }

  /// 喂平台光标/composing 几何(IME 候选窗定位)。
  void updateEditableGeometry({
    required Size size,
    required Matrix4 transform,
    required Rect caretRect,
  }) {
    final c = _connection;
    if (c == null || !c.attached) return;
    c
      ..setEditableSizeAndTransform(size, transform)
      ..setCaretRect(caretRect)
      ..setComposingRect(caretRect);
  }

  // -----------------------------------------------------------------
  // pad 坐标换算(唯一出入口)
  // -----------------------------------------------------------------

  static TextEditingValue _format(TextEditingValue v) {
    TextRange shift(TextRange r) =>
        !r.isValid ? r : TextRange(start: r.start + 1, end: r.end + 1);
    return TextEditingValue(
      text: _padChar + v.text,
      selection: v.selection.isValid
          ? v.selection.copyWith(
              baseOffset: v.selection.baseOffset + 1,
              extentOffset: v.selection.extentOffset + 1,
            )
          : v.selection,
      composing: shift(v.composing),
    );
  }

  /// CJK 上屏后补判 input rules(typedChar 取光标前一字符)。
  void _tryRulesAfterCommit(String blockId) {
    final blk = state.textBlockById(blockId);
    final caret = state.selection?.extent.offset ?? 0;
    if (blk == null || caret <= 0 || caret > blk.content.length) return;
    final outcome = tryApplyInputRules(
      state,
      blockId,
      typedChar: blk.content.text[caret - 1],
    );
    if (outcome == InputRuleOutcome.hrRequest) {
      onHorizontalRuleRequest?.call(blockId);
    }
  }

  /// 剥 pad。返回 null 表示 pad 已被 IME 删掉(= 段首退格信号)。
  static TextEditingValue? _unformat(TextEditingValue v) {
    if (!v.text.startsWith(_padChar)) return null;
    TextRange unshift(TextRange r) => !r.isValid
        ? r
        : TextRange(
            start: (r.start - 1).clamp(0, v.text.length - 1),
            end: (r.end - 1).clamp(0, v.text.length - 1),
          );
    return TextEditingValue(
      text: v.text.substring(1),
      selection: v.selection.isValid
          ? v.selection.copyWith(
              baseOffset: (v.selection.baseOffset - 1).clamp(
                0,
                v.text.length - 1,
              ),
              extentOffset: (v.selection.extentOffset - 1).clamp(
                0,
                v.text.length - 1,
              ),
            )
          : v.selection,
      composing: unshift(v.composing),
    );
  }

  // -----------------------------------------------------------------
  // TextInputClient
  // -----------------------------------------------------------------

  @override
  TextEditingValue? get currentTextEditingValue => _lastSent;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValue(TextEditingValue rawValue) {
    _applyingPlatformUpdate = true;
    try {
      _updateEditingValueImpl(rawValue);
    } finally {
      _applyingPlatformUpdate = false;
    }
  }

  void _updateEditingValueImpl(TextEditingValue rawValue) {
    final blockId = _attachedBlockId;
    if (blockId == null) return;
    _log(
      'recv text="${rawValue.text}" sel=${rawValue.selection.baseOffset}'
      '..${rawValue.selection.extentOffset} '
      'comp=${rawValue.composing} | lastSent="${_lastSent.text}" '
      'sel=${_lastSent.selection.baseOffset}..${_lastSent.selection.extentOffset}',
    );

    // 幽灵块防御(真机日志实锤的死循环):attach 的段落可能已被结构操作
    // (段首合并/undo 换快照)移出文档 —— 此时报文若被静默吞掉,_lastSent
    // 却前进,后续任何 syncFromState 都会用旧段落状态覆写平台,进入
    // 「用户打字 → 被清空」循环。改为:立即按当前选区重挂/重喂;选区
    // 也失效则断开,绝不半死不活。
    if (state.textBlockById(blockId) == null) {
      _log('ghost block $blockId — resync');
      if (state.selection != null) {
        syncFromState(show: false, force: true);
      } else {
        detach();
      }
      return;
    }

    final value = _unformat(rawValue);
    if (value == null) {
      // 文本不以 pad 开头。只有「恰好等于上次值去掉 pad」才是真·段首退格
      // (IME 只删了 pad);其余(macOS attach 后的空值回显、陈旧回显)一律
      // 视为平台状态失真 → 重喂权威状态,**绝不**触发合并(否则空回显会
      // 把段落错误合并)。
      final expectedRemainder = _lastSent.text.startsWith(_padChar)
          ? _lastSent.text.substring(1)
          : null;
      if (expectedRemainder != null && rawValue.text == expectedRemainder) {
        state.sealHistory();
        state.mergeWithPrevious(blockId);
      }
      syncFromState(show: false, force: true);
      return;
    }

    final prev =
        _unformat(_lastSent) ??
        TextEditingValue(
          text: state.textBlockById(blockId)?.content.text ?? '',
        );

    // '\n' 的语义要按**来源**区分:
    // - **新插入**的 '\n' = 回车(部分 IME 的回车路径不走 performAction),
    //   编辑器语义是分段,拦下来转 splitBlock;
    // - **段内既有**的 '\n' = 本段软换行(cook 的 <br> 导入即是此形态,
    //   序列化写行尾双空格),是正当内容,必须原样留着。
    //
    // 早先这里无条件 `replaceAll('\n', '')`,把两者一起洗了 —— 真机症状:
    // 网页端带换行的草稿在 fluxdo 打开后,只要打一个字,整段换行全没,
    // 几行并成一行。
    //
    // 注意**不能**在这里剥 FFFC:窗口文本里的 FFFC 是既有原子的合法哨兵,
    // 整体剥除会被 diff 误判为"删除了原子"。幻造哨兵只可能出现在**新插入
    // 段**里 → 对 diff.inserted 单独 sanitize(见下)。
    var sanitizedText = value.text;
    final rawDiff = diffWithCaret(
      prev.text,
      sanitizedText,
      value.selection.extentOffset,
    );
    if (rawDiff != null && rawDiff.inserted.contains('\n')) {
      final withoutBreaks = rawDiff.inserted.replaceAll('\n', '');
      if (withoutBreaks.isEmpty && rawDiff.oldEnd == rawDiff.start) {
        // 纯插入换行 = 回车 → 按宿主策略分段或插软换行
        state.insertNewline();
        syncFromState(show: false);
        return;
      }
      // 混合变更:只剥**插入段内**的换行,既有换行不动。
      sanitizedText = sanitizedText.substring(0, rawDiff.start) +
          withoutBreaks +
          sanitizedText.substring(rawDiff.start + rawDiff.inserted.length);
    }

    // 三段式 diff(对比上次值,caret 锚定):公共前缀/后缀 → 中段即变更。
    final diff = diffWithCaret(
      prev.text,
      sanitizedText,
      value.selection.extentOffset,
    );

    var composing = value.composing;
    // macOS 中文 IME quirk(appflowy non_delta_input_service.dart L274):
    // composing collapsed 时视为无 composing,否则退格删净预编辑后
    // IME 不再继续上报删除。M1 先复刻,真机验证后再收窄条件。
    if (defaultTargetPlatform == TargetPlatform.macOS &&
        composing.isValid &&
        composing.isCollapsed) {
      composing = TextRange.empty;
    }

    if (diff == null) {
      final isEcho = _isRecentEcho(rawValue);
      _lastSent = rawValue;
      // 文本没变 = 平台侧的纯光标/composing 通知。composing 活跃时采纳
      // (候选窗交互);其余**回显忽略**(macOS 引擎滞后回显 setEditingState,
      // 拖选/快速输入时按回显动选区会折叠拖选/搬光标 —— 回显必命中
      // _recentSent 指纹);**非回显 = 平台主动选区变化**,采纳:macOS
      // 菜单栏 Edit > Select All(Cmd+A 被 NSMenu 拦截,直接操作引擎
      // NSTextView 后发回全选选区,不走键事件也不走 performSelector)。
      if (composing.isValid && !composing.isCollapsed) {
        state.imeReplace(
          blockId,
          0,
          0,
          '',
          caretOffset: value.selection.extentOffset.clamp(
            0,
            sanitizedText.length,
          ),
          composing: composing,
        );
      } else if (state.hasComposing) {
        // composing 刚结束的收尾通知(无文本变化):清标记 + 封历史口。
        // Windows(微软拼音)上屏是两步:先发「文本+composing(选区仍
        // 滞后在拼音组首)」,再发本通知(composing 清空 + **最终光标**)。
        // 收尾通知里的选区才是上屏后的真实光标,必须采纳 —— 否则光标
        // 停在组首,表现为"打完字光标跳到文字前面"。
        if (value.selection.isValid) {
          state.imeReplace(
            blockId,
            0,
            0,
            '',
            caretOffset: value.selection.extentOffset.clamp(
              0,
              sanitizedText.length,
            ),
          );
        } else {
          state.updateComposing(TextRange.empty);
        }
        state.sealHistory();
        // 上屏收尾补判 input rules:本通知**没有文本变化**(走的就是
        // diff==null 这条路),下面按 diff.inserted 触发的常规路径进不来。
        //
        // 真机失效顺序:先打 `**`,再打拼音,再打闭合 `**`,最后上屏 ——
        // 敲 `*` 时拼音还在 composing 里,规则按约定跳过;上屏后没人再判
        // 一次,`**编辑器**` 就永远停在字面星号(`~~x~~` 同理)。
        //
        // typedChar 取光标前一字符:上屏后它就是这段输入的收尾字符。
        _tryRulesAfterCommit(blockId);
      } else if (!isEcho && value.selection.isValid) {
        // 只认**全选形状**(0..len):菜单 Edit 唯一主动发的选区就是
        // Select All;其余非回显纯选区通知维持忽略(回显可能带轻微
        // 变形的陈旧光标,全盘采纳会重蹈"拖选被折叠"覆辙)。
        final lo = value.selection.baseOffset;
        final hi = value.selection.extentOffset;
        final len = sanitizedText.length;
        if (len > 0 && ((lo == 0 && hi == len) || (lo == len && hi == 0))) {
          _log('adopt platform selectAll (menu)');
          state.selectAll();
        }
      }
      return;
    }

    final wasComposing = state.hasComposing;

    // 幻造哨兵防御:新插入段里的 FFFC 一律剥(原子只能经 insertAtom/
    // fromInlines 建立;IME 不可能合法产生哨兵)。窗口既有 FFFC 不受影响
    // (它们在 diff 的公共前后缀里)。
    final cleanInserted = EditableTextContent.sanitizeText(diff.inserted);
    final phantomCount = diff.inserted.length - cleanInserted.length;

    state.imeReplace(
      blockId,
      diff.start,
      diff.oldEnd,
      cleanInserted,
      caretOffset: (value.selection.extentOffset - phantomCount).clamp(
        0,
        sanitizedText.length - phantomCount,
      ),
      composing: composing,
    );

    // 只在「composition 刚结束」时封口(一次拼音上屏 = 一个 undo 步)。
    // 不能对每个无 composing 的按键都 seal —— 那会让英文/数字连续输入
    // 逐字符成 undo 步(真机日志:56 连击后 undo 出 56 级瀑布)。普通
    // 连续打字保持开组,由空闲定时(EditorState)/结构操作/点击封口。
    if (wasComposing && (!composing.isValid || composing.isCollapsed)) {
      state.sealHistory();
    }

    _lastSent = rawValue;

    // input rules(markdown 快捷语法):文本落地且无 composing 后,按
    // 末字符尝试(`# `→标题、`**x**`→粗体…)。命中即改文档 —— 走下方
    // reconcile 统一回喂平台。hr 请求上抛视图层(岛由 cook 链路产)。
    final composingActive = composing.isValid && !composing.isCollapsed;
    if (!composingActive && cleanInserted.isNotEmpty) {
      final outcome = tryApplyInputRules(
        state,
        blockId,
        typedChar: cleanInserted[cleanInserted.length - 1],
      );
      if (outcome == InputRuleOutcome.hrRequest) {
        onHorizontalRuleRequest?.call(blockId);
      }
    } else if (!composingActive && wasComposing) {
      // 上屏同时还带了文本变化(部分 IME 会把最后一个字符和上屏合并发)
      _tryRulesAfterCommit(blockId);
    }

    // reconcile:若应用后文档与 IME 认知不一致(编辑器改写了内容,
    // 比如剥了 '\n'/幻造 FFFC/input rule 转换),回喂纠正。
    final now = state.textBlockById(blockId);
    if (now != null && now.content.text != sanitizedText) {
      syncFromState(show: false, force: true);
    }
  }

  /// 三段式 diff:返回 old 的 `[start, oldEnd)` 被替换为 [inserted]。
  /// 无变化返回 null。
  ///
  /// **[caret] 锚定**(CodeMirror/ProseMirror findDiff 同款):输入/删除
  /// 永远发生在光标处,变更区间在新文本中应**终于 caret**。对重复字符
  /// (如 "111"→"1111")纯前后缀 diff 会把插入点算到区间末尾 —— 文本
  /// 碰巧一致,但 mark 区间/原子节点会在错误位置被调整。锚定法:先验证
  /// old 以 new[caret:] 结尾(光标后的文本未被本次编辑触碰),再在两个
  /// 头部内取公共前缀。验证不成立(如平台批量整形替换)退回纯前后缀。
  @visibleForTesting
  static ({int start, int oldEnd, String inserted})? diffWithCaret(
    String oldText,
    String newText,
    int caret,
  ) {
    if (oldText == newText) return null;

    if (caret >= 0 && caret <= newText.length) {
      final tail = newText.substring(caret);
      if (tail.length <= oldText.length && oldText.endsWith(tail)) {
        final oldHead = oldText.substring(0, oldText.length - tail.length);
        final newHead = newText.substring(0, caret);
        var prefix = 0;
        final minLen = oldHead.length < newHead.length
            ? oldHead.length
            : newHead.length;
        while (prefix < minLen && oldHead[prefix] == newHead[prefix]) {
          prefix++;
        }
        return (
          start: prefix,
          oldEnd: oldHead.length,
          inserted: newHead.substring(prefix),
        );
      }
    }

    // fallback:纯公共前缀/后缀。
    var prefix = 0;
    final minLen = oldText.length < newText.length
        ? oldText.length
        : newText.length;
    while (prefix < minLen && oldText[prefix] == newText[prefix]) {
      prefix++;
    }
    var oldSuffix = oldText.length;
    var newSuffix = newText.length;
    while (oldSuffix > prefix &&
        newSuffix > prefix &&
        oldText[oldSuffix - 1] == newText[newSuffix - 1]) {
      oldSuffix--;
      newSuffix--;
    }
    return (
      start: prefix,
      oldEnd: oldSuffix,
      inserted: newText.substring(prefix, newSuffix),
    );
  }

  @override
  void performAction(TextInputAction action) {
    if (action == TextInputAction.newline) {
      _applyingPlatformUpdate = true;
      try {
        state.sealHistory();
        state.insertNewline();
        syncFromState(show: false);
      } finally {
        _applyingPlatformUpdate = false;
      }
    }
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {
    onFloatingCursor?.call(point);
  }

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void connectionClosed() {
    _connection = null;
    _attachedBlockId = null;
    _lastSent = TextEditingValue.empty;
  }

  @override
  void insertTextPlaceholder(Size size) {}

  @override
  void removeTextPlaceholder() {}

  @override
  void showToolbar() {}

  @override
  void didChangeInputControl(
    TextInputControl? oldControl,
    TextInputControl? newControl,
  ) {}

  @override
  void performSelector(String selectorName) {
    // macOS AppKit selector 路径(appflowy delta_input_service.dart L212 有
    // 同款):部分按键(方向/删除/编辑命令)在 IME 链路里以 selector
    // 形式到达。先给视图层(onSelector:全选/剪贴板等需要视图层能力),
    // 再兜底 deleteBackward。
    if (onSelector?.call(selectorName) ?? false) return;
    if (selectorName == 'deleteBackward:') {
      _applyingPlatformUpdate = true;
      try {
        state.backspace();
        syncFromState(show: false);
      } finally {
        _applyingPlatformUpdate = false;
      }
    }
  }

  @override
  void insertContent(KeyboardInsertedContent content) {}
}

/// 子包自带的选区 toolbar —— 选区稳定后弹平台原生样式的文本选择菜单。
///
/// - iOS:SDK [AdaptiveTextSelectionToolbar.buttonItems] → 系统胶囊
///   (自动翻页箭头,毛玻璃自带边界)。
/// - Android + 桌面:Material 横排 [TextSelectionToolbar],容器用
///   surfaceContainerHigh + elevation 3(SDK 默认容器在自定义主题下直接用
///   surface 当底色,与帖子背景融为一体看不到边界,见 [_build] 注释)。
/// 复制/全选 label 走 MaterialLocalizations 自动本地化。
///
/// 按钮集(对齐 SDK getSelectableButtonItems :298-338 顺序,再接自有项):
/// - 复制(子包内 Clipboard.setData,代码块带 ```lang)
/// - 全选(回调交上层 SelectionNavigator.selectAll,移动端保持 toolbar 重定位)
/// - 复制引用 / 引用(回调交主项目,null 时隐藏)
/// - ProcessText 用户应用工具(仅 Android,系统翻译/搜索等,SDK :1752-1774)
///
/// 定位:anchors 按 SDK TextSelectionToolbarAnchors.fromSelection 语义取
/// 可见选区外接框的 top/bottom 中点,flip/夹边交给 SDK layout delegate。
/// 用 OverlayEntry 浮在内容上方,避免被滚动裁剪。
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'selection_data.dart';
import 'selection_process_text.dart';

class SelectionToolbar {
  SelectionToolbar({
    required this.context,
    required this.onQuote,
    required this.onCopied,
    this.onCopyQuote,
    this.onSelectAll,
    this.onProcessTextDone,
    this.tapRegionGroupId,
    this.copyQuoteLabel = '复制引用',
    this.quoteLabel = '引用',
  });

  final BuildContext context;

  /// 「引用」回调 —— 把选区纯文本交回主项目打开回复框。
  /// null = 不显示该按钮(未登录等无法引用的场景,仅保留复制类按钮)。
  final void Function(String plainText)? onQuote;
  final VoidCallback? onCopied;

  /// 「复制引用」回调 —— 把选区纯文本交回主项目拼 BBCode 进剪贴板。
  /// null = 不显示该按钮(主项目未接入时)。
  final void Function(String plainText)? onCopyQuote;

  /// 「全选」回调 —— 上层执行 SelectionNavigator.selectAll 并按平台决定
  /// 保持/收起 toolbar(对齐 SDK :1723-1729)。null = 不显示该按钮。
  final VoidCallback? onSelectAll;

  /// ProcessText 动作执行完毕(上层清选区,对齐 SDK 执行后 hideToolbar)。
  final VoidCallback? onProcessTextDone;

  /// 与内容层同一 TapRegion groupId —— 点 toolbar 不触发内容的 onTapOutside。
  final Object? tapRegionGroupId;

  final String copyQuoteLabel;
  final String quoteLabel;

  OverlayEntry? _entry;

  /// 当前选区数据(可变)—— 滚动时由 [reposition] 更新,builder 内读最新值
  /// 实时算坐标,markNeedsBuild 即重定位。
  SelectionData? _data;

  /// 竖直滞后补偿(本帧 scroll delta)——滚动时 export 几何滞后一帧,_build 把
  /// 竖直坐标减去它 → 与内容同帧对齐,消抖。show(松手)时归零。
  double _yComp = 0;

  /// 在选区旁显示 toolbar(上方优先,放不下翻下方,SDK delegate 处理)。
  void show(SelectionData data) {
    _data = data;
    _yComp = 0;
    // Android:首次触发 ProcessText 动作查询;就绪后若还在显示则补进按钮。
    SelectionProcessText.ensureLoaded().then((_) {
      if (_entry != null) _entry!.markNeedsBuild();
    });
    if (_entry != null) {
      _entry!.markNeedsBuild();
      return;
    }
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;

    _entry = OverlayEntry(builder: _build);
    overlay.insert(_entry!);
  }

  /// 滚动时调:更新选区几何并重定位。[yCompensation] = 本帧 scroll delta,
  /// 用于抵消 export 几何的一帧滞后(消抖,见 SelectionContentLayer._onScroll)。
  void reposition(SelectionData? data, {double yCompensation = 0}) {
    if (_entry == null) return;
    if (data == null) {
      hide();
      return;
    }
    _data = data;
    _yComp = yCompensation;
    _entry!.markNeedsBuild();
  }

  Widget _build(BuildContext ctx) {
    final data = _data;
    if (data == null) return const SizedBox.shrink();
    // 选区完全滚出视口(无可见块 → 无几何)→ 不显示(滚回视口再现),
    // 避免工具栏空浮在视口顶与可见内容脱节。
    if (data.globalRects.isEmpty) return const SizedBox.shrink();
    final overlay = Overlay.maybeOf(context);
    final overlayBox = overlay?.context.findRenderObject() as RenderBox?;
    if (overlayBox == null) return const SizedBox.shrink();

    // 可见选区外接框 → overlay 局部坐标;减 _yComp 抵消滚动一帧滞后(消抖)。
    final bounds = data.globalBounds;
    final tl = overlayBox.globalToLocal(bounds.topLeft);
    final selRect =
        Rect.fromLTWH(tl.dx, tl.dy - _yComp, bounds.width, bounds.height);

    // anchors 语义对齐 SDK TextSelectionToolbarAnchors.fromSelection:
    // primary = 外接框顶边中点、secondary = 底边中点,竖直方向夹进 overlay。
    // 底边锚额外夹到「下方还放得下 toolbar」的高度:选区底出视口且上方也放
    // 不下时,SDK delegate 会原样贴 below 锚(不做底部夹)→ toolbar 出屏;
    // 夹住后保证**始终可见**(44=Material toolbar 高,20=below 间距,8=屏距)。
    final size = overlayBox.size;
    const belowReserve =
        44.0 + TextSelectionToolbar.kToolbarContentDistanceBelow + 8.0;
    final maxAnchorY = math.max(0.0, size.height - belowReserve);
    final anchorX = selRect.center.dx.clamp(0.0, size.width);
    final anchorAbove = Offset(anchorX, selRect.top.clamp(0.0, size.height));
    final anchorBelow = Offset(anchorX, selRect.bottom.clamp(0.0, maxAnchorY));
    final anchors = TextSelectionToolbarAnchors(
      primaryAnchor: anchorAbove,
      secondaryAnchor: anchorBelow,
    );

    // 平台分发:
    // - iOS:AdaptiveTextSelectionToolbar → Cupertino 胶囊(毛玻璃自带边界)。
    // - Android + 桌面:自建 Material 横排 TextSelectionToolbar。不走 Adaptive
    //   的原因:① 桌面 Adaptive 产出竖排右键菜单样式(SDK 桌面只在右键弹),
    //   划词自动弹很突兀;② SDK 默认容器在自定义主题下直接用 colorScheme
    //   .surface 当底色 —— 与帖子背景同色、elevation 仅 1,暗色下完全融入
    //   看不到边界。故用 toolbarBuilder 覆盖:底色 = M3 菜单浮层标准层级
    //   surfaceContainerHigh(暗色比 surface 亮一档),elevation = 菜单标准 3。
    final items = _buttonItems(data);
    final Widget toolbar = defaultTargetPlatform == TargetPlatform.iOS
        ? AdaptiveTextSelectionToolbar.buttonItems(
            anchors: anchors,
            buttonItems: items,
          )
        : TextSelectionToolbar(
            anchorAbove: anchorAbove,
            anchorBelow: anchorBelow,
            toolbarBuilder: (context, child) => Material(
              // 44(SDK _kToolbarHeight)/ 2:与默认容器同形的胶囊圆角。
              borderRadius: const BorderRadius.all(Radius.circular(22)),
              clipBehavior: Clip.antiAlias,
              color: Theme.of(context).colorScheme.surfaceContainerHigh,
              elevation: 3,
              type: MaterialType.card,
              child: child,
            ),
            children: [
              for (var i = 0; i < items.length; i++)
                TextSelectionToolbarTextButton(
                  padding: TextSelectionToolbarTextButton.getPadding(
                      i, items.length),
                  onPressed: items[i].onPressed,
                  // TextSelectionToolbarTextButton 内部用固定的 SDK 默认样式,
                  // 不读取 ambient Theme,导致这里的文字始终是系统兜底字体
                  // (与全局设置的自定义字体不一致,CJK 下尤其明显)。显式套
                  // Theme 的 textTheme 让它跟随 app 全局字体设置。
                  child: Text(
                    AdaptiveTextSelectionToolbar.getButtonLabel(
                        ctx, items[i]),
                    style: Theme.of(ctx).textTheme.bodyMedium,
                  ),
                ),
            ],
          );

    return Positioned.fill(
      child: TapRegion(
        groupId: tapRegionGroupId,
        child: toolbar,
      ),
    );
  }

  /// 按钮集:copy → selectAll(SDK 顺序)→ 复制引用/引用 → ProcessText。
  List<ContextMenuButtonItem> _buttonItems(SelectionData data) {
    return [
      // 复制/全选用 type,label 由 AdaptiveTextSelectionToolbar 按平台本地化。
      ContextMenuButtonItem(
        type: ContextMenuButtonType.copy,
        onPressed: () {
          _copy(data);
          hide();
        },
      ),
      if (onSelectAll != null)
        ContextMenuButtonItem(
          type: ContextMenuButtonType.selectAll,
          // 不在此 hide:上层按平台决定保持重定位(移动端)或收起(桌面)。
          onPressed: onSelectAll,
        ),
      if (onCopyQuote != null)
        ContextMenuButtonItem(
          label: copyQuoteLabel,
          onPressed: () {
            onCopyQuote!(data.plainText);
            hide();
          },
        ),
      if (onQuote != null)
        ContextMenuButtonItem(
          label: quoteLabel,
          onPressed: () {
            onQuote!(data.plainText);
            hide();
          },
        ),
      // Android 用户应用工具(翻译/搜索等)。执行后收 toolbar + 通知上层清选区
      // (对齐 SDK _textProcessingActionButtonItems :1752-1774)。
      for (final action in SelectionProcessText.actions)
        ContextMenuButtonItem(
          label: action.label,
          onPressed: () async {
            hide();
            await SelectionProcessText.run(action.id, data.plainText);
            onProcessTextDone?.call();
          },
        ),
    ];
  }

  void hide() {
    _entry?.remove();
    _entry = null;
    _data = null;
  }

  void _copy(SelectionData data) {
    final code = data.code;
    final text = code != null
        ? '```${code.language ?? ''}\n${data.plainText}\n```'
        : data.plainText;
    Clipboard.setData(ClipboardData(text: text));
    onCopied?.call();
  }
}

/// fluxdo 自研帖子渲染引擎。
///
/// 设计目标:
/// - 用自研轻量节点渲染器替代 `flutter_widget_from_html`,解决长帖滚动卡顿
/// - 自研逻辑选区(逻辑位置 + 几何缓存),绕开系统 SelectionArea 在虚拟化
///   Sliver 内的崩溃(flutter/flutter #124078)
/// - Node 模型预留扩展性,后续可承载 WYSIWYG 编辑模式(本次范围不做)
///
/// 详细方案见 `docs/render_refactor_plan.md`。
library;

export 'src/chunk/html_chunk.dart';
export 'src/chunk/html_chunker.dart';
export 'src/config/render_config.dart';
export 'src/dev/fixtures_index.dart';
export 'src/dev/fixtures_index.g.dart';
export 'src/flatten/flatten_cache.dart';
export 'src/flatten/inline_flattener.dart';
export 'src/node/node.dart';
export 'src/parser/arrow_ligature.dart';
export 'src/parser/paragraph_parser.dart';
export 'src/render/code_block_handler.dart';
export 'src/render/emoji_handler.dart';
export 'src/render/footnote_handler.dart';
export 'src/render/iframe_handler.dart';
export 'src/render/audio_handler.dart';
export 'src/render/cached_paragraph_text.dart'
    show ParagraphLayoutCache, CachedParagraphText;
export 'src/render/paragraph_warmup.dart'
    show ParagraphWarmup, ParagraphWarmupProbe, WarmupContext;
export 'src/render/video_handler.dart';
export 'src/render/image_handler.dart';
export 'src/render/inline_span_text.dart';
export 'src/render/lazy_video_handler.dart';
export 'src/render/link_handler.dart';
export 'src/render/local_date_handler.dart';
export 'src/render/math_handler.dart';
export 'src/render/mention_handler.dart';
export 'src/render/node_factory.dart';
export 'src/render/onebox_handler.dart';
export 'src/render/policy_handler.dart';
export 'src/render/chat_transcript_handler.dart';
export 'src/render/poll_handler.dart';
export 'src/render/quote_avatar_handler.dart';
export 'src/render/svg_handler.dart';
export 'src/selection/selection_coordinator.dart' show SelectionCoordinator;
export 'src/selection/selection_data.dart';
export 'src/selection/selection_scope.dart' show SelectionScope;
export 'src/widget/fluxdo_render.dart';
export 'src/widget/screenshot_mode.dart';

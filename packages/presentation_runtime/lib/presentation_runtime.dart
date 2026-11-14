/// Riverpod presentation runtime: source ownership, consistency-group
/// admission, prepared install, bounded workers, and byte caches.
library presentation_runtime;

export 'src/cache/byte_lru_cache.dart';
export 'src/cache/markdown_preparation_cache.dart';
export 'src/preparation/markdown/markdown_preparation_engine.dart';
export 'src/preparation/markdown/message_markdown_decomposition.dart';
export 'src/preparation/markdown/message_markdown_models.dart';
export 'src/preparation/markdown/message_markdown_parser.dart';
export 'src/preparation/preparation_manager.dart';
export 'src/presentation_provider_entry.dart';
export 'src/presentation_runtime.dart';
export 'src/resources/prepared_display.dart';
export 'src/resources/resource_observation.dart';
export 'src/resources/source_invalidation.dart';
export 'src/scheduling/preparation_cancellation.dart';
export 'src/scheduling/preparation_executor.dart';
export 'src/scheduling/preparation_worker.dart';
export 'src/scheduling/preparation_worker_pool.dart';

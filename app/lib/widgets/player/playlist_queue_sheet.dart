import 'package:flutter/material.dart';
import 'package:gravity_torrent/l10n/app_localizations.dart';
import 'package:gravity_torrent/services/player_enhancements_service.dart';
import 'package:provider/provider.dart';

class PlaylistQueueSheet extends StatelessWidget {
  const PlaylistQueueSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Consumer<PlayerEnhancementsService>(
      builder: (context, svc, _) {
        if (svc.queue.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                l.emptyQueue,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),
          );
        }

        return DraggableScrollableSheet(
          initialChildSize: 0.5,
          minChildSize: 0.3,
          maxChildSize: 0.85,
          expand: false,
          builder: (context, scrollController) {
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    l.playbackQueue,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Expanded(
                  child: ReorderableListView.builder(
                    scrollController: scrollController,
                    itemCount: svc.queue.length,
                    onReorderItem: svc.reorderQueue,
                    itemBuilder: (context, i) {
                      final item = svc.queue[i];
                      final isCurrent = i == svc.currentIndex;
                      return Dismissible(
                        key: ValueKey(item),
                        direction: DismissDirection.endToStart,
                        onDismissed: (_) {
                          // Re-resolve the position by identity rather than
                          // trusting the build-time `i`: the queue can
                          // change from outside this sheet (e.g. auto-
                          // advance to the next item) while the dismiss
                          // animation is in flight.
                          final currentIndex = svc.queue.indexOf(item);
                          if (currentIndex != -1) {
                            svc.removeFromQueue(currentIndex);
                          }
                        },
                        background: Container(
                          color: Theme.of(context).colorScheme.errorContainer,
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 16),
                          child: Icon(
                            Icons.delete,
                            color: Theme.of(
                              context,
                            ).colorScheme.onErrorContainer,
                          ),
                        ),
                        child: ListTile(
                          leading: isCurrent
                              ? Icon(
                                  Icons.play_arrow,
                                  color: Theme.of(context).colorScheme.primary,
                                )
                              : Text(
                                  '${i + 1}',
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                          title: Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: ReorderableDragStartListener(
                            index: i,
                            child: const Icon(Icons.drag_handle),
                          ),
                          selected: isCurrent,
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

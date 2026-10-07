import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Menu chrome overlays the game, so opening it never changes game geometry.
class FloatingGameMenu extends StatelessWidget {
  final bool expanded;
  final bool canResume;
  final bool busy;
  final VoidCallback onToggle;
  final VoidCallback onResume;
  final Widget toolbar;
  final Widget child;

  const FloatingGameMenu({
    super.key,
    required this.expanded,
    required this.canResume,
    required this.busy,
    required this.onToggle,
    required this.onResume,
    required this.toolbar,
    required this.child,
  });

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape,
              includeRepeats: false): () {
            if (!busy) onToggle();
          },
        },
        child: Focus(
          autofocus: true,
          child: Stack(
            fit: StackFit.expand,
            children: [
              IgnorePointer(ignoring: expanded || busy, child: child),
              if (expanded && canResume)
                Positioned.fill(
                  child: Semantics(
                    label: 'Resume game',
                    button: true,
                    child: GestureDetector(
                      key: const ValueKey('game-menu-backdrop'),
                      behavior: HitTestBehavior.opaque,
                      onTap: busy ? null : onResume,
                      child: const ColoredBox(color: Colors.black54),
                    ),
                  ),
                ),
              Positioned(
                top: 0,
                bottom: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  bottom: false,
                  minimum: const EdgeInsets.all(8),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 720),
                      child: Material(
                        elevation: 6,
                        color: Theme.of(context).colorScheme.surface,
                        borderRadius: BorderRadius.circular(12),
                        child: Listener(
                          // Consume even blank toolbar space instead of letting
                          // the background resume gesture receive that tap.
                          behavior: HitTestBehavior.opaque,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              IconButton(
                                key: const ValueKey('game-menu-toggle'),
                                tooltip:
                                    expanded ? 'Close menu / resume' : 'Menu',
                                onPressed: busy ? null : onToggle,
                                icon: const Icon(Icons.menu),
                              ),
                              if (expanded)
                                Expanded(
                                  child: SingleChildScrollView(child: toolbar),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}

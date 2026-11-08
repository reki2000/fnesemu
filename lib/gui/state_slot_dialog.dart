import 'package:flutter/material.dart';

import 'state_slot.dart';
import 'storage.dart';

/// Lists the state slots of a game; the dialog returns the selected slot,
/// or null when it is dismissed. When [saving], every slot can be selected
/// and a state saved before is replaced; otherwise empty slots are
/// disabled and cannot be selected.
class StateSlotDialog extends StatelessWidget {
  final bool saving;
  final List<StateSlotInfo?> slots;

  const StateSlotDialog({super.key, required this.saving, required this.slots});

  static String _timeOf(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(saving ? 'Save state' : 'Load state'),
        content: SizedBox(
          width: 360,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: Storage.stateSlotCount,
            itemBuilder: (context, slot) {
              final info = slots[slot];
              return ListTile(
                key: ValueKey('state-slot-$slot'),
                enabled: saving || info != null,
                leading: SizedBox(
                  width: 64,
                  height: 48,
                  child: info?.thumbnail != null
                      ? Image.memory(info!.thumbnail!,
                          fit: BoxFit.contain,
                          filterQuality: FilterQuality.none)
                      : Icon(info == null
                          ? Icons.circle_outlined
                          : Icons.image_outlined),
                ),
                title: Text('Slot $slot'),
                subtitle:
                    Text(info == null ? 'Empty' : _timeOf(info.savedAt)),
                onTap: () => Navigator.of(context).pop(slot),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      );
}

/// Shows the state slot list of a game and returns the selected slot.
Future<int?> showStateSlotDialog(BuildContext context,
        {required bool saving, required List<StateSlotInfo?> slots}) =>
    showDialog<int>(
        context: context,
        builder: (_) => StateSlotDialog(saving: saving, slots: slots));

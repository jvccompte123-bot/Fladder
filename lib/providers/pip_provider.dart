import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/wrappers/pip_manager.dart';

final pipManagerProvider = Provider<PipManager>((ref) {
  final manager = PipManager();
  ref.onDispose(manager.dispose);
  return manager;
});

final pipStateProvider = StreamProvider<bool>((ref) {
  final manager = ref.watch(pipManagerProvider);
  // A page mounted after AVKit's didStart event must still know that the
  // native player owns playback. Subscribe before emitting the snapshot.
  return Stream<bool>.multi((controller) {
    final subscription = manager.isInPip.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    controller.add(manager.currentState);
    controller.onCancel = subscription.cancel;
  }).distinct();
});

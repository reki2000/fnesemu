import 'package:fnesemu_core/app_api.dart';

final _states = Expando<PadState>();

/// Drives the input of a core in tests. The first call connects a [PadState]
/// to the core; the core reads it where the hardware samples its controllers.
extension TestPad on Core {
  PadState get padState {
    var state = _states[this];
    if (state == null) {
      state = _states[this] = PadState();
      input = state;
    }
    return state;
  }

  void padDown(int controllerId, PadButton button) =>
      padState.press(controllerId, button);

  void padUp(int controllerId, PadButton button) =>
      padState.release(controllerId, button);

  void padAxis(int controllerId, PadAxis axis, double value) =>
      padState.setAxis(controllerId, axis, value);
}

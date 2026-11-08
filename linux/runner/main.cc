#include <stdlib.h>

#include "my_application.h"

int main(int argc, char** argv) {
  // Debug and profile engines read their switches from the environment;
  // Flutter GPU, which can draw the 3D renders of the cores, needs these.
  // Release engines ignore them, so the cores draw in software there.
  if (getenv("FLUTTER_ENGINE_SWITCHES") == nullptr) {
    setenv("FLUTTER_ENGINE_SWITCHES", "2", 0);
    setenv("FLUTTER_ENGINE_SWITCH_1", "enable-impeller", 0);
    setenv("FLUTTER_ENGINE_SWITCH_2", "enable-flutter-gpu", 0);
  }
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}

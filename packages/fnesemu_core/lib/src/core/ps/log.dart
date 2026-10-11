/// traces the bios calls and the cdrom commands to the debug log. They are
/// logged on every call, and building the messages costs even when nothing
/// is printed, so they are off unless built with `-DPS_TRACE=true`.
const psTrace = bool.fromEnvironment("PS_TRACE");

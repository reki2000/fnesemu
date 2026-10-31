# Test scope

Keep the DC test suite compact and focused on observable CPU, audio, video and media behavior.
Prefer a representative scenario in an existing test file over a new file or a matrix for each register bit, validation branch or internal field.
Keep save-state coverage at the public core boundary in `core_state_test.dart`; do not recreate separate component serialization suites.
Do not add tests that simply mirror the implementation or duplicate another layer's checks.
During bring-up, prioritize implementing missing audio and rendering behavior and use short runs of supplied BIOS/disc assets for progression evidence.
Add a focused regression only when it protects a meaningful behavior or a reproducible failure that the retained scenarios do not cover.

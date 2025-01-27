test-6502: 
	dart run lib/main_cputest.dart 

test-z80: 
	dart run lib/core/md/z80/z80_test.dart assets/tests.in assets/tests.expected

test-m68:
	dart run lib/core/md/m68/m68_test.dart

test:
	flutter test

playvgm:
	dart run lib/tools/vgmplayer.dart $(VGM)

format:
	flutter pub get
	flutter pub run import_path_converter:main
	flutter pub run import_sorter:main

.PHONY: cputest 
.PHONY: format

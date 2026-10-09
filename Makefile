test-6502: 
	dart run lib/main_cputest.dart 

test-z80: 
	dart run lib/core/md/z80/z80_test.dart assets/tests.in assets/tests.expected

test-m68:
	dart run lib/tools/m68_test.dart

test-r3000:
	dart run lib/core/ps1/r3000/r3000_test.dart

test-gte:
	dart run lib/core/ps/r3000/cop2_test.dart assets/ps1-tests/gte/test-all/tests.c

test:
	flutter test

playvgm:
	dart run lib/tools/vgmplayer.dart $(VGM)

platform-upgrade:
	rm -rf ios android windows linux macos web
	flutter create --org com.reki2000 .

format:
	flutter pub get
	dart fix --apply --code=directives_ordering

.PHONY: cputest 
.PHONY: format

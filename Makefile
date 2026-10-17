# the cpu test runners of the core package, run from here for the assets/
CORE := packages/fnesemu_core

test-6502:
	dart run $(CORE)/tool/nes_cputest.dart

test-z80:
	dart run $(CORE)/tool/z80_test.dart assets/tests.in assets/tests.expected

# the 8088 tests of https://github.com/SingleStepTests/8088 (v2) in assets/8088
test-v30:
	dart run $(CORE)/tool/v30_test.dart assets/8088/metadata.json $(wildcard assets/8088/*.json.gz)

test-m68:
	dart run $(CORE)/tool/m68_test.dart

test-r3000:
	dart run $(CORE)/tool/r3000_test.dart

test-gte:
	dart run $(CORE)/tool/gte_test.dart assets/ps1-tests/gte/test-all/tests.c

test:
	cd packages/cdrom_image && dart test
	cd packages/mp_pixel_image && flutter test
	cd $(CORE) && dart test
	flutter test

regress:
	python3 scripts/regress.py run quick

regress-full:
	flock /tmp/claude-1000/fnesemu-bench.lock python3 scripts/regress.py run full

playvgm:
	dart run tool/vgmplayer.dart $(VGM)

platform-upgrade:
	rm -rf ios android windows linux macos web
	flutter create --org com.reki2000 .

format:
	flutter pub get
	dart fix --apply --code=prefer_relative_imports,directives_ordering lib
	dart fix --apply --code=prefer_relative_imports,directives_ordering test
	cd $(CORE) && dart fix --apply --code=prefer_relative_imports,directives_ordering .
	cd packages/cdrom_image && dart fix --apply --code=prefer_relative_imports,directives_ordering .
	cd packages/mp_pixel_image && dart fix --apply --code=prefer_relative_imports,directives_ordering .

.PHONY: test format regress regress-full

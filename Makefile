CORE := packages/fnesemu_core
CPU := $(CORE)/test/cpu

# the cpu tests: make test-cpu-setup fetches the data into test/cpu/<name>/.build/, and a test without it is skipped
cpu_test = @if [ -e $(CPU)/$(1)/.build/.ready ]; then $(2); else echo "SKIP $(1): no data (run make test-cpu-setup)"; fi

test-cpu: test-6502 test-z80 test-m68 test-r3000 test-huc6280

test-cpu-setup:
	@for t in nestest z80_fuse m68k_sst r3000 huc6280; do \
		if python3 $(CPU)/$$t/setup.py; then touch $(CPU)/$$t/.build/.ready; echo "ready $$t"; \
		else rm -f $(CPU)/$$t/.build/.ready; echo "setup failed: $$t"; fi; \
	done

test-6502:
	$(call cpu_test,nestest,dart run $(CORE)/tool/cpu_test.dart nestest $(CPU)/nestest/.build/nestest.nes $(CPU)/nestest/.build/nestest.log)

test-z80:
	$(call cpu_test,z80_fuse,dart run $(CORE)/tool/cpu_test.dart z80 $(CPU)/z80_fuse/.build/tests.in $(CPU)/z80_fuse/.build/tests.expected)

# the 8088 tests of https://github.com/SingleStepTests/8088 (v2) in assets/8088
test-v30:
	dart run $(CORE)/tool/cpu_test.dart v30 assets/8088/metadata.json $(wildcard assets/8088/*.json.gz)

test-m68:
	$(call cpu_test,m68k_sst,dart run $(CORE)/tool/cpu_test.dart m68k $(CPU)/m68k_sst/.build/680x0/68000/v1)

test-r3000:
	$(call cpu_test,r3000,dart run $(CORE)/tool/cpu_test.dart r3000 $(CPU)/r3000/.build/r3000/v1)


test-huc6280:
	$(call cpu_test,huc6280,dart run $(CORE)/tool/cpu_test.dart huc6280 $(CPU)/huc6280/.build/huc6280/v1)

# the end-to-end cases of test/e2e (scripts/e2e.py); make test-e2e-setup fetches or builds their media
test-e2e:
	python3 scripts/e2e.py run -j 4

test-e2e-setup:
	python3 scripts/e2e.py setup

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

cputest: 
	dart run lib/main_cputest.dart 

mdz80test: 
	dart run lib/core/md/z80/z80_test.dart assets/tests.in assets/tests.expected

test:
	flutter test

format:
	flutter pub get
	flutter pub run import_path_converter:main
	flutter pub run import_sorter:main

.PHONY: cputest 
.PHONY: format

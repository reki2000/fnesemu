cputest: 
	dart run lib/main_cputest.dart 

test:
	flutter test

format:
	flutter pub get
	flutter pub run import_path_converter:main
	flutter pub run import_sorter:main

.PHONY: cputest 
.PHONY: format

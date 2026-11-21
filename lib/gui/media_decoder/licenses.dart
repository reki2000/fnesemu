// The license notice of the FFmpeg libraries that the app bundles for
// ATRAC3plus (mmd_libav, from mp_media_decoder), shown on the license page.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _notice =
    'This app includes mmd_libav, a build of the libavcodec and libavutil '
    'libraries of FFmpeg 7.1.1 with only the ATRAC3 and ATRAC3plus '
    'decoders. FFmpeg is licensed under the GNU Lesser General Public '
    'License version 2.1 or later; its copyright holders are listed in the '
    'FFmpeg source. The app loads mmd_libav as a separate shared library, '
    'which you may replace with a modified build.\n\n'
    'The FFmpeg source, the build script and the built libraries are '
    'published at '
    'https://github.com/reki2000/fnesemu/releases/tag/libav-atrac-7.1.1-1';

/// Adds the FFmpeg notice and the text of the LGPL to the license page;
/// nothing on the web, which has no native libraries.
void registerMediaDecoderLicenses() {
  if (kIsWeb) return;
  LicenseRegistry.addLicense(() async* {
    final lgpl = await rootBundle.loadString('assets/licenses/LGPL-2.1.txt');
    yield LicenseEntryWithLineBreaks(['FFmpeg'], '$_notice\n\n$lgpl');
  });
}

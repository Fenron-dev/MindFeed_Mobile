import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Bereitet ein Bild für die Vision-Analyse auf: verkleinert auf max. [maxDim]
/// Pixel Kantenlänge und kodiert als JPEG-`data:`-URL (spart Tokens/Kosten).
class ImageVision {
  const ImageVision._();

  static String toDataUrl(Uint8List bytes, {int maxDim = 1024, int quality = 80}) {
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        return 'data:image/jpeg;base64,${base64Encode(bytes)}';
      }
      final resized = (decoded.width > maxDim || decoded.height > maxDim)
          ? img.copyResize(
              decoded,
              width: decoded.width >= decoded.height ? maxDim : null,
              height: decoded.height > decoded.width ? maxDim : null,
            )
          : decoded;
      final jpg = img.encodeJpg(resized, quality: quality);
      return 'data:image/jpeg;base64,${base64Encode(jpg)}';
    } catch (_) {
      return 'data:image/jpeg;base64,${base64Encode(bytes)}';
    }
  }
}

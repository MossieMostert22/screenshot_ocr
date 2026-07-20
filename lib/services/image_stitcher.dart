import 'dart:io';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

class ImageStitcher {
  /// Takes a list of file paths pointing to successive viewports,
  /// stitches them vertically into a single image, and returns the final file path.
  Future<String?> stitchImagesVertically(List<String> filePaths) async {
    if (filePaths.isEmpty) return null;
    if (filePaths.length == 1) return filePaths.first;

    try {
      List<img.Image> decodedImages = [];
      int totalHeight = 0;
      int maxWidth = 0;

      // 1. Decode all file structures into raw pixel buffers
      for (String path in filePaths) {
        final bytes = await File(path).readAsBytes();
        final img.Image? decoded = img.decodeImage(bytes);
        
        if (decoded != null) {
          decodedImages.add(decoded);
          totalHeight += decoded.height;
          if (decoded.width > maxWidth) {
            maxWidth = decoded.width;
          }
        }
      }

      if (decodedImages.isEmpty) return null;

      // 2. Instantiate a blank vertical destination pixel canvas
      final img.Image stitchedCanvas = img.Image(width: maxWidth, height: totalHeight);

      // 3. Paint each viewport layer down the canvas sequentially
      int currentYOffset = 0;
      for (img.Image image in decodedImages) {
        // Draw the current screenshot data block into the canvas layout grid
        img.compositeImage(
          stitchedCanvas, 
          image, 
          dstX: 0, 
          dstY: currentYOffset,
        );
        currentYOffset += image.height;
      }

      // 4. Encode the final canvas grid back into a physical file layout
      final List<int> pngBytes = img.encodePng(stitchedCanvas);
      
      // Save it temporarily to your app cache folder directory
      final tempDir = await getTemporaryDirectory();
      final String finalPath = '${tempDir.path}/stitched_scroll_ocr_${DateTime.now().millisecondsSinceEpoch}.png';
      
      final File finalFile = File(finalPath);
      await finalFile.writeAsBytes(pngBytes);

      return finalPath;
    } catch (e) {
      // Return null if processing fails
      return null;
    }
  }
}

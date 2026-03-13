import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../models/photo_item.dart';
import '../services/webdav_service.dart';

class PhotoViewer extends StatefulWidget {
  final List<PhotoItem> galleryItems;
  final int initialIndex;
  final WebDavService service;

  const PhotoViewer({
    super.key,
    required this.galleryItems,
    required this.initialIndex,
    required this.service,
  });

  @override
  State<PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<PhotoViewer> {
  late PageController _pageController;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: widget.galleryItems.length,
        itemBuilder: (context, index) {
          return _buildSinglePage(widget.galleryItems[index]);
        },
      ),
    );
  }

  Widget _buildSinglePage(PhotoItem item) {
    return Center(
      child: FutureBuilder<File?>(
        future: _getBestImage(item),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircularProgressIndicator(color: Colors.white),
                SizedBox(height: 10),
                Text(
                  "正在加载原图...",
                  style: TextStyle(color: Colors.white70),
                ),
              ],
            );
          }

          if (snapshot.hasData && snapshot.data != null) {
            return InteractiveViewer(
              child: Image.file(snapshot.data!, fit: BoxFit.contain),
            );
          }

          return const Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.broken_image, color: Colors.white54, size: 50),
              Text("加载失败", style: TextStyle(color: Colors.white54)),
            ],
          );
        },
      ),
    );
  }

  Future<File?> _getBestImage(PhotoItem item) async {
    if (item.asset != null) {
      final file = await item.asset!.file;
      if (file != null && file.existsSync()) {
        return file;
      }
    }

    final tempDir = await getTemporaryDirectory();
    String fileName = item.remoteFileName ?? "${item.id}.jpg";
    if (!fileName.contains('.')) {
      fileName += ".jpg";
    }

    final localPath = '${tempDir.path}/temp_full_$fileName';
    final file = File(localPath);

    if (file.existsSync() && file.lengthSync() > 0) {
      return file;
    }

    try {
      await widget.service.downloadFile("MyPhotos/$fileName", localPath);
      return file;
    } catch (_) {
      return null;
    }
  }
}

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/photo_item.dart';
import '../services/db_helper.dart';
import '../services/webdav_service.dart';

mixin HomeLogicMixin<T extends StatefulWidget> on State<T> {
  final urlCtrl = TextEditingController();
  final userCtrl = TextEditingController();
  final passCtrl = TextEditingController();

  final List<String> logs = [];
  bool isRunning = false;
  Map<String, List<PhotoItem>> groupedItems = {};
  final Set<String> sessionUploadedIds = {};

  bool isSelectionMode = false;
  final Set<String> selectedIds = {};

  void initLogic() {
    _startAutoTasks();
  }

  @override
  void dispose() {
    urlCtrl.dispose();
    userCtrl.dispose();
    passCtrl.dispose();
    super.dispose();
  }

  void addLog(String message) {
    if (!mounted) return;
    setState(() {
      logs.insert(
        0,
        "${DateTime.now().hour}:${DateTime.now().minute.toString().padLeft(2, '0')} $message",
      );
      if (logs.length > 50) {
        logs.removeLast();
      }
    });
  }

  Future<void> _startAutoTasks() async {
    await loadConfig();
    await refreshGallery();
    if (urlCtrl.text.isEmpty) return;
    await _manageCache();
    await syncCloudToLocal();
    await doBackup(silent: true);
  }

  Future<void> connectAndRestoreThenBackup({bool silent = false}) async {
    await saveConfig();
    await syncCloudToLocal(showBusy: true);
    await doBackup(silent: silent);
  }

  Future<void> saveConfigAndRestore() async {
    await saveConfig();
    await syncCloudToLocal(showBusy: true);
  }

  Future<void> loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      urlCtrl.text = prefs.getString('url') ?? "";
      userCtrl.text = prefs.getString('user') ?? "";
      passCtrl.text = prefs.getString('pass') ?? "";
    });
  }

  Future<void> saveConfig() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('url', urlCtrl.text);
    await prefs.setString('user', userCtrl.text);
    await prefs.setString('pass', passCtrl.text);
  }

  Future<void> _manageCache() async {
    try {
      final tempDir = await getTemporaryDirectory();
      final files = tempDir
          .listSync()
          .whereType<File>()
          .where((file) => p.basename(file.path).startsWith('temp_full_'))
          .toList();

      int totalSize = 0;
      for (final file in files) {
        totalSize += await file.length();
      }

      if (totalSize > 200 * 1024 * 1024) {
        files.sort(
          (a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()),
        );
        for (final file in files) {
          file.deleteSync();
        }
      }
    } catch (_) {}
  }

  Future<bool> _ensurePhotoPermission() async {
    final permission = await PhotoManager.requestPermissionExtend();
    return permission.isAuth || permission.hasAccess;
  }

  Future<List<AssetEntity>> _loadAllImageAssets() async {
    final albums = await PhotoManager.getAssetPathList(type: RequestType.image);
    final assetsById = <String, AssetEntity>{};
    const pageSize = 200;

    for (final album in albums) {
      final total = await album.assetCountAsync;
      for (int page = 0; page * pageSize < total; page++) {
        final pageItems = await album.getAssetListPaged(
          page: page,
          size: pageSize,
        );
        for (final asset in pageItems) {
          assetsById[asset.id] = asset;
        }
      }
    }

    return assetsById.values.toList()
      ..sort(
        (a, b) => b.createDateTime.millisecondsSinceEpoch.compareTo(
          a.createDateTime.millisecondsSinceEpoch,
        ),
      );
  }

  String _buildCloudFileName(File file, AssetEntity asset) {
    final timestamp = asset.createDateTime.millisecondsSinceEpoch;
    final originalName = p.basename(file.path);
    return "${timestamp}_$originalName";
  }

  String _buildCloudVirtualId(String fileName) {
    return "cloud_${Uri.encodeComponent(fileName)}";
  }

  Future<void> syncCloudToLocal({bool showBusy = false}) async {
    if (isRunning) return;
    if (showBusy && mounted) {
      setState(() => isRunning = true);
    }
    try {
      if (urlCtrl.text.trim().isEmpty) {
        addLog("请先配置 WebDAV 地址");
        return;
      }

      final service = WebDavService(
        url: urlCtrl.text,
        user: userCtrl.text,
        pass: passCtrl.text,
      );
      final cloudFiles = await service.listRemoteFiles("MyPhotos/");
      if (cloudFiles.isEmpty) {
        await refreshGallery();
        addLog("云端未发现可恢复的照片");
        return;
      }

      final dbRecords = await DbHelper.getAllRecords();
      final localKnownFiles = dbRecords
          .map((record) => record['filename'] as String?)
          .toSet();
      final appDir = await getApplicationDocumentsDirectory();
      bool hasNewData = false;
      int newCount = 0;

      for (final fileName in cloudFiles) {
        if (localKnownFiles.contains(fileName)) continue;

        hasNewData = true;
        newCount++;
        int photoTime;
        try {
          photoTime = int.parse(fileName.split('_').first);
        } catch (_) {
          photoTime = DateTime.now().millisecondsSinceEpoch;
        }

        final virtualId = _buildCloudVirtualId(fileName);
        final thumbPath = '${appDir.path}/thumb_$virtualId.jpg';
        final thumbFile = File(thumbPath);

        if (!thumbFile.existsSync()) {
          try {
            await service.downloadFile("MyPhotos/.thumbs/$fileName", thumbPath);
          } catch (_) {}
        }

        await DbHelper.markAsUploaded(
          virtualId,
          thumbPath: thumbPath,
          time: photoTime,
          filename: fileName,
        );
      }

      await refreshGallery();
      addLog(hasNewData ? "已同步 $newCount 张云端照片" : "云端照片已是最新");
    } catch (e) {
      addLog("同步云端照片失败: $e");
    } finally {
      if (showBusy && mounted) {
        setState(() => isRunning = false);
      }
    }
  }

  Future<void> doBackup({bool silent = false}) async {
    if (isRunning) return;
    setState(() => isRunning = true);
    await saveConfig();

    try {
      if (urlCtrl.text.trim().isEmpty) {
        addLog("请先配置 WebDAV 地址");
        return;
      }

      if (!await _ensurePhotoPermission()) return;

      final service = WebDavService(
        url: urlCtrl.text,
        user: userCtrl.text,
        pass: passCtrl.text,
      );
      await service.ensureFolder("MyPhotos/");
      await service.ensureFolder("MyPhotos/.thumbs/");

      final photos = await _loadAllImageAssets();
      if (photos.isEmpty) return;

      final dbRecords = await DbHelper.getAllRecords();
      final filenameToRecord = <String, Map<String, dynamic>>{
        for (final row in dbRecords)
          if (row['filename'] != null) row['filename'] as String: row,
      };
      final processedCloudFileNames = <String>{};
      final appDir = await getApplicationDocumentsDirectory();
      for (final asset in photos) {
        if (await DbHelper.isUploaded(asset.id)) continue;

        final file = await asset.file;
        if (file == null) continue;

        final timestamp = asset.createDateTime.millisecondsSinceEpoch;
        final cloudFileName = _buildCloudFileName(file, asset);
        final existingRecord = filenameToRecord[cloudFileName];

        if (!processedCloudFileNames.add(cloudFileName) && existingRecord == null) {
          continue;
        }

        if (existingRecord != null) {
          final existingAssetId = existingRecord['asset_id'] as String;
          if (existingAssetId != asset.id) {
            await DbHelper.deleteByAssetId(existingAssetId);
          }

          await DbHelper.markAsUploaded(
            asset.id,
            thumbPath: existingRecord['thumbnail_path'] as String?,
            time: existingRecord['create_time'] as int? ?? timestamp,
            filename: cloudFileName,
          );

          if (mounted) {
            setState(() => sessionUploadedIds.add(asset.id));
          }
          continue;
        }

        final originalName = p.basename(file.path);

        if (!silent) {
          addLog("正在备份: $originalName");
        }

        await service.upload(file, "MyPhotos/$cloudFileName");
        final thumbData = await asset.thumbnailDataWithSize(
          const ThumbnailSize(300, 300),
        );

        String? thumbPath;
        if (thumbData != null) {
          await service.uploadBytes(
            thumbData,
            "MyPhotos/.thumbs/$cloudFileName",
          );
          final thumbFile = File('${appDir.path}/thumb_${asset.id}.jpg')
            ..writeAsBytesSync(thumbData);
          thumbPath = thumbFile.path;
        }

        await DbHelper.markAsUploaded(
          asset.id,
          thumbPath: thumbPath,
          time: timestamp,
          filename: cloudFileName,
        );
        filenameToRecord[cloudFileName] = {
          'asset_id': asset.id,
          'thumbnail_path': thumbPath,
          'create_time': timestamp,
          'filename': cloudFileName,
        };

        if (mounted) {
          setState(() => sessionUploadedIds.add(asset.id));
        }
      }
    } catch (e) {
      addLog("备份失败: $e");
    } finally {
      if (mounted) {
        setState(() => isRunning = false);
        await refreshGallery();
      }
    }
  }

  Future<void> refreshGallery() async {
    List<AssetEntity> localAssets = [];
    if (await _ensurePhotoPermission()) {
      localAssets = await _loadAllImageAssets();
    }

    final localAssetMap = {
      for (final asset in localAssets) asset.id: asset,
    };

    final dbRecords = await DbHelper.getAllRecords();
    final mergedMap = <String, PhotoItem>{};

    for (final row in dbRecords) {
      final id = row['asset_id'] as String;
      mergedMap[id] = PhotoItem(
        id: id,
        asset: localAssetMap[id],
        localThumbPath: row['thumbnail_path'] as String?,
        remoteFileName: row['filename'] as String?,
        createTime: row['create_time'] as int? ?? 0,
        isBackedUp: true,
      );
    }

    for (final asset in localAssets) {
      mergedMap.putIfAbsent(
        asset.id,
        () => PhotoItem(
          id: asset.id,
          asset: asset,
          createTime: asset.createDateTime.millisecondsSinceEpoch,
        ),
      );
    }

    final items = mergedMap.values.toList()
      ..sort((a, b) => b.createTime.compareTo(a.createTime));

    final groups = <String, List<PhotoItem>>{};
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));

    for (final item in items) {
      final date = DateTime.fromMillisecondsSinceEpoch(item.createTime);
      final itemDay = DateTime(date.year, date.month, date.day);
      final key = itemDay == today
          ? "今天"
          : itemDay == yesterday
              ? "昨天"
              : "${date.year}年${date.month}月${date.day}日";
      groups.putIfAbsent(key, () => []).add(item);
    }

    if (mounted) {
      setState(() => groupedItems = groups);
    }
  }

  void toggleSelection(String id) {
    setState(() {
      if (selectedIds.contains(id)) {
        selectedIds.remove(id);
        if (selectedIds.isEmpty) {
          isSelectionMode = false;
        }
      } else {
        selectedIds.add(id);
      }
    });
  }

  void selectAll() {
    final allIds = groupedItems.values.expand((list) => list).map((e) => e.id);
    setState(() => selectedIds.addAll(allIds));
  }

  void exitSelectionMode() {
    if (!mounted) return;
    setState(() {
      isSelectionMode = false;
      selectedIds.clear();
    });
  }

  Future<void> deleteSelectedCloud() async {
    if (selectedIds.isEmpty) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("删除云端备份"),
        content: Text(
          "确定要删除选中的 ${selectedIds.length} 张图片云端备份吗？\n\n本地相册不会删除，但云端文件会被永久移除。",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("取消"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("确认删除", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() => isRunning = true);
    try {
      final service = WebDavService(
        url: urlCtrl.text,
        user: userCtrl.text,
        pass: passCtrl.text,
      );
      final dbRecords = await DbHelper.getAllRecords();
      final idToFilename = {
        for (final row in dbRecords) row['asset_id'] as String: row['filename'],
      };

      int count = 0;
      for (final id in selectedIds) {
        final filename = idToFilename[id] as String?;
        if (filename == null) continue;

        try {
          await service.delete("MyPhotos/$filename");
          try {
            await service.delete("MyPhotos/.thumbs/$filename");
          } catch (_) {}

          final db = await DbHelper.db;
          await db.delete(
            'uploaded_assets',
            where: 'asset_id = ?',
            whereArgs: [id],
          );
          count++;
        } catch (_) {}
      }

      addLog("已删除 $count 个云端备份");
    } catch (e) {
      addLog("删除失败: $e");
    } finally {
      if (mounted) {
        exitSelectionMode();
        setState(() => isRunning = false);
        await refreshGallery();
      }
    }
  }

  Future<void> freeAllLocalSpace() async {
    final idsToDelete = <String>[];
    int count = 0;

    for (final list in groupedItems.values) {
      for (final item in list) {
        if (item.isBackedUp && item.asset != null) {
          idsToDelete.add(item.id);
          count++;
        }
      }
    }

    if (idsToDelete.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("当前没有可释放的已备份本地照片")),
      );
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("释放本地空间"),
        content: Text(
          "检测到 $count 张照片已备份到云端。\n\n确认要从系统相册中删除它们吗？删除后仍可在应用内查看云端缩略图和原图。",
          style: const TextStyle(height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("取消"),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("全部删除"),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      if (!await _ensurePhotoPermission()) {
        addLog("未获得相册权限，无法释放本地空间");
        return;
      }

      final result = await PhotoManager.editor.deleteWithIds(idsToDelete);
      if (result.isNotEmpty) {
        addLog("成功释放 ${result.length} 张照片占用的本地空间");
      }
    } catch (e) {
      addLog("释放失败: $e");
    } finally {
      if (mounted) {
        await refreshGallery();
      }
    }
  }

  Future<void> downloadSelectedToLocal() async {
    if (selectedIds.isEmpty) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("保存到本地"),
        content: Text(
          "确定要将选中的 ${selectedIds.length} 张图片保存到系统相册吗？\n\n如果图片已经存在于本地，会自动跳过。",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("取消"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("开始下载"),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() => isRunning = true);

    int successCount = 0;
    int skipCount = 0;
    int failCount = 0;

    try {
      if (!await _ensurePhotoPermission()) {
        addLog("未获得相册权限，无法保存图片");
        return;
      }

      final service = WebDavService(
        url: urlCtrl.text,
        user: userCtrl.text,
        pass: passCtrl.text,
      );
      final dbRecords = await DbHelper.getAllRecords();
      final idToRecord = {
        for (final row in dbRecords) row['asset_id'] as String: row,
      };
      final idToFilename = {
        for (final row in dbRecords) row['asset_id'] as String: row['filename'],
      };
      final tempDir = await getTemporaryDirectory();
      final allItems = groupedItems.values.expand((items) => items).toList();

      for (final id in selectedIds) {
        final item = allItems.firstWhere(
          (entry) => entry.id == id,
          orElse: () => PhotoItem(id: "none", createTime: 0),
        );

        if (item.asset != null) {
          skipCount++;
          continue;
        }

        final filename = idToFilename[id] as String?;
        if (filename == null) continue;

        try {
          addLog("正在下载: $filename");
          final tempPath = '${tempDir.path}/download_$filename';
          await service.downloadFile("MyPhotos/$filename", tempPath);

          final savedAsset = await PhotoManager.editor.saveImageWithPath(
            tempPath,
            title: filename,
          );

          final existingRecord = idToRecord[id];
          await DbHelper.deleteByAssetId(id);
          await DbHelper.markAsUploaded(
            savedAsset.id,
            thumbPath: existingRecord?['thumbnail_path'] as String?,
            time: existingRecord?['create_time'] as int?,
            filename: filename,
          );

          final tempFile = File(tempPath);
          if (tempFile.existsSync()) {
            tempFile.deleteSync();
          }

          successCount++;
        } catch (e) {
          addLog("下载失败: $e");
          failCount++;
        }
      }

      addLog("下载完成: 成功 $successCount，跳过 $skipCount");
      if (failCount > 0) {
        addLog("下载失败 $failCount 张");
      }
    } catch (e) {
      addLog("批量下载出错: $e");
    } finally {
      if (mounted) {
        exitSelectionMode();
        setState(() => isRunning = false);
        await refreshGallery();
      }
    }
  }
}

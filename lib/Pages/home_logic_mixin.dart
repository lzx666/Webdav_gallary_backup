import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/photo_item.dart';
import '../services/db_helper.dart';
import '../services/webdav_service.dart';

// 定义一个 Mixin，绑定到 State 上
mixin HomeLogicMixin<T extends StatefulWidget> on State<T> {
  // 控制器
  final urlCtrl = TextEditingController();
  final userCtrl = TextEditingController();
  final passCtrl = TextEditingController();

  // 状态变量
  final List<String> logs = [];
  bool isRunning = false;
  Map<String, List<PhotoItem>> groupedItems = {};
  final Set<String> sessionUploadedIds = {};
  
  // 多选状态
  bool isSelectionMode = false;
  final Set<String> selectedIds = {};

  // 初始化任务
  void initLogic() {
    _startAutoTasks();
  }

  void addLog(String m) {
    if (!mounted) return;
    setState(() {
      logs.insert(0, "${DateTime.now().hour}:${DateTime.now().minute} $m");
      if (logs.length > 50) logs.removeLast();
    });
  }

  Future<void> _startAutoTasks() async {
    await loadConfig();
    if (urlCtrl.text.isEmpty) return;
    _manageCache();
    await syncCloudToLocal();
    doBackup(silent: true);
  }

  Future<void> loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
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
      final appDir = await getTemporaryDirectory();
      final files = appDir.listSync().whereType<File>()
          .where((f) => p.basename(f.path).startsWith('temp_full_')).toList();
      int totalSize = 0;
      for (var f in files) totalSize += await f.length();
      if (totalSize > 200 * 1024 * 1024) {
        files.sort((a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()));
        for (var f in files) f.deleteSync();
      }
    } catch (_) {}
  }

  Future<void> syncCloudToLocal() async {
    if (isRunning) return;
    try {
      final service = WebDavService(url: urlCtrl.text, user: userCtrl.text, pass: passCtrl.text);
      List<String> cloudFiles = await service.listRemoteFiles("MyPhotos/");
      if (cloudFiles.isEmpty) return;

      final dbRecords = await DbHelper.getAllRecords();
      final localKnownFiles = dbRecords.map((e) => e['filename'] as String?).toSet();
      final appDir = await getApplicationDocumentsDirectory();
      bool hasNewData = false;

      for (String fileName in cloudFiles) {
        if (!localKnownFiles.contains(fileName)) {
          hasNewData = true;
          int photoTime;
          try {
            String timestampPart = fileName.split('_')[0];
            photoTime = int.parse(timestampPart);
          } catch (_) {
            photoTime = DateTime.now().millisecondsSinceEpoch;
          }

          String vId = "cloud_${fileName.hashCode}";
          String tPath = '${appDir.path}/thumb_$vId.jpg';
          if (!File(tPath).existsSync()) {
            try { await service.downloadFile("MyPhotos/.thumbs/$fileName", tPath); } catch (_) {}
          }
          await DbHelper.markAsUploaded(vId, thumbPath: tPath, time: photoTime, filename: fileName);
        }
      }
      if (hasNewData && mounted) refreshGallery();
    } catch (_) {}
  }

  Future<void> doBackup({bool silent = false}) async {
    if (isRunning) return;
    setState(() => isRunning = true);
    await saveConfig();
    try {
      if (Platform.isAndroid) {
        final ps = await PhotoManager.requestPermissionExtend();
        if (!ps.isAuth) return;
      } else {
        if (!(await Permission.photos.request().isGranted)) return;
      }

      final service = WebDavService(url: urlCtrl.text, user: userCtrl.text, pass: passCtrl.text);
      await service.ensureFolder("MyPhotos/");
      await service.ensureFolder("MyPhotos/.thumbs/");
      final albums = await PhotoManager.getAssetPathList(type: RequestType.image);

      if (albums.isNotEmpty) {
        final photos = await albums.first.getAssetListPaged(page: 0, size: 200);
        final appDir = await getApplicationDocumentsDirectory();
        for (var asset in photos) {
          if (await DbHelper.isUploaded(asset.id)) continue;
          File? file = await asset.file;
          if (file == null) continue;

          int timestamp = asset.createDateTime.millisecondsSinceEpoch;
          String originalName = p.basename(file.path);
          String cloudFileName = "${timestamp}_$originalName";

          if (!silent) addLog("正在备份: $originalName");

          await service.upload(file, "MyPhotos/$cloudFileName");
          final thumbData = await asset.thumbnailDataWithSize(const ThumbnailSize(300, 300));
          String? tPath;
          if (thumbData != null) {
            await service.uploadBytes(thumbData, "MyPhotos/.thumbs/$cloudFileName");
            final tFile = File('${appDir.path}/thumb_${asset.id}.jpg')..writeAsBytesSync(thumbData);
            tPath = tFile.path;
          }
          await DbHelper.markAsUploaded(asset.id, thumbPath: tPath, time: timestamp, filename: cloudFileName);
          if (mounted) setState(() => sessionUploadedIds.add(asset.id));
        }
      }
    } catch (e) {
      addLog("备份失败: $e");
    } finally {
      if (mounted) {
        setState(() => isRunning = false);
        refreshGallery();
      }
    }
  }

  Future<void> refreshGallery() async {
    final albums = await PhotoManager.getAssetPathList(type: RequestType.image);
    List<AssetEntity> localAssets = albums.isNotEmpty
        ? await albums.first.getAssetListPaged(page: 0, size: 5000) : [];
    Map<String, AssetEntity> localAssetMap = {for (var e in localAssets) e.id: e};

    final dbRecords = await DbHelper.getAllRecords();
    Map<String, PhotoItem> mergedMap = {};

    for (var row in dbRecords) {
      String id = row['asset_id'];
      mergedMap[id] = PhotoItem(
        id: id,
        asset: localAssetMap[id],
        localThumbPath: row['thumbnail_path'],
        remoteFileName: row['filename'],
        createTime: row['create_time'] ?? 0,
        isBackedUp: true,
      );
    }
    for (var asset in localAssets) {
      if (!mergedMap.containsKey(asset.id)) {
        mergedMap[asset.id] = PhotoItem(
            id: asset.id, asset: asset, createTime: asset.createDateTime.millisecondsSinceEpoch);
      }
    }

    var list = mergedMap.values.toList()..sort((a, b) => b.createTime.compareTo(a.createTime));
    Map<String, List<PhotoItem>> groups = {};
    DateTime now = DateTime.now();
    DateTime today = DateTime(now.year, now.month, now.day);
    DateTime yesterday = today.subtract(const Duration(days: 1));

    for (var item in list) {
      DateTime date = DateTime.fromMillisecondsSinceEpoch(item.createTime);
      DateTime itemDay = DateTime(date.year, date.month, date.day);
      String key = (itemDay == today) ? "今天" : (itemDay == yesterday ? "昨天" : "${date.year}年${date.month}月${date.day}日");
      groups.putIfAbsent(key, () => []).add(item);
    }
    if (mounted) setState(() => groupedItems = groups);
  }
  
  // --- 多选逻辑 ---
  void toggleSelection(String id) {
    setState(() {
      if (selectedIds.contains(id)) {
        selectedIds.remove(id);
        if (selectedIds.isEmpty) isSelectionMode = false;
      } else {
        selectedIds.add(id);
      }
    });
  }

  void selectAll() {
    final allIds = groupedItems.values.expand((l) => l).map((e) => e.id);
    setState(() => selectedIds.addAll(allIds));
  }

  void exitSelectionMode() {
    setState(() {
      isSelectionMode = false;
      selectedIds.clear();
    });
  }

  // --- 删除云端 ---
  Future<void> deleteSelectedCloud() async {
    if (selectedIds.isEmpty) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("删除云端备份"),
        content: Text("确定要删除选中的 ${selectedIds.length} 张图片的云端备份吗？\n\n注意：本地图片不会被删除，但云端数据将不可恢复。"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("取消")),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("确定删除", style: TextStyle(color: Colors.red))),
        ],
      )
    );
    if (confirm != true) return;

    setState(() => isRunning = true);
    try {
      final service = WebDavService(url: urlCtrl.text, user: userCtrl.text, pass: passCtrl.text);
      final dbRecords = await DbHelper.getAllRecords();
      final idToFilename = {for (var r in dbRecords) r['asset_id']: r['filename']};
      int count = 0;
      for (String id in selectedIds) {
        String? filename = idToFilename[id];
        if (filename != null) {
          try {
            await service.delete("MyPhotos/$filename");
            try { await service.delete("MyPhotos/.thumbs/$filename"); } catch (_) {}
            final db = await DbHelper.db;
            await db.delete('uploaded_assets', where: 'asset_id = ?', whereArgs: [id]);
            count++;
          } catch (_) {}
        }
      }
      addLog("已删除 $count 张云端备份");
    } catch (e) {
      addLog("删除出错: $e");
    } finally {
      if (mounted) {
        setState(() { isRunning = false; exitSelectionMode(); });
        refreshGallery();
      }
    }
  }

  // --- 一键释放本地空间 ---
  Future<void> freeAllLocalSpace() async {
    List<String> idsToDelete = [];
    int count = 0;
    for (var list in groupedItems.values) {
      for (var item in list) {
        if (item.isBackedUp && item.asset != null) {
          idsToDelete.add(item.id);
          count++;
        }
      }
    }

    if (idsToDelete.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("本地照片都还没备份，或者已经释放过了~")));
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("一键释放空间"),
        content: Text("发现 $count 张照片已经备份到云端。\n\n确定要从手机相册中删除它们吗？\n删除后，您仍可以在 App 内查看云端预览图。", style: const TextStyle(height: 1.5)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("取消")),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: Colors.red), onPressed: () => Navigator.pop(ctx, true), child: const Text("全部删除")),
        ],
      )
    );

    if (confirm != true) return;

    try {
      final result = await PhotoManager.editor.deleteWithIds(idsToDelete);
      if (result.isNotEmpty) {
        addLog("成功释放 ${result.length} 张照片空间");
      }
    } catch (e) {
      addLog("释放失败: $e");
    } finally {
      if (mounted) refreshGallery();
    }
  }
}
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/photo_item.dart';
import '../services/db_helper.dart';
import '../services/webdav_service.dart';
import '../widgets/smart_thumbnail.dart';
import 'photo_view_page.dart';

class SuperBackupPage extends StatefulWidget {
  const SuperBackupPage({super.key});
  @override
  State<SuperBackupPage> createState() => _SuperBackupPageState();
}

class _SuperBackupPageState extends State<SuperBackupPage> {
  final _urlCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();

  final List<String> _logs = [];
  bool isRunning = false;
  Map<String, List<PhotoItem>> _groupedItems = {};
  final Set<String> _sessionUploadedIds = {};

  // 多选模式状态
  bool _isSelectionMode = false;
  final Set<String> _selectedIds = {};

  int _crossAxisCount = 4;
  double _scale = 1.0;
  int _pointerCount = 0;

  @override
  void initState() {
    super.initState();
    _startAutoTasks();
  }

  void addLog(String m) {
    if (!mounted) return;
    setState(() {
      _logs.insert(0, "${DateTime.now().hour}:${DateTime.now().minute} $m");
      if (_logs.length > 50) {
        _logs.removeLast();
      }
    });
  }

  Future<void> _startAutoTasks() async {
    await _loadConfig();
    if (_urlCtrl.text.isEmpty) {
      return;
    }
    _manageCache();
    await _syncCloudToLocal();
    doBackup(silent: true);
  }

  Future<void> _loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _urlCtrl.text = prefs.getString('url') ?? "";
      _userCtrl.text = prefs.getString('user') ?? "";
      _passCtrl.text = prefs.getString('pass') ?? "";
    });
  }

  Future<void> _saveConfig() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('url', _urlCtrl.text);
    await prefs.setString('user', _userCtrl.text);
    await prefs.setString('pass', _passCtrl.text);
  }

  Future<void> _manageCache() async {
    try {
      final appDir = await getTemporaryDirectory();
      final files = appDir
          .listSync()
          .whereType<File>()
          .where((f) => p.basename(f.path).startsWith('temp_full_'))
          .toList();
      int totalSize = 0;
      for (var f in files) {
        totalSize += await f.length();
      }
      if (totalSize > 200 * 1024 * 1024) {
        files.sort(
          (a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()),
        );
        for (var f in files) {
          f.deleteSync();
        }
      }
    } catch (_) {}
  }

  Future<void> _syncCloudToLocal() async {
    if (isRunning) {
      return;
    }
    try {
      final service = WebDavService(
        url: _urlCtrl.text,
        user: _userCtrl.text,
        pass: _passCtrl.text,
      );
      List<String> cloudFiles = await service.listRemoteFiles("MyPhotos/");
      if (cloudFiles.isEmpty) {
        return;
      }

      final dbRecords = await DbHelper.getAllRecords();
      final localKnownFiles = dbRecords
          .map((e) => e['filename'] as String?)
          .toSet();
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
            try {
              await service.downloadFile("MyPhotos/.thumbs/$fileName", tPath);
            } catch (_) {
              // 缩略图下载失败不阻断流程
            }
          }
          await DbHelper.markAsUploaded(
            vId,
            thumbPath: tPath,
            time: photoTime,
            filename: fileName,
          );
        }
      }
      if (hasNewData && mounted) {
        _refreshGallery();
      }
    } catch (_) {}
  }

  Future<void> doBackup({bool silent = false}) async {
    if (isRunning) {
      return;
    }
    setState(() => isRunning = true);
    await _saveConfig();
    try {
      if (Platform.isAndroid) {
        final ps = await PhotoManager.requestPermissionExtend();
        if (!ps.isAuth) {
          return;
        }
      } else {
        if (!(await Permission.photos.request().isGranted)) {
          return;
        }
      }

      final service = WebDavService(
        url: _urlCtrl.text,
        user: _userCtrl.text,
        pass: _passCtrl.text,
      );
      await service.ensureFolder("MyPhotos/");
      await service.ensureFolder("MyPhotos/.thumbs/");
      final albums = await PhotoManager.getAssetPathList(
        type: RequestType.image,
      );

      if (albums.isNotEmpty) {
        final photos = await albums.first.getAssetListPaged(page: 0, size: 200);
        final appDir = await getApplicationDocumentsDirectory();
        for (var asset in photos) {
          if (await DbHelper.isUploaded(asset.id)) {
            continue;
          }
          File? file = await asset.file;
          if (file == null) {
            continue;
          }

          int timestamp = asset.createDateTime.millisecondsSinceEpoch;
          String originalName = p.basename(file.path);
          String cloudFileName = "${timestamp}_$originalName";

          if (!silent) {
            addLog("正在备份: $originalName");
          }

          await service.upload(file, "MyPhotos/$cloudFileName");

          final thumbData = await asset.thumbnailDataWithSize(
            const ThumbnailSize(300, 300),
          );
          String? tPath;
          if (thumbData != null) {
            await service.uploadBytes(
              thumbData,
              "MyPhotos/.thumbs/$cloudFileName",
            );
            final tFile = File('${appDir.path}/thumb_${asset.id}.jpg')
              ..writeAsBytesSync(thumbData);
            tPath = tFile.path;
          }
          await DbHelper.markAsUploaded(
            asset.id,
            thumbPath: tPath,
            time: timestamp,
            filename: cloudFileName,
          );
          if (mounted) {
            setState(() => _sessionUploadedIds.add(asset.id));
          }
        }
      }
    } catch (e) {
      addLog("备份失败: $e");
    } finally {
      if (mounted) {
        setState(() => isRunning = false);
        _refreshGallery();
      }
    }
  }

  Future<void> _refreshGallery() async {
    final albums = await PhotoManager.getAssetPathList(type: RequestType.image);
    List<AssetEntity> localAssets = albums.isNotEmpty
        ? await albums.first.getAssetListPaged(page: 0, size: 5000)
        : [];
    Map<String, AssetEntity> localAssetMap = {
      for (var e in localAssets) e.id: e,
    };

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
          id: asset.id,
          asset: asset,
          createTime: asset.createDateTime.millisecondsSinceEpoch,
        );
      }
    }

    var list = mergedMap.values.toList()
      ..sort((a, b) => b.createTime.compareTo(a.createTime));
    Map<String, List<PhotoItem>> groups = {};
    DateTime now = DateTime.now();
    DateTime today = DateTime(now.year, now.month, now.day);
    DateTime yesterday = today.subtract(const Duration(days: 1));

    for (var item in list) {
      DateTime date = DateTime.fromMillisecondsSinceEpoch(item.createTime);
      DateTime itemDay = DateTime(date.year, date.month, date.day);
      String key;
      if (itemDay == today) {
        key = "今天";
      } else if (itemDay == yesterday) {
        key = "昨天";
      } else {
        key = "${date.year}年${date.month}月${date.day}日";
      }
      groups.putIfAbsent(key, () => []).add(item);
    }
    if (mounted) {
      setState(() => _groupedItems = groups);
    }
  }

  Future<void> _deleteSelectedCloud() async {
    if (_selectedIds.isEmpty) {
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("删除云端备份"),
        content: Text(
          "确定要删除选中的 ${_selectedIds.length} 张图片的云端备份吗？\n\n注意：本地图片不会被删除，但云端数据将不可恢复。",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("取消"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("确定删除", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm != true) {
      return;
    }

    setState(() => isRunning = true);
    try {
      final service = WebDavService(
        url: _urlCtrl.text,
        user: _userCtrl.text,
        pass: _passCtrl.text,
      );
      final dbRecords = await DbHelper.getAllRecords();
      final idToFilename = {
        for (var r in dbRecords) r['asset_id']: r['filename'],
      };

      int count = 0;
      for (String id in _selectedIds) {
        String? filename = idToFilename[id];
        if (filename != null) {
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
          } catch (e) {
            addLog("删除失败: $filename");
          }
        }
      }
      addLog("已删除 $count 张云端备份");
    } catch (e) {
      addLog("删除出错: $e");
    } finally {
      if (mounted) {
        setState(() {
          isRunning = false;
          _isSelectionMode = false;
          _selectedIds.clear();
        });
        _refreshGallery();
      }
    }
  }

  Future<void> _freeAllLocalSpace() async {
    // 1. 扫描所有符合条件的照片：已备份 + 本地有原图
    List<String> idsToDelete = [];
    int count = 0;

    // 遍历所有分组
    for (var list in _groupedItems.values) {
      for (var item in list) {
        if (item.isBackedUp && item.asset != null) {
          idsToDelete.add(item.id);
          count++;
        }
      }
    }

    if (idsToDelete.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("本地照片都还没备份，或者已经释放过了~")));
      return;
    }

    // 2. 弹出确认框
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("一键释放空间"),
        content: Text(
          "发现 $count 张照片已经备份到云端。\n\n"
          "确定要从手机相册中删除它们吗？\n"
          "删除后，您仍可以在 App 内查看云端预览图。",
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

    // 3. 执行批量删除
    try {
      // 调用 PhotoManager 删除 (系统会再次弹窗确认，这是 iOS/Android 的安全限制，无法绕过)
      final result = await PhotoManager.editor.deleteWithIds(idsToDelete);

      if (result.isNotEmpty) {
        addLog("成功释放 ${result.length} 张照片空间");
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("已释放 ${result.length} 张照片")));
      }
    } catch (e) {
      addLog("释放失败: $e");
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("释放失败: $e")));
    } finally {
      if (mounted) {
        _refreshGallery(); // 刷新界面，让它们变成“云端状态”
      }
    }
  }

  Future<void> _freeLocalSpace() async {
    if (_selectedIds.isEmpty) {
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("释放本地空间"),
        content: Text(
          "确定要从手机中删除选中的 ${_selectedIds.length} 张图片吗？\n\n注意：\n1. 仅删除【已备份】的本地原图。\n2. 未备份的图片将被跳过。\n3. 删除后您仍可在 App 内查看云端预览图。",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("取消"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("确定释放", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm != true) {
      return;
    }

    List<String> idsToDelete = [];
    List<PhotoItem> allItems = _groupedItems.values.expand((e) => e).toList();

    for (String id in _selectedIds) {
      final item = allItems.firstWhere(
        (e) => e.id == id,
        orElse: () => PhotoItem(id: "none", createTime: 0),
      );
      if (item.id != "none" && item.isBackedUp && item.asset != null) {
        idsToDelete.add(item.id);
      }
    }

    if (idsToDelete.isEmpty) {
      addLog("没有可释放的图片");
      return;
    }

    try {
      final result = await PhotoManager.editor.deleteWithIds(idsToDelete);
      if (result.isNotEmpty) {
        addLog("已释放 ${result.length} 张本地图片");
      }
    } catch (e) {
      addLog("释放失败: $e");
    } finally {
      if (mounted) {
        setState(() {
          _isSelectionMode = false;
          _selectedIds.clear();
        });
        _refreshGallery();
      }
    }
  }

  void _handleScaleEnd() {
    int newCount = _crossAxisCount;
    if (_scale > 1.2) {
      newCount--;
    } else if (_scale < 0.8) {
      newCount++;
    }
    newCount = newCount.clamp(2, 6);
    if (newCount != _crossAxisCount) {
      HapticFeedback.selectionClick();
    }
    setState(() {
      _crossAxisCount = newCount;
      _scale = 1.0;
    });
  }

  void _toggleSelection(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
        if (_selectedIds.isEmpty) {
          _isSelectionMode = false;
        }
      } else {
        _selectedIds.add(id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      floatingActionButton: (_isSelectionMode || isRunning)
          ? null
          : FloatingActionButton.extended(
              onPressed: () => doBackup(silent: false),
              icon: const Icon(Icons.backup_outlined),
              label: const Text("立即备份"),
            ),
      bottomNavigationBar: _isSelectionMode
          ? BottomAppBar(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center, // 居中
                children: [
                  TextButton.icon(
                    onPressed: _deleteSelectedCloud,
                    icon: const Icon(Icons.cloud_off, color: Colors.red),
                    label: const Text(
                      "从云端删除选中",
                      style: TextStyle(color: Colors.red, fontSize: 16),
                    ),
                  ),
                ],
              ),
            )
          : null,
      body: Listener(
        onPointerDown: (_) => setState(() => _pointerCount++),
        onPointerUp: (_) => setState(() => _pointerCount--),
        onPointerCancel: (_) => setState(() => _pointerCount = 0),
        child: GestureDetector(
          onScaleUpdate: (d) {
            if (_pointerCount >= 2) {
              setState(() => _scale = d.scale.clamp(0.5, 2.0));
            }
          },
          onScaleEnd: (_) => _handleScaleEnd(),
          child: Transform.scale(
            scale: _scale,
            child: CustomScrollView(
              physics: (_pointerCount >= 2 || _scale != 1.0)
                  ? const NeverScrollableScrollPhysics()
                  : const BouncingScrollPhysics(),
              slivers: [
                SliverAppBar(
                  pinned: true,
                  floating: true,
                  snap: true,
                  backgroundColor: theme.colorScheme.surface,
                  surfaceTintColor: theme.colorScheme.surfaceTint,
                  title: _isSelectionMode
                      ? Text("已选 ${_selectedIds.length} 张")
                      : const Text(
                          "相册",
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                  leading: _isSelectionMode
                      ? IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(() {
                            _isSelectionMode = false;
                            _selectedIds.clear();
                          }),
                        )
                      : null,
                  // 修改 SliverAppBar 的 actions
                  actions: [
                    if (!_isSelectionMode) ...[
                      IconButton(
                        onPressed: _syncCloudToLocal,
                        icon: const Icon(Icons.sync),
                      ),
                      // 👇 新增：弹出菜单
                      PopupMenuButton<String>(
                        onSelected: (value) {
                          if (value == 'settings') _showSettingsPanel();
                          if (value == 'free_space')
                            _freeAllLocalSpace(); // 一键释放入口
                        },
                        itemBuilder: (BuildContext context) =>
                            <PopupMenuEntry<String>>[
                              const PopupMenuItem<String>(
                                value: 'free_space',
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.cleaning_services_outlined,
                                      color: Colors.black87,
                                    ),
                                    SizedBox(width: 12),
                                    Text('释放本地空间'),
                                  ],
                                ),
                              ),
                              const PopupMenuDivider(),
                              const PopupMenuItem<String>(
                                value: 'settings',
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.settings_outlined,
                                      color: Colors.black87,
                                    ),
                                    SizedBox(width: 12),
                                    Text('连接设置'),
                                  ],
                                ),
                              ),
                            ],
                        icon: const Icon(Icons.more_vert), // 变成三个点
                      ),
                    ] else ...[
                      IconButton(
                        onPressed: () {
                          final allIds = _groupedItems.values
                              .expand((l) => l)
                              .map((e) => e.id);
                          setState(() => _selectedIds.addAll(allIds));
                        },
                        icon: const Icon(Icons.select_all),
                      ),
                    ],
                    const SizedBox(width: 8),
                  ],
                ),

                if (isRunning)
                  const SliverToBoxAdapter(child: LinearProgressIndicator()),

                if (_logs.isNotEmpty && !_isSelectionMode)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                      child: Text(
                        _logs.first,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ),
                  ),

                ..._buildMD3Content(theme),

                const SliverToBoxAdapter(child: SizedBox(height: 120)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildMD3Content(ThemeData theme) {
    List<Widget> slivers = [];
    _groupedItems.forEach((date, items) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
            child: Text(
              date,
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      );
      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: _crossAxisCount,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            delegate: SliverChildBuilderDelegate(
              (_, i) => _buildMD3PhotoTile(items[i], items, i, theme),
              childCount: items.length,
            ),
          ),
        ),
      );
    });
    return slivers;
  }

  Widget _buildMD3PhotoTile(
    PhotoItem item,
    List<PhotoItem> group,
    int index,
    ThemeData theme,
  ) {
    bool selected = _selectedIds.contains(item.id);

    return GestureDetector(
      onLongPress: () {
        if (!_isSelectionMode) {
          setState(() {
            _isSelectionMode = true;
            _selectedIds.add(item.id);
            HapticFeedback.selectionClick();
          });
        }
      },
      onTap: () {
        if (_isSelectionMode) {
          _toggleSelection(item.id);
        } else {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => PhotoViewer(
                galleryItems: group,
                initialIndex: index,
                service: WebDavService(
                  url: _urlCtrl.text,
                  user: _userCtrl.text,
                  pass: _passCtrl.text,
                ),
              ),
            ),
          );
        }
      },
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: selected
              ? Border.all(color: theme.colorScheme.primary, width: 3)
              : null,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05), // ✅ 修复：使用 withValues
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Transform.scale(
              scale: selected ? 0.9 : 1.0,
              child: SmartThumbnail(
                item: item,
                service: WebDavService(
                  url: _urlCtrl.text,
                  user: _userCtrl.text,
                  pass: _passCtrl.text,
                ),
              ),
            ),

            if (_isSelectionMode)
              Positioned(
                top: 8,
                left: 8,
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: selected
                        ? theme.colorScheme.primary
                        : Colors.black26,
                    border: Border.all(color: Colors.white, width: 1.5),
                  ),
                  child: const Padding(
                    padding: EdgeInsets.all(4.0),
                    child: Icon(Icons.check, size: 12, color: Colors.white),
                  ),
                ),
              ),

            if (item.isBackedUp && !_isSelectionMode)
              Positioned(
                top: 8,
                right: 8,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    // ✅ 修复：使用 withValues
                    color: theme.colorScheme.primaryContainer.withValues(
                      alpha: 0.8,
                    ),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    item.asset == null ? Icons.cloud_outlined : Icons.done,
                    size: 14,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showSettingsPanel() {
    final theme = Theme.of(context);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => Container(
        padding: EdgeInsets.fromLTRB(
          24,
          24,
          24,
          MediaQuery.of(context).viewInsets.bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("连接设置", style: theme.textTheme.headlineSmall),
            const SizedBox(height: 24),
            TextField(
              controller: _urlCtrl,
              decoration: const InputDecoration(
                labelText: "WebDAV URL",
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _userCtrl,
              decoration: const InputDecoration(
                labelText: "用户名",
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _passCtrl,
              decoration: const InputDecoration(
                labelText: "密码",
                border: OutlineInputBorder(),
              ),
              obscureText: true,
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  Navigator.pop(context);
                  doBackup(silent: false);
                },
                child: const Text("保存并备份"),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

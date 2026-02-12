import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'db_helper.dart';
import 'webdav_service.dart';
import 'photo_view_page.dart';

void main() {
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
  ));
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    themeMode: ThemeMode.light,
    home: SuperBackupPage(),
  ));
}

class SuperBackupPage extends StatefulWidget {
  const SuperBackupPage({super.key});
  @override
  State<SuperBackupPage> createState() => _SuperBackupPageState();
}

class _SuperBackupPageState extends State<SuperBackupPage> {
  final _urlCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  
  List<String> _logs = [];
  bool isRunning = false;
  
  Map<String, List<PhotoItem>> _groupedItems = {}; 
  int _crossAxisCount = 3; 
  int _startColCount = 3; 

  final Set<String> _sessionUploadedIds = {};

  @override
  void initState() {
    super.initState();
    _startAutoTasks();
  }

  // --- 逻辑部分保持不变 ---
  Future<void> _startAutoTasks() async {
    await _loadConfig();
    if (_urlCtrl.text.isEmpty) return;
    _manageCache();
    await _syncDatabase(isRestore: true, silent: true);
    doBackup(silent: true);
  }

  _loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _urlCtrl.text = prefs.getString('url') ?? "";
        _userCtrl.text = prefs.getString('user') ?? "";
        _passCtrl.text = prefs.getString('pass') ?? "";
      });
    }
  }

  _saveConfig() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('url', _urlCtrl.text);
    await prefs.setString('user', _userCtrl.text);
    await prefs.setString('pass', _passCtrl.text);
  }

  void addLog(String m) {
    if (!mounted) return;
    setState(() {
      _logs.insert(0, "${DateTime.now().hour}:${DateTime.now().minute} $m"); 
      if (_logs.length > 50) _logs.removeLast();
    });
  }

  Future<void> _manageCache() async {
    try {
      final appDir = await getTemporaryDirectory();
      if (!appDir.existsSync()) return;
      final files = appDir.listSync().whereType<File>().where((f) => p.basename(f.path).startsWith('temp_')).toList();
      int totalSize = 0;
      for (var f in files) totalSize += await f.length();
      const int maxCacheSize = 100 * 1024 * 1024;
      if (totalSize > maxCacheSize) {
        files.sort((a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()));
        for (var f in files) {
          f.deleteSync();
          if (totalSize < (maxCacheSize * 0.8)) break;
        }
      }
    } catch (e) {}
  }

  Future<void> _refreshGallery() async {
    if (!mounted) return;
    final albums = await PhotoManager.getAssetPathList(type: RequestType.image);
    List<AssetEntity> localAssets = [];
    if (albums.isNotEmpty) {
      localAssets = await albums.first.getAssetListPaged(page: 0, size: 500);
    }
    final dbRecords = await DbHelper.getAllRecords();
    Map<String, PhotoItem> mergedMap = {};
    for (var row in dbRecords) {
      String id = row['asset_id'];
      mergedMap[id] = PhotoItem(
        id: id,
        localThumbPath: row['thumbnail_path'],
        remoteFileName: row['filename'],
        createTime: row['create_time'] ?? 0,
        isBackedUp: true,
      );
    }
    for (var asset in localAssets) {
      bool backed = mergedMap.containsKey(asset.id);
      mergedMap[asset.id] = PhotoItem(
        id: asset.id,
        asset: asset,
        localThumbPath: backed ? mergedMap[asset.id]?.localThumbPath : null,
        remoteFileName: backed ? mergedMap[asset.id]?.remoteFileName : null,
        createTime: asset.createDateTime.millisecondsSinceEpoch,
        isBackedUp: backed,
      );
    }
    var list = mergedMap.values.toList();
    list.sort((a, b) => b.createTime.compareTo(a.createTime));
    Map<String, List<PhotoItem>> groups = {};
    for (var item in list) {
      DateTime date = DateTime.fromMillisecondsSinceEpoch(item.createTime);
      String key = "${date.year}年${date.month}月"; 
      if (!groups.containsKey(key)) groups[key] = [];
      groups[key]!.add(item);
    }
    if (mounted) setState(() => _groupedItems = groups);
  }

  Future<void> _syncDatabase({bool isRestore = false, bool silent = false}) async {
    if (isRunning) return;
    if (mounted) setState(() => isRunning = true);
    try {
      final service = WebDavService(url: _urlCtrl.text, user: _userCtrl.text, pass: _passCtrl.text);
      await service.ensureFolder("MyPhotos/");
      final dbPath = await DbHelper.getDbPath();
      if (isRestore) {
        try {
          await DbHelper.close(); 
          await service.downloadFile("MyPhotos/backup_records.db", dbPath);
          await _refreshGallery(); 
        } catch (e) {}
      } else {
        if (File(dbPath).existsSync()) await service.upload(File(dbPath), "MyPhotos/backup_records.db");
      }
    } finally {
      if (mounted) setState(() => isRunning = false);
    }
  }

  Future<void> doBackup({bool silent = false}) async {
    if (isRunning) return;
    if (mounted) setState(() => isRunning = true);
    await _saveConfig();
    try {
      final service = WebDavService(url: _urlCtrl.text, user: _userCtrl.text, pass: _passCtrl.text);
      if (!(await Permission.photos.request().isGranted)) return;
      await service.ensureFolder("MyPhotos/");
      await service.ensureFolder("MyPhotos/.thumbs/");
      final albums = await PhotoManager.getAssetPathList(type: RequestType.image);
      if (albums.isNotEmpty) {
        final photos = await albums.first.getAssetListPaged(page: 0, size: 50);
        final appDir = await getApplicationDocumentsDirectory();
        int count = 0;
        for (var asset in photos) {
          if (await DbHelper.isUploaded(asset.id)) continue;
          File? file = await asset.file;
          if (file == null) continue;
          String fileName = p.basename(file.path);
          await service.upload(file, "MyPhotos/$fileName");
          final thumbData = await asset.thumbnailDataWithSize(const ThumbnailSize(200, 200));
          String? localPath;
          if (thumbData != null) {
            await service.uploadBytes(thumbData, "MyPhotos/.thumbs/$fileName");
            final thumbFile = File('${appDir.path}/thumb_${asset.id}.jpg');
            await thumbFile.writeAsBytes(thumbData);
            localPath = thumbFile.path;
          }
          await DbHelper.markAsUploaded(asset.id, thumbPath: localPath, time: asset.createDateTime.millisecondsSinceEpoch, filename: fileName);
          if (mounted) setState(() => _sessionUploadedIds.add(asset.id));
          count++;
          if (count % 3 == 0) await _refreshGallery(); 
        }
        if (count > 0) {
          final dbFile = File(await DbHelper.getDbPath());
          await service.upload(dbFile, "MyPhotos/backup_records.db");
        }
      }
    } finally {
      if (mounted) {
        setState(() => isRunning = false);
        _refreshGallery();
      }
    }
  }

  // --- UI 构建部分：优化重点 ---

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      floatingActionButton: FloatingActionButton(
        onPressed: isRunning ? null : () => doBackup(),
        backgroundColor: isRunning ? Colors.grey : Colors.blueAccent,
        child: isRunning 
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
            : const Icon(Icons.cloud_upload),
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.opaque, // 确保空白区域也能响应手势
        onScaleStart: (details) => _startColCount = _crossAxisCount,
        onScaleUpdate: (details) {
          if (details.pointerCount >= 2) {
            // 使用 sensitivity 增加灵敏度平滑度
            final double sensitivity = 0.5; 
            final newCount = (_startColCount / details.scale).round().clamp(2, 6);
            if (newCount != _crossAxisCount) {
              setState(() => _crossAxisCount = newCount);
            }
          }
        },
        child: CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: [
            SliverAppBar(
              expandedHeight: 100.0,
              floating: true,
              pinned: true,
              backgroundColor: Colors.white,
              flexibleSpace: FlexibleSpaceBar(
                titlePadding: const EdgeInsets.only(left: 16, bottom: 16),
                title: const Text("TimeAlbum", style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
              ),
              actions: [IconButton(icon: const Icon(Icons.settings, color: Colors.black87), onPressed: _showSettingsPanel)],
            ),
            
            if (_groupedItems.isEmpty)
              const SliverFillRemaining(child: Center(child: Text("正在加载或暂无照片...", style: TextStyle(color: Colors.grey))))
            else
              // 【核心修改点】扁平化 Sliver 结构，不再嵌套 GridView
              ..._buildSliverContent(),
              
            const SliverToBoxAdapter(child: SizedBox(height: 100)), // 底部留白
          ],
        ),
      ),
    );
  }

  List<Widget> _buildSliverContent() {
    List<Widget> slivers = [];
    for (var entry in _groupedItems.entries) {
      // 1. 日期标题
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 10),
            child: Text(entry.key, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          ),
        ),
      );
      // 2. 该月份的照片网格
      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: _crossAxisCount, // 动态列数
              crossAxisSpacing: 4,
              mainAxisSpacing: 4,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, i) => _buildPhotoTile(entry.value[i], entry.value, i),
              childCount: entry.value.length,
            ),
          ),
        ),
      );
    }
    return slivers;
  }

  Widget _buildPhotoTile(PhotoItem item, List<PhotoItem> groupList, int index) {
    return GestureDetector(
      onTap: () {
        final service = WebDavService(url: _urlCtrl.text, user: _userCtrl.text, pass: _passCtrl.text);
        Navigator.push(context, MaterialPageRoute(builder: (_) => PhotoViewer(
          galleryItems: groupList, 
          initialIndex: index,
          service: service
        )));
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Stack(
          fit: StackFit.expand,
          children: [
            SmartThumbnail(
              item: item, 
              service: WebDavService(url: _urlCtrl.text, user: _userCtrl.text, pass: _passCtrl.text)
            ),
            if (_sessionUploadedIds.contains(item.id))
              Positioned(
                right: 5, top: 5, 
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(color: Colors.white.withOpacity(0.8), shape: BoxShape.circle),
                  child: const Icon(Icons.cloud_upload, color: Colors.blue, size: 14),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // --- 配置面板逻辑 ---
  void _showSettingsPanel() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        builder: (_, controller) => Container(
          decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
          padding: const EdgeInsets.all(20),
          child: ListView(
            controller: controller,
            children: [
              _buildTextField(_urlCtrl, "WebDAV 地址", Icons.link),
              const SizedBox(height: 10),
              _buildTextField(_userCtrl, "用户名", Icons.person),
              const SizedBox(height: 10),
              _buildTextField(_passCtrl, "密码", Icons.lock, isObscure: true),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildActionButton(Icons.cloud_sync, "同步", Colors.blue, () => doBackup()),
                  _buildActionButton(Icons.restore, "恢复", Colors.orange, () => _syncDatabase(isRestore: true)),
                ],
              ),
              const SizedBox(height: 20),
              Container(
                height: 150,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: Colors.grey[100], borderRadius: BorderRadius.circular(10)),
                child: ListView.builder(
                  itemCount: _logs.length,
                  itemBuilder: (ctx, i) => Text(_logs[i], style: const TextStyle(fontSize: 12, color: Colors.black54)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTextField(TextEditingController ctrl, String label, IconData icon, {bool isObscure = false}) {
    return TextField(
      controller: ctrl,
      obscureText: isObscure,
      decoration: InputDecoration(labelText: label, prefixIcon: Icon(icon), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12))),
    );
  }

  Widget _buildActionButton(IconData icon, String label, Color color, VoidCallback onTap) {
    return InkWell(
      onTap: () { Navigator.pop(context); onTap(); },
      child: Column(children: [CircleAvatar(backgroundColor: color.withOpacity(0.1), child: Icon(icon, color: color)), Text(label)]),
    );
  }
}

// SmartThumbnail 保持不变
class SmartThumbnail extends StatefulWidget {
  final PhotoItem item;
  final WebDavService service;
  const SmartThumbnail({super.key, required this.item, required this.service});
  @override
  State<SmartThumbnail> createState() => _SmartThumbnailState();
}

class _SmartThumbnailState extends State<SmartThumbnail> {
  File? _imageFile;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _checkAndLoad();
  }

  Future<void> _checkAndLoad() async {
    if (widget.item.asset != null) return;
    final appDir = await getApplicationDocumentsDirectory();
    final targetPath = '${appDir.path}/thumb_${widget.item.id}.jpg';
    final file = File(targetPath);
    if (file.existsSync()) {
      if (mounted) setState(() => _imageFile = file);
      return;
    }
    if (mounted) setState(() => _isLoading = true);
    try {
      String remoteName = widget.item.remoteFileName ?? "${widget.item.id}.jpg";
      if (!remoteName.contains('.')) remoteName += ".jpg";
      await widget.service.downloadFile("MyPhotos/.thumbs/$remoteName", targetPath);
      await DbHelper.markAsUploaded(widget.item.id, thumbPath: targetPath, time: widget.item.createTime, filename: widget.item.remoteFileName);
      if (mounted) setState(() { _imageFile = File(targetPath); _isLoading = false; });
    } catch (e) {
      if (mounted) setState(() { _isLoading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.item.asset != null) {
      return FutureBuilder<Uint8List?>(
        future: widget.item.asset!.thumbnailDataWithSize(const ThumbnailSize(200, 200)),
        builder: (_, s) => s.hasData ? Image.memory(s.data!, fit: BoxFit.cover) : Container(color: Colors.grey[200]),
      );
    }
    if (_imageFile != null) return Image.file(_imageFile!, fit: BoxFit.cover);
    return Container(color: Colors.grey[200], child: _isLoading ? const Center(child: SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2))) : const Icon(Icons.cloud_download, color: Colors.white));
  }
}
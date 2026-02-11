import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'db_helper.dart';
import 'webdav_service.dart';

void main() => runApp(const MaterialApp(home: SuperBackupPage()));

class SuperBackupPage extends StatefulWidget {
  const SuperBackupPage({super.key});
  @override
  State<SuperBackupPage> createState() => _SuperBackupPageState();
}

class _SuperBackupPageState extends State<SuperBackupPage> {
  final _urlCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  String log = "等待操作...";
  bool isRunning = false;

  @override
  void initState() {
    super.initState();
    _loadConfig(); // 启动时加载保存的密码
  }

  _loadConfig() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      _urlCtrl.text = p.getString('url') ?? "";
      _userCtrl.text = p.getString('user') ?? "";
      _passCtrl.text = p.getString('pass') ?? "";
    });
  }

  _saveConfig() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('url', _urlCtrl.text);
    await p.setString('user', _userCtrl.text);
    await p.setString('pass', _passCtrl.text);
  }

  void addLog(String m) => setState(() => log += "\n${m}");

  Future<void> doBackup() async {
    if (isRunning) return;
    setState(() { isRunning = true; log = "🚀 开始任务..."; });
    await _saveConfig();

    try {
      // 1. 初始化服务
      final service = WebDavService(url: _urlCtrl.text, user: _userCtrl.text, pass: _passCtrl.text);
      
      // 2. 权限
      if (!(await Permission.photos.request().isGranted)) return addLog("❌ 无相册权限");

      // 3. 自动创建文件夹 (MKCOL)
      addLog("检查远程文件夹...");
      await service.ensureFolder("MyPhotos/");

      // 4. 获取相册
      final albums = await PhotoManager.getAssetPathList(type: RequestType.image);
      final photos = await albums.first.getAssetListPaged(page: 0, size: 50);
      
      int count = 0;
      for (var asset in photos) {
        // 5. 增量判断 (SQLite)
        if (await DbHelper.isUploaded(asset.id)) continue;

        File? file = await asset.file;
        if (file == null) continue;

        String fileName = path.basename(file.path);
        addLog("正在传: $fileName");
        
        // 6. 调用解耦后的上传服务
        await service.upload(file, "MyPhotos/$fileName");
        
        await DbHelper.markAsUploaded(asset.id);
        count++;
      }
      addLog("✅ 完成！新上传 $count 张");
    } catch (e) {
      addLog("❌ 失败: $e");
    } finally {
      setState(() => isRunning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("WebDAV 完全体备份")),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(controller: _urlCtrl, decoration: const InputDecoration(labelText: "服务器地址")),
            TextField(controller: _userCtrl, decoration: const InputDecoration(labelText: "账号")),
            TextField(controller: _passCtrl, decoration: const InputDecoration(labelText: "密码"), obscureText: true),
            const SizedBox(height: 20),
            ElevatedButton(onPressed: isRunning ? null : doBackup, child: Text(isRunning ? "同步中..." : "立即增量同步")),
            const Divider(),
            Expanded(child: SingleChildScrollView(child: Text(log, style: const TextStyle(fontSize: 12, color: Colors.blueGrey)))),
          ],
        ),
      ),
    );
  }
}
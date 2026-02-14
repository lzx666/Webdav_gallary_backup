import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';

class WebDavService {
  final String url;
  final String user;
  final String pass;
  late Dio _dio;

  WebDavService({required this.url, required this.user, required this.pass}) {
    String cleanUrl = url.endsWith('/') ? url : '$url/';
    _dio = Dio(BaseOptions(
      baseUrl: cleanUrl,
      headers: {
        "Authorization": "Basic ${base64Encode(utf8.encode("$user:$pass"))}",
      },
      connectTimeout: const Duration(seconds: 15),
      sendTimeout: const Duration(minutes: 10),
    ));
  }

  Future<void> ensureFolder(String folderName) async {
    String path = folderName.endsWith('/') ? folderName.substring(0, folderName.length - 1) : folderName;
    try {
      await _dio.request(path, options: Options(method: "MKCOL"));
    } on DioException catch (e) {
      if (e.response?.statusCode != 405 && e.response?.statusCode != 301) {
        // 忽略文件夹已存在的错误
      }
    }
  }

  // --- 核心修复：添加获取云端文件列表的方法 ---
// --- 修复后的 listRemoteFiles 方法 ---
  Future<List<String>> listRemoteFiles(String folderPath) async {
    try {
      // 1. 确保路径以 / 结尾
      String path = folderPath.endsWith('/') ? folderPath : '$folderPath/';
      
      final response = await _dio.request(
        path,
        options: Options(
          method: "PROPFIND",
          headers: {"Depth": "1"}, // 只查询当前层级
        ),
      );

      if (response.statusCode == 207) {
        final String xml = response.data.toString();
        
        // 2. 使用正则提取 href (兼容部分服务器返回的大小写差异)
        final RegExp hrefReg = RegExp(r'<d:href[^>]*>([^<]+)<\/d:href>', caseSensitive: false);
        final matches = hrefReg.allMatches(xml);
        
        List<String> files = [];
        
        // ✅ 核心修复：建立支持的格式白名单 (加入了 .webp 和 .heif)
        final supportedExtensions = {'.jpg', '.jpeg', '.png', '.heic', '.heif', '.webp','.gif'};

        for (var m in matches) {
          String rawPath = m.group(1) ?? "";
          String decodedPath = Uri.decodeFull(rawPath); // URL 解码
          String name = decodedPath.split('/').last;    // 提取文件名
          
          // 3. 过滤逻辑
          if (name.isNotEmpty && 
              name != path.split('/').last && // 排除文件夹自身
              !name.startsWith('.')) {        // 排除隐藏文件 (.DS_Store 等)
             
             // 将文件名转为小写，检查是否以白名单中的后缀结尾
             String lowerName = name.toLowerCase();
             bool isImage = false;
             
             // 遍历白名单检查
             for (var ext in supportedExtensions) {
               if (lowerName.endsWith(ext)) {
                 isImage = true;
                 break;
               }
             }

             if (isImage) {
               files.add(name);
             }
          }
        }
        return files;
      }
      return [];
    } catch (e) {
      print("List files error: $e");
      return [];
    }
  }

  Future<void> upload(File file, String remotePath) async {
    int len = await file.length();
    await _dio.put(remotePath, data: file.openRead(), options: Options(headers: {Headers.contentLengthHeader: len}));
  }

  Future<void> uploadBytes(Uint8List bytes, String remotePath) async {
    // 优化：直接传输 bytes 提高效率
    await _dio.put(remotePath, data: Stream.value(bytes), options: Options(headers: {Headers.contentLengthHeader: bytes.length}));
  }

  Future<void> downloadFile(String remotePath, String localPath) async {
    await _dio.download(remotePath, localPath);
  }
}
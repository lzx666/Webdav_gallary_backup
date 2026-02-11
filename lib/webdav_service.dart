import 'dart:convert';
import 'dart:io';
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
      headers: {"Authorization": "Basic ${base64Encode(utf8.encode("$user:$pass"))}"},
      connectTimeout: const Duration(seconds: 10),
    ));
  }

  // MKCOL：自动创建文件夹
  Future<void> ensureFolder(String folderName) async {
    try {
      await _dio.request(folderName, options: Options(method: "MKCOL"));
    } on DioException catch (e) {
      if (e.response?.statusCode != 405) rethrow; // 405说明文件夹已存在，忽略即可
    }
  }

  // PUT：上传文件
  Future<void> upload(File file, String remotePath) async {
    await _dio.put(
      remotePath,
      data: file.openRead(),
      options: Options(headers: {Headers.contentLengthHeader: await file.length()}),
    );
  }
}
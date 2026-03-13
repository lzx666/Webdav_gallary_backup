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
    final cleanUrl = url.endsWith('/') ? url : '$url/';
    _dio = Dio(
      BaseOptions(
        baseUrl: cleanUrl,
        headers: {
          "Authorization": "Basic ${base64Encode(utf8.encode("$user:$pass"))}",
        },
        connectTimeout: const Duration(seconds: 15),
        sendTimeout: const Duration(minutes: 10),
      ),
    );
  }

  Future<void> ensureFolder(String folderName) async {
    final path = folderName.endsWith('/')
        ? folderName.substring(0, folderName.length - 1)
        : folderName;
    try {
      await _dio.request(path, options: Options(method: "MKCOL"));
    } on DioException catch (e) {
      if (e.response?.statusCode != 405 && e.response?.statusCode != 301) {
        rethrow;
      }
    }
  }

  Future<List<String>> listRemoteFiles(String folderPath) async {
    final path = folderPath.endsWith('/') ? folderPath : '$folderPath/';

    try {
      final response = await _dio.request(
        path,
        options: Options(
          method: "PROPFIND",
          headers: {"Depth": "1"},
        ),
      );

      if (response.statusCode != 207) {
        throw Exception("PROPFIND failed: HTTP ${response.statusCode}");
      }

      final xml = response.data.toString();
      final hrefReg = RegExp(
        r'<(?:\w+:)?href[^>]*>([^<]+)</(?:\w+:)?href>',
        caseSensitive: false,
      );
      final supportedExtensions = {
        '.jpg',
        '.jpeg',
        '.png',
        '.heic',
        '.heif',
        '.webp',
        '.gif',
      };
      final files = <String>{};

      for (final match in hrefReg.allMatches(xml)) {
        final rawPath = match.group(1);
        if (rawPath == null || rawPath.isEmpty) continue;

        final decodedPath = Uri.decodeFull(rawPath);
        final normalizedPath = decodedPath.endsWith('/')
            ? decodedPath.substring(0, decodedPath.length - 1)
            : decodedPath;
        final name = normalizedPath.split('/').last;

        if (name.isEmpty || name.startsWith('.')) continue;

        final lowerName = name.toLowerCase();
        if (supportedExtensions.any(lowerName.endsWith)) {
          files.add(name);
        }
      }

      return files.toList()..sort();
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 401 || status == 403) {
        throw Exception("WebDAV 认证失败，请检查账号或应用专用密码");
      }
      if (status == 404) {
        return [];
      }
      throw Exception("读取云端目录失败: ${e.message ?? 'unknown error'}");
    }
  }

  Future<void> upload(File file, String remotePath) async {
    final len = await file.length();
    await _dio.put(
      remotePath,
      data: file.openRead(),
      options: Options(headers: {Headers.contentLengthHeader: len}),
    );
  }

  Future<void> uploadBytes(Uint8List bytes, String remotePath) async {
    await _dio.put(
      remotePath,
      data: Stream.value(bytes),
      options: Options(headers: {Headers.contentLengthHeader: bytes.length}),
    );
  }

  Future<void> downloadFile(String remotePath, String localPath) async {
    await _dio.download(remotePath, localPath);
  }

  Future<void> delete(String remotePath) async {
    await _dio.delete(remotePath);
  }
}

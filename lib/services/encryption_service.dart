import 'dart:io';
import 'dart:typed_data';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;

class EncryptionService {
  static final EncryptionService _instance = EncryptionService._internal();
  factory EncryptionService() => _instance;
  EncryptionService._internal();

  static const int _key = 0x42; // Simple XOR key for securing downloads
  HttpServer? _server;
  int? _port;

  /// Initializes the local decryption server
  Future<void> init() async {
    if (_server != null) return;

    final handler = const Pipeline().addHandler(_handleRequest);

    _server = await io.serve(handler, InternetAddress.loopbackIPv4, 0);
    _port = _server!.port;
    print('Encryption server running on port $_port');
  }

  /// Encrypts or Decrypts data using XOR
  Uint8List encryptData(List<int> data) {
    final result = Uint8List(data.length);
    for (int i = 0; i < data.length; i++) {
      result[i] = data[i] ^ _key;
    }
    return result;
  }

  /// Handles requests from the audio player to stream decrypted content
  Future<Response> _handleRequest(Request request) async {
    // The path contains the full absolute path of the file
    String filePath = request.url.path;

    // On Windows, the path might start with a drive letter, e.g., /C:/...
    if (Platform.isWindows && filePath.startsWith('/')) {
      filePath = filePath.substring(1);
    }

    final file = File(filePath);
    if (!await file.exists()) {
      return Response.notFound('File not found: $filePath');
    }

    final int fileLength = await file.length();

    // Handle Range Headers for seeking support
    final rangeHeader = request.headers['range'];
    if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
      final parts = rangeHeader.substring(6).split('-');
      final start = int.tryParse(parts[0]) ?? 0;
      final end = (parts.length > 1 && parts[1].isNotEmpty)
          ? int.tryParse(parts[1]) ?? (fileLength - 1)
          : (fileLength - 1);

      if (start >= fileLength) {
        return Response(416, body: 'Requested range not satisfiable');
      }

      final stream = file
          .openRead(start, end + 1)
          .map((chunk) => encryptData(chunk));

      return Response(
        206,
        body: stream,
        headers: {
          'Content-Type': _getContentType(filePath),
          'Accept-Ranges': 'bytes',
          'Content-Length': '${end - start + 1}',
          'Content-Range': 'bytes $start-$end/$fileLength',
        },
      );
    }

    // Full file request
    final stream = file.openRead().map((chunk) => encryptData(chunk));
    return Response.ok(
      stream,
      headers: {
        'Content-Type': _getContentType(filePath),
        'Accept-Ranges': 'bytes',
        'Content-Length': '$fileLength',
      },
    );
  }

  String _getContentType(String path) {
    if (path.endsWith('.m4a')) return 'audio/mp4';
    if (path.endsWith('.webm')) return 'audio/webm';
    if (path.endsWith('.mp3')) return 'audio/mpeg';
    return 'audio/mpeg'; // Default
  }

  /// Returns a local URL that serve decrypted content for the given encrypted file
  String getUrl(String filePath) {
    if (_port == null) return filePath; // Fallback

    // Ensure the path is properly formatted for URL
    final uriPath = Uri.file(filePath).path;
    return 'http://127.0.0.1:$_port$uriPath';
  }
}

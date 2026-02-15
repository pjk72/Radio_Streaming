import 'dart:io';
import 'dart:typed_data';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:path_provider/path_provider.dart'; // Added for temp dir

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

    // Use anyIPv4 instead of loopback to ensure accessibility on all Android devices/emulators
    // unforeseen networking quirks can sometimes block strict 127.0.0.1 binding
    _server = await io.serve(handler, InternetAddress.anyIPv4, 0);
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
    // URL decoding to handle spaces and special characters
    // request.url.path returns the decoded path component, so manual decoding *might* be redundant
    // but safer to decode if we are seeing encoded strings.
    // However, shelf might have already decoded it. Let's check raw path segments if needed.

    // If request.url.path is already decoded by shelf, calling decodeFull again on a path with % might break it UNLESS we caused it.
    // Let's rely on standard decoding.
    String filePath = request.url.path;
    if (Platform.isWindows && filePath.startsWith('/')) {
      filePath = filePath.substring(1);
    }

    // On Android, the path from request.url.path might need decoding if we manually encoded it in getUrl
    filePath = Uri.decodeComponent(filePath);

    // Fix for absolute paths on Android potentially missing the leading / when coming from URI parsing
    if (!filePath.startsWith('/') && !Platform.isWindows) {
      filePath = '/' + filePath;
    }

    print('EncryptionService: Request for $filePath');
    final file = File(filePath);
    if (!await file.exists()) {
      print('EncryptionService: File NOT found: $filePath');
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
    // We need to encode the path segments to be a valid URL
    // But we must preserve the structure.

    // 1. Remove scheme 'file://' if present to just get the path
    String cleanPath = filePath;
    if (filePath.startsWith('file://')) {
      cleanPath = Uri.parse(filePath).toFilePath();
    }

    // 2. Encode the path components to handle spaces/special chars
    // We cannot just use Uri.encodeFull because it leaves '/' alone which is good,
    // but we want to be sure.
    final uriPath = Uri.encodeFull(cleanPath);

    // 3. Construct URL.
    // Ensure cleanPath starts with / for the URL construction if not present
    var pathStr = uriPath;
    if (!pathStr.startsWith('/')) {
      pathStr = '/$pathStr';
    }

    // Validate port
    if (_port == null) {
      print('EncryptionService: ERROR - Port is null, server not running!');
      return filePath;
    }

    final url = 'http://127.0.0.1:$_port$pathStr';
    print('EncryptionService: Generated URL: $url for raw path: $filePath');
    return url;
  }

  /// Decrypts the given file to a temporary file and returns it.
  Future<File> decryptToTempFile(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception('File not found: $filePath');
    }

    final bytes = await file.readAsBytes();
    final decryptedBytes = encryptData(bytes); // XOR works both ways

    final tempDir = await getTemporaryDirectory();
    final String extension = filePath.endsWith('.m4a')
        ? '.m4a'
        : filePath.endsWith('.mp3')
        ? '.mp3'
        : '.tmp';

    // Use a unique name based on hash or timestamp to avoid collisions but allow caching if needed
    // For now, unique every time to be safe.
    final tempFile = File(
      '${tempDir.path}/temp_decrypted_${DateTime.now().millisecondsSinceEpoch}$extension',
    );

    await tempFile.writeAsBytes(decryptedBytes);
    return tempFile;
  }
}

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_static/shelf_static.dart';
import 'package:shelf_multipart/shelf_multipart.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final status = await Permission.manageExternalStorage.request();
  if (!status.isGranted) {
    openAppSettings();
    runApp(const MyApp(ip: 'ไม่ได้รับสิทธิ์เข้าถึง Storage'));
    return;
  }

  final rootDir = Directory('/storage/emulated/0');
  await createIndexHtml(rootDir.path);

  final staticHandler = createStaticHandler(
    rootDir.path,
    defaultDocument: 'index.html',
    serveFilesOutsidePath: true,
  );

  final handler = Pipeline().addMiddleware(logRequests()).addHandler((Request request) async {
    // Upload handler
    if (request.url.path == 'upload' && request.method == 'POST') {
      final path = request.url.queryParameters['path'] ?? '';
      final uploadDir = Directory('${rootDir.path}/$path');
      if (!await uploadDir.exists()) {
        await uploadDir.create(recursive: true);
      }

      final multipart = request.multipart();
      if (multipart != null) {
        await for (final part in multipart.parts) {
          final headers = part.headers;
          final contentDisposition = headers['content-disposition'];
          final filename = _extractFilename(contentDisposition);

          if (filename != null) {
            final bytes = await part.readBytes();
            final sanitizedFilename = filename.replaceAll(RegExp(r'[\\/]+'), '');
            final file = File('${uploadDir.path}/$sanitizedFilename');
            await file.writeAsBytes(bytes);
          }
        }
        return Response.ok('Upload complete');
      } else {
        return Response.internalServerError(body: 'Invalid multipart request');
      }
    }

    // List files and folders
    if (request.url.path == 'files') {
      final queryPath = request.url.queryParameters['path'] ?? '';
      final targetDir = Directory('${rootDir.path}/$queryPath');

      if (!await targetDir.exists()) {
        return Response.notFound('Directory not found');
      }

      final folders = <String>[];
      final files = <String>[];

      await for (var entity in targetDir.list(followLinks: false)) {
        final name = entity.path.replaceFirst('${rootDir.path}/', '');
        if (entity is Directory) {
          folders.add(name);
        } else if (entity is File) {
          files.add(name);
        }
      }

      return Response.ok(
        '''
        {
          "path": "$queryPath",
          "folders": ${folders.map((f) => '"$f"').toList()},
          "files": ${files.map((f) => '"$f"').toList()}
        }
        ''',
        headers: {'Content-Type': 'application/json'},
      );
    }

    // Download file
    if (request.url.pathSegments.length >= 2 &&
        request.url.pathSegments.first == 'download') {
      final filename = request.url.pathSegments.sublist(1).join('/');
      final file = File('${rootDir.path}/$filename');
      if (await file.exists()) {
        return Response.ok(
          file.openRead(),
          headers: {'Content-Type': 'application/octet-stream'},
        );
      } else {
        return Response.notFound('File not found');
      }
    }

    return staticHandler(request);
  });

  await shelf_io.serve(handler, InternetAddress.anyIPv4, 3000);

  final info = NetworkInfo();
  final ip = await info.getWifiIP();
  runApp(MyApp(ip: ip ?? 'ไม่พบ IP'));
}

class MyApp extends StatelessWidget {
  final String ip;
  const MyApp({required this.ip});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: Text('Flutter File Server')),
        body: Center(
          child: Text('เปิด browser ที่ PC หรือมือถือ แล้วเข้า http://$ip:3000'),
        ),
      ),
    );
  }
}

String? _extractFilename(String? contentDisposition) {
  if (contentDisposition == null) return null;
  final regex = RegExp(r'filename="([^"]+)"');
  final match = regex.firstMatch(contentDisposition);
  return match?.group(1);
}

Future<void> createIndexHtml(String path) async {
  final file = File('$path/index.html');
  await file.writeAsString('''
    <!DOCTYPE html>
    <html>
    <head><title>Flutter File Server</title></head>
    <body>
      <h1>Upload File</h1>
      <input type="file" id="file-input" />
      <progress id="upload-progress" value="0" max="100" style="width:300px;"></progress>
      <button onclick="uploadFile()">Upload</button>

      <h2>Download Files</h2>
      <div id="breadcrumb"></div>
      <ul id="folder-list"></ul>
      <ul id="file-list"></ul>

      <script>
        let currentPath = '';

        function updateBreadcrumb() {
          const parts = currentPath.split('/').filter(p => p);
          const breadcrumb = document.getElementById('breadcrumb');
          breadcrumb.innerHTML = '';
          let path = '';
          const rootLink = document.createElement('a');
          rootLink.href = '#';
          rootLink.textContent = 'root';
          rootLink.onclick = () => { currentPath = ''; loadFiles(); };
          breadcrumb.appendChild(rootLink);
          parts.forEach((part, index) => {
            breadcrumb.appendChild(document.createTextNode(' / '));
            path += '/' + part;
            const link = document.createElement('a');
            link.href = '#';
            link.textContent = part;
            link.onclick = () => {
              currentPath = parts.slice(0, index + 1).join('/');
              loadFiles();
            };
            breadcrumb.appendChild(link);
          });
        }

        async function loadFiles() {
          updateBreadcrumb();
          const res = await fetch('/files?path=' + encodeURIComponent(currentPath));
          const data = await res.json();
          const folderList = document.getElementById('folder-list');
          const fileList = document.getElementById('file-list');
          folderList.innerHTML = '';
          fileList.innerHTML = '';

          data.folders.forEach(folder => {
            const li = document.createElement('li');
            const a = document.createElement('a');
            a.href = '#';
            a.textContent = folder.split('/').pop();
            a.onclick = () => {
              currentPath = folder;
              loadFiles();
            };
            li.appendChild(a);
            folderList.appendChild(li);
          });

          data.files.forEach(file => {
            const li = document.createElement('li');
            const ext = file.split('.').pop().toLowerCase();
            if (['jpg', 'jpeg', 'png', 'gif', 'bmp'].includes(ext)) {
              const img = document.createElement('img');
              img.src = '/download/' + file;
              img.style.maxWidth = '200px';
              img.style.marginBottom = '8px';
              li.appendChild(img);
            }
            const a = document.createElement('a');
            a.href = '/download/' + file;
            a.textContent = file.split('/').pop();
            li.appendChild(document.createElement('br'));
            li.appendChild(a);
            fileList.appendChild(li);
          });
        }

        function uploadFile() {
          const fileInput = document.getElementById('file-input');
          const progressBar = document.getElementById('upload-progress');
          const file = fileInput.files[0];
          if (!file) return;

          const formData = new FormData();
          formData.append('file', file);

          const xhr = new XMLHttpRequest();
          xhr.open('POST', '/upload?path=' + encodeURIComponent(currentPath), true);

          xhr.upload.onprogress = function(e) {
            if (e.lengthComputable) {
              const percent = (e.loaded / e.total) * 100;
              progressBar.value = percent;
            }
          };

          xhr.onload = function() {
            if (xhr.status === 200) {
              progressBar.value = 100;
              loadFiles();
            } else {
              alert('Upload failed');
            }
          };

          xhr.onerror = function() {
            alert('Upload error');
          };

          xhr.send(formData);
        }

        loadFiles();
      </script>
    </body>
    </html>
  ''');
}

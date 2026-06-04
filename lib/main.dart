import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:mime/mime.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_static/shelf_static.dart';
import 'package:shelf_multipart/shelf_multipart.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

// ---------------------------------------------------------------------------
// AdMob IDs — replace with real IDs before publishing to Play Store
// ---------------------------------------------------------------------------
const String _adUnitId = 'ca-app-pub-3940256099942544/6300978111'; // test banner

// ---------------------------------------------------------------------------
// Notification constants
// ---------------------------------------------------------------------------
const _statusChannelId = 'filebeam_status';
const _statusChannelName = 'FileBeam Status';
const _statusNotifId = 889;

/// Called when user taps a notification action while app is in background.
@pragma('vm:entry-point')
void _onNotificationAction(NotificationResponse response) {
  if (response.actionId == 'stop') {
    FlutterBackgroundService().invoke('stopService');
  }
}

Future<void> _showStatusNotification(String url) async {
  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
    onDidReceiveBackgroundNotificationResponse: _onNotificationAction,
  );

  await plugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(
        const AndroidNotificationChannel(
          _statusChannelId,
          _statusChannelName,
          description: 'FileBeam server status and quick actions',
          importance: Importance.low,
          playSound: false,
          enableVibration: false,
          enableLights: false,
        ),
      );

  await plugin.show(
    _statusNotifId,
    'FileBeam is running',
    url,
    NotificationDetails(
      android: AndroidNotificationDetails(
        _statusChannelId,
        _statusChannelName,
        importance: Importance.low,
        priority: Priority.low,
        ongoing: true,
        autoCancel: false,
        playSound: false,
        enableVibration: false,
        styleInformation: BigTextStyleInformation(
          'Ready to receive files over Wi-Fi\n$url\n\nOpen the URL in any browser on the same network to browse and transfer files.',
          contentTitle: 'FileBeam is running in background',
          summaryText: 'Tap \"Share\" to send the URL to another device',
        ),
        actions: const [
          AndroidNotificationAction(
            'stop',
            'Stop',
            cancelNotification: false,
            showsUserInterface: false,
          ),
          AndroidNotificationAction(
            'share',
            'Share URL',
            cancelNotification: false,
            showsUserInterface: true,
          ),
        ],
      ),
    ),
  );
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  final rootDir = Directory('/storage/emulated/0');
  await createIndexHtml(rootDir.path);

  final staticHandler = createStaticHandler(
    rootDir.path,
    defaultDocument: 'index.html',
    serveFilesOutsidePath: true,
  );

  final handler = Pipeline().addMiddleware(logRequests()).addHandler((
    Request request,
  ) async {
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
            final sanitizedFilename = filename.replaceAll(
              RegExp(r'[\\/]+'),
              '',
            );
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

    // Download file (with Range / 206 Partial Content support)
    if (request.url.pathSegments.length >= 2 &&
        request.url.pathSegments.first == 'download') {
      final filename = request.url.pathSegments.sublist(1).join('/');
      final file = File('${rootDir.path}/$filename');
      if (!await file.exists()) {
        return Response.notFound('File not found');
      }

      final fileSize = await file.length();
      final mimeType =
          lookupMimeType(filename) ?? 'application/octet-stream';
      final rangeHeader = request.headers['range'];

      if (rangeHeader != null) {
        final match =
            RegExp(r'bytes=(\d+)-(\d*)').firstMatch(rangeHeader);
        if (match != null) {
          final start = int.parse(match.group(1)!);
          final end = match.group(2)!.isNotEmpty
              ? int.parse(match.group(2)!)
              : fileSize - 1;
          final safeEnd = end.clamp(0, fileSize - 1);
          final length = safeEnd - start + 1;
          return Response(
            206,
            body: file.openRead(start, safeEnd + 1),
            headers: {
              'Content-Type': mimeType,
              'Content-Length': '$length',
              'Content-Range': 'bytes $start-$safeEnd/$fileSize',
              'Accept-Ranges': 'bytes',
            },
          );
        }
      }

      return Response.ok(
        file.openRead(),
        headers: {
          'Content-Type': mimeType,
          'Content-Length': '$fileSize',
          'Accept-Ranges': 'bytes',
        },
      );
    }

    return staticHandler(request);
  });

  await shelf_io.serve(handler, InternetAddress.anyIPv4, 3000);

  final info = NetworkInfo();
  final ip = await info.getWifiIP() ?? 'N/A';
  final url = 'http://$ip:3000';

  service.invoke('updateIp', {'ip': ip});
  service.invoke('serviceStatus', {'running': true});
  service.invoke('serverLog', {'message': 'Server running at $url'});

  // Allow UI to request current state after late attach
  service.on('requestStatus').listen((_) {
    service.invoke('updateIp', {'ip': ip});
    service.invoke('serviceStatus', {'running': true});
  });

  if (service is AndroidServiceInstance) {
    service.setForegroundNotificationInfo(
      title: 'FileBeam is running in background',
      content: 'Accepting files over Wi-Fi · $url',
    );
  }

  await _showStatusNotification(url);

  service.on('stopService').listen((_) async {
    service.invoke('serviceStatus', {'running': false});
    service.invoke('serverLog', {'message': 'Server stopped'});
    final plugin = FlutterLocalNotificationsPlugin();
    await plugin.cancel(_statusNotifId);
    service.stopSelf();
  });
}

Future<void> initializeService() async {
  // Create LOW-importance channel before service starts so Android uses it
  final notifPlugin = FlutterLocalNotificationsPlugin();
  await notifPlugin.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
    onDidReceiveBackgroundNotificationResponse: _onNotificationAction,
  );
  await notifPlugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(
        const AndroidNotificationChannel(
          'file_server_channel',
          'FileBeam Service',
          description: 'Required to keep FileBeam running in the background',
          importance: Importance.low,
          playSound: false,
          enableVibration: false,
        ),
      );

  final service = FlutterBackgroundService();
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: 'file_server_channel',
      initialNotificationTitle: 'FileBeam',
      initialNotificationContent: 'Server is starting...',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: onStart,
    ),
  );
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await MobileAds.instance.initialize();

  // Handle "Share URL" notification action (launches app)
  final notifPlugin = FlutterLocalNotificationsPlugin();
  await notifPlugin.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
    onDidReceiveNotificationResponse: (response) {
      if (response.actionId == 'share') {
        // Share action handled inside HomeScreen via system share sheet
        SystemChannels.platform
            .invokeMethod('SystemNavigator.pop'); // bring app to foreground
      }
    },
    onDidReceiveBackgroundNotificationResponse: _onNotificationAction,
  );

  await Permission.notification.request();

  final status = await Permission.manageExternalStorage.request();
  if (!status.isGranted) {
    openAppSettings();
    runApp(const FileBeamApp(initialIp: 'Storage permission denied'));
    return;
  }

  await initializeService();

  final service = FlutterBackgroundService();
  final isRunning = await service.isRunning();
  if (!isRunning) {
    await service.startService();
  }

  runApp(const FileBeamApp(initialIp: 'Starting...'));
}

// ---------------------------------------------------------------------------
// App
// ---------------------------------------------------------------------------

class FileBeamApp extends StatelessWidget {
  final String initialIp;
  const FileBeamApp({super.key, required this.initialIp});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FileBeam',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6C63FF),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0F0F1A),
      ),
      home: HomeScreen(initialIp: initialIp),
    );
  }
}

// ---------------------------------------------------------------------------

class HomeScreen extends StatefulWidget {
  final String initialIp;
  const HomeScreen({super.key, required this.initialIp});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  late String _ip;
  bool _isRunning = false;
  final List<({String msg, String time})> _logs = [];
  final _scrollController = ScrollController();
  late AnimationController _pulseController;
  BannerAd? _bannerAd;
  bool _isBannerReady = false;

  @override
  void initState() {
    super.initState();
    _ip = widget.initialIp;

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _loadBannerAd();

    final svc = FlutterBackgroundService();

    svc.on('updateIp').listen((event) {
      if (event != null && mounted) {
        setState(() => _ip = event['ip'] as String? ?? '');
      }
    });

    svc.on('serviceStatus').listen((event) {
      if (event != null && mounted) {
        setState(() => _isRunning = event['running'] as bool? ?? false);
      }
    });

    svc.on('serverLog').listen((event) {
      if (event != null && mounted) {
        final msg = event['message'] as String? ?? '';
        final now = DateTime.now();
        final time =
            '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
        setState(() {
          _logs.add((msg: msg, time: time));
          if (_logs.length > 200) _logs.removeAt(0);
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
          }
        });
      }
    });

    svc.isRunning().then((running) {
      if (mounted) {
        setState(() => _isRunning = running);
        // If already running, request current IP (UI may have missed the initial event)
        if (running) {
          Future.delayed(const Duration(milliseconds: 300), () {
            if (mounted) svc.invoke('requestStatus');
          });
        }
      }
    });
  }

  void _loadBannerAd() {
    _bannerAd = BannerAd(
      adUnitId: _adUnitId,
      size: AdSize.banner,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (_) {
          if (mounted) setState(() => _isBannerReady = true);
        },
        onAdFailedToLoad: (ad, error) {
          ad.dispose();
          _bannerAd = null;
        },
      ),
    )..load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _pulseController.dispose();
    _bannerAd?.dispose();
    super.dispose();
  }

  Future<void> _toggleService() async {
    final svc = FlutterBackgroundService();
    if (_isRunning) {
      svc.invoke('stopService');
    } else {
      final now = DateTime.now();
      final time =
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
      setState(() => _logs.add((msg: 'Starting server...', time: time)));
      await svc.startService();
    }
  }

  String get _serverUrl => 'http://$_ip:3000';
  bool get _hasValidIp => RegExp(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$').hasMatch(_ip);

  void _copyUrl() {
    Clipboard.setData(ClipboardData(text: _serverUrl));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('URL copied to clipboard'),
        duration: const Duration(seconds: 2),
        backgroundColor: const Color(0xFF6C63FF),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.only(
                  left: 16,
                  right: 16,
                  top: 16,
                  bottom: (_isBannerReady && _bannerAd != null)
                      ? (_bannerAd!.size.height + 8).toDouble()
                      : 16,
                ),
                child: Column(
                  children: [
                    _buildStatusCard(),
                    const SizedBox(height: 16),
                    if (_isRunning && _hasValidIp) ...[
                      _buildQrCard(),
                      const SizedBox(height: 16),
                    ],
                    if (_isRunning && !_hasValidIp) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF6C63FF)),
                            ),
                            SizedBox(width: 12),
                            Text('Fetching IP address...', style: TextStyle(color: Color(0xFF8892A4), fontSize: 13)),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    _buildLogCard(),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
            if (_isBannerReady && _bannerAd != null)
              Container(
                color: const Color(0xFF1A1A2E),
                height: _bannerAd!.size.height.toDouble(),
                width: double.infinity,
                alignment: Alignment.center,
                child: AdWidget(ad: _bannerAd!),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF1A1A2E), Color(0xFF16213E)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF6C63FF), Color(0xFF48CAE4)],
              ),
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF6C63FF).withOpacity(0.4),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: const Icon(Icons.send_to_mobile_rounded, color: Colors.white, size: 22),
          ),
          const SizedBox(width: 14),
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'FileBeam',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              Text(
                'Wireless File Transfer',
                style: TextStyle(fontSize: 12, color: Color(0xFF8892A4)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatusCard() {
    final isOn = _isRunning;
    final activeColor = isOn ? const Color(0xFF00E676) : const Color(0xFFFF5252);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isOn
              ? [const Color(0xFF1B2838), const Color(0xFF1A2F24)]
              : [const Color(0xFF1B2838), const Color(0xFF2A1A1A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: activeColor.withOpacity(0.35), width: 1),
      ),
      child: Row(
        children: [
          AnimatedBuilder(
            animation: _pulseController,
            builder: (_, __) => Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: activeColor.withOpacity(0.1 + 0.1 * _pulseController.value),
              ),
              child: Icon(
                isOn ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
                color: activeColor,
                size: 28,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isOn ? 'Server is running' : 'Server is stopped',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: activeColor,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  isOn ? 'Ready to accept Wi-Fi connections' : 'Tap Start to launch the server',
                  style: const TextStyle(fontSize: 12, color: Color(0xFF8892A4)),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: _toggleService,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 11),
              decoration: isOn
                  ? BoxDecoration(
                      border: Border.all(color: const Color(0xFFFF5252).withOpacity(0.7), width: 1.5),
                      borderRadius: BorderRadius.circular(14),
                      color: const Color(0xFFFF5252).withOpacity(0.12),
                    )
                  : BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF6C63FF), Color(0xFF48CAE4)],
                      ),
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF6C63FF).withOpacity(0.4),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
              child: Text(
                isOn ? 'Stop' : 'Start',
                style: TextStyle(
                  color: isOn ? const Color(0xFFFF5252) : Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQrCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF6C63FF).withOpacity(0.3)),
      ),
      child: Column(
        children: [
          const Row(
            children: [
              Icon(Icons.qr_code_2_rounded, color: Color(0xFF6C63FF), size: 20),
              SizedBox(width: 8),
              Text(
                'Scan QR to connect',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  fontSize: 14,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF6C63FF).withOpacity(0.25),
                  blurRadius: 20,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: QrImageView(
              data: _serverUrl,
              version: QrVersions.auto,
              size: 180,
              backgroundColor: Colors.white,
            ),
          ),
          const SizedBox(height: 20),
          GestureDetector(
            onTap: _copyUrl,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: const Color(0xFF6C63FF).withOpacity(0.1),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFF6C63FF).withOpacity(0.3)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.link_rounded, color: Color(0xFF6C63FF), size: 18),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      _serverUrl,
                      style: const TextStyle(
                        color: Color(0xFF6C63FF),
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.copy_rounded, color: Color(0xFF8892A4), size: 16),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Tap to copy URL',
            style: TextStyle(fontSize: 11, color: Color(0xFF8892A4)),
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _buildLogCard() {
    return Container(
      height: 240,
      decoration: BoxDecoration(
        color: const Color(0xFF0D1117),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(0xFFFF5F57),
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  width: 12,
                  height: 12,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(0xFFFFBD2E),
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  width: 12,
                  height: 12,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(0xFF28C840),
                  ),
                ),
                const SizedBox(width: 12),
                const Text(
                  'Activity Log',
                  style: TextStyle(
                    fontSize: 12,
                    color: Color(0xFF8892A4),
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
          const Divider(color: Color(0xFF30363D), height: 1),
          Expanded(
            child: _logs.isEmpty
                ? const Center(
                    child: Text(
                      'No activity yet',
                      style: TextStyle(
                        color: Color(0xFF8892A4),
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(12),
                    itemCount: _logs.length,
                    itemBuilder: (_, i) {
                      final entry = _logs[i];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              entry.time,
                              style: const TextStyle(
                                color: Color(0xFF8892A4),
                                fontSize: 10,
                                fontFamily: 'monospace',
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                entry.msg,
                                style: const TextStyle(
                                  color: Color(0xFF39D353),
                                  fontSize: 11,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

String? _extractFilename(String? contentDisposition) {
  if (contentDisposition == null) return null;
  final regex = RegExp(r'filename="([^"]+)"');
  final match = regex.firstMatch(contentDisposition);
  return match?.group(1);
}

Future<void> createIndexHtml(String path) async {
  final file = File('$path/index.html');
  await file.writeAsString(r'''<!DOCTYPE html>
<html lang="th">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>FileBeam</title>
  <style>
    *{box-sizing:border-box;margin:0;padding:0}
    :root{
      --bg:#0f0f1a;--surface:#1a1a2e;--surface2:#16213e;
      --accent:#6c63ff;--accent2:#48cae4;
      --text:#e2e8f0;--muted:#8892a4;--border:#30363d;--green:#39d353;
    }
    body{background:var(--bg);color:var(--text);font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;min-height:100vh}
    header{background:linear-gradient(135deg,var(--surface),var(--surface2));border-bottom:1px solid var(--border);padding:14px 20px;display:flex;align-items:center;gap:12px;position:sticky;top:0;z-index:100;backdrop-filter:blur(8px)}
    .logo{width:40px;height:40px;background:linear-gradient(135deg,var(--accent),var(--accent2));border-radius:12px;display:flex;align-items:center;justify-content:center;font-size:20px;flex-shrink:0;box-shadow:0 4px 12px rgba(108,99,255,.4)}
    header h1{font-size:18px;font-weight:700}
    header p{font-size:11px;color:var(--muted)}
    .container{max-width:960px;margin:0 auto;padding:20px}
    .upload-zone{border:2px dashed var(--accent);border-radius:18px;padding:28px 20px;text-align:center;cursor:pointer;transition:all .3s;background:rgba(108,99,255,.04);margin-bottom:20px}
    .upload-zone:hover,.upload-zone.drag-over{background:rgba(108,99,255,.12);border-color:var(--accent2);transform:translateY(-2px)}
    .upload-zone input{display:none}
    .upload-icon{font-size:36px;margin-bottom:8px}
    .upload-zone h3{margin-bottom:4px;font-size:16px}
    .upload-zone p{font-size:12px;color:var(--muted)}
    .progress-wrap{margin-top:14px;display:none}
    .progress-bg{height:6px;background:var(--border);border-radius:3px;overflow:hidden}
    .progress-fill{height:100%;background:linear-gradient(90deg,var(--accent),var(--accent2));border-radius:3px;width:0;transition:width .15s}
    .progress-label{font-size:11px;color:var(--muted);margin-top:5px;text-align:right}
    .breadcrumb{display:flex;align-items:center;flex-wrap:wrap;gap:4px;margin-bottom:14px;font-size:13px;background:var(--surface);border:1px solid var(--border);border-radius:12px;padding:8px 14px}
    .breadcrumb a{color:var(--accent);text-decoration:none;padding:2px 6px;border-radius:6px;transition:background .2s}
    .breadcrumb a:hover{background:rgba(108,99,255,.15)}
    .breadcrumb span{color:var(--muted)}
    a{text-decoration:none;color:#6c63ff}
    a:hover{text-decoration:underline;color:#48cae4}
    .section-title{font-size:11px;color:var(--muted);font-weight:700;text-transform:uppercase;letter-spacing:.8px;margin:16px 0 10px;padding-left:4px}
    .file-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:10px}
    .file-item{background:var(--surface);border:1px solid var(--border);border-radius:14px;padding:14px 10px;cursor:pointer;transition:all .2s;display:flex;flex-direction:column;align-items:center;gap:8px;text-align:center;user-select:none}
    .file-item:hover{border-color:var(--accent);background:rgba(108,99,255,.08);transform:translateY(-3px);box-shadow:0 8px 20px rgba(0,0,0,.3)}
    .file-item:active{transform:translateY(-1px)}
    .file-icon{font-size:30px}
    .file-name{font-size:11px;word-break:break-all;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden;color:var(--text)}
    .file-item img{width:80px;height:80px;object-fit:cover;border-radius:10px;background:var(--border)}
    .empty{text-align:center;color:var(--muted);padding:48px 20px;font-size:14px}
    .empty-icon{font-size:48px;margin-bottom:12px}
    @media(max-width:480px){.file-grid{grid-template-columns:repeat(auto-fill,minmax(110px,1fr))}.container{padding:14px}}
  </style>
</head>
<body>
<header>
  <div class="logo">&#128225;</div>
  <div>
    <h1>FileBeam</h1>
    <p>Wireless File Transfer</p>
  </div>
</header>
<div class="container">
  <div class="upload-zone" id="drop-zone">
    <input type="file" id="file-input" multiple>
    <div class="upload-icon">&#9729;&#65039;</div>
    <h3>Upload Files</h3>
    <p>Drag & drop files here, or tap to select</p>
    <div class="progress-wrap" id="progress-wrap">
      <div class="progress-bg"><div class="progress-fill" id="progress-fill"></div></div>
      <div class="progress-label" id="progress-label">0%</div>
    </div>
  </div>
  <div class="breadcrumb" id="breadcrumb"></div>
  <div id="content"></div>
</div>
<script>
var currentPath='';
var iconMap={pdf:'&#128196;',doc:'&#128203;',docx:'&#128203;',txt:'&#128196;',xls:'&#128202;',xlsx:'&#128202;',csv:'&#128202;',zip:'&#128230;',rar:'&#128230;','7z':'&#128230;',tar:'&#128230;',gz:'&#128230;',mp4:'&#127916;',mkv:'&#127916;',avi:'&#127916;',mov:'&#127916;',webm:'&#127916;',mp3:'&#127925;',flac:'&#127925;',wav:'&#127925;',m4a:'&#127925;',aac:'&#127925;',jpg:'&#128444;&#65039;',jpeg:'&#128444;&#65039;',png:'&#128444;&#65039;',gif:'&#128444;&#65039;',webp:'&#128444;&#65039;',bmp:'&#128444;&#65039;',apk:'&#128241;',exe:'&#9881;&#65039;',dmg:'&#128191;'};
function icon(n){var e=n.split('.').pop().toLowerCase();return iconMap[e]||'&#128196;'}
function isImg(n){return /\.(jpg|jpeg|png|gif|webp|bmp)$/i.test(n)}
function updateBreadcrumb(){
  var bc=document.getElementById('breadcrumb');
  bc.innerHTML='';
  var parts=currentPath.split('/').filter(Boolean);
  var a=document.createElement('a');
  a.href='#';a.innerHTML='&#127968; Home';
  a.onclick=function(){currentPath='';loadFiles();return false;};
  bc.appendChild(a);
  var p='';
  parts.forEach(function(part,i){
    var sep=document.createElement('span');sep.textContent=' / ';bc.appendChild(sep);
    p+=(p?'/':'')+part;
    var lnk=document.createElement('a');var fp=p;
    lnk.href='#';lnk.textContent=part;
    lnk.onclick=function(){currentPath=fp;loadFiles();return false;};
    bc.appendChild(lnk);
  });
}
function loadFiles(){
  updateBreadcrumb();
  fetch('/files?path='+encodeURIComponent(currentPath)).then(function(r){return r.json();}).then(function(data){
    var c=document.getElementById('content');c.innerHTML='';
    if(data.folders.length===0&&data.files.length===0){
      c.innerHTML='<div class="empty"><div class="empty-icon">&#128194;</div><p>This folder is empty</p></div>';return;
    }
    if(data.folders.length>0){
      var t=document.createElement('div');t.className='section-title';t.textContent='Folders ('+data.folders.length+')';c.appendChild(t);
      var g=document.createElement('div');g.className='file-grid';
      data.folders.forEach(function(f){
        var name=f.split('/').pop();
        var item=document.createElement('div');item.className='file-item';
        item.innerHTML='<div class="file-icon">&#128193;</div><div class="file-name">'+name+'</div>';
        item.onclick=function(){currentPath=f;loadFiles();};
        g.appendChild(item);
      });
      c.appendChild(g);
    }
    if(data.files.length>0){
      var t2=document.createElement('div');t2.className='section-title';t2.textContent='Files ('+data.files.length+')';c.appendChild(t2);
      var g2=document.createElement('div');g2.className='file-grid';
      data.files.forEach(function(f){
        var name=f.split('/').pop();
        var src='/download/'+encodeURIComponent(f).replace(/%2F/g,'/');
        var item=document.createElement('div');item.className='file-item';
        if(isImg(name)){item.innerHTML='<img src="'+src+'" loading="lazy" alt="'+name+'"><div class="file-name">'+name+'</div>';}
        else{item.innerHTML='<div class="file-icon">'+icon(name)+'</div><div class="file-name">'+name+'</div>';}
        item.onclick=function(){window.location.href=src;};
        g2.appendChild(item);
      });
      c.appendChild(g2);
    }
  });
}
var dz=document.getElementById('drop-zone');
var fi=document.getElementById('file-input');
dz.addEventListener('click',function(){fi.click();});
dz.addEventListener('dragover',function(e){e.preventDefault();dz.classList.add('drag-over');});
dz.addEventListener('dragleave',function(){dz.classList.remove('drag-over');});
dz.addEventListener('drop',function(e){e.preventDefault();dz.classList.remove('drag-over');doUpload(e.dataTransfer.files);});
fi.addEventListener('change',function(){doUpload(fi.files);});
function doUpload(files){Array.prototype.forEach.call(files,function(f){uploadOne(f);});}
function uploadOne(f){
  var pw=document.getElementById('progress-wrap');
  var pf=document.getElementById('progress-fill');
  var pl=document.getElementById('progress-label');
  pw.style.display='block';
  var fd=new FormData();fd.append('file',f);
  var xhr=new XMLHttpRequest();
  xhr.open('POST','/upload?path='+encodeURIComponent(currentPath),true);
  xhr.upload.onprogress=function(e){if(e.lengthComputable){var p=Math.round(e.loaded/e.total*100);pf.style.width=p+'%';pl.textContent=f.name+' — '+p+'%';}};
  xhr.onload=function(){
    if(xhr.status===200){pf.style.width='100%';pl.textContent='✅ '+f.name+' uploaded';setTimeout(function(){pw.style.display='none';pf.style.width='0';},2000);loadFiles();}
    else{pl.textContent='❌ '+f.name+' upload failed';}
  };
  xhr.onerror=function(){pl.textContent='❌ Upload error';};
  xhr.send(fd);
}
loadFiles();
</script>
</body>
</html>''');
}

import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeService();
  runApp(PicoProximityApp());
}

// Background service initialization
Future<void> initializeService() async {
  final service = FlutterBackgroundService();

  await service.configure(
    iosConfiguration: IosConfiguration(
      autoStart: true,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false,
      isForegroundMode: true,
      autoStartOnBoot: false,
    ),
  );
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  final proximityService = BackgroundProximityService(service);
  await proximityService.initialize();
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  return true;
}

// Background proximity detection service with authentication
class BackgroundProximityService {
  final ServiceInstance service;
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _ledCharacteristic;
  BluetoothCharacteristic? _authCharacteristic;
  bool _isConnected = false;
  bool _isAuthenticated = false;
  Timer? _scanTimer;
  Timer? _rssiTimer;

  // Configuration
  static const String TARGET_DEVICE_NAME = "Gate";
  static const String SERVICE_UUID = "12345678-1234-5678-1234-123456789abc";
  static const String LED_CHAR_UUID = "87654321-1234-5678-1234-cba987654321";
  static const String AUTH_CHAR_UUID = "11111111-2222-3333-4444-555555555555";

  BackgroundProximityService(this.service);

  Future<void> initialize() async {
    print("🚀 Background proximity service with auth initializing...");

    service.on('stop_service').listen((_) => _stopService());
    service
        .on('send_command')
        .listen((event) => _sendCommand(event!['command']));
    service.on('authenticate').listen(
        (event) => _authenticate(event!['password'], event!['deviceName']));

    await _startProximityDetection();

    Timer.periodic(Duration(seconds: 30), (timer) {
      service.invoke('heartbeat', {
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'connected': _isConnected,
        'authenticated': _isAuthenticated,
        'device': _connectedDevice?.platformName ?? 'None',
      });
    });
  }

  Future<void> _startProximityDetection() async {
    print("🔍 Starting proximity detection for $TARGET_DEVICE_NAME");

    service.invoke('status_update', {
      'status': 'Scanning for Pico W...',
      'connected': false,
      'authenticated': false,
    });

    _startScanning();
  }

  void _startScanning() {
    if (_isConnected) return;

    print("📡 Starting BLE scan for: $TARGET_DEVICE_NAME with service UUID");

    // Scan for all devices and filter by name AND/OR service UUID
    FlutterBluePlus.startScan(
      timeout: Duration(seconds: 6),
    );

    _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
      for (ScanResult result in results) {
        final deviceName = result.device.platformName;
        final serviceUuids = result.advertisementData.serviceUuids;

        print(
            "🔍 Found device: '$deviceName' with ${serviceUuids.length} services");

        // Check if it has our service UUID
        bool hasOurService = serviceUuids.any((uuid) =>
            uuid.toString().toLowerCase() == SERVICE_UUID.toLowerCase());

        // Connect if it matches our name OR has our service UUID
        bool shouldConnect =
            (deviceName == TARGET_DEVICE_NAME) || hasOurService;

        if (shouldConnect && !_isConnected) {
          print(
              "🎯 Found target device: '$deviceName' (name match: ${deviceName == TARGET_DEVICE_NAME}, service match: $hasOurService)");
          _connectToDevice(result.device);
          break;
        }
      }
    });

    _scanTimer = Timer(Duration(seconds: 8), () {
      if (!_isConnected) {
        print("⏰ Scan timeout - restarting scan...");
        FlutterBluePlus.stopScan();
        Future.delayed(Duration(seconds: 2), () => _startScanning());
      }
    });
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    try {
      print("🔗 Connecting to ${device.platformName}...");
      FlutterBluePlus.stopScan();
      _scanSubscription?.cancel();
      _scanTimer?.cancel();

      service.invoke('status_update', {
        'status': 'Connecting to Pico W...',
        'connected': false,
        'authenticated': false,
      });

      await device.connect(timeout: Duration(seconds: 15));
      _connectedDevice = device;
      _isConnected = true;

      print("✅ Connected to Pico W!");

      List<BluetoothService> services = await device.discoverServices();

      for (BluetoothService bleService in services) {
        if (bleService.uuid.toString().toLowerCase() ==
            SERVICE_UUID.toLowerCase()) {
          for (BluetoothCharacteristic char in bleService.characteristics) {
            if (char.uuid.toString().toLowerCase() ==
                LED_CHAR_UUID.toLowerCase()) {
              _ledCharacteristic = char;
              print("🎛️ Found LED characteristic");
            } else if (char.uuid.toString().toLowerCase() ==
                AUTH_CHAR_UUID.toLowerCase()) {
              _authCharacteristic = char;
              print("🔑 Found Auth characteristic");

              // Start listening for auth notifications
              await char.setNotifyValue(true);
              char.lastValueStream.listen((value) {
                _handleAuthResponse(value);
              });
            }
          }
        }
      }

      service.invoke('status_update', {
        'status': 'Connected - Waiting for authentication...',
        'connected': true,
        'authenticated': false,
      });

      // Try to authenticate automatically
      await _tryAutoAuthentication();

      device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          print("❌ Device disconnected");
          _onProximityLost();
        }
      });
    } catch (e) {
      print("❌ Connection failed: $e");
      _isConnected = false;
      _connectedDevice = null;
      Future.delayed(Duration(seconds: 3), () => _startScanning());
    }
  }

  Future<void> _tryAutoAuthentication() async {
    // Try to get saved credentials
    final prefs = await SharedPreferences.getInstance();
    final savedPassword = prefs.getString('pico_password');
    final savedDeviceName = prefs.getString('device_name') ?? 'Flutter Device';

    if (savedPassword != null) {
      print("🔑 Trying auto-authentication with saved password...");
      await _authenticate(savedPassword, savedDeviceName);
    } else {
      print("🔍 No saved password - manual authentication required");
      service.invoke('auth_required', {
        'message':
            'Please enter the Pico W password to authenticate this device'
      });
    }
  }

  Future<void> _authenticate(String password, String deviceName) async {
    if (_authCharacteristic == null) {
      print("❌ Auth characteristic not available");
      return;
    }

    try {
      // Simple protocol: "PASSWORD|DEVICE_NAME"
      final authString = "$password|$deviceName";
      final bytes = utf8.encode(authString);

      print("📤 Sending auth data (simple protocol):");
      print("   String: '$authString'");
      print("   Bytes length: ${bytes.length}");

      await _authCharacteristic!.write(bytes);
      print("✅ Authentication data sent successfully");

      // Save credentials for future use
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('pico_password', password);
      await prefs.setString('device_name', deviceName);
    } catch (e) {
      print("❌ Failed to send authentication: $e");
    }
  }

  void _handleAuthResponse(List<int> value) {
    try {
      final response = utf8.decode(value);
      print("📝 Auth response: $response");

      if (response.startsWith('SUCCESS|')) {
        _isAuthenticated = true;
        final message = response.substring(8); // Remove "SUCCESS|" prefix

        service.invoke('auth_success', {
          'status': 'auth_success',
          'message': message,
        });

        service.invoke('status_update', {
          'status': 'Authenticated - Proximity Active!',
          'connected': true,
          'authenticated': true,
        });

        _onProximityTriggered();
      } else if (response.startsWith('FAILED|')) {
        _isAuthenticated = false;
        final message = response.substring(7); // Remove "FAILED|" prefix

        service.invoke('auth_failed', {
          'message': message,
        });

        service.invoke('status_update', {
          'status': 'Authentication failed - Check password',
          'connected': true,
          'authenticated': false,
        });
      }
    } catch (e) {
      print("❌ Error parsing auth response: $e");
    }
  }

  Future<void> _onProximityTriggered() async {
    print("🎯 PROXIMITY TRIGGERED!");

    service.invoke('proximity_triggered', {
      'device_name': _connectedDevice?.platformName ?? 'Unknown',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });

    // Start RSSI monitoring
    _startRSSIMonitoring();

    print("✅ Proximity behaviors completed");
  }

  Future<void> _startRSSIMonitoring() async {
    _rssiTimer?.cancel();

    _rssiTimer = Timer.periodic(Duration(seconds: 1), (timer) async {
      if (_connectedDevice != null &&
          _isAuthenticated &&
          _ledCharacteristic != null) {
        try {
          // Get RSSI from Flutter
          final rssi = await _connectedDevice!.readRssi();
          print("📶 RSSI: $rssi dBm - sending to Pico");

          // Send RSSI to Pico
          final rssiCommand = "rssi:$rssi";
          await _ledCharacteristic!.write(rssiCommand.codeUnits);
        } catch (e) {
          print("❌ Failed to read/send RSSI: $e");
        }
      }
    });

    print("📶 Started RSSI monitoring");
  }

  void _stopRSSIMonitoring() {
    _rssiTimer?.cancel();
    _rssiTimer = null;
    print("📶 Stopped RSSI monitoring");
  }

  void _onProximityLost() {
    print("📤 PROXIMITY LOST");
    _isConnected = false;
    _isAuthenticated = false;
    _connectedDevice = null;
    _ledCharacteristic = null;
    _authCharacteristic = null;

    // Stop RSSI monitoring
    _stopRSSIMonitoring();

    service.invoke('proximity_lost', {
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });

    service.invoke('status_update', {
      'status': 'Connection lost - Scanning again...',
      'connected': false,
      'authenticated': false,
    });

    Future.delayed(Duration(seconds: 2), () => _startScanning());
  }

  Future<void> _sendCommand(String command) async {
    if (_ledCharacteristic != null && _isAuthenticated) {
      try {
        await _ledCharacteristic!.write(command.codeUnits);
        print("📤 Sent command: $command");
      } catch (e) {
        print("❌ Failed to send command: $e");
      }
    } else {
      print("❌ Cannot send command - not authenticated or not connected");
    }
  }

  void _stopService() {
    print("🛑 Stopping proximity service...");
    FlutterBluePlus.stopScan();
    _scanSubscription?.cancel();
    _scanTimer?.cancel();
    _stopRSSIMonitoring();
    _connectedDevice?.disconnect();
    service.stopSelf();
  }
}

// Main Flutter App UI with Authentication
class PicoProximityApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pico Proximity Detector',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Color(0xFF1a1a2e),
        appBarTheme: AppBarTheme(
          backgroundColor: Color(0xFF16213e),
          elevation: 0,
        ),
      ),
      home: ProximityHomePage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class ProximityHomePage extends StatefulWidget {
  @override
  _ProximityHomePageState createState() => _ProximityHomePageState();
}

class _ProximityHomePageState extends State<ProximityHomePage> {
  bool _serviceRunning = false;
  String _currentStatus = "Service not started";
  bool _isConnected = false;
  bool _isAuthenticated = false;
  String _lastEvent = "No events yet";
  List<String> _eventLog = [];

  final _passwordController = TextEditingController();
  final _deviceNameController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _initializeServiceListener();
    _checkServiceStatus();
    _loadSavedCredentials();
  }

  void _loadSavedCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    final savedDeviceName = prefs.getString('device_name') ?? '';
    setState(() {
      _deviceNameController.text = savedDeviceName;
    });
  }

  void _initializeServiceListener() {
    final service = FlutterBackgroundService();

    service.on('status_update').listen((event) {
      if (mounted) {
        setState(() {
          _currentStatus = event?['status'] ?? 'Unknown';
          _isConnected = event?['connected'] ?? false;
          _isAuthenticated = event?['authenticated'] ?? false;
        });
      }
    });

    service.on('auth_required').listen((event) {
      if (mounted) {
        _showAuthenticationDialog();
      }
    });

    service.on('auth_success').listen((event) {
      if (mounted) {
        final message = event?['message'] ?? 'Authentication successful';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('✅ $message'), backgroundColor: Colors.green),
        );
      }
    });

    service.on('auth_failed').listen((event) {
      if (mounted) {
        final message = event?['message'] ?? 'Authentication failed';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('❌ $message'), backgroundColor: Colors.red),
        );
        _showAuthenticationDialog();
      }
    });

    service.on('proximity_triggered').listen((event) {
      if (mounted) {
        final deviceName = event?['device_name'] ?? 'Unknown';
        final eventText = "🎯 Proximity triggered: $deviceName";
        setState(() {
          _lastEvent = eventText;
          _eventLog.insert(
              0, "${DateTime.now().toString().substring(11, 19)} - $eventText");
          if (_eventLog.length > 10) _eventLog.removeLast();
        });
      }
    });

    service.on('proximity_lost').listen((event) {
      if (mounted) {
        const eventText = "📤 Proximity lost";
        setState(() {
          _lastEvent = eventText;
          _eventLog.insert(
              0, "${DateTime.now().toString().substring(11, 19)} - $eventText");
          if (_eventLog.length > 10) _eventLog.removeLast();
        });
      }
    });

    service.on('heartbeat').listen((event) {
      if (mounted && _serviceRunning) {
        final connected = event?['connected'] ?? false;
        final authenticated = event?['authenticated'] ?? false;
        final device = event?['device'] ?? 'None';
        setState(() {
          _isConnected = connected;
          _isAuthenticated = authenticated;
          if (connected &&
              authenticated &&
              _currentStatus.contains('Scanning')) {
            _currentStatus = "Connected & Authenticated to $device";
          }
        });
      }
    });
  }

  void _showAuthenticationDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('🔑 Authenticate Device'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Enter the Pico W password to add this device as trusted:'),
              SizedBox(height: 20),
              TextField(
                controller: _deviceNameController,
                decoration: InputDecoration(
                  labelText: 'Device Name',
                  hintText: 'My Phone',
                  border: OutlineInputBorder(),
                ),
              ),
              SizedBox(height: 15),
              TextField(
                controller: _passwordController,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'Password',
                  hintText: 'Enter Pico W password',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                final password = _passwordController.text.trim();
                final deviceName = _deviceNameController.text.trim();

                if (password.isNotEmpty && deviceName.isNotEmpty) {
                  Navigator.of(context).pop();
                  _authenticateDevice(password, deviceName);
                  _passwordController.clear();
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Please fill in both fields')),
                  );
                }
              },
              child: Text('Authenticate'),
            ),
          ],
        );
      },
    );
  }

  void _authenticateDevice(String password, String deviceName) {
    final service = FlutterBackgroundService();
    service.invoke('authenticate', {
      'password': password,
      'deviceName': deviceName,
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('🔑 Authenticating device...')),
    );
  }

  void _checkServiceStatus() async {
    final service = FlutterBackgroundService();
    final isRunning = await service.isRunning();
    setState(() {
      _serviceRunning = isRunning;
      if (!isRunning) {
        _currentStatus = "Service not running";
        _isConnected = false;
        _isAuthenticated = false;
      }
    });
  }

  Future<void> _requestPermissions() async {
    final permissions = [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ];

    for (Permission permission in permissions) {
      final status = await permission.request();
      if (status != PermissionStatus.granted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Permission ${permission.toString()} denied')),
        );
      }
    }
  }

  Future<void> _toggleService() async {
    if (_serviceRunning) {
      _stopService();
    } else {
      await _startService();
    }
  }

  Future<void> _startService() async {
    await _requestPermissions();

    final service = FlutterBackgroundService();
    await service.startService();

    setState(() {
      _serviceRunning = true;
      _currentStatus = "Starting service...";
      _lastEvent = "Service started";
      _eventLog.insert(0,
          "${DateTime.now().toString().substring(11, 19)} - Service started");
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('🚀 Background proximity service started!')),
    );
  }

  void _stopService() {
    final service = FlutterBackgroundService();
    service.invoke('stop_service');

    setState(() {
      _serviceRunning = false;
      _currentStatus = "Service stopped";
      _isConnected = false;
      _isAuthenticated = false;
      _lastEvent = "Service stopped";
      _eventLog.insert(0,
          "${DateTime.now().toString().substring(11, 19)} - Service stopped");
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('🛑 Service stopped')),
    );
  }

  void _sendManualCommand(String command) {
    if (!_isConnected || !_isAuthenticated) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Not connected or not authenticated')),
      );
      return;
    }

    final service = FlutterBackgroundService();
    service.invoke('send_command', {'command': command});

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('📤 Sent command: $command')),
    );
  }

  void _clearSavedCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('pico_password');
    await prefs.remove('device_name');

    setState(() {
      _deviceNameController.clear();
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('🗑️ Saved credentials cleared')),
    );
  }

  void _showManualAuthDialog() {
    if (!_isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Not connected to Pico W')),
      );
      return;
    }
    _showAuthenticationDialog();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('🔐 Secure Pico Proximity'),
        centerTitle: true,
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'clear_credentials') {
                _clearSavedCredentials();
              } else if (value == 'manual_auth') {
                _showManualAuthDialog();
              }
            },
            itemBuilder: (BuildContext context) => [
              PopupMenuItem(
                value: 'manual_auth',
                child: Text('🔑 Manual Authentication'),
              ),
              PopupMenuItem(
                value: 'clear_credentials',
                child: Text('🗑️ Clear Saved Credentials'),
              ),
            ],
          ),
        ],
      ),
      body: Padding(
        padding: EdgeInsets.all(20),
        child: Column(
          children: [
            // Status Card
            Card(
              color: Color(0xFF16213e),
              child: Padding(
                padding: EdgeInsets.all(20),
                child: Column(
                  children: [
                    Icon(
                      _serviceRunning
                          ? (_isAuthenticated
                              ? Icons.verified_user
                              : (_isConnected
                                  ? Icons.bluetooth_searching
                                  : Icons.bluetooth_searching))
                          : Icons.bluetooth_disabled,
                      size: 60,
                      color: _serviceRunning
                          ? (_isAuthenticated
                              ? Colors.green
                              : (_isConnected ? Colors.orange : Colors.yellow))
                          : Colors.grey,
                    ),
                    SizedBox(height: 15),
                    Text(
                      _serviceRunning
                          ? (_isAuthenticated
                              ? 'Authenticated & Active'
                              : (_isConnected
                                  ? 'Connected - Not Authenticated'
                                  : 'Service Active'))
                          : 'Service Inactive',
                      style:
                          TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center,
                    ),
                    SizedBox(height: 10),
                    Text(
                      _currentStatus,
                      style: TextStyle(fontSize: 16, color: Colors.white70),
                      textAlign: TextAlign.center,
                    ),
                    if (_isConnected && !_isAuthenticated) ...[
                      SizedBox(height: 15),
                      ElevatedButton.icon(
                        onPressed: _showManualAuthDialog,
                        icon: Icon(Icons.lock_open),
                        label: Text('Authenticate Now'),
                        style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.orange[700]),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            SizedBox(height: 20),

            // Control Buttons
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: _toggleService,
                    child: Text(_serviceRunning
                        ? '🛑 Stop Service'
                        : '🚀 Start Service'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor:
                          _serviceRunning ? Colors.red[600] : Colors.green[600],
                      padding: EdgeInsets.symmetric(vertical: 15),
                    ),
                  ),
                ),
              ],
            ),

            SizedBox(height: 20),

            // Authentication Status
            if (_isConnected) ...[
              Card(
                color: _isAuthenticated ? Color(0xFF1e4620) : Color(0xFF4a2c2a),
                child: Padding(
                  padding: EdgeInsets.all(15),
                  child: Row(
                    children: [
                      Icon(
                        _isAuthenticated ? Icons.verified_user : Icons.warning,
                        color: _isAuthenticated ? Colors.green : Colors.orange,
                        size: 30,
                      ),
                      SizedBox(width: 15),
                      Expanded(
                        child: Text(
                          _isAuthenticated
                              ? 'Device authenticated and trusted'
                              : 'Device connected but not authenticated',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: _isAuthenticated
                                ? Colors.green[200]
                                : Colors.orange[200],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(height: 20),
            ],

            // Manual Control Buttons (when authenticated)
            if (_isAuthenticated) ...[
              Text('Manual LED Control:',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => _sendManualCommand('on'),
                      child: Text('💡 LED ON'),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green[700]),
                    ),
                  ),
                  SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => _sendManualCommand('off'),
                      child: Text('⚫ LED OFF'),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red[700]),
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => _sendManualCommand('toggle'),
                      child: Text('🔄 Toggle'),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue[700]),
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => _sendManualCommand('unlock'),
                      child: Text('🔓 Unlock'),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.purple[700]),
                    ),
                  ),
                  SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => _sendManualCommand('lock'),
                      child: Text('🔒 Lock'),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.grey[700]),
                    ),
                  ),
                ],
              ),
              SizedBox(height: 20),
            ],

            // Info Box
            Card(
              color: Color(0xFF2a2a3e),
              child: Padding(
                padding: EdgeInsets.all(15),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'How Authentication Works:',
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.blue[200]),
                    ),
                    SizedBox(height: 8),
                    Text('• First connection requires Pico W password',
                        style: TextStyle(fontSize: 13)),
                    Text('• Device gets added to trusted devices list',
                        style: TextStyle(fontSize: 13)),
                    Text('• Future connections authenticate automatically',
                        style: TextStyle(fontSize: 13)),
                    Text(
                        '• Only authenticated devices trigger proximity behaviors',
                        style: TextStyle(fontSize: 13)),
                  ],
                ),
              ),
            ),

            SizedBox(height: 15),

            // Event Log
            Expanded(
              child: Card(
                color: Color(0xFF16213e),
                child: Padding(
                  padding: EdgeInsets.all(15),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Recent Events:',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      SizedBox(height: 10),
                      Expanded(
                        child: ListView.builder(
                          itemCount: _eventLog.length,
                          itemBuilder: (context, index) {
                            return Padding(
                              padding: EdgeInsets.symmetric(vertical: 2),
                              child: Text(
                                _eventLog[index],
                                style: TextStyle(
                                  fontSize: 12,
                                  fontFamily: 'monospace',
                                  color: Colors.white70,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _passwordController.dispose();
    _deviceNameController.dispose();
    super.dispose();
  }
}

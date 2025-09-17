import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:logger/logger.dart';

import 'page2.dart'; // ✅ import the second page

// ✅ Setup logger
final logger = Logger();

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bluetooth Demo',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const BluetoothDeviceListScreen(),
    );
  }
}

// ================== DEVICE LIST SCREEN ==================
class BluetoothDeviceListScreen extends StatefulWidget {
  const BluetoothDeviceListScreen({super.key});

  @override
  State<BluetoothDeviceListScreen> createState() =>
      _BluetoothDeviceListScreenState();
}

class _BluetoothDeviceListScreenState
    extends State<BluetoothDeviceListScreen> {
  final List<ScanResult> scanResults = [];
  bool isScanning = false;

  @override
  void initState() {
    super.initState();
    checkPermissions();
  }

  Future<void> checkPermissions() async {
    await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();
  }

  void startScan() {
    setState(() => isScanning = true);
    scanResults.clear();

    FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));

    FlutterBluePlus.scanResults.listen((results) {
      if (!mounted) return;
      setState(() {
        scanResults
          ..clear()
          ..addAll(
            results.where((r) =>
                r.device.remoteId.toString().toUpperCase().startsWith("00:80")),
          ); // 🔹 only MACs starting with 00:80
      });
    });

    FlutterBluePlus.isScanning.listen((scanning) {
      if (!mounted) return;
      setState(() => isScanning = scanning);
    });
  }

  Future<void> connectToDevice(BluetoothDevice device) async {
    logger.i("Trying to connect to ${device.platformName} (${device.remoteId})");

    if (!mounted) return;

    // Show loading dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      await device.connect(autoConnect: false).catchError((e) {
        if (!e.toString().contains("already connected")) throw e;
        logger.w("Device already connected, ignoring exception.");
      });

      late final StreamSubscription<BluetoothConnectionState> subscription;

      subscription = device.connectionState.listen((state) async {
        if (state == BluetoothConnectionState.connected && mounted) {
          logger.i("Device connected successfully!");

          if (Navigator.canPop(context)) Navigator.pop(context);

          if (mounted) {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ConnectedDeviceScreen(device: device),
              ),
            );
          }

          await subscription.cancel();
        }
      });
    } catch (e) {
      logger.e("Connection failed: $e");
      if (!mounted) return;
      if (Navigator.canPop(context)) Navigator.pop(context);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Connection failed: $e")),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Bluetooth Devices"),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: isScanning ? null : startScan,
          ),
        ],
      ),
      body: isScanning
          ? const Center(child: CircularProgressIndicator())
          : scanResults.isEmpty
              ? const Center(
                  child: Text(
                    "No devices found with MAC starting 00:80",
                    style: TextStyle(fontSize: 16),
                  ),
                )
              : ListView.builder(
                  itemCount: scanResults.length,
                  itemBuilder: (context, index) {
                    final result = scanResults[index];
                    return ListTile(
                      title: Text(result.device.platformName.isNotEmpty
                          ? result.device.platformName
                          : "Unknown Device"),
                      subtitle: Text(result.device.remoteId.toString()),
                      trailing: ElevatedButton(
                        onPressed: () => connectToDevice(result.device),
                        child: const Text("Connect"),
                      ),
                    );
                  },
                ),
    );
  }
}

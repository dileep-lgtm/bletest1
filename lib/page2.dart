import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:logger/logger.dart';
import 'package:fl_chart/fl_chart.dart';

final logger = Logger();

class ConnectedDeviceScreen extends StatefulWidget {
  final BluetoothDevice device;

  const ConnectedDeviceScreen({super.key, required this.device});

  @override
  State<ConnectedDeviceScreen> createState() => _ConnectedDeviceScreenState();
}

class _ConnectedDeviceScreenState extends State<ConnectedDeviceScreen> {
  StreamSubscription<List<int>>? _notifySubAA21;
  StreamSubscription<List<int>>? _notifySubAA03;

  final List<FlSpot> _dataAA21 = [];
  final List<FlSpot> _dataAA03 = [];

  double _xAA21 = 0;
  double _xAA03 = 0;

  bool _loading = true;

  @override
  void initState() {
    super.initState();

    // Auto return to device list if disconnected
    widget.device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected && mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    });

    _subscribeToCharacteristics();
  }

  @override
  void dispose() {
    _notifySubAA21?.cancel();
    _notifySubAA03?.cancel();
    super.dispose();
  }

  /// Converts big-endian bytes to int
  int _bigEndianToInt(List<int> bytes, {bool signed = false}) {
    if (bytes.isEmpty) return 0;
    int result = 0;
    for (final b in bytes) {
      result = (result << 8) | (b & 0xFF);
    }
    if (signed) {
      final int bits = bytes.length * 8;
      final int signBit = 1 << (bits - 1);
      if ((result & signBit) != 0) {
        result -= 1 << bits;
      }
    }
    return result;
  }

  Future<void> _subscribeToCharacteristics() async {
    try {
      final services = await widget.device.discoverServices();

      // ---- Subscribe to AA21 ----
      final serviceAA20 = services.firstWhere(
        (s) => s.uuid.toString().toLowerCase().contains("0000aa20"),
        orElse: () => throw Exception("Service 0000aa20 not found"),
      );

      final charAA21 = serviceAA20.characteristics.firstWhere(
        (c) => c.uuid.toString().toLowerCase().contains("0000aa21"),
        orElse: () => throw Exception("Characteristic 0000aa21 not found"),
      );

      await charAA21.setNotifyValue(true);
      _notifySubAA21 = charAA21.onValueReceived.listen((value) {
        if (value.isNotEmpty) {
          final number = _bigEndianToInt(value, signed: false);

          logger.i(
            "[AA21] HEX=${value.map((b) => b.toRadixString(16).padLeft(2, '0')).join()} -> $number",
          );

          setState(() {
            _xAA21 += 1;
            _dataAA21.add(FlSpot(_xAA21, number.toDouble()));
            if (_dataAA21.length > 500) _dataAA21.removeAt(0);
          });
        }
      });

      // ---- Subscribe to AA03 ----
      final serviceAA00 = services.firstWhere(
        (s) => s.uuid.toString().toLowerCase().contains("0000aa00"),
        orElse: () => throw Exception("Service 0000aa00 not found"),
      );

      final charAA03 = serviceAA00.characteristics.firstWhere(
        (c) => c.uuid.toString().toLowerCase().contains("0000aa03"),
        orElse: () => throw Exception("Characteristic 0000aa03 not found"),
      );

      await charAA03.setNotifyValue(true);
      _notifySubAA03 = charAA03.onValueReceived.listen((value) {
        if (value.isNotEmpty) {
          final number = _bigEndianToInt(value, signed: false);
          final scaledNumber = number * 0.002;

          logger.i(
            "[AA03] HEX=${value.map((b) => b.toRadixString(16).padLeft(2, '0')).join()} "
            "-> raw: $number, scaled: $scaledNumber",
          );

          setState(() {
            _xAA03 += 1;
            _dataAA03.add(FlSpot(_xAA03, scaledNumber.toDouble()));
            if (_dataAA03.length > 50) _dataAA03.removeAt(0);
          });
        }
      });

      setState(() => _loading = false);
    } catch (e) {
      logger.e("Error subscribing: $e");
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _disconnectDevice() async {
    try {
      logger.i("Disconnecting device...");

      await _notifySubAA21?.cancel();
      await _notifySubAA03?.cancel();

      await widget.device.disconnect();

      logger.i("Device disconnected.");
    } catch (e) {
      logger.w("Error disconnecting: $e");
    }
  }

  Widget _buildGraph(List<FlSpot> data, String title, Color color) {
    final graphHeight = MediaQuery.of(context).size.height / 4;

    // Safe dynamic Y axis
    final double minY = data.isNotEmpty
        ? data.map((e) => e.y).reduce((a, b) => a < b ? a : b)
        : 0.0;
    final double maxY = data.isNotEmpty
        ? data.map((e) => e.y).reduce((a, b) => a > b ? a : b)
        : 100.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        SizedBox(
          height: graphHeight,
          child: LineChart(
            LineChartData(
              minY: minY,
              maxY: maxY,
              titlesData: FlTitlesData(show: false),
              gridData: FlGridData(show: true),
              borderData: FlBorderData(show: true),
              lineBarsData: [
                LineChartBarData(
                  spots: data,
                  isCurved: true,
                  color: color,
                  barWidth: 2,
                  dotData: FlDotData(show: false),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("Live Data - ${widget.device.platformName}"),
        actions: [
          IconButton(
            icon: const Icon(Icons.link_off),
            onPressed: _disconnectDevice,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  _buildGraph(_dataAA21, "ECG (0xAA21)", Colors.red),
                  _buildGraph(_dataAA03, "PPG (0xAA03)", Colors.green),
                ],
              ),
            ),
    );
  }
}

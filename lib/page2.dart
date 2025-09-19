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

  final List<double> _ecgWindow = []; // buffer for moving average

  double _xAA21 = 0;
  double _xAA03 = 0;

  bool _loading = true;

  // sweep limits
  static const int _maxXAA21 = 1000; // ECG
  static const int _maxXAA03 = 100;  // PPG

  @override
  void initState() {
    super.initState();

    // Auto return if disconnected
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

  double _applyEcgMovingAverage(double newValue) {
    // keep last 3 values
    _ecgWindow.add(newValue);
    if (_ecgWindow.length > 3) {
      _ecgWindow.removeAt(0);
    }

    // compute average
    double sum = 0;
    for (final v in _ecgWindow) {
      sum += v;
    }
    return sum / _ecgWindow.length;
  }

  Future<void> _subscribeToCharacteristics() async {
    try {
      final services = await widget.device.discoverServices();

      // --- ECG (AA21) ---
      final serviceAA20 = services.firstWhere(
        (s) => s.uuid.toString().toLowerCase().contains("0000aa20"),
      );
      final charAA21 = serviceAA20.characteristics.firstWhere(
        (c) => c.uuid.toString().toLowerCase().contains("0000aa21"),
      );

      await charAA21.setNotifyValue(true);
      _notifySubAA21 = charAA21.onValueReceived.listen((value) {
        if (value.isNotEmpty) {
          final raw = _bigEndianToInt(value);
          final filtered = _applyEcgMovingAverage(raw.toDouble());

          setState(() {
            _xAA21 += 1;
            if (_xAA21 > _maxXAA21) {
              _xAA21 = 0;
              _dataAA21.clear();
            }
            _dataAA21.add(FlSpot(_xAA21, filtered));
          });
        }
      });

      // --- PPG (AA03) ---
      final serviceAA00 = services.firstWhere(
        (s) => s.uuid.toString().toLowerCase().contains("0000aa00"),
      );
      final charAA03 = serviceAA00.characteristics.firstWhere(
        (c) => c.uuid.toString().toLowerCase().contains("0000aa03"),
      );

      await charAA03.setNotifyValue(true);
      _notifySubAA03 = charAA03.onValueReceived.listen((value) {
        if (value.isNotEmpty) {
          final number = _bigEndianToInt(value);
          final scaled = number * 0.002;

          setState(() {
            _xAA03 += 1;
            if (_xAA03 > _maxXAA03) {
              _xAA03 = 0;
              _dataAA03.clear();
            }
            _dataAA03.add(FlSpot(_xAA03, scaled));
          });
        }
      });

      setState(() => _loading = false);
    } catch (e) {
      logger.e("Error subscribing: $e");
      setState(() => _loading = false);
    }
  }

  Future<void> _disconnectDevice() async {
    try {
      await _notifySubAA21?.cancel();
      await _notifySubAA03?.cancel();
      await widget.device.disconnect();
    } catch (_) {}
  }

  Widget _buildGraph(List<FlSpot> data, String title, double maxX) {
    final graphHeight = MediaQuery.of(context).size.height / 4;
    final FlSpot? latest = data.isNotEmpty ? data.last : null;

    final double minY = data.isNotEmpty ? data.map((e) => e.y).reduce((a, b) => a < b ? a : b) - 10 : 0;
    final double maxY = data.isNotEmpty ? data.map((e) => e.y).reduce((a, b) => a > b ? a : b) + 10 : 100;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        SizedBox(
          height: graphHeight,
          child: LineChart(
            LineChartData(
              minX: 0,
              maxX: maxX.toDouble(),
              minY: minY,
              maxY: maxY,
              titlesData: FlTitlesData(show: false),
              gridData: FlGridData(show: true),
              borderData: FlBorderData(show: true),
              lineBarsData: [
                // Full waveform
                LineChartBarData(
                  spots: data,
                  isCurved: false,
                  color: Colors.blue,
                  barWidth: 2,
                  dotData: FlDotData(show: false),
                ),
                // Green moving dot
                if (latest != null)
                  LineChartBarData(
                    spots: [latest],
                    isCurved: false,
                    color: Colors.green,
                    barWidth: 0,
                    dotData: FlDotData(
                      show: true,
                      getDotPainter: (spot, _, __, ___) => FlDotCirclePainter(
                        radius: 5,
                        color: Colors.green,
                        strokeWidth: 0,
                      ),
                    ),
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
                  _buildGraph(_dataAA21, "ECG (0xAA21, 3-pt MA)", _maxXAA21.toDouble()),
                  _buildGraph(_dataAA03, "PPG (0xAA03)", _maxXAA03.toDouble()),
                ],
              ),
            ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:jackfield/jackfield.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  String _adapter = 'Loading';
  final _jackfieldPlugin = Jackfield.instance;

  @override
  void initState() {
    super.initState();
    loadCapabilities();
  }

  Future<void> loadCapabilities() async {
    String adapter;
    try {
      final capabilities = await _jackfieldPlugin.capabilities();
      adapter = '${capabilities.platform} / ${capabilities.mechanism.name}';
    } on JackfieldTransportException {
      adapter = 'Unavailable';
    } on JackfieldProtocolException {
      adapter = 'Invalid adapter response';
    }

    // If the widget was removed from the tree while the asynchronous platform
    // message was in flight, we want to discard the reply rather than calling
    // setState to update our non-existent appearance.
    if (!mounted) return;

    setState(() {
      _adapter = adapter;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Plugin example app')),
        body: Center(child: Text('Adapter: $_adapter')),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:jackfield/jackfield.dart';

import 'call_controller.dart';
import 'screens/diagnostics_screen.dart';
import 'screens/home_screen.dart';

class JackfieldApp extends StatefulWidget {
  const JackfieldApp({super.key, this.controller});

  final CallController? controller;

  @override
  State<JackfieldApp> createState() => _JackfieldAppState();
}

class _JackfieldAppState extends State<JackfieldApp> {
  late final CallController controller =
      widget.controller ??
      CallController(jackfield: Jackfield.instance, signaling: FakeSignaling());

  @override
  void initState() {
    super.initState();
    controller.refresh();
    controller.initialize();
  }

  @override
  void dispose() {
    if (widget.controller == null) controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Jackfield manual stand',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Jackfield: ручной стенд'),
            bottom: const TabBar(
              tabs: [
                Tab(text: 'Звонки', icon: Icon(Icons.call)),
                Tab(text: 'Диагностика', icon: Icon(Icons.medical_information)),
              ],
            ),
          ),
          body: TabBarView(
            children: [
              HomeScreen(controller: controller),
              DiagnosticsScreen(controller: controller),
            ],
          ),
        ),
      ),
    );
  }
}

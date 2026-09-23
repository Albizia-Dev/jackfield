import 'package:flutter/material.dart';

import '../call_controller.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({required this.controller, super.key});
  final CallController controller;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _callId = TextEditingController();
  final _party = TextEditingController(text: 'Manual tester');

  @override
  void dispose() {
    _callId.dispose();
    _party.dispose();
    super.dispose();
  }

  String get _id => _callId.text.trim().isEmpty
      ? 'manual-${DateTime.now().microsecondsSinceEpoch}'
      : _callId.text.trim();

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) => ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Ручная проверка системного UI. Сигналинг имитируется; медиа остаётся ответственностью приложения.',
        ),
        const SizedBox(height: 12),
        Text(
          'Adapter: ${widget.controller.capabilities?.platform ?? 'Loading'} / ${widget.controller.capabilities?.mechanism.name ?? 'Loading'}',
        ),
        Text('Статус: ${widget.controller.status}', key: const Key('status')),
        TextField(
          controller: _callId,
          decoration: const InputDecoration(
            labelText: 'Call ID (пусто = новый)',
          ),
        ),
        TextField(
          controller: _party,
          decoration: const InputDecoration(
            labelText: 'Имя или ID собеседника',
          ),
        ),
        const SizedBox(height: 12),
        SwitchListTile(
          title: const Text('Имитация сигналинга успешна'),
          subtitle: const Text('Выключите для проверки отказа после ответа'),
          value: widget.controller.signaling is FakeSignaling
              ? (widget.controller.signaling as FakeSignaling).shouldConnect
              : true,
          onChanged: widget.controller.signaling is FakeSignaling
              ? (value) => setState(
                  () =>
                      (widget.controller.signaling as FakeSignaling)
                              .shouldConnect =
                          value,
                )
              : null,
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: () =>
                  widget.controller.incoming(callId: _id, party: _party.text),
              icon: const Icon(Icons.call_received),
              label: const Text('Показать входящий'),
            ),
            FilledButton.icon(
              onPressed: () =>
                  widget.controller.outgoing(callId: _id, party: _party.text),
              icon: const Icon(Icons.call_made),
              label: const Text('Начать исходящий'),
            ),
            OutlinedButton.icon(
              onPressed: widget.controller.endCurrentCall,
              icon: const Icon(Icons.call_end),
              label: const Text('Завершить выбранный'),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Text('События', style: Theme.of(context).textTheme.titleMedium),
        if (widget.controller.eventLog.isEmpty) const Text('Событий пока нет'),
        for (final item in widget.controller.eventLog) SelectableText(item),
      ],
    ),
  );
}

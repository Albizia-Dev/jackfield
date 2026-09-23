import 'package:flutter/material.dart';
import 'package:jackfield/jackfield.dart';

import '../call_controller.dart';

class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({required this.controller, super.key});
  final CallController controller;

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  final _endpoint = TextEditingController();
  final _bearer = TextEditingController();
  String? _inputError;

  @override
  void dispose() {
    _endpoint.dispose();
    _bearer.dispose();
    super.dispose();
  }

  Future<void> _applyCallback() async {
    final url = Uri.tryParse(_endpoint.text.trim());
    if (url == null ||
        url.scheme != 'https' ||
        url.host.isEmpty ||
        _bearer.text.isEmpty) {
      setState(() => _inputError = 'Укажите HTTPS URL и непустой bearer token');
      return;
    }
    final token = _bearer.text;
    _bearer.clear();
    setState(() => _inputError = null);
    await widget.controller.initialize(
      callbacks: CallbackConfiguration(
        endpoint: url,
        auth: CallbackAuth.bearer(token),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final capabilities = widget.controller.capabilities;
      final diagnostics = widget.controller.diagnostics;
      final unavailable = JackfieldFeature.values.where(
        (feature) => !(capabilities?.features.contains(feature) ?? false),
      );
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Возможности', style: Theme.of(context).textTheme.titleLarge),
          SelectableText(
            'Платформа: ${capabilities?.platform ?? 'не получена'}\nМеханизм: ${capabilities?.mechanism.name ?? 'неизвестен'}\nОграничение: ${capabilities?.reason ?? 'не указано'}\nНедоступно: ${unavailable.map((e) => e.name).join(', ')}',
          ),
          const SizedBox(height: 12),
          Text('Диагностика', style: Theme.of(context).textTheme.titleLarge),
          SelectableText(
            'Механизм: ${diagnostics?.mechanism.name ?? 'неизвестен'}\nFlutter inbox: ${diagnostics?.pendingFlutterEvents ?? 'неизвестно'}\nHTTP outbox: ${diagnostics?.pendingHttpEvents ?? 'неизвестно'}\nHTTP auth pause: ${diagnostics?.httpPausedForAuthentication ?? 'неизвестно'}\nПоследняя ошибка: ${diagnostics?.lastError?.code.name ?? 'нет'}\nРазрешения: ${diagnostics?.permissions.entries.map((e) => '${e.key}=${e.value.name}').join(', ') ?? 'неизвестно'}',
          ),
          TextButton.icon(
            onPressed: widget.controller.refresh,
            icon: const Icon(Icons.refresh),
            label: const Text('Обновить диагностику'),
          ),
          const Divider(),
          Text(
            'Автономный HTTPS callback',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const Text(
            'Только ручная настройка. Токен очищается из поля после применения; используйте тестовые секреты.',
          ),
          TextField(
            controller: _endpoint,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(labelText: 'HTTPS endpoint'),
          ),
          TextField(
            controller: _bearer,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Bearer token'),
          ),
          if (_inputError != null)
            Text(
              _inputError!,
              semanticsLabel: 'Ошибка настройки callback: $_inputError',
            ),
          FilledButton(
            onPressed: _applyCallback,
            child: const Text('Применить callback'),
          ),
          const Divider(),
          Text('Push tokens', style: Theme.of(context).textTheme.titleMedium),
          const Text(
            'Снимок не запрашивает системное разрешение. Значения чувствительны: используйте только тестовые токены.',
          ),
          OutlinedButton(
            onPressed: widget.controller.inspectTokens,
            child: const Text('Показать токены'),
          ),
          if (widget.controller.tokens != null &&
              widget.controller.tokens!.tokens.isEmpty)
            const Text('Токенов нет'),
          for (final token in widget.controller.tokens?.tokens ?? <PushToken>[])
            SelectableText('${token.provider}: ${token.value}'),
        ],
      );
    },
  );
}

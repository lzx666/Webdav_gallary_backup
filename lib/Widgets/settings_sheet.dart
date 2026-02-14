import 'package:flutter/material.dart';

class SettingsSheet extends StatelessWidget {
  final TextEditingController urlCtrl;
  final TextEditingController userCtrl;
  final TextEditingController passCtrl;
  final VoidCallback onSave;

  const SettingsSheet({
    super.key,
    required this.urlCtrl,
    required this.userCtrl,
    required this.passCtrl,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.fromLTRB(
        24, 
        24, 
        24, 
        MediaQuery.of(context).viewInsets.bottom + 24
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("连接设置", style: theme.textTheme.headlineSmall),
          const SizedBox(height: 24),
          TextField(
            controller: urlCtrl,
            decoration: const InputDecoration(
              labelText: "WebDAV URL",
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.link),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: userCtrl,
            decoration: const InputDecoration(
              labelText: "用户名",
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.person_outline),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: passCtrl,
            decoration: const InputDecoration(
              labelText: "密码",
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.lock_outline),
            ),
            obscureText: true,
          ),
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () {
                Navigator.pop(context);
                onSave();
              },
              child: const Text("保存并备份"),
            ),
          ),
        ],
      ),
    );
  }
}
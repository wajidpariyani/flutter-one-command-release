import 'package:flutter/material.dart';

// Injected at build time by scripts/build_*.sh via --dart-define-from-file
// (config/dev.json or config/prod.json) and --dart-define.
const appEnv = String.fromEnvironment('APP_ENV', defaultValue: 'local');
const apiBaseUrl =
    String.fromEnvironment('API_BASE_URL', defaultValue: 'http://localhost');
const buildVersion =
    String.fromEnvironment('BUILD_VERSION', defaultValue: 'unversioned');

void main() => runApp(const BuildDemoApp());

class BuildDemoApp extends StatelessWidget {
  const BuildDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    final isProd = appEnv == 'prod';
    return MaterialApp(
      title: 'Build Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: isProd ? Colors.deepPurple : Colors.teal,
        useMaterial3: true,
      ),
      home: Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isProd ? Icons.rocket_launch : Icons.build_circle,
                size: 96,
              ),
              const SizedBox(height: 24),
              Text(
                appEnv.toUpperCase(),
                style: Theme.of(context).textTheme.displayMedium,
              ),
              const SizedBox(height: 8),
              Text('v$buildVersion'),
              const SizedBox(height: 4),
              Text(apiBaseUrl),
            ],
          ),
        ),
      ),
    );
  }
}

// lib/screens/menu_teste_screen.dart
import 'package:flutter/material.dart';
import 'mapa_screen.dart';
import 'mapa_3d_teste_screen.dart';

class MenuTesteScreen extends StatelessWidget {
  const MenuTesteScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('NaviFake - Menu de Testes')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const MapaScreen()),
                );
              },
              child: const Text('Mapa Atual (2D)'),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const Mapa3DTesteScreen()),
                );
              },
              child: const Text('Testar Mapa 3D'),
            ),
          ],
        ),
      ),
    );
  }
}

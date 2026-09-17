// lib/screens/mapa_3d_teste_screen.dart
import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

class Mapa3DTesteScreen extends StatefulWidget {
  const Mapa3DTesteScreen({super.key});

  @override
  State<Mapa3DTesteScreen> createState() => _Mapa3DTesteScreenState();
}

class _Mapa3DTesteScreenState extends State<Mapa3DTesteScreen> {
  MaplibreMapController? _controller;

  // Estilo gratuito do OpenFreeMap (sem chave de API, sem limite).
  // "bright" é um dos estilos prontos deles, com prédios em 3D.
  static const String _estiloMapa =
      'https://tiles.openfreemap.org/styles/bright';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Teste Mapa 3D')),
      body: MaplibreMap(
        styleString: _estiloMapa,
        initialCameraPosition: const CameraPosition(
          target: LatLng(-23.5505, -46.6333), // São Paulo
          zoom: 16,
          tilt: 60, // inclinação da câmera — dá a sensação 3D
        ),
        onMapCreated: (controller) {
          _controller = controller;
        },
      ),
    );
  }
}

import 'package:latlong2/latlong.dart';

class InstrucaoNavegacao {
  final String texto;       // Frase já traduzida, ex: "Vire à esquerda"
  final LatLng ponto;        // Onde a manobra ocorre
  final double distanciaMetros; // Distância desse trecho até a manobra
  bool jaFalada;

  InstrucaoNavegacao({
    required this.texto,
    required this.ponto,
    required this.distanciaMetros,
    this.jaFalada = false,
  });
}

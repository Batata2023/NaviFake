class Alerta {
  final String? id;
  final String tipo;
  final double latitude;
  final double longitude;
  final int timestamp;

  Alerta({
    this.id,
    required this.tipo,
    required this.latitude,
    required this.longitude,
    required this.timestamp,
  });

  // Converte o objeto Alerta em Map, formato que o Firebase entende
  Map<String, dynamic> toMap() {
    return {
      'tipo': tipo,
      'latitude': latitude,
      'longitude': longitude,
      'timestamp': timestamp,
    };
  }

  // Converte os dados que vêm do Firebase de volta em um objeto Alerta
  factory Alerta.fromMap(String id, Map<dynamic, dynamic> map) {
    return Alerta(
      id: id,
      tipo: map['tipo'],
      latitude: map['latitude'],
      longitude: map['longitude'],
      timestamp: map['timestamp'],
    );
  }
}

// Mapa com os tipos de alerta disponíveis no app
const tiposDeAlerta = {
  'radar_fixo': '🚓 Radar fixo',
  'radar_movel': '📸 Radar móvel',
  'transito': '🚧 Trânsito/lentidão',
  'acidente': '⚠️ Acidente',
  'blitz': '🚔 Blitz policial',
  'animal_pista': '🐄 Animal na pista',
  'buraco': '🕳️ Buraco na via',
  'lombada': '🐢 Lombada',
};

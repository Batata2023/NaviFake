import 'package:firebase_database/firebase_database.dart';
import '../models/alerta.dart';

class AlertaService {
  final DatabaseReference _ref =
      FirebaseDatabase.instance.ref('alertas');

  // Tempo (em milissegundos) que um alerta permanece válido: 4 horas
  static const int _tempoExpiracaoMs = 4 * 60 * 60 * 1000;

  Future<void> reportarAlerta(Alerta alerta) async {
    await _ref.push().set(alerta.toMap());
  }

  // Escuta os alertas em tempo real, filtrando os expirados
  // e removendo-os do banco de forma oportunista.
  Stream<List<Alerta>> escutarAlertas() {
    return _ref.onValue.map((DatabaseEvent event) {
      final data = event.snapshot.value as Map<dynamic, dynamic>?;

      if (data == null) return <Alerta>[];

      final agora = DateTime.now().millisecondsSinceEpoch;
      final List<Alerta> validos = [];

      for (final entry in data.entries) {
        final alerta = Alerta.fromMap(
          entry.key.toString(),
          entry.value as Map<dynamic, dynamic>,
        );

        final expirado = (agora - alerta.timestamp) > _tempoExpiracaoMs;

        if (expirado) {
          // Limpeza oportunista: remove do banco quando alguém detecta que venceu
         if (alerta.id != null) {
  removerAlerta(alerta.id!);
}

        } else {
          validos.add(alerta);
        }
      }

      return validos;
    });
  }

  Future<void> removerAlerta(String id) async {
    await _ref.child(id).remove();
  }
}

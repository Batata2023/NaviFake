import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import '../models/alerta.dart';
import '../services/alerta_service.dart';
import 'package:flutter_tts/flutter_tts.dart';
import '../utils/traducao_manobra.dart';
import '../models/instrucao_navegacao.dart';

class MapaScreen extends StatefulWidget {
  const MapaScreen({super.key});

  @override
  State<MapaScreen> createState() => _MapaScreenState();
}

class _MapaScreenState extends State<MapaScreen> {
  LatLng? _minhaLocalizacao;
  LatLng? _destino;
  List<LatLng> _pontosRota = [];
  final MapController _mapController = MapController();
  StreamSubscription<Position>? _streamPosicao;
  bool _primeiraLocalizacao = true;
  final TextEditingController _buscaController = TextEditingController();
  bool _buscando = false;
  final AlertaService _alertaService = AlertaService();

  // Direção atual do usuário (heading do GPS), usada para girar o ícone
  double _direcaoAtual = 0;

  // Controle do modo de navegação em tempo real
  bool _modoNavegacao = false;
  DateTime? _ultimoRecalculo;

  // Resumo de tempo/distância da rota atual (vindos do OSRM)
  double? _duracaoSegundos;
  double? _distanciaMetros;

  // Instruções de voz (turn-by-turn)
  final FlutterTts _tts = FlutterTts();
  List<InstrucaoNavegacao> _instrucoes = [];
  int _indiceInstrucaoAtual = 0;

  // Controle da solicitação manual de permissão de localização (necessário
  // no iOS/Safari, que só libera geolocalização se disparada por um toque
  // real do usuário, não automaticamente ao abrir a tela)
  bool _solicitandoLocalizacao = false;
  bool _erroPermissaoLocalizacao = false;

  @override
  void initState() {
    super.initState();
    _tts.setLanguage('pt-BR');
    // Não chamamos _iniciarRastreamento() aqui de propósito.
    // No iOS, pedir geolocalização automaticamente (sem toque do usuário)
    // faz o navegador bloquear silenciosamente, sem mostrar o popup.
    // Por isso o usuário precisa tocar em um botão para ativar o GPS.
  }

  Future<void> _ativarLocalizacaoManual() async {
    setState(() {
      _solicitandoLocalizacao = true;
      _erroPermissaoLocalizacao = false;
    });

    await _iniciarRastreamento();

    setState(() {
      _solicitandoLocalizacao = false;
    });
  }

  Future<void> _iniciarRastreamento() async {
    bool servicoAtivo = await Geolocator.isLocationServiceEnabled();
    if (!servicoAtivo) {
      setState(() => _erroPermissaoLocalizacao = true);
      _mostrarErro('Ative o serviço de localização do dispositivo.');
      return;
    }

    LocationPermission permissao = await Geolocator.checkPermission();
    if (permissao == LocationPermission.denied) {
      permissao = await Geolocator.requestPermission();
      if (permissao == LocationPermission.denied) {
        setState(() => _erroPermissaoLocalizacao = true);
        _mostrarErro('Permissão de localização negada.');
        return;
      }
    }

    if (permissao == LocationPermission.deniedForever) {
      setState(() => _erroPermissaoLocalizacao = true);
      _mostrarErro(
          'Permissão de localização bloqueada. Ative nas configurações do navegador.');
      return;
    }

    const configuracao = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 5,
    );

    _streamPosicao =
        Geolocator.getPositionStream(locationSettings: configuracao)
            .listen((Position posicao) {
      final novaPosicao = LatLng(posicao.latitude, posicao.longitude);

      setState(() {
        _minhaLocalizacao = novaPosicao;
        // Só atualiza a direção se o GPS retornar um heading válido
        if (posicao.heading >= 0) {
          _direcaoAtual = posicao.heading;
        }
      });

      if (_primeiraLocalizacao) {
        _mapController.move(novaPosicao, 15);
        _primeiraLocalizacao = false;
      }

      // Modo navegação: a câmera segue o usuário, verifica desvio de rota
      // e checa se está próximo da próxima instrução de voz
      if (_modoNavegacao) {
        _mapController.move(novaPosicao, _mapController.camera.zoom);
        _verificarDesvioDaRota(novaPosicao);
        _verificarProximaInstrucao(novaPosicao);
      }
    });
  }

  // Verifica se o texto digitado parece ser um CEP
  bool _pareceCep(String texto) {
    final regexCep = RegExp(r'^\d{5}-?\d{3}$');
    return regexCep.hasMatch(texto.trim());
  }

  // Busca o endereço completo a partir do CEP usando ViaCEP
  Future<String?> _buscarEnderecoPorCep(String cep) async {
    final cepLimpo = cep.replaceAll('-', '').trim();

    try {
      final url = Uri.parse('https://viacep.com.br/ws/$cepLimpo/json/');
      final resposta = await http.get(url);
      final dados = json.decode(resposta.body);

      if (dados['erro'] == true) {
        return null;
      }

      final logradouro = dados['logradouro'] ?? '';
      final bairro = dados['bairro'] ?? '';
      final cidade = dados['localidade'] ?? '';
      final uf = dados['uf'] ?? '';

      return '$logradouro, $bairro, $cidade, $uf, Brasil';
    } catch (e) {
      return null;
    }
  }

  // Busca o endereço (ou CEP) e transforma em coordenadas
  Future<void> _buscarEndereco(String textoDigitado) async {
    if (textoDigitado.trim().isEmpty) return;

    if (_minhaLocalizacao == null) {
      _mostrarErro('Ative sua localização antes de buscar um destino.');
      return;
    }

    setState(() => _buscando = true);

    String enderecoParaBuscar = textoDigitado;

    if (_pareceCep(textoDigitado)) {
      final enderecoEncontrado = await _buscarEnderecoPorCep(textoDigitado);

      if (enderecoEncontrado == null) {
        _mostrarErro('CEP não encontrado.');
        setState(() => _buscando = false);
        return;
      }

      enderecoParaBuscar = enderecoEncontrado;
    }

    try {
      final url = Uri.parse(
        'https://nominatim.openstreetmap.org/search?q=${Uri.encodeComponent(enderecoParaBuscar)}&format=json&limit=1',
      );

      final resposta = await http.get(
        url,
        headers: {'User-Agent': 'NaviFake-App-Pessoal'},
      );

      final dados = json.decode(resposta.body) as List;

      if (dados.isEmpty) {
        _mostrarErro('Endereço não encontrado.');
        setState(() => _buscando = false);
        return;
      }

      final lat = double.parse(dados[0]['lat']);
      final lon = double.parse(dados[0]['lon']);
      final destinoEncontrado = LatLng(lat, lon);

      setState(() {
        _destino = destinoEncontrado;
      });

      await _tracarRota(_minhaLocalizacao!, destinoEncontrado);
    } catch (e) {
      _mostrarErro('Erro ao buscar endereço. Verifique sua internet.');
    }

    setState(() => _buscando = false);
  }

  // Traça a rota entre origem e destino usando OSRM, incluindo os "steps"
  // (manobras) para gerar as instruções de voz turn-by-turn, além do
  // tempo e distância estimados da viagem.
  Future<void> _tracarRota(LatLng origem, LatLng destino) async {
    try {
      final url = Uri.parse(
        'https://router.project-osrm.org/route/v1/driving/'
        '${origem.longitude},${origem.latitude};'
        '${destino.longitude},${destino.latitude}'
        '?overview=full&geometries=geojson&steps=true',
      );

      final resposta = await http.get(url);
      final dados = json.decode(resposta.body);

      if (dados['code'] != 'Ok') {
        _mostrarErro('Não foi possível traçar a rota.');
        return;
      }

      final rota = dados['routes'][0];

      final duracao = (rota['duration'] as num).toDouble();
      final distancia = (rota['distance'] as num).toDouble();

      final coordenadas = rota['geometry']['coordinates'] as List;
      final pontos =
          coordenadas.map<LatLng>((c) => LatLng(c[1], c[0])).toList();

      // Monta a lista de instruções a partir dos "steps" de todas as "legs"
      final List<InstrucaoNavegacao> novasInstrucoes = [];
      for (final leg in rota['legs']) {
        for (final step in leg['steps']) {
          final maneuver = step['maneuver'];
          final tipo = maneuver['type'];
          final modificador = maneuver['modifier'];
          final coordManobra = maneuver['location']; // [lon, lat]

          novasInstrucoes.add(
            InstrucaoNavegacao(
              texto: traduzirManobra(tipo, modificador),
              ponto: LatLng(coordManobra[1], coordManobra[0]),
              distanciaMetros: (step['distance'] as num).toDouble(),
            ),
          );
        }
      }

      setState(() {
        _pontosRota = pontos;
        _instrucoes = novasInstrucoes;
        _indiceInstrucaoAtual = 0;
        _duracaoSegundos = duracao;
        _distanciaMetros = distancia;
      });

      // Só enquadra origem+destino se NÃO estivermos navegando
      // (durante a navegação a câmera já está seguindo o usuário)
      if (!_modoNavegacao) {
        _mapController.fitCamera(
          CameraFit.coordinates(
            coordinates: [origem, destino],
            padding: const EdgeInsets.all(50),
          ),
        );
      }
    } catch (e) {
      _mostrarErro('Erro ao calcular rota. Verifique sua internet.');
    }
  }

  // Verifica se o usuário se desviou da rota traçada e recalcula se necessário
  Future<void> _verificarDesvioDaRota(LatLng posicaoAtual) async {
    if (_pontosRota.isEmpty || _destino == null) return;

    // Evita recalcular com muita frequência (mínimo 5 segundos entre recálculos)
    final agora = DateTime.now();
    if (_ultimoRecalculo != null &&
        agora.difference(_ultimoRecalculo!) < const Duration(seconds: 5)) {
      return;
    }

    const distancia = Distance();
    double menorDistancia = double.infinity;

    for (final ponto in _pontosRota) {
      final d = distancia(posicaoAtual, ponto);
      if (d < menorDistancia) menorDistancia = d;
    }

    // Se o usuário está a mais de 40 metros da rota, recalcula
    if (menorDistancia > 40) {
      _ultimoRecalculo = agora;
      await _tracarRota(posicaoAtual, _destino!);
    }
  }

  // Verifica se o usuário está perto da próxima manobra e, se estiver,
  // dispara a instrução de voz correspondente (uma única vez por manobra).
  void _verificarProximaInstrucao(LatLng posicaoAtual) {
    if (_instrucoes.isEmpty || _indiceInstrucaoAtual >= _instrucoes.length) {
      return;
    }

    final instrucaoAtual = _instrucoes[_indiceInstrucaoAtual];
    const distancia = Distance();
    final distanciaAteManobra = distancia(posicaoAtual, instrucaoAtual.ponto);

    // Quando estiver a menos de 150m da manobra e ainda não avisou, fala
    if (distanciaAteManobra < 150 && !instrucaoAtual.jaFalada) {
      instrucaoAtual.jaFalada = true;
      _tts.speak(instrucaoAtual.texto);
    }

    // Quando estiver muito próximo (chegou na manobra), avança pra próxima
    if (distanciaAteManobra < 20) {
      _indiceInstrucaoAtual++;
    }
  }

  void _mostrarErro(String mensagem) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(mensagem)),
    );
  }

  // Formata segundos em texto legível: "12 min" ou "1h 5min"
  String _formatarDuracao(double segundos) {
    final minutos = (segundos / 60).round();
    if (minutos < 60) return '$minutos min';
    final horas = minutos ~/ 60;
    final minutosRestantes = minutos % 60;
    return '${horas}h ${minutosRestantes}min';
  }

  // Formata metros em texto legível: "5.3 km"
  String _formatarDistancia(double metros) {
    final km = metros / 1000;
    return '${km.toStringAsFixed(1)} km';
  }

  // Retorna o ícone correspondente a cada tipo de alerta
  IconData _iconePorTipo(String tipo) {
    switch (tipo) {
      case 'radar_fixo':
      case 'radar_movel':
        return Icons.camera_alt;
      case 'transito':
        return Icons.traffic;
      case 'acidente':
        return Icons.car_crash;
      case 'blitz':
        return Icons.local_police;
      case 'animal_pista':
        return Icons.pets;
      case 'buraco':
        return Icons.warning;
      case 'lombada':
        return Icons.speed;
      default:
        return Icons.error;
    }
  }

  // Salva um novo alerta na posição atual do usuário
  void _reportarAlerta(String tipo) {
    if (_minhaLocalizacao == null) return;

    final novoAlerta = Alerta(
      tipo: tipo,
      latitude: _minhaLocalizacao!.latitude,
      longitude: _minhaLocalizacao!.longitude,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );

    _alertaService.reportarAlerta(novoAlerta);
    Navigator.pop(context);
  }

  // Abre o menu (bottom sheet) para escolher o tipo de alerta a reportar
  void _abrirMenuReportar() {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return ListView(
          shrinkWrap: true,
          children: tiposDeAlerta.entries.map((entry) {
            return ListTile(
              leading: Icon(_iconePorTipo(entry.key)),
              title: Text(entry.value),
              onTap: () => _reportarAlerta(entry.key),
            );
          }).toList(),
        );
      },
    );
  }

  // Ativa/desativa o modo de navegação (câmera seguindo o usuário)
  void _alternarModoNavegacao() {
    setState(() {
      _modoNavegacao = !_modoNavegacao;
    });

    if (_modoNavegacao && _minhaLocalizacao != null) {
      _mapController.move(_minhaLocalizacao!, 17);
    }
  }

  // Recentraliza o mapa na posição atual do usuário
  void _recentrarNaMinhaLocalizacao() {
    if (_minhaLocalizacao != null) {
      _mapController.move(_minhaLocalizacao!, 17);
    }
  }

  // Aumenta o zoom em 1 nível
  void _aumentarZoom() {
    _mapController.move(
      _mapController.camera.center,
      _mapController.camera.zoom + 1,
    );
  }

  // Diminui o zoom em 1 nível
  void _diminuirZoom() {
    _mapController.move(
      _mapController.camera.center,
      _mapController.camera.zoom - 1,
    );
  }

  @override
  void dispose() {
    _streamPosicao?.cancel();
    _buscaController.dispose();
    _tts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('NaviFake')),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton(
            heroTag: 'navegar',
            onPressed: _alternarModoNavegacao,
            backgroundColor: _modoNavegacao ? Colors.green : Colors.grey,
            child: Icon(
              _modoNavegacao ? Icons.navigation : Icons.navigation_outlined,
            ),
          ),
          const SizedBox(height: 12),
          FloatingActionButton(
            heroTag: 'alerta',
            onPressed: _abrirMenuReportar,
            backgroundColor: Colors.orange,
            child: const Icon(Icons.add_alert),
          ),
        ],
      ),
      body: StreamBuilder<List<Alerta>>(
        stream: _alertaService.escutarAlertas(),
        builder: (context, snapshotAlertas) {
          final alertas = snapshotAlertas.data ?? [];

          return Stack(
            children: [
              FlutterMap(
                mapController: _mapController,
                options: const MapOptions(
                  initialCenter: LatLng(-23.5505, -46.6333),
                  initialZoom: 13,
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.emerson.navifake',
                  ),
                  if (_pontosRota.isNotEmpty)
                    PolylineLayer(
                      polylines: [
                        Polyline(
                          points: _pontosRota,
                          color: Colors.blueAccent,
                          strokeWidth: 5,
                        ),
                      ],
                    ),
                  MarkerLayer(
                    markers: [
                      if (_minhaLocalizacao != null)
                        Marker(
                          point: _minhaLocalizacao!,
                          width: 40,
                          height: 40,
                          child: Transform.rotate(
                            // Converte graus (heading do GPS) para radianos
                            angle: _direcaoAtual * (3.1415926535 / 180),
                            child: const Icon(
                              Icons.navigation,
                              color: Colors.blue,
                              size: 32,
                            ),
                          ),
                        ),
                      if (_destino != null)
                        Marker(
                          point: _destino!,
                          width: 40,
                          height: 40,
                          child: const Icon(Icons.location_on,
                              color: Colors.red, size: 40),
                        ),
                      ...alertas.map((alerta) {
                        return Marker(
                          point: LatLng(alerta.latitude, alerta.longitude),
                          width: 36,
                          height: 36,
                          child: Icon(
                            _iconePorTipo(alerta.tipo),
                            color: Colors.deepOrange,
                            size: 30,
                          ),
                        );
                      }),
                    ],
                  ),
                ],
              ),

              // Overlay: botão para ativar localização manualmente
              // (necessário para funcionar no Safari/Chrome iOS, que só
              // libera geolocalização a partir de um toque real do usuário)
              if (_minhaLocalizacao == null)
                Positioned.fill(
                  child: Container(
                    color: Colors.black45,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_erroPermissaoLocalizacao)
                            const Padding(
                              padding: EdgeInsets.only(bottom: 12),
                              child: Text(
                                'Não foi possível obter sua localização.\nVerifique as permissões do navegador.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.white),
                              ),
                            ),
                          ElevatedButton.icon(
                            onPressed: _solicitandoLocalizacao
                                ? null
                                : _ativarLocalizacaoManual,
                            icon: _solicitandoLocalizacao
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : const Icon(Icons.my_location),
                            label: Text(
                              _solicitandoLocalizacao
                                  ? 'Buscando localização...'
                                  : 'Ativar minha localização',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

              // Barra de busca de endereço/CEP
              Positioned(
                top: 10,
                left: 10,
                right: 10,
                child: Material(
                  elevation: 4,
                  borderRadius: BorderRadius.circular(8),
                  child: TextField(
                    controller: _buscaController,
                    decoration: InputDecoration(
                      hintText: 'Digite um endereço ou CEP...',
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 16),
                      border: InputBorder.none,
                      suffixIcon: _buscando
                          ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox(
                                width: 20,
                                height: 20,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              ),
                            )
                          : IconButton(
                              icon: const Icon(Icons.search),
                              onPressed: () =>
                                  _buscarEndereco(_buscaController.text),
                            ),
                    ),
                    onSubmitted: _buscarEndereco,
                  ),
                ),
              ),

              // Card com resumo de tempo e distância da rota atual
              if (_duracaoSegundos != null && _distanciaMetros != null)
                Positioned(
                  top: 70,
                  left: 10,
                  right: 10,
                  child: Material(
                    elevation: 4,
                    borderRadius: BorderRadius.circular(8),
                    color: Colors.white,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.access_time,
                              size: 18, color: Colors.blue),
                          const SizedBox(width: 6),
                          Text(
                            _formatarDuracao(_duracaoSegundos!),
                            style:
                                const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(width: 16),
                          const Icon(Icons.route, size: 18, color: Colors.blue),
                          const SizedBox(width: 6),
                          Text(_formatarDistancia(_distanciaMetros!)),
                        ],
                      ),
                    ),
                  ),
                ),

              // Controles de zoom e recentralização (canto inferior ESQUERDO)
              Positioned(
                left: 10,
                bottom: 20,
                child: Column(
                  children: [
                    FloatingActionButton.small(
                      heroTag: 'recentrar',
                      backgroundColor: Colors.white,
                      onPressed: _recentrarNaMinhaLocalizacao,
                      child: const Icon(Icons.my_location, color: Colors.blue),
                    ),
                    const SizedBox(height: 8),
                    FloatingActionButton.small(
                      heroTag: 'zoomIn',
                      backgroundColor: Colors.white,
                      onPressed: _aumentarZoom,
                      child: const Icon(Icons.add, color: Colors.black87),
                    ),
                    const SizedBox(height: 8),
                    FloatingActionButton.small(
                      heroTag: 'zoomOut',
                      backgroundColor: Colors.white,
                      onPressed: _diminuirZoom,
                      child: const Icon(Icons.remove, color: Colors.black87),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

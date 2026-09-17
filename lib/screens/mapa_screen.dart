// lib/screens/mapa_screen.dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:wakelock_plus/wakelock_plus.dart';
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

  double _direcaoAtual = 0;

  bool _modoNavegacao = false;
  DateTime? _ultimoRecalculo;

  double? _duracaoSegundos;
  double? _distanciaMetros;

  final FlutterTts _tts = FlutterTts();
  List<InstrucaoNavegacao> _instrucoes = [];
  int _indiceInstrucaoAtual = 0;

  bool _solicitandoLocalizacao = false;
  bool _erroPermissaoLocalizacao = false;

  List<Map<String, dynamic>> _sugestoes = [];
  Timer? _debounce;

  // --- Tema noturno ---
  bool _temaNoturno = false;

  // --- Proximidade de alertas ---
  List<Alerta> _alertasAtuais = [];
  final Set<String> _alertasJaAvisados = {};
  StreamSubscription<List<Alerta>>? _streamAlertas;
  static const double _raioAvisoMetros = 300;

  // --- Velocidade atual vs. limite da via ---
  double _velocidadeAtualKmh = 0;
  List<double?> _limitesVelocidade = [];

  // Zoom fixo usado durante o modo navegação (mais próximo, estilo Waze).
  static const double _zoomNavegacao = 18;

  @override
  void initState() {
    super.initState();
    _tts.setLanguage('pt-BR');

    // Mantém a lista de alertas atualizada para uso fora do StreamBuilder,
    // permitindo verificar proximidade a cada atualização de GPS.
    _streamAlertas = _alertaService.escutarAlertas().listen((alertas) {
      _alertasAtuais = alertas;
    });
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
        if (posicao.heading >= 0) {
          _direcaoAtual = posicao.heading;
        }
        // posicao.speed vem em metros/segundo; convertendo para km/h.
        _velocidadeAtualKmh = posicao.speed * 3.6;
      });

      // Verifica se algum alerta reportado está próximo do usuário.
      _verificarProximidadeAlertas(novaPosicao);

      if (_primeiraLocalizacao) {
        _mapController.move(novaPosicao, 15);
        _primeiraLocalizacao = false;
      }

      if (_modoNavegacao) {
        // moveAndRotate gira o mapa para acompanhar a direção do usuário
        // (modo "heading-up") e mantém o zoom fixo e próximo, como no Waze.
        _mapController.moveAndRotate(
          novaPosicao,
          _zoomNavegacao,
          -_direcaoAtual,
        );
        _verificarDesvioDaRota(novaPosicao);
        _verificarProximaInstrucao(novaPosicao);
      }
    });
  }

  // Compara a posição atual com cada alerta ativo e avisa (voz + snackbar)
  // quando o usuário entra no raio de aviso. Cada alerta só avisa uma vez
  // por sessão, controlado por _alertasJaAvisados.
  void _verificarProximidadeAlertas(LatLng posicaoAtual) {
    const distancia = Distance();

    for (final alerta in _alertasAtuais) {
      if (alerta.id == null || _alertasJaAvisados.contains(alerta.id)) {
        continue;
      }

      final pontoAlerta = LatLng(alerta.latitude, alerta.longitude);
      final d = distancia(posicaoAtual, pontoAlerta);

      if (d <= _raioAvisoMetros) {
        _alertasJaAvisados.add(alerta.id!);
        final nomeAlerta = tiposDeAlerta[alerta.tipo] ?? 'Alerta';
        _tts.speak('Atenção, $nomeAlerta próximo');
        _mostrarErro('$nomeAlerta a ${d.round()} metros');
      }
    }
  }

  bool _pareceCep(String texto) {
    final regexCep = RegExp(r'^\d{5}-?\d{3}$');
    return regexCep.hasMatch(texto.trim());
  }

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

  void _onBuscaChanged(String texto) {
    if (_debounce?.isActive ?? false) _debounce!.cancel();

    if (texto.trim().isEmpty) {
      setState(() => _sugestoes = []);
      return;
    }

    _debounce = Timer(const Duration(milliseconds: 600), () async {
      final resultados = await _buscarSugestoes(texto);
      if (mounted) setState(() => _sugestoes = resultados);
    });
  }

  Future<List<Map<String, dynamic>>> _buscarSugestoes(String texto) async {
    try {
      final url = Uri.parse(
        'https://nominatim.openstreetmap.org/search'
        '?q=${Uri.encodeComponent(texto)}&format=json&addressdetails=1&limit=5',
      );

      final resposta = await http.get(
        url,
        headers: {'User-Agent': 'NaviFake-App-Pessoal'},
      );

      if (resposta.statusCode == 200) {
        final List dados = json.decode(resposta.body);
        return dados.cast<Map<String, dynamic>>();
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  Future<void> _selecionarSugestao(Map<String, dynamic> sugestao) async {
    if (_minhaLocalizacao == null) {
      _mostrarErro('Ative sua localização antes de buscar um destino.');
      return;
    }

    final lat = double.parse(sugestao['lat']);
    final lon = double.parse(sugestao['lon']);
    final destinoEncontrado = LatLng(lat, lon);

    _buscaController.text = sugestao['display_name'] ?? '';

    setState(() {
      _destino = destinoEncontrado;
      _sugestoes = [];
    });

    FocusScope.of(context).unfocus();
    await _tracarRota(_minhaLocalizacao!, destinoEncontrado);
  }

  Future<void> _buscarEndereco(String textoDigitado) async {
    if (textoDigitado.trim().isEmpty) return;

    if (_minhaLocalizacao == null) {
      _mostrarErro('Ative sua localização antes de buscar um destino.');
      return;
    }

    setState(() {
      _buscando = true;
      _sugestoes = [];
    });

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

  Future<void> _tracarRota(LatLng origem, LatLng destino) async {
    try {
      final url = Uri.parse(
        'https://router.project-osrm.org/route/v1/driving/'
        '${origem.longitude},${origem.latitude};'
        '${destino.longitude},${destino.latitude}'
        '?overview=full&geometries=geojson&steps=true&annotations=maxspeed',
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

      final List<InstrucaoNavegacao> novasInstrucoes = [];
      final List<double?> limites = [];

      for (final leg in rota['legs']) {
        for (final step in leg['steps']) {
          final maneuver = step['maneuver'];
          final tipo = maneuver['type'];
          final modificador = maneuver['modifier'];
          final coordManobra = maneuver['location'];

          novasInstrucoes.add(
            InstrucaoNavegacao(
              texto: traduzirManobra(tipo, modificador),
              ponto: LatLng(coordManobra[1], coordManobra[0]),
              distanciaMetros: (step['distance'] as num).toDouble(),
            ),
          );
        }

        // Limite de velocidade por segmento (depende dos dados do
        // OpenStreetMap na região; pode vir nulo em vias sem essa tag).
        final maxspeeds = leg['annotation']?['maxspeed'] as List?;
        if (maxspeeds != null) {
          for (final item in maxspeeds) {
            final speed = item['speed'];
            limites.add(speed != null ? (speed as num).toDouble() : null);
          }
        }
      }

      setState(() {
        _pontosRota = pontos;
        _instrucoes = novasInstrucoes;
        _indiceInstrucaoAtual = 0;
        _duracaoSegundos = duracao;
        _distanciaMetros = distancia;
        _limitesVelocidade = limites;
      });

      // Nova rota: reseta os avisos de proximidade para que os alertas
      // no novo trajeto possam ser avisados novamente.
      _alertasJaAvisados.clear();

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

  Future<void> _verificarDesvioDaRota(LatLng posicaoAtual) async {
    if (_pontosRota.isEmpty || _destino == null) return;

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

    if (menorDistancia > 40) {
      _ultimoRecalculo = agora;
      await _tracarRota(posicaoAtual, _destino!);
    }
  }

  void _verificarProximaInstrucao(LatLng posicaoAtual) {
    if (_instrucoes.isEmpty || _indiceInstrucaoAtual >= _instrucoes.length) {
      return;
    }

    final instrucaoAtual = _instrucoes[_indiceInstrucaoAtual];
    const distancia = Distance();
    final distanciaAteManobra = distancia(posicaoAtual, instrucaoAtual.ponto);

    if (distanciaAteManobra < 150 && !instrucaoAtual.jaFalada) {
      instrucaoAtual.jaFalada = true;
      _tts.speak(instrucaoAtual.texto);
    }

    if (distanciaAteManobra < 20) {
      _indiceInstrucaoAtual++;
    }
  }

  void _mostrarErro(String mensagem) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(mensagem)),
    );
  }

  String _formatarDuracao(double segundos) {
    final minutos = (segundos / 60).round();
    if (minutos < 60) return '$minutos min';
    final horas = minutos ~/ 60;
    final minutosRestantes = minutos % 60;
    return '${horas}h ${minutosRestantes}min';
  }

  String _formatarDistancia(double metros) {
    final km = metros / 1000;
    return '${km.toStringAsFixed(1)} km';
  }

  // Limite de velocidade referente ao trecho atual da rota (o primeiro
  // valor não nulo disponível). Retorna null se a via não tiver essa
  // informação no OpenStreetMap.
  double? get _limiteAtual {
    for (final limite in _limitesVelocidade) {
      if (limite != null) return limite;
    }
    return null;
  }

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

  void _alternarModoNavegacao() {
    setState(() {
      _modoNavegacao = !_modoNavegacao;
    });

    if (_modoNavegacao && _minhaLocalizacao != null) {
      // Ativa modo heading-up com zoom próximo e mantém a tela acesa
      // enquanto o usuário está navegando.
      _mapController.moveAndRotate(
          _minhaLocalizacao!, _zoomNavegacao, -_direcaoAtual);
      WakelockPlus.enable();
    } else {
      // Volta o mapa para o norte e libera a economia de energia da tela.
      _mapController.rotate(0);
      WakelockPlus.disable();
    }
  }

  void _recentrarNaMinhaLocalizacao() {
    if (_minhaLocalizacao != null) {
      _mapController.move(_minhaLocalizacao!, 17);
    }
  }

  void _aumentarZoom() {
    _mapController.move(
      _mapController.camera.center,
      _mapController.camera.zoom + 1,
    );
  }

  void _diminuirZoom() {
    _mapController.move(
      _mapController.camera.center,
      _mapController.camera.zoom - 1,
    );
  }

  void _alternarTema() {
    setState(() {
      _temaNoturno = !_temaNoturno;
    });
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _streamPosicao?.cancel();
    _streamAlertas?.cancel();
    _buscaController.dispose();
    _debounce?.cancel();
    _tts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Sempre usamos o OpenStreetMap padrão — o "modo escuro" é aplicado
    // visualmente com um filtro de cor, sem depender de nenhum serviço
    // externo que exija API key.
    const tileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

    final corFundoCard = _temaNoturno ? const Color(0xFF1E1E1E) : Colors.white;
    final corTextoCard = _temaNoturno ? Colors.white : Colors.black87;

    final limiteAtual = _limiteAtual;
    final acimaDoLimite =
        limiteAtual != null && _velocidadeAtualKmh > limiteAtual;

    return Theme(
      data: _temaNoturno ? ThemeData.dark() : ThemeData.light(),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('NaviFake'),
          actions: [
            IconButton(
              icon: Icon(_temaNoturno ? Icons.light_mode : Icons.dark_mode),
              tooltip: _temaNoturno ? 'Ativar tema claro' : 'Ativar tema noturno',
              onPressed: _alternarTema,
            ),
          ],
        ),
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
                    // Camada de tiles com inversão de cor no tema noturno.
                    // ColorFilter.matrix com valores -1 inverte as cores
                    // (preto vira branco e vice-versa), simulando modo
                    // escuro sem precisar de outro servidor de mapas.
                    ColorFiltered(
                      colorFilter: _temaNoturno
                          ? const ColorFilter.matrix(<double>[
                              -1, 0, 0, 0, 255,
                              0, -1, 0, 0, 255,
                              0, 0, -1, 0, 255,
                              0, 0, 0, 1, 0,
                            ])
                          : const ColorFilter.mode(
                              Colors.transparent, BlendMode.multiply),
                      child: TileLayer(
                        urlTemplate: tileUrl,
                        userAgentPackageName: 'com.emerson.navifake',
                        subdomains: const ['a', 'b', 'c'],
                      ),
                    ),
                    if (_pontosRota.isNotEmpty)
                      PolylineLayer(
                        polylines: [
                          Polyline(
                            points: _pontosRota,
                            color: _temaNoturno ? Colors.cyanAccent : Colors.blueAccent,
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
                              angle: _direcaoAtual * (3.1415926535 / 180),
                              child: Icon(
                                Icons.navigation,
                                color: _temaNoturno ? Colors.cyanAccent : Colors.blue,
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

                // Barra de busca + lista de sugestões (autocomplete)
                Positioned(
                  top: 10,
                  left: 10,
                  right: 10,
                  child: Column(
                    children: [
                      Material(
                        elevation: 4,
                        borderRadius: BorderRadius.circular(8),
                        color: corFundoCard,
                        child: TextField(
                          controller: _buscaController,
                          style: TextStyle(color: corTextoCard),
                          decoration: InputDecoration(
                            hintText: 'Digite um endereço ou CEP...',
                            hintStyle: TextStyle(
                                color: corTextoCard.withOpacity(0.6)),
                            contentPadding:
                                const EdgeInsets.symmetric(horizontal: 16),
                            border: InputBorder.none,
                            suffixIcon: _buscando
                                ? const Padding(
                                    padding: EdgeInsets.all(12),
                                    child: SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    ),
                                  )
                                : IconButton(
                                    icon: Icon(Icons.search, color: corTextoCard),
                                    onPressed: () =>
                                        _buscarEndereco(_buscaController.text),
                                  ),
                          ),
                          onChanged: _onBuscaChanged,
                          onSubmitted: _buscarEndereco,
                        ),
                      ),

                      if (_sugestoes.isNotEmpty)
                        Material(
                          elevation: 4,
                          borderRadius: BorderRadius.circular(8),
                          color: corFundoCard,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 220),
                            child: ListView.builder(
                              padding: EdgeInsets.zero,
                              shrinkWrap: true,
                              itemCount: _sugestoes.length,
                              itemBuilder: (context, index) {
                                final item = _sugestoes[index];
                                return ListTile(
                                  dense: true,
                                  leading: Icon(Icons.place, color: corTextoCard),
                                  title: Text(
                                    item['display_name'] ?? '',
                                    style: TextStyle(color: corTextoCard),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  onTap: () => _selecionarSugestao(item),
                                );
                              },
                            ),
                          ),
                        ),
                    ],
                  ),
                ),

                if (_duracaoSegundos != null && _distanciaMetros != null && _sugestoes.isEmpty)
                  Positioned(
                    top: 70,
                    left: 10,
                    right: 10,
                    child: Material(
                      elevation: 4,
                      borderRadius: BorderRadius.circular(8),
                      color: corFundoCard,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.access_time,
                                size: 18,
                                color: _temaNoturno ? Colors.cyanAccent : Colors.blue),
                            const SizedBox(width: 6),
                            Text(
                              _formatarDuracao(_duracaoSegundos!),
                              style: TextStyle(
                                  fontWeight: FontWeight.bold, color: corTextoCard),
                            ),
                            const SizedBox(width: 16),
                            Icon(Icons.route,
                                size: 18,
                                color: _temaNoturno ? Colors.cyanAccent : Colors.blue),
                            const SizedBox(width: 6),
                            Text(_formatarDistancia(_distanciaMetros!),
                                style: TextStyle(color: corTextoCard)),
                          ],
                        ),
                      ),
                    ),
                  ),

                // Painel de velocidade atual vs. limite da via — só
                // aparece durante a navegação ativa.
                if (_modoNavegacao)
                  Positioned(
                    bottom: 100,
                    right: 10,
                    child: Row(
                      children: [
                        // Velocidade atual (sempre disponível via GPS)
                        Material(
                          elevation: 4,
                          shape: const CircleBorder(),
                          color: acimaDoLimite ? Colors.red : corFundoCard,
                          child: Container(
                            width: 64,
                            height: 64,
                            alignment: Alignment.center,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  _velocidadeAtualKmh.round().toString(),
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                    color: acimaDoLimite
                                        ? Colors.white
                                        : corTextoCard,
                                  ),
                                ),
                                Text(
                                  'km/h',
                                  style: TextStyle(
                                    fontSize: 9,
                                    color: acimaDoLimite
                                        ? Colors.white
                                        : corTextoCard,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),

                        // Limite da via (só aparece se o OSM tiver o dado)
                        if (limiteAtual != null) ...[
                          const SizedBox(width: 8),
                          Container(
                            width: 54,
                            height: 54,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white,
                              border: Border.all(color: Colors.red, width: 4),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              limiteAtual.round().toString(),
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: Colors.black,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),

                Positioned(
                  left: 10,
                  bottom: 20,
                  child: Column(
                    children: [
                      FloatingActionButton.small(
                        heroTag: 'recentrar',
                        backgroundColor: corFundoCard,
                        onPressed: _recentrarNaMinhaLocalizacao,
                        child: Icon(Icons.my_location,
                            color: _temaNoturno ? Colors.cyanAccent : Colors.blue),
                      ),
                      const SizedBox(height: 8),
                      FloatingActionButton.small(
                        heroTag: 'zoomIn',
                        backgroundColor: corFundoCard,
                        onPressed: _aumentarZoom,
                        child: Icon(Icons.add, color: corTextoCard),
                      ),
                      const SizedBox(height: 8),
                      FloatingActionButton.small(
                        heroTag: 'zoomOut',
                        backgroundColor: corFundoCard,
                        onPressed: _diminuirZoom,
                        child: Icon(Icons.remove, color: corTextoCard),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

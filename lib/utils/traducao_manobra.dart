// Traduz o par (tipo, modificador) que o OSRM devolve para uma frase em português.
String traduzirManobra(String tipo, String? modificador) {
  switch (tipo) {
    case 'depart':
      return 'Siga em frente';
    case 'arrive':
      return 'Você chegou ao destino';
    case 'turn':
      return 'Vire ${_traduzirModificador(modificador)}';
    case 'new name':
    case 'continue':
      return 'Continue em frente';
    case 'roundabout':
    case 'rotary':
      return 'Entre na rotatória';
    case 'merge':
      return 'Mantenha-se ${_traduzirModificador(modificador)}';
    case 'fork':
      return 'Na bifurcação, siga ${_traduzirModificador(modificador)}';
    case 'end of road':
      return 'No fim da via, vire ${_traduzirModificador(modificador)}';
    default:
      return 'Siga em frente';
  }
}

String _traduzirModificador(String? modificador) {
  switch (modificador) {
    case 'left':
      return 'à esquerda';
    case 'right':
      return 'à direita';
    case 'slight left':
      return 'levemente à esquerda';
    case 'slight right':
      return 'levemente à direita';
    case 'sharp left':
      return 'fortemente à esquerda';
    case 'sharp right':
      return 'fortemente à direita';
    case 'straight':
      return 'em frente';
    case 'uturn':
      return 'em retorno (meia-volta)';
    default:
      return 'em frente';
  }
}

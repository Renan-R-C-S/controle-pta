/**
 * OBSERVACOES (itens 18 e 19)
 * ---------------------------------------------------------------------------
 * REGRA 13: no maximo 200 caracteres.
 * REGRA 14: a edicao e permitida ate fim_efetivo + 30 minutos.
 *
 * O bloqueio visual desta tela e apenas conveniencia. Quem decide se o prazo
 * acabou e o relogio do SERVIDOR, dentro de fn_observacao_salvar - um celular
 * com a hora adiantada nao consegue burlar o prazo, e um celular atrasado
 * recebe a recusa do banco mesmo que o botao esteja habilitado.
 */

import { rpc } from './api.js';
import { tokenAtual } from './auth.js';
import { APP } from './config.js';
import { ErroApp } from './erros.js';
import { agora, deTextoLocal, minutosEntre } from './tempo.js';
import { observacaoValida } from './validacoes.js';

export async function salvar(usoId, texto) {
  if (!observacaoValida(texto)) throw new ErroApp('OBSERVACAO_LONGA');

  return rpc('fn_observacao_salvar', {
    p_token: tokenAtual(),
    p_uso_id: usoId,
    p_texto: texto ?? '',
  });
}

/** Caracteres restantes, para o contador "152 / 200" (item 18). */
export function restantes(texto) {
  return APP.limiteObservacao - (texto ?? '').length;
}

/**
 * Situacao do prazo de edicao, calculada com a hora corrigida do servidor.
 * Retorna { liberado, minutosRestantes, limite }.
 */
export function prazo(uso) {
  if (!uso) return { liberado: false, minutosRestantes: 0, limite: null };

  // Enquanto o uso esta aberto nao ha limite: o prazo so comeca a contar
  // depois que o funcionario finaliza (REGRA 14).
  if (uso.status === 'EM_USO') {
    return { liberado: true, minutosRestantes: null, limite: null };
  }

  const limite = deTextoLocal(uso.limite_edicao_observacao);
  if (!limite) return { liberado: true, minutosRestantes: null, limite: null };

  // Compara duas marcas do MESMO relogio: o limite e a hora corrente vieram
  // ambos do servidor, no fuso oficial. Assim um aparelho configurado em outro
  // fuso (ou com a hora errada) nao distorce a contagem exibida.
  const referencia = deTextoLocal(uso.agora?.local) ?? agora();
  const restam = minutosEntre(referencia, limite);
  return {
    liberado: restam > 0,
    minutosRestantes: Math.max(0, restam),
    limite,
  };
}

export const MINUTOS_DE_PRAZO = APP.minutosEdicaoObservacao;

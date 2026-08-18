/**
 * USO IMEDIATO - QR CODE 1 (itens 11 a 17)
 * ---------------------------------------------------------------------------
 * REGRA 5  o QR Code 1 representa uso imediato, nunca agendamento futuro;
 * REGRA 8  todo uso tem inicio_efetivo, fim_pretendido e fim_efetivo;
 * REGRA 9  o inicio_efetivo e definido pelo servidor (nao pelo celular);
 * REGRA 10 o fim_efetivo so e gravado no clique de "Finalizar uso";
 * REGRA 12 nao existe finalizacao automatica: o uso fica aberto ate o clique.
 */

import { rpc } from './api.js';
import { tokenAtual } from './auth.js';
import { ErroApp } from './erros.js';

/**
 * Inicia o uso da PTA.
 * @param {string} codigoPta   codigo lido do QR Code
 * @param {string} horaFim     "HH:MM" pretendido, informado pelo funcionario
 */
export async function iniciar(codigoPta, horaFim, fornecedorId = null) {
  if (!/^\d{2}:\d{2}$/.test(horaFim ?? '')) throw new ErroApp('HORARIO_INVALIDO');

  return rpc('fn_uso_iniciar', {
    p_token: tokenAtual(),
    p_pta_codigo: codigoPta,
    p_fim_pretendido: horaFim,
    p_fornecedor_id: fornecedorId,
  });
}

/** REGRA 10: o fim efetivo e o instante real do clique, medido no servidor. */
export async function finalizar(usoId) {
  return rpc('fn_uso_finalizar', {
    p_token: tokenAtual(),
    p_uso_id: usoId,
  });
}

/** Detalhe do uso, incluindo se a observacao ainda pode ser editada. */
export async function detalhe(usoId) {
  return rpc('fn_uso_detalhe', {
    p_token: tokenAtual(),
    p_uso_id: usoId,
  });
}

/** Uso em aberto do funcionario logado, em qualquer PTA (pode ser null). */
export async function meuUsoAberto() {
  return rpc('fn_meu_uso_aberto', { p_token: tokenAtual() });
}

/** Agendamentos futuros + usos recentes do funcionario ("Minha programacao"). */
export async function minhaProgramacao() {
  return rpc('fn_minha_programacao', { p_token: tokenAtual() });
}

/** Historico consolidado de utilizacao (tela 10). */
export async function historico({ dataInicio = null, dataFim = null, ptaId = null, limite = 200 } = {}) {
  return rpc('fn_historico', {
    p_data_ini: dataInicio,
    p_data_fim: dataFim,
    p_pta_id: ptaId,
    p_limite: limite,
  });
}

/**
 * AGENDAMENTOS - QR CODE 2 (itens 20, 22, 23)
 * ---------------------------------------------------------------------------
 * REGRA 6  o QR Code 2 cria PROGRAMACAO, nunca uso efetivo;
 * REGRA 17 dois agendamentos da mesma PTA nao podem se sobrepor.
 *
 * A verificacao de conflito feita aqui serve para avisar o usuario antes de
 * enviar o formulario. A garantia real e a constraint de exclusao do
 * PostgreSQL, que tambem vale quando duas pessoas agendam ao mesmo tempo.
 */

import { rpc } from './api.js';
import { tokenAtual } from './auth.js';

export async function criar({ ptaId, data, horaInicio, horaFim }) {
  return rpc('fn_agendamento_criar', {
    p_token: tokenAtual(),
    p_pta_id: ptaId,
    p_data: data,
    p_hora_inicio: horaInicio,
    p_hora_fim: horaFim,
  });
}

export async function cancelar(agendamentoId) {
  return rpc('fn_agendamento_cancelar', {
    p_token: tokenAtual(),
    p_agendamento_id: agendamentoId,
  });
}

/** Linha do tempo de um dia: agendamentos e usos, sem misturar os conceitos. */
export async function agendaDoDia(data, ptaId = null) {
  return rpc('fn_agenda_dia', { p_data: data, p_pta_id: ptaId });
}

/** Contagem por dia, usada para marcar o calendario mensal (item 26). */
export async function calendarioDoMes(ano, mes) {
  return rpc('fn_calendario_mes', { p_ano: ano, p_mes: mes });
}

/** Detalhe de um item do calendario, com o rastro de sobrescrita (item 27). */
export async function detalhe(tipo, id) {
  return rpc('fn_detalhe_registro', { p_tipo: tipo, p_id: id });
}

/**
 * Horarios ja ocupados de uma PTA em um dia, no formato usado por
 * validacoes.conflitaCom(). Considera programacoes ativas e usos em andamento.
 */
export function ocupacoesDe(itens, ptaId) {
  return itens
    .filter((item) => item.pta_id === ptaId)
    .filter((item) =>
      item.tipo === 'USO'
        ? item.status === 'EM_USO'
        : item.status === 'AGENDADO')
    .map((item) => ({
      inicio: item.inicio,
      fim: item.fim,
      rotulo: `${item.pta_codigo} ${item.inicio}-${item.fim} (${item.funcionario})`,
    }));
}

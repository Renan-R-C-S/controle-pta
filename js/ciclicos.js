/**
 * AGENDAMENTOS CICLICOS
 * ---------------------------------------------------------------------------
 * Regra de repeticao criada por um administrador em nome de um colaborador
 * ja cadastrado. Tres formatos:
 *
 *   DIAS_SEMANA     repete nos dias escolhidos (seg/qua/sex, por exemplo)
 *   INTERVALO_DIAS  repete a cada N dias
 *   DIA_DO_MES      repete num dia fixo do mes (todo dia 5, todo dia 28)
 *
 * As ocorrencias sao materializadas como programacoes comuns no calendario, o
 * que faz a checagem de conflito e a prioridade do QR Code 1 continuarem
 * valendo sem nenhum caso especial.
 *
 * Sem agendador no plano gratuito do Supabase, quem empurra o horizonte de
 * geracao e o proprio administrador, pelo botao "Estender".
 */

import { rpc } from './api.js';
import { tokenAtual } from './auth.js';

export const TIPOS = {
  DIAS_SEMANA: 'Dias da semana',
  INTERVALO_DIAS: 'A cada N dias',
  DIA_DO_MES: 'Em um dia do mes',
};

export const DIAS = [
  { valor: 0, curto: 'dom', longo: 'domingo' },
  { valor: 1, curto: 'seg', longo: 'segunda' },
  { valor: 2, curto: 'ter', longo: 'terca' },
  { valor: 3, curto: 'qua', longo: 'quarta' },
  { valor: 4, curto: 'qui', longo: 'quinta' },
  { valor: 5, curto: 'sex', longo: 'sexta' },
  { valor: 6, curto: 'sab', longo: 'sabado' },
];

/** Frase curta descrevendo a regra, para a lista da administracao. */
export function descreverRegra(regra) {
  if (regra.tipo === 'DIA_DO_MES') {
    return `todo dia ${regra.dia_do_mes}`;
  }
  if (regra.tipo === 'INTERVALO_DIAS') {
    return regra.intervalo_dias === 1
      ? 'todos os dias'
      : `a cada ${regra.intervalo_dias} dias`;
  }
  const nomes = (regra.dias_semana ?? [])
    .map((d) => DIAS.find((x) => x.valor === Number(d))?.curto)
    .filter(Boolean);
  return nomes.length ? nomes.join(', ') : 'sem dias definidos';
}

export async function listar() {
  return rpc('fn_ciclico_listar', { p_token: tokenAtual() });
}

export async function criar({
  ptaId, funcionarioId, horaInicio, horaFim, tipo,
  diasSemana = null, intervaloDias = null, diaDoMes = null,
  dataInicio = null, dataFim = null, fornecedorId = null,
}) {
  return rpc('fn_ciclico_criar', {
    p_token: tokenAtual(),
    p_pta_id: ptaId,
    p_funcionario_id: funcionarioId,
    p_hora_inicio: horaInicio,
    p_hora_fim: horaFim,
    p_tipo: tipo,
    p_dias_semana: tipo === 'DIAS_SEMANA' ? diasSemana : null,
    p_intervalo_dias: tipo === 'INTERVALO_DIAS' ? intervaloDias : null,
    p_dia_do_mes: tipo === 'DIA_DO_MES' ? diaDoMes : null,
    p_data_inicio: dataInicio,
    p_data_fim: dataFim,
    p_fornecedor_id: fornecedorId,
  });
}

/** Desativa a regra. As ocorrencias passadas permanecem: sao historico. */
export async function desativar(ciclicoId, cancelarFuturos = true) {
  return rpc('fn_ciclico_desativar', {
    p_token: tokenAtual(),
    p_ciclico_id: ciclicoId,
    p_cancelar_futuros: cancelarFuturos,
  });
}

export async function estender(ciclicoId) {
  return rpc('fn_ciclico_estender', {
    p_token: tokenAtual(),
    p_ciclico_id: ciclicoId,
  });
}

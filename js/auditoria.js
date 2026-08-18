/**
 * AUDITORIA (item 25)
 * ---------------------------------------------------------------------------
 * Somente leitura. Nenhuma tela do sistema permite apagar ou editar o
 * historico: a tabela tem gatilho que recusa UPDATE e DELETE (REGRA 16).
 */

import { rpc } from './api.js';

export async function listar({ limite = 100, ptaId = null } = {}) {
  return rpc('fn_auditoria', { p_limite: limite, p_pta_id: ptaId });
}

/** Rotulos legiveis para os tipos de acao gravados no banco. */
export const ROTULOS_ACAO = {
  CADASTRO_USUARIO: 'Cadastro de colaborador',
  LOGIN: 'Login',
  LOGIN_FALHA: 'Tentativa de login',
  LOGOUT: 'Logout',
  AGENDAMENTO_CRIADO: 'Agendamento criado',
  AGENDAMENTO_CANCELADO: 'Agendamento cancelado',
  AGENDAMENTO_SOBRESCRITO: 'Agendamento sobrescrito',
  AGENDAMENTO_CONCLUIDO: 'Agendamento concluido',
  USO_INICIADO: 'Uso iniciado',
  USO_FINALIZADO: 'Uso finalizado',
  OBSERVACAO_CRIADA: 'Observacao criada',
  OBSERVACAO_EDITADA: 'Observacao editada',
};

export function rotuloAcao(tipo) {
  return ROTULOS_ACAO[tipo] ?? tipo;
}

/** Transforma o par (dados_anteriores, dados_novos) em linhas "campo: de -> para". */
export function diferencas(antes, depois) {
  const campos = new Set([...Object.keys(antes ?? {}), ...Object.keys(depois ?? {})]);
  const linhas = [];

  for (const campo of campos) {
    const de = antes?.[campo];
    const para = depois?.[campo];
    if (JSON.stringify(de) === JSON.stringify(para)) continue;
    linhas.push({
      campo,
      de: de === null || de === undefined ? '-' : String(de),
      para: para === null || para === undefined ? '-' : String(para),
    });
  }

  return linhas;
}

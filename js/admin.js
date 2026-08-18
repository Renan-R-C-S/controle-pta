/**
 * ADMINISTRACAO
 * ---------------------------------------------------------------------------
 * Tres papeis:
 *   FUNCIONARIO   uso normal
 *   ADMIN         + alterar/cancelar qualquer programacao, excluir funcionarios
 *                   e promover outros a ADMIN
 *   ADMIN_MASTER  + revogar ADMIN e definir o limite de matriculas
 *
 * IMPORTANTE: esconder um botao nao e seguranca. Toda funcao chamada aqui
 * reconfere o papel no banco antes de agir (fn__exigir_admin / fn__exigir_master
 * em sql/02_funcoes.sql). Alguem que force a chamada pelo console recebe
 * SEM_PERMISSAO_ADMIN do mesmo jeito.
 *
 * Nenhum papel altera auditoria ou historico - nem o administrador principal.
 */

import { rpc } from './api.js';
import { funcionarioLogado, tokenAtual } from './auth.js';

export const PAPEIS = {
  FUNCIONARIO: 'Funcionario',
  ADMIN: 'Administrador',
  ADMIN_MASTER: 'Administrador principal',
};

export function rotuloPapel(papel) {
  return PAPEIS[papel] ?? papel;
}

/** Atalhos de interface. A decisao real e sempre do banco. */
export function souAdmin() {
  return Boolean(funcionarioLogado()?.admin);
}

export function souMaster() {
  return Boolean(funcionarioLogado()?.master);
}

/** Lista todos os funcionarios, inclusive os desativados. */
export async function listarFuncionarios() {
  return rpc('fn_admin_listar_funcionarios', { p_token: tokenAtual() });
}

/**
 * Concede ou retira o papel de administrador.
 * @param {'FUNCIONARIO'|'ADMIN'} papel
 */
export async function definirPapel(funcionarioId, papel) {
  return rpc('fn_admin_definir_papel', {
    p_token: tokenAtual(),
    p_funcionario_id: funcionarioId,
    p_papel: papel,
  });
}

/**
 * "Exclui" um funcionario - na pratica, desativa.
 * Apagar fisicamente destruiria os usos e a auditoria dele, que sao justamente
 * o que nao pode ser alterado (REGRA 16). Desativado, ele some da lista de
 * login, tem as sessoes encerradas, as programacoes futuras canceladas e
 * libera vaga no limite de matriculas.
 */
export async function excluirFuncionario(funcionarioId) {
  return rpc('fn_admin_desativar_funcionario', {
    p_token: tokenAtual(),
    p_funcionario_id: funcionarioId,
  });
}

export async function reativarFuncionario(funcionarioId) {
  return rpc('fn_admin_reativar_funcionario', {
    p_token: tokenAtual(),
    p_funcionario_id: funcionarioId,
  });
}

/** Configuracao geral: limite de matriculas, ativos, vagas. */
export async function configuracao() {
  return rpc('fn_admin_configuracao', { p_token: tokenAtual() });
}

/** Define o teto de funcionarios ativos. 0 = sem limite. Somente ADMIN_MASTER. */
export async function definirLimiteMatriculas(limite) {
  return rpc('fn_admin_definir_limite_matriculas', {
    p_token: tokenAtual(),
    p_limite: limite,
  });
}

/**
 * PERFIL DO PROPRIO FUNCIONARIO
 * ---------------------------------------------------------------------------
 * O funcionario pode corrigir o proprio nome - erro de digitacao no cadastro,
 * nome de casada, abreviacao mal escolhida.
 *
 * A MATRICULA nao muda por aqui, e isso e proposital: ela e a identidade do
 * registro. Usos, agendamentos e auditoria apontam para esse funcionario, e a
 * matricula e o que liga tudo isso a pessoa real da fabrica. Trocar a matricula
 * seria reescrever historico, que o sistema nao permite a ninguem (REGRA 16).
 *
 * A troca de nome em si e auditada, com o valor anterior guardado.
 */

import { rpc } from './api.js';
import { tokenAtual } from './auth.js';
import { ErroApp } from './erros.js';
import { nomeValido } from './validacoes.js';

export async function alterarNome(nome) {
  if (!nomeValido(nome)) throw new ErroApp('NOME_INVALIDO');

  return rpc('fn_perfil_alterar_nome', {
    p_token: tokenAtual(),
    p_nome: nome.trim(),
  });
}

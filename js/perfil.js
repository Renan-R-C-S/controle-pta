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
import { nomeValido, pinValido } from './validacoes.js';

export async function alterarNome(nome) {
  if (!nomeValido(nome)) throw new ErroApp('NOME_INVALIDO');

  return rpc('fn_perfil_alterar_nome', {
    p_token: tokenAtual(),
    p_nome: nome.trim(),
  });
}

/**
 * Troca do proprio PIN.
 * Exige o PIN atual: sem isso, uma sessao esquecida aberta no celular deixaria
 * qualquer um trocar a senha do dono.
 */
export async function trocarPin({ atual, novo, confirmacao }) {
  if (!pinValido(novo)) throw new ErroApp('PIN_FORMATO');
  if (novo !== confirmacao) throw new ErroApp('PIN_DIFERENTE');

  return rpc('fn_perfil_trocar_pin', {
    p_token: tokenAtual(),
    p_pin_atual: atual,
    p_pin_novo: novo,
  });
}

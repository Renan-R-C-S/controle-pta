/**
 * TERCEIROS (FORNECEDORES)
 * ---------------------------------------------------------------------------
 * Empresa ou prestador externo envolvido no uso ou na programacao.
 *
 * Um registro por uso/agendamento. Onde o nome aparece, ele vem colado ao do
 * colaborador que o incluiu, no formato "Colaborador / Terceiro" - ver
 * pessoaComTerceiro() em js/ui.js.
 */

import { rpc } from './api.js';
import { tokenAtual } from './auth.js';
import { ErroApp } from './erros.js';

/** Lista/busca terceiros. Sem termo, devolve os primeiros 100 por nome. */
export async function listar(busca = null) {
  return rpc('fn_fornecedores', { p_busca: busca });
}

/**
 * Cadastra um terceiro.
 * Nome repetido nao cria duplicata: o banco devolve o cadastro existente com
 * ja_existia = true, entao "Alfa Montagens" e "alfa montagens " sao o mesmo.
 */
export async function criar(nome, documento = null) {
  const limpo = (nome ?? '').trim();
  if (limpo.length < 2 || limpo.length > 80) throw new ErroApp('FORNECEDOR_NOME_INVALIDO');

  return rpc('fn_fornecedor_criar', {
    p_token: tokenAtual(),
    p_nome: limpo,
    p_documento: documento?.trim() || null,
  });
}

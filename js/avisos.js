/**
 * AVISOS (comunicados exibidos no login)
 * ---------------------------------------------------------------------------
 * Um aviso pode ser geral, dirigido a setores, dirigido a pessoas especificas,
 * ou uma combinacao. Sem destino cadastrado ele vale para todo mundo; com
 * destinos, vale para a uniao deles.
 *
 * Nao existe registro de "ja li": o aviso reaparece a cada login enquanto
 * estiver ativo e dentro do prazo. Guardar leitura daria a falsa impressao de
 * confirmacao de ciencia, que este sistema nao coleta.
 */

import { rpc } from './api.js';
import { tokenAtual } from './auth.js';

/** Avisos vigentes que alcancam quem esta logado. Usado no popup pos-login. */
export async function paraMim() {
  return rpc('fn_avisos_para_mim', { p_token: tokenAtual() });
}

export async function listar() {
  return rpc('fn_aviso_listar', { p_token: tokenAtual() });
}

/**
 * @param {string[]} [setores]  ids dos setores destinatarios
 * @param {string[]} [pessoas]  ids dos colaboradores destinatarios
 * @param {string}   [inicioEm] ISO; null = vale desde ja
 * @param {string}   [fimEm]    ISO; null = prazo indefinido
 */
export async function criar({ titulo, mensagem, setores, pessoas, inicioEm, fimEm }) {
  return rpc('fn_aviso_criar', {
    p_token: tokenAtual(),
    p_titulo: titulo?.trim(),
    p_mensagem: mensagem?.trim(),
    p_setores: setores?.length ? setores : null,
    p_pessoas: pessoas?.length ? pessoas : null,
    p_inicio_em: inicioEm || null,
    p_fim_em: fimEm || null,
  });
}

export async function definirAtivo(avisoId, ativo) {
  return rpc('fn_aviso_definir_ativo', {
    p_token: tokenAtual(),
    p_aviso_id: avisoId,
    p_ativo: ativo,
  });
}

export async function excluir(avisoId) {
  return rpc('fn_aviso_excluir', { p_token: tokenAtual(), p_aviso_id: avisoId });
}

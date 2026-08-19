/**
 * PTAs (itens 9, 39, 41)
 * ---------------------------------------------------------------------------
 * O identificador da PTA chega pela URL do QR Code 1:
 *     https://dominio.com/?modo=uso&pta=PTA001
 *
 * O usuario nunca escolhe a PTA manualmente nesse fluxo. O sistema aceita as
 * variacoes "PTA001", "pta-001" e "PTA-1", normalizando tudo para "PTA-001"
 * (a normalizacao definitiva acontece no banco, em fn__normalizar_codigo_pta).
 */

import { rpc } from './api.js';
import { tokenAtual } from './auth.js';

/** Le os parametros do QR Code a partir da URL (item 41). */
export function parametrosDaUrl() {
  const params = new URLSearchParams(window.location.search);
  return {
    modo: (params.get('modo') ?? '').toLowerCase() || null,
    pta: params.get('pta'),
  };
}

/** Normalizacao local, apenas para exibir o codigo antes da resposta do banco. */
export function normalizarCodigo(codigo) {
  if (!codigo) return null;
  const digitos = String(codigo).toUpperCase().trim().replace(/[^0-9]/g, '');
  if (!digitos) return String(codigo).toUpperCase().trim();
  return `PTA-${digitos.padStart(3, '0')}`;
}

export async function listarPtas() {
  return rpc('fn_ptas');
}

/**
 * Situacao completa da PTA para o dashboard do QR Code 1 (itens 10 e 38):
 * status (DISPONIVEL / EM_USO), uso em andamento, proximos agendamentos e a
 * hora oficial do servidor.
 */
export async function situacao(codigoPta) {
  return rpc('fn_pta_situacao', {
    p_codigo: codigoPta,
    p_token: tokenAtual(),
  });
}

/* -------------------------------------------------------------------------- */
/* Gestao das PTAs (administracao)                                             */
/* -------------------------------------------------------------------------- */

/** Lista com o estado administrativo: ativo, em uso, e se pode ser excluida. */
export async function listarParaAdmin() {
  return rpc('fn_admin_listar_ptas', { p_token: tokenAtual() });
}

/** O codigo aceita '917', 'pta 917' ou 'PTA-917'. O banco normaliza. */
export async function criarPta({ codigo, descricao, local }) {
  return rpc('fn_pta_criar', {
    p_token: tokenAtual(),
    p_codigo: codigo,
    p_descricao: descricao?.trim() || null,
    p_local: local?.trim() || null,
  });
}

export async function alterarPta({ id, codigo, descricao, local }) {
  return rpc('fn_pta_alterar', {
    p_token: tokenAtual(),
    p_pta_id: id,
    p_codigo: codigo,
    p_descricao: descricao?.trim() || null,
    p_local: local?.trim() || null,
  });
}

/** Desabilitada, a PTA some das telas de escolha mas mantem o historico. */
export async function definirAtivo(id, ativo) {
  return rpc('fn_pta_definir_ativo', { p_token: tokenAtual(), p_pta_id: id, p_ativo: ativo });
}

/** So funciona enquanto a PTA nunca teve uso, programacao ou regra ciclica. */
export async function excluirPta(id) {
  return rpc('fn_pta_excluir', { p_token: tokenAtual(), p_pta_id: id });
}

/** Item 13: o que esta em uso neste instante. Consulta livre, sem login. */
export async function emUsoAgora() {
  return rpc('fn_em_uso_agora');
}

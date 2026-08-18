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

/**
 * CAMADA DE ACESSO AO SUPABASE
 * ---------------------------------------------------------------------------
 * Unico ponto do sistema que conversa com o backend.
 *
 * O frontend NAO faz SELECT/INSERT/UPDATE direto em tabelas: todas as chamadas
 * passam por funcoes RPC (SECURITY DEFINER) que validam sessao e regras de
 * negocio no banco. Ver sql/02_funcoes.sql e sql/03_rls.sql.
 */

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';
import { SUPABASE_URL, SUPABASE_ANON_KEY, configuracaoPendente } from './config.js';
import { ErroApp, normalizarErro } from './erros.js';

let cliente = null;

/** Cliente Supabase (criado sob demanda). */
export function supabase() {
  if (configuracaoPendente()) {
    throw new ErroApp('NAO_CONFIGURADO', 'js/config.js ainda tem valores de exemplo');
  }
  if (!cliente) {
    cliente = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
  }
  return cliente;
}

/**
 * Executa uma funcao RPC e devolve os dados ja tratados.
 *
 * Duas formas de erro sao convertidas em ErroApp:
 *   1. excecao lancada pelo PostgreSQL (ex.: PTA_EM_USO);
 *   2. retorno { ok: false, erro: 'CODIGO' } - usado quando a funcao precisa
 *      PERSISTIR algo antes de recusar a operacao (caso do contador de
 *      tentativas de PIN, que seria desfeito por um RAISE).
 */
export async function rpc(nomeFuncao, parametros = {}) {
  const { data, error } = await supabase().rpc(nomeFuncao, parametros);

  if (error) {
    const tratado = normalizarErro(error);
    console.debug(`[PTA] rpc ${nomeFuncao} falhou:`, error);
    throw tratado;
  }

  if (data && typeof data === 'object' && !Array.isArray(data) && data.ok === false && data.erro) {
    throw new ErroApp(data.erro, `rpc ${nomeFuncao}`);
  }

  return data;
}

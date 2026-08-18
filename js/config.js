/**
 * CONFIGURACAO DO SISTEMA
 * ---------------------------------------------------------------------------
 * Preencha os dois valores abaixo com os dados do seu projeto Supabase:
 *   Painel do Supabase -> Project Settings -> API
 *
 *   SUPABASE_URL       = "Project URL"
 *   SUPABASE_ANON_KEY  = "anon public" (chave publica)
 *
 * ATENCAO (item 31): use SOMENTE a chave "anon".
 * A chave "service_role" ignora todas as politicas de seguranca do banco e
 * NUNCA pode aparecer no frontend - todo o codigo publicado no GitHub Pages
 * fica visivel para qualquer pessoa.
 *
 * A chave anon e publica por natureza. A protecao real do sistema esta no
 * banco: RLS habilitado sem politicas + funcoes SECURITY DEFINER (sql/03_rls.sql).
 */

export const SUPABASE_URL = 'https://SEU-PROJETO.supabase.co';
export const SUPABASE_ANON_KEY = 'COLE_AQUI_SUA_CHAVE_ANON';

/** Configuracoes gerais da aplicacao. */
export const APP = {
  nome: 'Controle de PTA',

  /** Fuso horario oficial (item 34). O servidor e a fonte da verdade. */
  fusoHorario: 'America/Sao_Paulo',

  /** REGRA 13: limite de caracteres da observacao. */
  limiteObservacao: 200,

  /** REGRA 14: minutos de tolerancia para editar a observacao. */
  minutosEdicaoObservacao: 30,

  /** REGRA 2: quantidade de digitos do PIN. */
  digitosPin: 4,

  /** Chave usada no localStorage. Guarda APENAS o token de sessao (item 32). */
  chaveSessao: 'pta.sessao',

  /** Intervalo de atualizacao automatica das telas ao vivo (ms). */
  intervaloAtualizacao: 60000,
};

/** Indica se o arquivo ainda esta com os valores de exemplo. */
export function configuracaoPendente() {
  return (
    !SUPABASE_URL ||
    SUPABASE_URL.includes('SEU-PROJETO') ||
    !SUPABASE_ANON_KEY ||
    SUPABASE_ANON_KEY.includes('COLE_AQUI')
  );
}

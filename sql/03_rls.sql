-- =============================================================================
-- SISTEMA DE CONTROLE E AGENDAMENTO DE PTA
-- Arquivo 03 - ROW LEVEL SECURITY E PRIVILEGIOS (item 31)
--
-- MODELO ADOTADO: "deny by default".
--
-- O frontend usa a chave anon, que corresponde ao papel `anon` do Postgres.
-- Esse papel:
--   * NAO tem SELECT/INSERT/UPDATE/DELETE em nenhuma tabela;
--   * so pode executar as funcoes liberadas em 02_funcoes.sql.
--
-- Como toda leitura e escrita passa por funcoes SECURITY DEFINER que validam o
-- token de sessao, o usuario nao consegue:
--   * ler o hash do PIN de ninguem;
--   * trocar um ID no DevTools para finalizar o uso de outra pessoa;
--   * apagar ou reescrever historico;
--   * inserir um agendamento sem passar pela checagem de conflito.
--
-- RLS fica HABILITADO (e nao FORCE) em todas as tabelas: assim o papel anon e
-- barrado mesmo que algum GRANT seja concedido por engano no futuro, enquanto o
-- dono do banco - usado pelas funcoes SECURITY DEFINER - continua operando.
-- =============================================================================

alter table public.setores               enable row level security;
alter table public.funcionarios          enable row level security;
alter table public.ptas                  enable row level security;
alter table public.agendamentos          enable row level security;
alter table public.usos                  enable row level security;
alter table public.agendamentos_afetados enable row level security;
alter table public.auditoria             enable row level security;
alter table public.sessoes               enable row level security;
alter table public.matriculas_reservadas enable row level security;
alter table public.configuracao          enable row level security;
alter table public.fornecedores           enable row level security;
alter table public.agendamentos_ciclicos enable row level security;

-- Nenhuma politica e criada de proposito: sem politica, RLS nega tudo para os
-- papeis nao-donos. Toda a superficie util esta nas funcoes RPC.

-- Remove os privilegios que o Supabase concede por padrao no schema public ----
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;

-- Novas tabelas criadas depois deste script tambem nascem sem privilegios
alter default privileges in schema public revoke all on tables    from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;

-- Por padrao o Postgres concede EXECUTE em toda nova funcao ao papel PUBLIC.
-- Retiramos essa concessao implicita de tudo o que ja existe. As funcoes que o
-- frontend usa continuam acessiveis porque 02_funcoes.sql as concedeu
-- EXPLICITAMENTE a anon/authenticated - e revogar de PUBLIC nao afeta um GRANT
-- nominal. Resultado: so a lista do final de 02_funcoes.sql fica chamavel.
revoke execute on all functions in schema public from public;

-- Mesma politica para as funcoes criadas daqui em diante
alter default privileges in schema public revoke execute on functions from public;

-- O papel anon precisa apenas enxergar o schema para chamar as funcoes
grant usage on schema public to anon, authenticated;

-- =============================================================================
-- VERIFICACAO RAPIDA
-- Rode as consultas abaixo apos aplicar o script. O resultado esperado esta
-- indicado em cada uma.
-- =============================================================================

-- 1) Todas as tabelas devem aparecer com rowsecurity = true
-- select tablename, rowsecurity
--   from pg_tables where schemaname = 'public' order by tablename;

-- 2) Nao deve retornar NENHUMA linha (anon sem privilegio direto em tabela)
-- select table_name, privilege_type
--   from information_schema.role_table_grants
--  where grantee = 'anon' and table_schema = 'public';

-- 3) Deve listar somente as funcoes fn_* publicas (nenhuma fn__* interna)
-- select p.proname
--   from pg_proc p
--   join pg_namespace n on n.oid = p.pronamespace
--  where n.nspname = 'public'
--    and has_function_privilege('anon', p.oid, 'execute')
--  order by 1;

-- =============================================================================
-- LEMBRETE DE OPERACAO
-- A chave service_role NUNCA deve aparecer no frontend (item 31). Ela ignora
-- RLS por completo. No GitHub Pages todo o codigo e publico: use apenas a
-- chave anon em js/config.js.
-- =============================================================================

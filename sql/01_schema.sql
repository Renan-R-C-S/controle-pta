-- =============================================================================
-- SISTEMA DE CONTROLE E AGENDAMENTO DE PTA
-- Arquivo 01 - ESQUEMA (tabelas, restricoes, indices)
-- Execute no SQL Editor do Supabase na ordem: 01 -> 02 -> 03 -> 04 -> 05
-- =============================================================================

-- O search_path abaixo garante que as classes de operador do btree_gist e as
-- funcoes do pgcrypto sejam encontradas, independentemente do schema em que as
-- extensoes foram instaladas neste projeto.
set search_path = public, extensions;

-- Extensoes -------------------------------------------------------------------
create extension if not exists pgcrypto   with schema extensions;  -- hash de PIN (bcrypt)
create extension if not exists btree_gist with schema extensions;  -- exclusao por intervalo

-- Fuso horario oficial do sistema (item 34 do escopo).
-- Todos os instantes sao gravados em timestamptz (UTC internamente) e convertidos
-- para 'America/Sao_Paulo' apenas na leitura/apresentacao.
create or replace function public.fn_tz() returns text
language sql immutable as $$ select 'America/Sao_Paulo'::text $$;

-- =============================================================================
-- SETORES
-- =============================================================================
create table if not exists public.setores (
  id         uuid primary key default gen_random_uuid(),
  nome       text not null,
  ordem      smallint not null default 0,
  ativo      boolean not null default true,
  criado_em  timestamptz not null default now(),
  constraint setores_nome_unico   unique (nome),
  constraint setores_nome_valido  check (char_length(btrim(nome)) between 2 and 60)
);

-- =============================================================================
-- FUNCIONARIOS
-- REGRA 1: matricula unica GLOBALMENTE (inclusive entre setores diferentes).
-- REGRA 2: PIN de exatamente 4 digitos (validado nas funcoes de 02_funcoes.sql).
-- REGRA 3: o PIN nunca e armazenado em texto puro - apenas hash bcrypt + salt.
-- =============================================================================
create table if not exists public.funcionarios (
  id                 uuid primary key default gen_random_uuid(),
  nome               text not null,
  matricula          text not null,
  pin_hash           text not null,
  setor_id           uuid not null references public.setores(id) on delete restrict,
  ativo              boolean not null default true,
  tentativas_falhas  smallint not null default 0,
  bloqueado_ate      timestamptz,
  ultimo_login_em    timestamptz,
  criado_em          timestamptz not null default now(),
  atualizado_em      timestamptz not null default now(),
  -- REGRA 1 garantida pelo banco, nao apenas pelo JavaScript
  constraint funcionarios_matricula_unica   unique (matricula),
  constraint funcionarios_matricula_formato check (matricula ~ '^[0-9]{4,10}$'),
  constraint funcionarios_nome_valido       check (char_length(btrim(nome)) between 3 and 80),
  constraint funcionarios_tentativas_ok     check (tentativas_falhas >= 0)
);

create index if not exists idx_funcionarios_setor
  on public.funcionarios (setor_id) where ativo;

-- =============================================================================
-- PTAs (Plataformas de Trabalho em Altura)
-- O codigo e o identificador transportado pelo QR Code 1.
-- =============================================================================
create table if not exists public.ptas (
  id         uuid primary key default gen_random_uuid(),
  codigo     text not null,
  descricao  text,
  local      text,
  ativo      boolean not null default true,
  criado_em  timestamptz not null default now(),
  constraint ptas_codigo_unico   unique (codigo),
  constraint ptas_codigo_formato check (codigo ~ '^PTA-[0-9]{3,4}$')
);

-- =============================================================================
-- AGENDAMENTOS (QR Code 2) - o que foi PLANEJADO
-- REGRA 6 / 21: agendamento nao e uso efetivo; os campos "planejado" sao
-- separados dos campos "efetivo" da tabela usos.
-- REGRA 17: conflito de horario na mesma PTA e bloqueado pelo proprio banco.
-- =============================================================================
create table if not exists public.agendamentos (
  id                uuid primary key default gen_random_uuid(),
  pta_id            uuid not null references public.ptas(id) on delete restrict,
  funcionario_id    uuid not null references public.funcionarios(id) on delete restrict,
  data_ref          date not null,                 -- dia de referencia em America/Sao_Paulo
  inicio_planejado  timestamptz not null,
  fim_planejado     timestamptz not null,
  status            text not null default 'AGENDADO',
  motivo_status     text,
  cancelado_em      timestamptz,
  criado_em         timestamptz not null default now(),
  atualizado_em     timestamptz not null default now(),
  constraint agendamentos_status_valido check (status in (
      'AGENDADO', 'SOBRESCRITO', 'CANCELADO', 'CONCLUIDO', 'AFETADO_POR_USO_IMEDIATO')),
  constraint agendamentos_intervalo_valido check (fim_planejado > inicio_planejado),
  constraint agendamentos_duracao_max check (
      fim_planejado - inicio_planejado <= interval '14 hours'),
  -- REGRA 17 - garantia real contra usuarios simultaneos:
  -- dois agendamentos ATIVOS da mesma PTA nunca podem se sobrepor no tempo.
  constraint agendamentos_sem_conflito exclude using gist (
      pta_id with =,
      tstzrange(inicio_planejado, fim_planejado, '[)') with &&
  ) where (status = 'AGENDADO')
);

create index if not exists idx_agendamentos_data on public.agendamentos (data_ref, pta_id);
create index if not exists idx_agendamentos_func on public.agendamentos (funcionario_id, data_ref);

-- =============================================================================
-- USOS (QR Code 1) - o que EFETIVAMENTE aconteceu
-- REGRA 8/9/10/11/12: inicio_efetivo automatico, fim_pretendido informado pelo
-- funcionario, fim_efetivo gravado somente no clique de finalizacao.
-- REGRA 13/14: observacao <= 200 caracteres, editavel ate fim_efetivo + 30 min.
-- =============================================================================
create table if not exists public.usos (
  id                        uuid primary key default gen_random_uuid(),
  pta_id                    uuid not null references public.ptas(id) on delete restrict,
  funcionario_id            uuid not null references public.funcionarios(id) on delete restrict,
  data_ref                  date not null,
  inicio_efetivo            timestamptz not null,   -- REGRA 9: definido pelo servidor
  fim_pretendido            timestamptz not null,   -- informado pelo funcionario
  fim_efetivo               timestamptz,            -- REGRA 10: NULL enquanto aberto
  status                    text not null default 'EM_USO',
  agendamento_origem_id     uuid references public.agendamentos(id) on delete set null,
  observacao                text,
  observacao_atualizada_em  timestamptz,
  limite_edicao_observacao  timestamptz,            -- fim_efetivo + 30 minutos
  criado_em                 timestamptz not null default now(),
  atualizado_em             timestamptz not null default now(),
  constraint usos_status_valido     check (status in ('EM_USO', 'FINALIZADO')),
  constraint usos_pretendido_valido check (fim_pretendido > inicio_efetivo),  -- item 12
  constraint usos_efetivo_valido    check (fim_efetivo is null or fim_efetivo >= inicio_efetivo),
  constraint usos_observacao_limite check (observacao is null or char_length(observacao) <= 200),
  constraint usos_coerencia_status  check (
      (status = 'EM_USO'     and fim_efetivo is null) or
      (status = 'FINALIZADO' and fim_efetivo is not null))
);

-- Apenas UM uso aberto por PTA (impede dois usos simultaneos no mesmo equipamento)
create unique index if not exists uq_uso_aberto_por_pta
  on public.usos (pta_id) where (status = 'EM_USO');

-- Apenas UM uso aberto por funcionario (decisao documentada em docs/DECISOES.md)
create unique index if not exists uq_uso_aberto_por_funcionario
  on public.usos (funcionario_id) where (status = 'EM_USO');

create index if not exists idx_usos_data on public.usos (data_ref, pta_id);
create index if not exists idx_usos_func on public.usos (funcionario_id, data_ref);

-- =============================================================================
-- AGENDAMENTOS AFETADOS (REGRA 7 / 18)
-- Vinculo entre um uso imediato (QR1) e os agendamentos (QR2) que ele afetou.
-- O agendamento anterior NUNCA e apagado - apenas marcado e vinculado aqui.
-- =============================================================================
create table if not exists public.agendamentos_afetados (
  id               uuid primary key default gen_random_uuid(),
  uso_id           uuid not null references public.usos(id) on delete restrict,
  agendamento_id   uuid not null references public.agendamentos(id) on delete restrict,
  status_anterior  text not null,
  status_novo      text not null,
  causado_por      uuid not null references public.funcionarios(id) on delete restrict,
  criado_em        timestamptz not null default now(),
  constraint agendamentos_afetados_unico unique (uso_id, agendamento_id)
);

create index if not exists idx_afetados_agendamento
  on public.agendamentos_afetados (agendamento_id);

-- =============================================================================
-- AUDITORIA (REGRA 15 / 16) - append-only
-- =============================================================================
create table if not exists public.auditoria (
  id                bigserial primary key,
  usuario_id        uuid references public.funcionarios(id) on delete set null,
  pta_id            uuid references public.ptas(id) on delete set null,
  tipo_acao         text not null,
  registro_tipo     text not null,
  registro_id       text,
  ocorrido_em       timestamptz not null default now(),
  dados_anteriores  jsonb,
  dados_novos       jsonb,
  descricao         text,
  constraint auditoria_tipo_acao_valido check (tipo_acao in (
      'CADASTRO_USUARIO', 'LOGIN', 'LOGIN_FALHA', 'LOGOUT',
      'AGENDAMENTO_CRIADO', 'AGENDAMENTO_CANCELADO', 'AGENDAMENTO_SOBRESCRITO',
      'AGENDAMENTO_CONCLUIDO',
      'USO_INICIADO', 'USO_FINALIZADO',
      'OBSERVACAO_CRIADA', 'OBSERVACAO_EDITADA'))
);

create index if not exists idx_auditoria_ocorrido on public.auditoria (ocorrido_em desc);
create index if not exists idx_auditoria_registro on public.auditoria (registro_tipo, registro_id);
create index if not exists idx_auditoria_usuario  on public.auditoria (usuario_id, ocorrido_em desc);

-- =============================================================================
-- SESSOES
-- O sistema usa autenticacao propria (matricula + PIN) porque o login precisa
-- ocorrer em poucos toques logo apos a leitura do QR Code. O token abaixo e um
-- segredo opaco e aleatorio - NUNCA o PIN. Ver docs/DECISOES.md.
-- =============================================================================
create table if not exists public.sessoes (
  token             uuid primary key default gen_random_uuid(),
  funcionario_id    uuid not null references public.funcionarios(id) on delete cascade,
  criado_em         timestamptz not null default now(),
  ultimo_acesso_em  timestamptz not null default now(),
  expira_em         timestamptz not null,
  encerrada_em      timestamptz
);

create index if not exists idx_sessoes_func on public.sessoes (funcionario_id);

-- =============================================================================
-- Gatilho generico de atualizado_em
-- =============================================================================
create or replace function public.fn_touch_atualizado_em()
returns trigger language plpgsql as $$
begin
  new.atualizado_em := now();
  return new;
end $$;

drop trigger if exists trg_touch_funcionarios on public.funcionarios;
create trigger trg_touch_funcionarios before update on public.funcionarios
  for each row execute function public.fn_touch_atualizado_em();

drop trigger if exists trg_touch_agendamentos on public.agendamentos;
create trigger trg_touch_agendamentos before update on public.agendamentos
  for each row execute function public.fn_touch_atualizado_em();

drop trigger if exists trg_touch_usos on public.usos;
create trigger trg_touch_usos before update on public.usos
  for each row execute function public.fn_touch_atualizado_em();

-- =============================================================================
-- Protecao do historico (REGRA 16)
-- A auditoria e o vinculo de sobrescritas sao imutaveis mesmo para o dono do
-- banco. Correcoes devem ser feitas como NOVOS eventos (item 49 do escopo).
-- =============================================================================
create or replace function public.fn_bloquear_alteracao_historico()
returns trigger language plpgsql as $$
begin
  raise exception 'HISTORICO_IMUTAVEL' using errcode = 'P0001';
end $$;

drop trigger if exists trg_auditoria_imutavel on public.auditoria;
create trigger trg_auditoria_imutavel before update or delete on public.auditoria
  for each row execute function public.fn_bloquear_alteracao_historico();

drop trigger if exists trg_afetados_imutavel on public.agendamentos_afetados;
create trigger trg_afetados_imutavel before update or delete on public.agendamentos_afetados
  for each row execute function public.fn_bloquear_alteracao_historico();

-- =============================================================================
-- PERFIS DE ACESSO E ADMINISTRACAO
--
-- Tres papeis:
--   FUNCIONARIO   uso normal do sistema
--   ADMIN         + alterar/cancelar qualquer programacao, desativar usuarios,
--                   promover outros a ADMIN
--   ADMIN_MASTER  + revogar ADMIN de alguem e definir o limite de matriculas
--
-- Nenhum papel altera auditoria ou historico: os gatilhos de imutabilidade
-- valem para todo mundo, inclusive para o dono do banco.
-- =============================================================================

alter table public.funcionarios
  add column if not exists papel          text not null default 'FUNCIONARIO',
  add column if not exists desativado_em  timestamptz,
  add column if not exists desativado_por uuid references public.funcionarios(id);

alter table public.funcionarios drop constraint if exists funcionarios_papel_valido;
alter table public.funcionarios add constraint funcionarios_papel_valido
  check (papel in ('FUNCIONARIO', 'ADMIN', 'ADMIN_MASTER'));

create index if not exists idx_funcionarios_papel
  on public.funcionarios (papel) where papel <> 'FUNCIONARIO';

-- Matriculas que ja nascem com papel administrativo quando forem cadastradas.
-- E o mecanismo de partida do sistema: sem ele nao existiria o primeiro ADMIN.
-- ATENCAO: quem cadastrar primeiro uma destas matriculas assume o papel. Essas
-- pessoas devem se cadastrar no primeiro dia (ver README, secao 10).
create table if not exists public.matriculas_reservadas (
  matricula   text primary key,
  papel       text not null,
  observacao  text,
  criado_em   timestamptz not null default now(),
  constraint matriculas_reservadas_papel   check (papel in ('ADMIN', 'ADMIN_MASTER')),
  constraint matriculas_reservadas_formato check (matricula ~ '^[0-9]{4,10}$')
);

-- Parametros gerais ajustaveis pelo ADMIN_MASTER.
create table if not exists public.configuracao (
  chave           text primary key,
  valor           text not null,
  descricao       text,
  atualizado_em   timestamptz not null default now(),
  atualizado_por  uuid references public.funcionarios(id) on delete set null
);

-- limite_matriculas: quantidade maxima de funcionarios ATIVOS.
-- O valor 0 significa "sem limite". Desativar alguem libera vaga.
insert into public.configuracao (chave, valor, descricao)
values ('limite_matriculas', '0',
        'Maximo de funcionarios ativos. 0 = sem limite. Somente o ADMIN_MASTER altera.')
on conflict (chave) do nothing;

-- Novos tipos de acao auditavel (REGRA 15)
alter table public.auditoria drop constraint if exists auditoria_tipo_acao_valido;
alter table public.auditoria add constraint auditoria_tipo_acao_valido check (tipo_acao in (
    'CADASTRO_USUARIO', 'LOGIN', 'LOGIN_FALHA', 'LOGOUT',
    'AGENDAMENTO_CRIADO', 'AGENDAMENTO_CANCELADO', 'AGENDAMENTO_SOBRESCRITO',
    'AGENDAMENTO_CONCLUIDO', 'AGENDAMENTO_ALTERADO',
    'USO_INICIADO', 'USO_FINALIZADO',
    'OBSERVACAO_CRIADA', 'OBSERVACAO_EDITADA',
    'NOME_ALTERADO', 'PAPEL_ALTERADO',
    'FUNCIONARIO_DESATIVADO', 'FUNCIONARIO_REATIVADO',
    'LIMITE_MATRICULAS_ALTERADO'));

-- =============================================================================
-- TERCEIROS (FORNECEDORES)
--
-- Empresa ou prestador externo envolvido no uso ou na programacao.
-- Um registro por uso/agendamento (decisao em docs/DECISOES.md, item 18).
-- =============================================================================
create table if not exists public.fornecedores (
  id          uuid primary key default gen_random_uuid(),
  nome        text not null,
  documento   text,
  ativo       boolean not null default true,
  criado_em   timestamptz not null default now(),
  criado_por  uuid references public.funcionarios(id) on delete set null,
  constraint fornecedores_nome_valido check (char_length(btrim(nome)) between 2 and 80)
);

-- Nome unico ignorando maiusculas e espacos: evita "Alfa Montagens" e
-- "alfa montagens " virarem dois cadastros da mesma empresa.
create unique index if not exists uq_fornecedor_nome
  on public.fornecedores (lower(btrim(nome)));

alter table public.usos
  add column if not exists fornecedor_id uuid references public.fornecedores(id) on delete restrict;
alter table public.agendamentos
  add column if not exists fornecedor_id uuid references public.fornecedores(id) on delete restrict;

-- =============================================================================
-- CANCELAMENTO DE USO EM ABERTO
--
-- Um administrador pode encerrar um uso que ficou esquecido. Isso NAO e o mesmo
-- que finalizar: nao existe fim_efetivo, porque ninguem observou o fim real.
-- O registro fica como CANCELADO, visivel no calendario e no historico.
-- =============================================================================
alter table public.usos
  add column if not exists cancelado_em     timestamptz,
  add column if not exists cancelado_por    uuid references public.funcionarios(id),
  add column if not exists motivo_cancelamento text;

alter table public.usos drop constraint if exists usos_status_valido;
alter table public.usos add constraint usos_status_valido
  check (status in ('EM_USO', 'FINALIZADO', 'CANCELADO'));

alter table public.usos drop constraint if exists usos_coerencia_status;
alter table public.usos add constraint usos_coerencia_status check (
  (status = 'EM_USO'     and fim_efetivo is null) or
  (status = 'FINALIZADO' and fim_efetivo is not null) or
  (status = 'CANCELADO'  and fim_efetivo is null and cancelado_em is not null));

-- Os indices de "uso aberto" continuam olhando so para EM_USO, entao um uso
-- cancelado libera a PTA e libera o funcionario para iniciar outro.

-- =============================================================================
-- AGENDAMENTOS CICLICOS
--
-- Regra de repeticao criada por um administrador em nome de um funcionario.
-- As ocorrencias sao materializadas como agendamentos comuns, ligadas de volta
-- pela coluna ciclico_id - assim o calendario, a checagem de conflito e a
-- sobrescrita pelo QR Code 1 continuam funcionando sem nenhum caso especial.
-- =============================================================================
create table if not exists public.agendamentos_ciclicos (
  id              uuid primary key default gen_random_uuid(),
  pta_id          uuid not null references public.ptas(id) on delete restrict,
  funcionario_id  uuid not null references public.funcionarios(id) on delete restrict,
  hora_inicio     time not null,
  hora_fim        time not null,
  tipo            text not null,
  dias_semana     smallint[],      -- 0=domingo ... 6=sabado (tipo DIAS_SEMANA)
  intervalo_dias  smallint,        -- a cada N dias        (tipo INTERVALO_DIAS)
  data_inicio     date not null,
  data_fim        date,            -- null = sem data final
  gerado_ate      date,            -- ate onde as ocorrencias ja foram criadas
  fornecedor_id   uuid references public.fornecedores(id) on delete restrict,
  ativo           boolean not null default true,
  criado_por      uuid not null references public.funcionarios(id) on delete restrict,
  criado_em       timestamptz not null default now(),
  atualizado_em   timestamptz not null default now(),
  desativado_em   timestamptz,
  desativado_por  uuid references public.funcionarios(id),
  constraint ciclicos_tipo_valido check (tipo in ('DIAS_SEMANA', 'INTERVALO_DIAS')),
  constraint ciclicos_horario_valido check (hora_fim > hora_inicio),
  constraint ciclicos_periodo_valido check (data_fim is null or data_fim >= data_inicio),
  -- Cada tipo exige exatamente o seu proprio parametro
  constraint ciclicos_parametro_coerente check (
    (tipo = 'DIAS_SEMANA'    and dias_semana is not null and array_length(dias_semana, 1) between 1 and 7
                             and intervalo_dias is null) or
    (tipo = 'INTERVALO_DIAS' and intervalo_dias is not null and intervalo_dias between 1 and 365
                             and dias_semana is null)),
  constraint ciclicos_dias_validos check (
    dias_semana is null or (dias_semana <@ array[0,1,2,3,4,5,6]::smallint[]))
);

create index if not exists idx_ciclicos_ativos
  on public.agendamentos_ciclicos (ativo, pta_id) where ativo;

alter table public.agendamentos
  add column if not exists ciclico_id uuid references public.agendamentos_ciclicos(id) on delete restrict;

create index if not exists idx_agendamentos_ciclico
  on public.agendamentos (ciclico_id) where ciclico_id is not null;

drop trigger if exists trg_touch_ciclicos on public.agendamentos_ciclicos;
create trigger trg_touch_ciclicos before update on public.agendamentos_ciclicos
  for each row execute function public.fn_touch_atualizado_em();

-- =============================================================================
-- NOVOS PARAMETROS DE CONFIGURACAO
-- =============================================================================

-- Teto de horas que um uso pode declarar ao ser aberto. Tambem serve de
-- referencia para destacar, no painel, os usos que ficaram abertos demais.
-- Definido por qualquer ADMIN (o limite de matriculas continua sendo do MASTER).
insert into public.configuracao (chave, valor, descricao)
values ('max_horas_uso_aberto', '14',
        'Maximo de horas que um uso do QR Code 1 pode declarar/permanecer aberto.')
on conflict (chave) do nothing;

insert into public.configuracao (chave, valor, descricao)
values ('horizonte_ciclico_dias', '90',
        'Quantos dias a frente as ocorrencias de agendamentos ciclicos sao geradas.')
on conflict (chave) do nothing;

-- =============================================================================
-- NOVOS TIPOS DE ACAO AUDITAVEL
-- =============================================================================
alter table public.auditoria drop constraint if exists auditoria_tipo_acao_valido;
alter table public.auditoria add constraint auditoria_tipo_acao_valido check (tipo_acao in (
    'CADASTRO_USUARIO', 'LOGIN', 'LOGIN_FALHA', 'LOGOUT',
    'AGENDAMENTO_CRIADO', 'AGENDAMENTO_CANCELADO', 'AGENDAMENTO_SOBRESCRITO',
    'AGENDAMENTO_CONCLUIDO', 'AGENDAMENTO_ALTERADO',
    'USO_INICIADO', 'USO_FINALIZADO', 'USO_CANCELADO',
    'OBSERVACAO_CRIADA', 'OBSERVACAO_EDITADA',
    'NOME_ALTERADO', 'PAPEL_ALTERADO',
    'FUNCIONARIO_DESATIVADO', 'FUNCIONARIO_REATIVADO',
    'LIMITE_MATRICULAS_ALTERADO', 'CONFIGURACAO_ALTERADA',
    'FORNECEDOR_CRIADO',
    'CICLICO_CRIADO', 'CICLICO_DESATIVADO', 'CICLICO_GERADO'));

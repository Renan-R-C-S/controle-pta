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

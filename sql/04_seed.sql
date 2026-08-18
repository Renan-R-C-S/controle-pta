-- =============================================================================
-- SISTEMA DE CONTROLE E AGENDAMENTO DE PTA
-- Arquivo 04 - DADOS DE TESTE (item 40)
--
-- Este script e IDEMPOTENTE: pode ser executado novamente sem duplicar dados.
--
-- PINs dos funcionarios ficticios (apenas para demonstracao):
--   Joao Silva     10001  PIN 1234
--   Maria Souza    10002  PIN 2345
--   Carlos Santos  10003  PIN 3456
--   Ana Oliveira   10004  PIN 4567
--
-- Os PINs sao gravados com hash bcrypt, exatamente como no cadastro real
-- (REGRA 3). Em producao, apague estes funcionarios de demonstracao.
-- =============================================================================

-- O search_path abaixo garante que as classes de operador do btree_gist e as
-- funcoes do pgcrypto sejam encontradas, independentemente do schema em que as
-- extensoes foram instaladas neste projeto.
set search_path = public, extensions;

-- Setores (item 6) ------------------------------------------------------------
insert into public.setores (nome, ordem) values
  ('Mecanica', 1), ('Eletrica', 2), ('PCM', 3), ('Producao', 4)
on conflict (nome) do nothing;

-- PTAs (item 39) --------------------------------------------------------------
insert into public.ptas (codigo, descricao, local) values
  ('PTA-001', 'Plataforma tesoura 10m',   'Galpao A - Linha 1'),
  ('PTA-002', 'Plataforma articulada 14m','Galpao B - Expedicao'),
  ('PTA-003', 'Plataforma tesoura 8m',    'Galpao A - Utilidades')
on conflict (codigo) do nothing;

-- Funcionarios ----------------------------------------------------------------
insert into public.funcionarios (nome, matricula, pin_hash, setor_id)
select v.nome, v.matricula,
       crypt(v.pin, gen_salt('bf', 10)),
       s.id
  from (values
        ('Joao Silva',    '10001', '1234', 'Mecanica'),
        ('Maria Souza',   '10002', '2345', 'Eletrica'),
        ('Carlos Santos', '10003', '3456', 'Producao'),
        ('Ana Oliveira',  '10004', '4567', 'PCM')
       ) as v(nome, matricula, pin, setor)
  join public.setores s on s.nome = v.setor
on conflict (matricula) do nothing;

-- =============================================================================
-- AGENDAMENTOS DE EXEMPLO
-- Os horarios sao calculados em relacao a HOJE para que a demonstracao continue
-- fazendo sentido em qualquer data de execucao.
-- =============================================================================
do $$
declare
  v_hoje     date := (now() at time zone public.fn_tz())::date;
  v_amanha   date := v_hoje + 1;
  v_ontem    date := v_hoje - 1;
  v_joao     uuid; v_maria uuid; v_carlos uuid; v_ana uuid;
  v_pta1     uuid; v_pta2  uuid; v_pta3   uuid;
begin
  select id into v_joao   from public.funcionarios where matricula = '10001';
  select id into v_maria  from public.funcionarios where matricula = '10002';
  select id into v_carlos from public.funcionarios where matricula = '10003';
  select id into v_ana    from public.funcionarios where matricula = '10004';
  select id into v_pta1   from public.ptas where codigo = 'PTA-001';
  select id into v_pta2   from public.ptas where codigo = 'PTA-002';
  select id into v_pta3   from public.ptas where codigo = 'PTA-003';

  -- Nao repete a carga se ja houver agendamentos de demonstracao
  if exists (select 1 from public.agendamentos) then
    raise notice 'Agendamentos de demonstracao ja existem - nada a fazer.';
    return;
  end if;

  -- (a) Programacao futura normal ------------------------------------------
  insert into public.agendamentos (pta_id, funcionario_id, data_ref, inicio_planejado, fim_planejado)
  values
    (v_pta1, v_joao,  v_amanha, public.fn__local_para_utc(v_amanha, '08:00'),
                                public.fn__local_para_utc(v_amanha, '10:00')),
    (v_pta2, v_maria, v_amanha, public.fn__local_para_utc(v_amanha, '10:30'),
                                public.fn__local_para_utc(v_amanha, '12:00')),
    (v_pta1, v_ana,   v_amanha, public.fn__local_para_utc(v_amanha, '13:00'),
                                public.fn__local_para_utc(v_amanha, '15:00'));

  -- (b) Programacao de HOJE na PTA-003, usada pelo cenario de sobrescrita
  --     do arquivo 05. Fica no fim do dia para continuar valida.
  insert into public.agendamentos (pta_id, funcionario_id, data_ref, inicio_planejado, fim_planejado)
  values
    (v_pta3, v_joao, v_hoje,
     greatest(public.fn__local_para_utc(v_hoje, '14:00'), now() + interval '40 minutes'),
     greatest(public.fn__local_para_utc(v_hoje, '16:00'), now() + interval '3 hours'));

  -- (c) Programacao passada ja concluida ------------------------------------
  insert into public.agendamentos (pta_id, funcionario_id, data_ref, inicio_planejado, fim_planejado, status)
  values
    (v_pta2, v_carlos, v_ontem, public.fn__local_para_utc(v_ontem, '08:00'),
                                public.fn__local_para_utc(v_ontem, '12:00'), 'CONCLUIDO');

  -- (d) Uso passado ja finalizado, com observacao e prazo de edicao vencido --
  --     Demonstra os itens 15 (fim antes do previsto) e 19 (prazo expirado).
  insert into public.usos (
    pta_id, funcionario_id, data_ref, inicio_efetivo, fim_pretendido, fim_efetivo,
    status, observacao, observacao_atualizada_em, limite_edicao_observacao)
  values (
    v_pta2, v_carlos, v_ontem,
    public.fn__local_para_utc(v_ontem, '08:00'),
    public.fn__local_para_utc(v_ontem, '12:00'),
    public.fn__local_para_utc(v_ontem, '10:47'),
    'FINALIZADO',
    'Necessario reposicionar a PTA devido a interferencia do equipamento.',
    public.fn__local_para_utc(v_ontem, '10:50'),
    public.fn__local_para_utc(v_ontem, '11:17'));

  -- (e) Uso passado que ULTRAPASSOU o horario pretendido (item 16) -----------
  insert into public.usos (
    pta_id, funcionario_id, data_ref, inicio_efetivo, fim_pretendido, fim_efetivo,
    status, limite_edicao_observacao)
  values (
    v_pta1, v_maria, v_ontem,
    public.fn__local_para_utc(v_ontem, '13:00'),
    public.fn__local_para_utc(v_ontem, '15:00'),
    public.fn__local_para_utc(v_ontem, '15:38'),
    'FINALIZADO',
    public.fn__local_para_utc(v_ontem, '16:08'));

  raise notice 'Dados de demonstracao carregados.';
end $$;

-- =============================================================================
-- CONFERENCIA
-- =============================================================================
-- select nome, matricula, (select nome from setores where id = setor_id) as setor
--   from funcionarios order by matricula;
-- select * from fn_agenda_dia((now() at time zone fn_tz())::date + 1);

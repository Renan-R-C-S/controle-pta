-- =============================================================================
-- SISTEMA DE CONTROLE E AGENDAMENTO DE PTA
-- Arquivo 05 - CENARIO DE DEMONSTRACAO DA PRIORIDADE DO QR CODE 1
--
-- Este script executa o fluxo do item 48 usando as MESMAS funcoes RPC que o
-- frontend chama - ou seja, o resultado gerado aqui e indistinguivel de um uso
-- real feito pelo celular.
--
-- Cenario reproduzido (item 4 / REGRA 7):
--   1. Joao ja tem uma programacao na PTA-003 para hoje (criada no arquivo 04);
--   2. Carlos chega antes, le o QR Code 1 da PTA-003 e inicia o uso imediato;
--   3. O agendamento de Joao NAO e apagado: fica AFETADO_POR_USO_IMEDIATO;
--   4. O vinculo entre os dois registros e gravado em agendamentos_afetados;
--   5. A auditoria registra quem causou a alteracao, quando, e os dois valores.
--
-- Ao final, a PTA-003 permanece EM_USO, o que tambem serve para demonstrar a
-- tela de retorno do QR Code 1 (item 38).
-- =============================================================================

-- O search_path abaixo garante que as classes de operador do btree_gist e as
-- funcoes do pgcrypto sejam encontradas, independentemente do schema em que as
-- extensoes foram instaladas neste projeto.
set search_path = public, extensions;

do $$
declare
  v_carlos_id  uuid;
  v_login      jsonb;
  v_token      uuid;
  v_resultado  jsonb;
  v_afetados   int;
  -- O MVP so aceita uso terminando no mesmo dia. Limitar o alvo a 23:59 de hoje
  -- deixa a demonstracao funcionar a qualquer hora, sem virar a data.
  v_local      timestamp;
  v_fim        time;
begin
  v_local := now() at time zone public.fn_tz();
  v_fim   := least(v_local + interval '100 minutes',
                   v_local::date + time '23:59')::time;

  select id into v_carlos_id from public.funcionarios where matricula = '10003';
  if v_carlos_id is null then
    raise exception 'Execute o arquivo 04_seed.sql antes deste script.';
  end if;

  if exists (select 1 from public.usos where status = 'EM_USO') then
    raise notice 'Ja existe um uso em aberto - cenario de demonstracao ignorado.';
    return;
  end if;

  -- 1) Carlos faz login (matricula 10003 / PIN 3456)
  v_login := public.fn_login(v_carlos_id, '3456');
  if not (v_login->>'ok')::boolean then
    raise exception 'Falha no login de demonstracao: %', v_login->>'erro';
  end if;
  v_token := (v_login->>'token')::uuid;

  -- 2) Carlos le o QR Code 1 da PTA-003 e informa o fim pretendido.
  --    O inicio efetivo e definido pelo servidor (REGRA 9).
  v_resultado := public.fn_uso_iniciar(
    v_token,
    'PTA-003',
    v_fim);

  v_afetados := (v_resultado->>'agendamentos_afetados')::int;

  raise notice '--------------------------------------------------------------';
  raise notice 'Uso imediato criado na PTA-003';
  raise notice '  inicio efetivo : %', v_resultado->>'inicio_efetivo';
  raise notice '  fim pretendido : %', v_resultado->>'fim_pretendido';
  raise notice '  agendamentos afetados: %', v_afetados;
  raise notice '--------------------------------------------------------------';

  if v_afetados = 0 then
    raise notice 'Nenhum agendamento foi afetado (os horarios nao se cruzaram).';
    raise notice 'Isso pode ocorrer se o script rodar no fim do dia.';
  end if;

  -- 3) Encerra a sessao tecnica usada por este script.
  --    O uso continua EM_USO de proposito, para demonstrar a tela de retorno.
  perform public.fn_logout(v_token);
end $$;

-- =============================================================================
-- CONFERENCIA DO CENARIO
-- =============================================================================

-- O agendamento anterior continua existindo, agora marcado:
select a.status,
       f.nome                                                              as agendou,
       to_char(a.inicio_planejado at time zone public.fn_tz(), 'HH24:MI')  as inicio,
       to_char(a.fim_planejado    at time zone public.fn_tz(), 'HH24:MI')  as fim,
       a.motivo_status
  from public.agendamentos a
  join public.funcionarios f on f.id = a.funcionario_id
  join public.ptas p         on p.id = a.pta_id
 where p.codigo = 'PTA-003';

-- O vinculo entre o uso e o agendamento afetado (REGRA 18):
select af.status_anterior, af.status_novo, fc.nome as causado_por,
       to_char(af.criado_em at time zone public.fn_tz(), 'DD/MM/YYYY HH24:MI') as quando
  from public.agendamentos_afetados af
  join public.funcionarios fc on fc.id = af.causado_por;

-- A trilha de auditoria (REGRA 15):
select * from public.fn_auditoria(20, null);

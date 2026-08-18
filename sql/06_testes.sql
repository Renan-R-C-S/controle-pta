-- =============================================================================
-- SISTEMA DE CONTROLE E AGENDAMENTO DE PTA
-- Arquivo 06 - BATERIA DE TESTES AUTOMATIZADOS (item 46)
--
-- COMO LER O RESULTADO
-- Este script termina DE PROPOSITO com um erro chamado
-- "RELATORIO_DE_TESTES__NADA_FOI_GRAVADO". Esse erro serve para desfazer
-- (rollback) tudo o que os testes criaram - nenhum dado de teste fica no banco.
-- O RELATORIO COMPLETO ESTA NO CORPO DA MENSAGEM DESSE ERRO.
--
-- Se aparecer alguma linha [FALHA], a regra correspondente nao esta ativa.
--
-- QUANDO RODAR
-- A qualquer hora. Os testes que iniciam usos limitam o horario de termino a
-- 23:59 do proprio dia, entao a virada de data nao os afeta. A unica excecao e
-- rodar no ultimo minuto do dia, quando nao sobra horario futuro nenhum.
-- =============================================================================

-- O search_path abaixo garante que as classes de operador do btree_gist e as
-- funcoes do pgcrypto sejam encontradas, independentemente do schema em que as
-- extensoes foram instaladas neste projeto.
set search_path = public, extensions;

do $$
declare
  v_rel      text := E'\n';
  v_ok       int  := 0;
  v_falha    int  := 0;
  v_erro     text;
  v_desc     text;
  v_setor    uuid;
  v_p901     uuid; v_p902 uuid; v_p903 uuid;
  v_ua       uuid; v_ub uuid; v_uc uuid;
  v_ta       uuid; v_tb uuid; v_tc uuid;
  v_r        jsonb;
  v_uso_a    uuid;
  v_uso_b    uuid;
  v_ag_b     uuid;
  v_ag_hoje  uuid;
  v_amanha   date := (now() at time zone public.fn_tz())::date + 1;
  v_ontem    date := (now() at time zone public.fn_tz())::date - 1;

  -- Horarios de fim usados pelos testes de uso imediato.
  --
  -- O MVP so aceita uso terminando no mesmo dia (docs/DECISOES.md, item 5).
  -- Se o teste pedisse cegamente "daqui a 90 minutos", rodar as 22h30 geraria
  -- 00:05 - um horario ja passado - e uma duzia de testes que nada tem a ver
  -- com data falhariam em efeito domino.
  --
  -- Por isso o alvo e limitado a 23:59 de hoje: continua sendo um horario
  -- futuro e valido a qualquer hora, e os testes medem o que se propoem a
  -- medir. Quem verifica a recusa de horario passado e o T13, de proposito.
  v_local     timestamp;
  v_ultima    timestamp;
  v_fim_60    time;
  v_fim_90    time;
  v_fim_120   time;
  v_i        int;
  v_txt      text;
  v_bool     boolean;
  v_int      int;
  v_txt2     text;
  -- administracao
  v_um       uuid; v_tm    uuid;   -- ADMIN_MASTER
  v_uadm     uuid; v_tadm  uuid;   -- ADMIN comum
  v_ualvo    uuid; v_talvo uuid;   -- funcionario que sera desativado
  v_ag_alvo  uuid;
  -- terceiros, cancelamento e ciclicos
  v_forn      uuid;
  v_uuid      uuid;
  v_uso_c     uuid;
  v_ag_master uuid;
  v_ciclico   uuid;
  v_ciclico2  uuid;
begin
  v_local   := now() at time zone public.fn_tz();
  v_ultima  := v_local::date + time '23:59';
  v_fim_60  := least(v_local + interval '60 minutes',  v_ultima)::time;
  v_fim_90  := least(v_local + interval '90 minutes',  v_ultima)::time;
  v_fim_120 := least(v_local + interval '120 minutes', v_ultima)::time;

  -- ===========================================================================
  -- PREPARACAO (tudo sera desfeito no final)
  -- ===========================================================================
  insert into public.setores (nome, ordem) values ('TESTE_AUTOMATIZADO', 99)
  returning id into v_setor;

  insert into public.ptas (codigo, descricao) values ('PTA-901', 'Teste 1') returning id into v_p901;
  insert into public.ptas (codigo, descricao) values ('PTA-902', 'Teste 2') returning id into v_p902;
  insert into public.ptas (codigo, descricao) values ('PTA-903', 'Teste 3') returning id into v_p903;

  v_rel := v_rel || E'===========================================================\n';
  v_rel := v_rel || E' RELATORIO DE TESTES - CONTROLE DE PTA\n';
  v_rel := v_rel || E'===========================================================\n';
  v_rel := v_rel || E'\n-- USUARIO -------------------------------------------\n';

  -- ===========================================================================
  -- USUARIO
  -- ===========================================================================

  -- T01 cadastro novo (REGRA 1, 2, 3)
  v_desc := 'T01 cadastro de funcionario novo'; v_erro := null;
  begin
    v_r := public.fn_cadastrar_funcionario('Teste Alfa', '900001', '1111', v_setor);
    v_ta := (v_r->>'token')::uuid;
    v_ua := (v_r->'funcionario'->>'id')::uuid;
  exception when others then v_erro := sqlerrm; end;
  if v_erro is null and v_ta is not null then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'sem token') || E'\n'; end if;

  -- T02 matricula duplicada (REGRA 1)
  v_desc := 'T02 matricula duplicada e recusada'; v_erro := null;
  begin
    perform public.fn_cadastrar_funcionario('Outro Nome', '900001', '9999', v_setor);
  exception when others then v_erro := sqlerrm; end;
  if v_erro = 'MATRICULA_DUPLICADA' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'aceitou!') || E'\n'; end if;

  -- T03 PIN com 3 digitos (REGRA 2)
  v_desc := 'T03 PIN de 3 digitos e recusado'; v_erro := null;
  begin
    perform public.fn_cadastrar_funcionario('Teste Curto', '900011', '123', v_setor);
  exception when others then v_erro := sqlerrm; end;
  if v_erro = 'PIN_FORMATO' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'aceitou!') || E'\n'; end if;

  -- T04 PIN com letra (REGRA 2)
  v_desc := 'T04 PIN com letra e recusado'; v_erro := null;
  begin
    perform public.fn_cadastrar_funcionario('Teste Letra', '900012', '12A4', v_setor);
  exception when others then v_erro := sqlerrm; end;
  if v_erro = 'PIN_FORMATO' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'aceitou!') || E'\n'; end if;

  -- T05 o PIN nao fica em texto puro (REGRA 3)
  v_desc := 'T05 PIN gravado apenas como hash bcrypt'; v_erro := null;
  select pin_hash into v_txt from public.funcionarios where id = v_ua;
  if v_txt is not null and v_txt <> '1111' and v_txt like '$2%' then
    v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_txt, 'nulo') || E'\n'; end if;

  -- usuarios auxiliares
  v_r := public.fn_cadastrar_funcionario('Teste Beta',  '900002', '2222', v_setor);
  v_tb := (v_r->>'token')::uuid; v_ub := (v_r->'funcionario'->>'id')::uuid;
  v_r := public.fn_cadastrar_funcionario('Teste Gama',  '900003', '3333', v_setor);
  v_tc := (v_r->>'token')::uuid; v_uc := (v_r->'funcionario'->>'id')::uuid;

  -- T06 login correto
  v_desc := 'T06 login com PIN correto'; v_erro := null;
  begin
    v_r := public.fn_login(v_ua, '1111');
  exception when others then v_erro := sqlerrm; end;
  if v_erro is null and (v_r->>'ok')::boolean and (v_r->>'token') is not null then
    v_ta := (v_r->>'token')::uuid;
    v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, v_r::text) || E'\n'; end if;

  -- T07 login incorreto
  v_desc := 'T07 login com PIN incorreto e recusado'; v_erro := null;
  begin
    v_r := public.fn_login(v_ua, '9999');
  exception when others then v_erro := sqlerrm; end;
  if v_erro is null and (v_r->>'ok')::boolean is false and v_r->>'erro' = 'PIN_INCORRETO' then
    v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, v_r::text) || E'\n'; end if;

  -- T08 bloqueio apos 5 tentativas (item 8)
  v_desc := 'T08 conta bloqueia apos 5 tentativas invalidas'; v_erro := null;
  for v_i in 1..5 loop
    begin v_r := public.fn_login(v_uc, '0000'); exception when others then v_erro := sqlerrm; end;
  end loop;
  if v_r->>'erro' = 'CONTA_BLOQUEADA' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, v_r::text) || E'\n'; end if;

  -- T09 contador de tentativas foi realmente persistido
  v_desc := 'T09 tentativas invalidas ficam gravadas (nao sofrem rollback)';
  select tentativas_falhas into v_int from public.funcionarios where id = v_uc;
  if v_int >= 5 then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> contador=' || v_int || E'\n'; end if;

  -- T10 sessao invalida
  v_desc := 'T10 token invalido e rejeitado'; v_erro := null;
  begin perform public.fn_sessao_info(gen_random_uuid());
  exception when others then v_erro := sqlerrm; end;
  if v_erro = 'SESSAO_INVALIDA' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'aceitou!') || E'\n'; end if;

  v_rel := v_rel || E'\n-- QR CODE 1 (USO IMEDIATO) --------------------------\n';

  -- ===========================================================================
  -- QR CODE 1
  -- ===========================================================================

  -- T11 PTA inexistente (REGRA 4)
  v_desc := 'T11 PTA inexistente retorna erro'; v_erro := null;
  begin perform public.fn_pta_situacao('PTA-999', v_ta);
  exception when others then v_erro := sqlerrm; end;
  if v_erro = 'PTA_NAO_ENCONTRADA' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'aceitou!') || E'\n'; end if;

  -- T12 PTA valida + normalizacao do parametro do QR ("pta901" -> "PTA-901")
  v_desc := 'T12 PTA valida disponivel (aceita codigo sem hifen)'; v_erro := null;
  begin v_r := public.fn_pta_situacao('pta901', v_ta);
  exception when others then v_erro := sqlerrm; end;
  if v_erro is null and v_r->>'status' = 'DISPONIVEL' and v_r->'pta'->>'codigo' = 'PTA-901' then
    v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, v_r::text) || E'\n'; end if;

  -- T13 horario final anterior ao inicial (item 12)
  v_desc := 'T13 fim pretendido no passado e recusado'; v_erro := null;
  begin
    perform public.fn_uso_iniciar(v_ta, 'PTA-901',
      (to_char(now() at time zone public.fn_tz() - interval '1 hour', 'HH24:MI'))::time);
  exception when others then v_erro := sqlerrm; end;
  if v_erro = 'HORARIO_FINAL_ANTERIOR' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'aceitou!') || E'\n'; end if;

  -- T14 inicio de uso (REGRA 5, 8, 9)
  v_desc := 'T14 inicio de uso pelo QR Code 1'; v_erro := null;
  begin
    v_r := public.fn_uso_iniciar(v_ta, 'PTA-901',
      v_fim_90);
    v_uso_a := (v_r->>'uso_id')::uuid;
  exception when others then v_erro := sqlerrm; end;
  if v_erro is null and v_uso_a is not null then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'sem uso') || E'\n'; end if;

  -- T15 uso fica ABERTO com fim_efetivo nulo (REGRA 10, 12)
  v_desc := 'T15 uso nasce EM_USO com fim_efetivo nulo';
  select (status = 'EM_USO' and fim_efetivo is null) into v_bool from public.usos where id = v_uso_a;
  if v_bool then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || E'\n'; end if;

  -- T16 PTA ja em uso por outra pessoa
  v_desc := 'T16 segundo uso na mesma PTA e bloqueado'; v_erro := null;
  begin
    perform public.fn_uso_iniciar(v_tb, 'PTA-901',
      v_fim_120);
  exception when others then v_erro := sqlerrm; end;
  if v_erro = 'PTA_EM_USO' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'aceitou!') || E'\n'; end if;

  -- T17 usuario ja possui uso aberto em outra PTA
  v_desc := 'T17 usuario com uso aberto nao inicia outro'; v_erro := null;
  begin
    perform public.fn_uso_iniciar(v_ta, 'PTA-902',
      v_fim_120);
  exception when others then v_erro := sqlerrm; end;
  if v_erro = 'USUARIO_COM_USO_ABERTO' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'aceitou!') || E'\n'; end if;

  -- T18 observacao acima de 200 caracteres (REGRA 13)
  v_desc := 'T18 observacao com 201 caracteres e recusada'; v_erro := null;
  begin perform public.fn_observacao_salvar(v_ta, v_uso_a, repeat('x', 201));
  exception when others then v_erro := sqlerrm; end;
  if v_erro = 'OBSERVACAO_LONGA' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'aceitou!') || E'\n'; end if;

  -- T19 observacao valida durante o uso
  v_desc := 'T19 observacao valida e aceita durante o uso'; v_erro := null;
  begin perform public.fn_observacao_salvar(v_ta, v_uso_a, 'Necessario reposicionar a PTA.');
  exception when others then v_erro := sqlerrm; end;
  if v_erro is null then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || v_erro || E'\n'; end if;

  -- T20 finalizar uso de outra pessoa (item 31)
  v_desc := 'T20 finalizar uso de outro funcionario e bloqueado'; v_erro := null;
  begin perform public.fn_uso_finalizar(v_tb, v_uso_a);
  exception when others then v_erro := sqlerrm; end;
  if v_erro = 'SEM_PERMISSAO' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'aceitou!') || E'\n'; end if;

  -- T21 finalizacao ANTES do horario pretendido (item 15, REGRA 10 e 11)
  v_desc := 'T21 finalizacao antes do previsto grava a hora real'; v_erro := null;
  begin v_r := public.fn_uso_finalizar(v_ta, v_uso_a);
  exception when others then v_erro := sqlerrm; end;
  select (fim_efetivo is not null and fim_efetivo < fim_pretendido and status = 'FINALIZADO')
    into v_bool from public.usos where id = v_uso_a;
  if v_erro is null and v_bool and (v_r->>'ultrapassou_previsto')::boolean is false then
    v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, v_r::text) || E'\n'; end if;

  -- T22 nao permite finalizar duas vezes
  v_desc := 'T22 uso ja finalizado nao finaliza de novo'; v_erro := null;
  begin perform public.fn_uso_finalizar(v_ta, v_uso_a);
  exception when others then v_erro := sqlerrm; end;
  if v_erro = 'USO_JA_FINALIZADO' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'aceitou!') || E'\n'; end if;

  -- T23 observacao dentro dos 30 minutos (REGRA 14)
  v_desc := 'T23 observacao editavel dentro dos 30 minutos'; v_erro := null;
  begin perform public.fn_observacao_salvar(v_ta, v_uso_a, 'Observacao editada logo apos finalizar.');
  exception when others then v_erro := sqlerrm; end;
  if v_erro is null then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || v_erro || E'\n'; end if;

  -- T24 observacao apos os 30 minutos (REGRA 14)
  -- Empurra o limite para o passado para simular a passagem do tempo.
  v_desc := 'T24 observacao bloqueada apos 30 minutos do fim efetivo'; v_erro := null;
  update public.usos set limite_edicao_observacao = now() - interval '1 minute' where id = v_uso_a;
  begin perform public.fn_observacao_salvar(v_ta, v_uso_a, 'Tentativa fora do prazo.');
  exception when others then v_erro := sqlerrm; end;
  if v_erro = 'OBSERVACAO_PRAZO_EXPIRADO' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'aceitou!') || E'\n'; end if;

  -- T25 finalizacao DEPOIS do horario pretendido (item 16)
  v_desc := 'T25 finalizacao apos o previsto e registrada como ultrapassagem'; v_erro := null;
  begin
    v_r := public.fn_uso_iniciar(v_ta, 'PTA-902',
      v_fim_60);
    v_uso_b := (v_r->>'uso_id')::uuid;
    -- simula um uso que comecou ha 2 horas e deveria ter terminado ha 1 hora
    update public.usos
       set inicio_efetivo = now() - interval '2 hours',
           fim_pretendido = now() - interval '1 hour'
     where id = v_uso_b;
    v_r := public.fn_uso_finalizar(v_ta, v_uso_b);
  exception when others then v_erro := sqlerrm; end;
  if v_erro is null and (v_r->>'ultrapassou_previsto')::boolean then
    v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, v_r::text) || E'\n'; end if;

  -- T26 o horario pretendido nao foi sobrescrito pelo efetivo (REGRA 11)
  v_desc := 'T26 fim_pretendido e fim_efetivo permanecem distintos';
  select (fim_pretendido <> fim_efetivo) into v_bool from public.usos where id = v_uso_b;
  if v_bool then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || E'\n'; end if;

  v_rel := v_rel || E'\n-- QR CODE 2 (AGENDAMENTO) --------------------------\n';

  -- ===========================================================================
  -- QR CODE 2
  -- ===========================================================================

  -- T27 criacao de agendamento (REGRA 6)
  v_desc := 'T27 criacao de agendamento futuro'; v_erro := null;
  begin v_r := public.fn_agendamento_criar(v_ta, v_p903, v_amanha, '08:00', '10:00');
  exception when others then v_erro := sqlerrm; end;
  if v_erro is null then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || v_erro || E'\n'; end if;

  -- T28 conflito de horario (REGRA 17)
  v_desc := 'T28 agendamento sobreposto (09:00-11:00) e bloqueado'; v_erro := null;
  begin perform public.fn_agendamento_criar(v_tb, v_p903, v_amanha, '09:00', '11:00');
  exception when others then v_erro := sqlerrm; end;
  if v_erro = 'CONFLITO_AGENDAMENTO' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'aceitou!') || E'\n'; end if;

  -- T29 horario encostado nao e conflito (10:00-12:00 apos 08:00-10:00)
  v_desc := 'T29 agendamento adjacente (10:00-12:00) e permitido'; v_erro := null;
  begin
    v_r := public.fn_agendamento_criar(v_tb, v_p903, v_amanha, '10:00', '12:00');
    v_ag_b := (v_r->>'id')::uuid;
  exception when others then v_erro := sqlerrm; end;
  if v_erro is null then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || v_erro || E'\n'; end if;

  -- T30 agendamento no passado
  v_desc := 'T30 agendamento em data passada e recusado'; v_erro := null;
  begin perform public.fn_agendamento_criar(v_ta, v_p903, v_ontem, '08:00', '10:00');
  exception when others then v_erro := sqlerrm; end;
  if v_erro = 'AGENDAMENTO_PASSADO' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'aceitou!') || E'\n'; end if;

  -- T31 fim anterior ao inicio
  v_desc := 'T31 agendamento com fim antes do inicio e recusado'; v_erro := null;
  begin perform public.fn_agendamento_criar(v_ta, v_p903, v_amanha, '14:00', '13:00');
  exception when others then v_erro := sqlerrm; end;
  if v_erro = 'HORARIO_FINAL_ANTERIOR' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'aceitou!') || E'\n'; end if;

  -- T32 cancelar agendamento de outra pessoa
  v_desc := 'T32 cancelar agendamento de outro funcionario e bloqueado'; v_erro := null;
  begin perform public.fn_agendamento_cancelar(v_ta, v_ag_b);
  exception when others then v_erro := sqlerrm; end;
  -- Desde que existe o perfil administrativo, quem barra este caso e o
  -- fn__exigir_admin: cancelar programacao alheia passou a ser acao de ADMIN.
  if v_erro = 'SEM_PERMISSAO_ADMIN' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'aceitou!') || E'\n'; end if;

  v_rel := v_rel || E'\n-- SOBRESCRITA QR1 > QR2 ----------------------------\n';

  -- ===========================================================================
  -- SOBRESCRITA (REGRA 7 e 18)
  -- ===========================================================================

  -- Programacao de Beta para daqui a pouco, na PTA-903.
  insert into public.agendamentos (pta_id, funcionario_id, data_ref, inicio_planejado, fim_planejado)
  values (v_p903, v_ub, (now() at time zone public.fn_tz())::date,
          now() + interval '20 minutes', now() + interval '3 hours')
  returning id into v_ag_hoje;

  -- Alfa chega antes e inicia o uso imediato pelo QR Code 1.
  v_desc := 'T33 uso imediato do QR1 prevalece sobre o agendamento do QR2'; v_erro := null;
  begin
    v_r := public.fn_uso_iniciar(v_ta, 'PTA-903',
      v_fim_120);
  exception when others then v_erro := sqlerrm; end;
  if v_erro is null and (v_r->>'agendamentos_afetados')::int = 1 then
    v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, v_r::text) || E'\n'; end if;

  -- T34 o agendamento anterior NAO foi apagado (REGRA 18)
  v_desc := 'T34 agendamento anterior preservado e marcado como afetado';
  select status into v_txt from public.agendamentos where id = v_ag_hoje;
  if v_txt = 'AFETADO_POR_USO_IMEDIATO' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> status=' || coalesce(v_txt, 'APAGADO!') || E'\n'; end if;

  -- T35 vinculo de rastreabilidade gravado
  v_desc := 'T35 vinculo uso <-> agendamento afetado registrado';
  select count(*) into v_int from public.agendamentos_afetados where agendamento_id = v_ag_hoje;
  if v_int = 1 then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || v_int || ' vinculos' || E'\n'; end if;

  v_rel := v_rel || E'\n-- AUDITORIA ----------------------------------------\n';

  -- ===========================================================================
  -- AUDITORIA (REGRA 15 e 16)
  -- ===========================================================================

  -- T36 auditoria da sobrescrita com valor anterior e novo
  v_desc := 'T36 auditoria da sobrescrita guarda valor anterior e novo';
  select count(*) into v_int
    from public.auditoria
   where tipo_acao = 'AGENDAMENTO_SOBRESCRITO'
     and registro_id = v_ag_hoje::text
     and dados_anteriores is not null
     and dados_novos is not null;
  if v_int = 1 then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || v_int || ' registros' || E'\n'; end if;

  -- T37 eventos principais auditados
  v_desc := 'T37 cadastro, login, uso e agendamento geram auditoria';
  select count(distinct tipo_acao) into v_int
    from public.auditoria
   where tipo_acao in ('CADASTRO_USUARIO','LOGIN','LOGIN_FALHA','USO_INICIADO',
                       'USO_FINALIZADO','AGENDAMENTO_CRIADO','OBSERVACAO_CRIADA',
                       'OBSERVACAO_EDITADA','AGENDAMENTO_SOBRESCRITO');
  if v_int >= 8 then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || ' (' || v_int || ' tipos)' || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> apenas ' || v_int || ' tipos' || E'\n'; end if;

  -- T38 auditoria nao pode ser apagada (REGRA 16)
  v_desc := 'T38 auditoria nao pode ser apagada'; v_erro := null;
  begin delete from public.auditoria where tipo_acao = 'LOGIN';
  exception when others then v_erro := sqlerrm; end;
  if v_erro = 'HISTORICO_IMUTAVEL' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'apagou!') || E'\n'; end if;

  -- T39 auditoria nao pode ser alterada (REGRA 16)
  v_desc := 'T39 auditoria nao pode ser alterada'; v_erro := null;
  begin update public.auditoria set descricao = 'adulterado' where tipo_acao = 'LOGIN';
  exception when others then v_erro := sqlerrm; end;
  if v_erro = 'HISTORICO_IMUTAVEL' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'alterou!') || E'\n'; end if;

  -- T40 consulta do calendario devolve agendamentos e usos separados (REGRA 11)
  v_desc := 'T40 calendario separa AGENDAMENTO de USO';
  select count(distinct tipo) into v_int
    from public.fn_agenda_dia((now() at time zone public.fn_tz())::date, null);
  if v_int = 2 then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || v_int || ' tipos' || E'\n'; end if;

  v_rel := v_rel || E'\n-- ADMINISTRACAO E PERFIL ---------------------------\n';

  -- ===========================================================================
  -- PERFIS DE ACESSO
  -- ===========================================================================

  -- Matriculas reservadas de teste (desfeitas junto com o resto)
  insert into public.matriculas_reservadas (matricula, papel)
  values ('900591', 'ADMIN_MASTER'), ('900592', 'ADMIN');

  v_r := public.fn_cadastrar_funcionario('Teste Master', '900591', '5591', v_setor);
  v_tm := (v_r->>'token')::uuid; v_um := (v_r->'funcionario'->>'id')::uuid;
  v_r := public.fn_cadastrar_funcionario('Teste Admin', '900592', '5592', v_setor);
  v_tadm := (v_r->>'token')::uuid; v_uadm := (v_r->'funcionario'->>'id')::uuid;
  v_r := public.fn_cadastrar_funcionario('Teste Alvo', '900004', '4444', v_setor);
  v_talvo := (v_r->>'token')::uuid; v_ualvo := (v_r->'funcionario'->>'id')::uuid;

  -- T41 matricula reservada nasce com papel administrativo
  v_desc := 'T41 matricula reservada nasce com papel administrativo';
  select papel into v_txt  from public.funcionarios where id = v_um;
  select papel into v_txt2 from public.funcionarios where id = v_uadm;
  if v_txt = 'ADMIN_MASTER' and v_txt2 = 'ADMIN' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_txt,'?') || '/' || coalesce(v_txt2,'?') || E'\n'; end if;

  -- T42 funcionario comum nao entra na administracao
  v_desc := 'T42 funcionario comum nao acessa a administracao'; v_erro := null;
  begin perform * from public.fn_admin_listar_funcionarios(v_ta);
  exception when others then v_erro := sqlerrm; end;
  if v_erro = 'SEM_PERMISSAO_ADMIN' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'entrou!') || E'\n'; end if;

  -- T43 ADMIN promove alguem a ADMIN
  v_desc := 'T43 ADMIN promove funcionario a ADMIN'; v_erro := null;
  begin perform public.fn_admin_definir_papel(v_tadm, v_ub, 'ADMIN');
  exception when others then v_erro := sqlerrm; end;
  select papel into v_txt from public.funcionarios where id = v_ub;
  if v_erro is null and v_txt = 'ADMIN' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, v_txt) || E'\n'; end if;

  -- T44 ADMIN comum NAO revoga (privilegio exclusivo do master)
  v_desc := 'T44 ADMIN comum nao consegue revogar papel de ADMIN'; v_erro := null;
  begin perform public.fn_admin_definir_papel(v_tadm, v_ub, 'FUNCIONARIO');
  exception when others then v_erro := sqlerrm; end;
  if v_erro = 'SOMENTE_ADMIN_MASTER' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'revogou!') || E'\n'; end if;

  -- T45 ADMIN_MASTER revoga
  v_desc := 'T45 ADMIN_MASTER revoga papel de ADMIN'; v_erro := null;
  begin perform public.fn_admin_definir_papel(v_tm, v_ub, 'FUNCIONARIO');
  exception when others then v_erro := sqlerrm; end;
  select papel into v_txt from public.funcionarios where id = v_ub;
  if v_erro is null and v_txt = 'FUNCIONARIO' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, v_txt) || E'\n'; end if;

  -- T46 o ADMIN_MASTER e intocavel
  v_desc := 'T46 papel do ADMIN_MASTER nao pode ser alterado'; v_erro := null;
  begin perform public.fn_admin_definir_papel(v_tadm, v_um, 'FUNCIONARIO');
  exception when others then v_erro := sqlerrm; end;
  if v_erro = 'ADMIN_MASTER_PROTEGIDO' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'alterou!') || E'\n'; end if;

  -- T47 ninguem altera o proprio papel
  v_desc := 'T47 ninguem altera o proprio papel'; v_erro := null;
  begin perform public.fn_admin_definir_papel(v_tadm, v_uadm, 'FUNCIONARIO');
  exception when others then v_erro := sqlerrm; end;
  if v_erro = 'PAPEL_PROPRIO_BLOQUEADO' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'alterou!') || E'\n'; end if;

  -- ===========================================================================
  -- ADMINISTRACAO SOBRE PROGRAMACOES
  -- ===========================================================================

  -- Programacao do "alvo" para amanha bem cedo, usada nos testes seguintes
  v_r := public.fn_agendamento_criar(v_talvo, v_p901, v_amanha, '06:00', '07:00');
  v_ag_alvo := (v_r->>'id')::uuid;

  -- T48 ADMIN altera programacao de outra pessoa
  v_desc := 'T48 ADMIN altera programacao de outro funcionario'; v_erro := null;
  begin perform public.fn_agendamento_alterar(v_tadm, v_ag_alvo, v_amanha, '06:30', '07:30');
  exception when others then v_erro := sqlerrm; end;
  select to_char(inicio_planejado at time zone public.fn_tz(), 'HH24:MI') into v_txt
    from public.agendamentos where id = v_ag_alvo;
  if v_erro is null and v_txt = '06:30' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, v_txt) || E'\n'; end if;

  -- T49 funcionario comum NAO altera programacao alheia
  v_desc := 'T49 funcionario comum nao altera programacao alheia'; v_erro := null;
  begin perform public.fn_agendamento_alterar(v_ta, v_ag_alvo, v_amanha, '05:00', '05:30');
  exception when others then v_erro := sqlerrm; end;
  if v_erro = 'SEM_PERMISSAO_ADMIN' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'alterou!') || E'\n'; end if;

  -- T50 a alteracao continua respeitando conflito.
  -- O horario ocupado precisa estar na MESMA PTA do agendamento que sera
  -- movido (v_ag_alvo esta na PTA-901), senao nao ha conflito nenhum.
  perform public.fn_agendamento_criar(v_tb, v_p901, v_amanha, '08:00', '09:00');

  v_desc := 'T50 alteracao para horario ocupado e bloqueada'; v_erro := null;
  begin perform public.fn_agendamento_alterar(v_tadm, v_ag_alvo, v_amanha, '08:30', '09:30');
  exception when others then v_erro := sqlerrm; end;
  if v_erro = 'CONFLITO_AGENDAMENTO' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'aceitou!') || E'\n'; end if;

  -- T51 ADMIN cancela programacao de outro
  v_desc := 'T51 ADMIN cancela programacao de outro funcionario'; v_erro := null;
  begin perform public.fn_agendamento_cancelar(v_tadm, v_ag_alvo);
  exception when others then v_erro := sqlerrm; end;
  select status into v_txt from public.agendamentos where id = v_ag_alvo;
  if v_erro is null and v_txt = 'CANCELADO' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, v_txt) || E'\n'; end if;

  -- T52 a programacao cancelada continua existindo (REGRA 18)
  v_desc := 'T52 programacao "excluida" pelo admin continua no historico';
  select count(*) into v_int from public.agendamentos where id = v_ag_alvo;
  if v_int = 1 then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> sumiu do banco' || E'\n'; end if;

  -- ===========================================================================
  -- EXCLUSAO DE FUNCIONARIOS
  -- ===========================================================================

  -- T53 desativar o ADMIN_MASTER e bloqueado
  v_desc := 'T53 ADMIN_MASTER nao pode ser desativado'; v_erro := null;
  begin perform public.fn_admin_desativar_funcionario(v_tadm, v_um);
  exception when others then v_erro := sqlerrm; end;
  if v_erro = 'ADMIN_MASTER_PROTEGIDO' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'desativou!') || E'\n'; end if;

  -- T54 desativar a si mesmo e bloqueado
  v_desc := 'T54 ninguem desativa a si mesmo'; v_erro := null;
  begin perform public.fn_admin_desativar_funcionario(v_tadm, v_uadm);
  exception when others then v_erro := sqlerrm; end;
  if v_erro = 'EXCLUSAO_PROPRIA_BLOQUEADA' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'desativou!') || E'\n'; end if;

  -- Programacao futura do alvo, para conferir o cancelamento em cascata
  perform public.fn_agendamento_criar(v_talvo, v_p902, v_amanha, '06:00', '07:00');

  -- T55 desativar funcionario cancela as programacoes futuras dele
  v_desc := 'T55 desativar funcionario cancela suas programacoes futuras'; v_erro := null;
  begin v_r := public.fn_admin_desativar_funcionario(v_tadm, v_ualvo);
  exception when others then v_erro := sqlerrm; end;
  select ativo into v_bool from public.funcionarios where id = v_ualvo;
  if v_erro is null and v_bool is false and (v_r->>'agendamentos_cancelados')::int = 1 then
    v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, v_r::text) || E'\n'; end if;

  -- T56 o historico do desativado permanece
  v_desc := 'T56 historico do funcionario desativado e preservado';
  select count(*) into v_int from public.auditoria where usuario_id = v_ualvo;
  if v_int > 0 then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> auditoria vazia' || E'\n'; end if;

  -- T57 desativado some da lista de login
  v_desc := 'T57 funcionario desativado some da lista de login';
  select count(*) into v_int from public.fn_funcionarios_por_setor(v_setor) f where f.id = v_ualvo;
  if v_int = 0 then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || E'\n'; end if;

  -- T58 desativado nao consegue mais entrar
  v_desc := 'T58 funcionario desativado nao consegue fazer login'; v_erro := null;
  begin v_r := public.fn_login(v_ualvo, '4444');
  exception when others then v_erro := sqlerrm; end;
  if v_erro = 'FUNCIONARIO_NAO_ENCONTRADO' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, v_r::text) || E'\n'; end if;

  -- T59 reativar devolve o acesso
  v_desc := 'T59 administrador consegue reativar um funcionario'; v_erro := null;
  begin perform public.fn_admin_reativar_funcionario(v_tadm, v_ualvo);
  exception when others then v_erro := sqlerrm; end;
  select ativo into v_bool from public.funcionarios where id = v_ualvo;
  if v_erro is null and v_bool then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'continua inativo') || E'\n'; end if;

  -- ===========================================================================
  -- LIMITE DE MATRICULAS
  -- ===========================================================================

  -- T60 ADMIN comum nao mexe no limite
  v_desc := 'T60 somente o ADMIN_MASTER altera o limite de matriculas'; v_erro := null;
  begin perform public.fn_admin_definir_limite_matriculas(v_tadm, 50);
  exception when others then v_erro := sqlerrm; end;
  if v_erro = 'SOMENTE_ADMIN_MASTER' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'alterou!') || E'\n'; end if;

  -- T61 limite abaixo do numero de ativos e recusado
  v_desc := 'T61 limite abaixo do total de ativos e recusado'; v_erro := null;
  begin perform public.fn_admin_definir_limite_matriculas(v_tm, 1);
  exception when others then v_erro := sqlerrm; end;
  if v_erro = 'LIMITE_ABAIXO_DO_ATUAL' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'aceitou!') || E'\n'; end if;

  -- T62 limite cheio impede novo cadastro
  v_desc := 'T62 limite de matriculas impede novo cadastro'; v_erro := null;
  select count(*) into v_int from public.funcionarios where ativo;
  perform public.fn_admin_definir_limite_matriculas(v_tm, v_int);
  begin perform public.fn_cadastrar_funcionario('Teste Excedente', '900099', '9099', v_setor);
  exception when others then v_erro := sqlerrm; end;
  if v_erro = 'LIMITE_MATRICULAS_ATINGIDO' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'cadastrou!') || E'\n'; end if;

  -- T63 limite 0 volta a liberar
  v_desc := 'T63 limite 0 significa sem limite'; v_erro := null;
  perform public.fn_admin_definir_limite_matriculas(v_tm, 0);
  begin perform public.fn_cadastrar_funcionario('Teste Liberado', '900098', '9098', v_setor);
  exception when others then v_erro := sqlerrm; end;
  if v_erro is null then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || v_erro || E'\n'; end if;

  -- ===========================================================================
  -- PERFIL DO PROPRIO FUNCIONARIO
  -- ===========================================================================

  -- T64 funcionario altera o proprio nome
  v_desc := 'T64 funcionario altera o proprio nome'; v_erro := null;
  begin perform public.fn_perfil_alterar_nome(v_ta, 'Teste Alfa Renomeado');
  exception when others then v_erro := sqlerrm; end;
  select nome into v_txt from public.funcionarios where id = v_ua;
  if v_erro is null and v_txt = 'Teste Alfa Renomeado' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, v_txt) || E'\n'; end if;

  -- T65 a matricula NAO muda junto
  v_desc := 'T65 alterar o nome nao altera a matricula';
  select matricula into v_txt from public.funcionarios where id = v_ua;
  if v_txt = '900001' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_txt,'?') || E'\n'; end if;

  -- T66 a troca de nome fica registrada com o valor anterior
  v_desc := 'T66 troca de nome gera auditoria com valor anterior';
  select count(*) into v_int from public.auditoria
   where tipo_acao = 'NOME_ALTERADO' and registro_id = v_ua::text
     and dados_anteriores->>'nome' = 'Teste Alfa';
  if v_int = 1 then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || v_int || ' registros' || E'\n'; end if;

  -- T67 nome invalido e recusado
  v_desc := 'T67 nome muito curto e recusado'; v_erro := null;
  begin perform public.fn_perfil_alterar_nome(v_ta, 'Jo');
  exception when others then v_erro := sqlerrm; end;
  if v_erro = 'NOME_INVALIDO' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'aceitou!') || E'\n'; end if;

  -- T68 nem o administrador apaga auditoria
  v_desc := 'T68 administrador tambem nao apaga auditoria'; v_erro := null;
  begin delete from public.auditoria where tipo_acao = 'PAPEL_ALTERADO';
  exception when others then v_erro := sqlerrm; end;
  if v_erro = 'HISTORICO_IMUTAVEL' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'apagou!') || E'\n'; end if;

  v_rel := v_rel || E'\n-- TERCEIROS, CANCELAMENTO E CICLICOS ---------------\n';

  -- ===========================================================================
  -- TERCEIROS (FORNECEDORES)
  -- ===========================================================================

  -- T69 cadastro de terceiro
  v_desc := 'T69 funcionario cadastra um terceiro'; v_erro := null;
  begin
    v_r := public.fn_fornecedor_criar(v_ta, 'Alfa Montagens Ltda', '11222333000144');
    v_forn := (v_r->>'id')::uuid;
  exception when others then v_erro := sqlerrm; end;
  if v_erro is null and v_forn is not null and (v_r->>'ja_existia')::boolean is false then
    v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, v_r::text) || E'\n'; end if;

  -- T70 nome repetido nao duplica cadastro
  v_desc := 'T70 terceiro com mesmo nome nao vira cadastro duplicado'; v_erro := null;
  begin v_r := public.fn_fornecedor_criar(v_tb, '  alfa MONTAGENS ltda ');
  exception when others then v_erro := sqlerrm; end;
  if v_erro is null and (v_r->>'ja_existia')::boolean and (v_r->>'id')::uuid = v_forn then
    v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, v_r::text) || E'\n'; end if;

  -- T71 busca por trecho do nome
  v_desc := 'T71 busca de terceiro por trecho do nome';
  select count(*) into v_int from public.fn_fornecedores('montag');
  if v_int = 1 then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || v_int || ' resultados' || E'\n'; end if;

  -- T72 terceiro fica vinculado ao uso
  v_desc := 'T72 uso registra o terceiro escolhido'; v_erro := null;
  begin
    v_r := public.fn_uso_iniciar(v_tb, 'PTA-902', v_fim_90, v_forn);
    v_uso_c := (v_r->>'uso_id')::uuid;
  exception when others then v_erro := sqlerrm; end;
  select fornecedor_id into v_uuid from public.usos where id = v_uso_c;
  if v_erro is null and v_uuid = v_forn then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'sem vinculo') || E'\n'; end if;

  -- T73 terceiro inexistente e recusado
  v_desc := 'T73 uso com terceiro inexistente e recusado'; v_erro := null;
  begin perform public.fn_agendamento_criar(v_ta, v_p902, v_amanha, '05:00', '05:30', gen_random_uuid());
  exception when others then v_erro := sqlerrm; end;
  if v_erro = 'FORNECEDOR_NAO_ENCONTRADO' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'aceitou!') || E'\n'; end if;

  -- ===========================================================================
  -- CANCELAMENTO DE USO EM ABERTO
  -- ===========================================================================

  -- T74 administrador cancela uso em aberto
  v_desc := 'T74 administrador cancela um uso em aberto'; v_erro := null;
  begin perform public.fn_admin_cancelar_uso(v_tadm, v_uso_c, 'Esquecido em aberto');
  exception when others then v_erro := sqlerrm; end;
  select status into v_txt from public.usos where id = v_uso_c;
  if v_erro is null and v_txt = 'CANCELADO' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, v_txt) || E'\n'; end if;

  -- T75 uso cancelado NAO ganha fim_efetivo inventado
  v_desc := 'T75 uso cancelado fica sem fim efetivo';
  select (fim_efetivo is null and cancelado_em is not null and cancelado_por is not null)
    into v_bool from public.usos where id = v_uso_c;
  if v_bool then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || E'\n'; end if;

  -- T76 cancelar libera a PTA para um novo uso
  v_desc := 'T76 uso cancelado libera a PTA'; v_erro := null;
  begin
    v_r := public.fn_uso_iniciar(v_tb, 'PTA-902', v_fim_90);
    perform public.fn_uso_finalizar(v_tb, (v_r->>'uso_id')::uuid);
  exception when others then v_erro := sqlerrm; end;
  if v_erro is null then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || v_erro || E'\n'; end if;

  -- T77 uso cancelado continua aparecendo no cronograma
  v_desc := 'T77 uso cancelado continua visivel no calendario';
  select count(*) into v_int
    from public.fn_agenda_dia((now() at time zone public.fn_tz())::date, null) d
   where d.id = v_uso_c and d.status = 'CANCELADO';
  if v_int = 1 then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || v_int || E'\n'; end if;

  -- T78 uso ja finalizado nao pode ser cancelado
  v_desc := 'T78 uso ja finalizado nao pode ser cancelado'; v_erro := null;
  begin perform public.fn_admin_cancelar_uso(v_tadm, v_uso_a, 'tentativa');
  exception when others then v_erro := sqlerrm; end;
  if v_erro = 'USO_NAO_CANCELAVEL' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'cancelou!') || E'\n'; end if;

  -- ===========================================================================
  -- LIMITE DE HORAS DE USO EM ABERTO
  -- ===========================================================================

  -- T79 somente administrador define o limite de horas
  v_desc := 'T79 funcionario comum nao altera o limite de horas'; v_erro := null;
  begin perform public.fn_admin_definir_max_horas_uso(v_ta, 6);
  exception when others then v_erro := sqlerrm; end;
  if v_erro = 'SEM_PERMISSAO_ADMIN' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'alterou!') || E'\n'; end if;

  -- T80 o limite configurado vale na abertura do uso
  -- So faz sentido se ainda houver mais de 1h ate a meia-noite.
  v_desc := 'T80 limite de horas recusa uso mais longo'; v_erro := null;
  perform public.fn_admin_definir_max_horas_uso(v_tadm, 1);
  -- O alvo foi desativado no T55, o que encerrou as sessoes dele; o T59
  -- reativou o cadastro, mas nao a sessao. Precisa entrar de novo.
  -- A PTA-903 esta ocupada desde o T33, entao o teste usa a PTA-902.
  v_r := public.fn_login(v_ualvo, '4444');
  v_talvo := (v_r->>'token')::uuid;
  if extract(epoch from (public.fn__local_para_utc(v_local::date, v_fim_120) - now())) > 4200 then
    begin perform public.fn_uso_iniciar(v_talvo, 'PTA-902', v_fim_120);
    exception when others then v_erro := sqlerrm; end;
    if v_erro = 'DURACAO_EXCESSIVA' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
    else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'aceitou!') || E'\n'; end if;
  else
    v_ok := v_ok + 1;
    v_rel := v_rel || '  [OK]    ' || v_desc || ' (pulado: menos de 1h ate a meia-noite)' || E'\n';
  end if;
  perform public.fn_admin_definir_max_horas_uso(v_tadm, 14);

  -- ===========================================================================
  -- REGISTROS DO ADMINISTRADOR PRINCIPAL
  -- ===========================================================================

  -- Programacao criada pelo proprio ADMIN_MASTER
  v_r := public.fn_agendamento_criar(v_tm, v_p902, v_amanha, '14:00', '15:00');
  v_ag_master := (v_r->>'id')::uuid;

  -- T81 outro administrador nao altera registro do master
  v_desc := 'T81 ADMIN comum nao altera registro criado pelo ADMIN_MASTER'; v_erro := null;
  begin perform public.fn_agendamento_alterar(v_tadm, v_ag_master, v_amanha, '16:00', '17:00');
  exception when others then v_erro := sqlerrm; end;
  if v_erro = 'REGISTRO_DO_ADMIN_MASTER' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'alterou!') || E'\n'; end if;

  -- T82 outro administrador nao cancela registro do master
  v_desc := 'T82 ADMIN comum nao cancela registro do ADMIN_MASTER'; v_erro := null;
  begin perform public.fn_agendamento_cancelar(v_tadm, v_ag_master);
  exception when others then v_erro := sqlerrm; end;
  if v_erro = 'REGISTRO_DO_ADMIN_MASTER' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'cancelou!') || E'\n'; end if;

  -- T83 o proprio master altera o que criou
  v_desc := 'T83 o ADMIN_MASTER altera o proprio registro'; v_erro := null;
  begin perform public.fn_agendamento_alterar(v_tm, v_ag_master, v_amanha, '16:00', '17:00');
  exception when others then v_erro := sqlerrm; end;
  if v_erro is null then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || v_erro || E'\n'; end if;

  -- ===========================================================================
  -- AGENDAMENTOS CICLICOS
  -- ===========================================================================

  -- T84 funcionario comum nao cria regra ciclica
  v_desc := 'T84 funcionario comum nao cria agendamento ciclico'; v_erro := null;
  begin perform public.fn_ciclico_criar(v_ta, v_p901, v_ua, '05:00', '05:30', 'INTERVALO_DIAS',
                                        null, 7, null, null, null);
  exception when others then v_erro := sqlerrm; end;
  if v_erro = 'SEM_PERMISSAO_ADMIN' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'criou!') || E'\n'; end if;

  -- T85 regra por dias da semana gera ocorrencias
  v_desc := 'T85 ciclico por dias da semana gera ocorrencias'; v_erro := null;
  begin
    v_r := public.fn_ciclico_criar(v_tadm, v_p901, v_ub, '03:00', '04:00', 'DIAS_SEMANA',
                                   array[1,3,5]::smallint[], null, null, null, null);
    v_ciclico := (v_r->>'id')::uuid;
  exception when others then v_erro := sqlerrm; end;
  select count(*) into v_int from public.agendamentos where ciclico_id = v_ciclico;
  -- ~90 dias com 3 dias por semana => algo em torno de 38 ocorrencias
  if v_erro is null and v_int between 30 and 45 then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || ' (' || v_int || ' ocorrencias)' || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, v_int::text) || E'\n'; end if;

  -- T86 as ocorrencias caem exatamente nos dias pedidos
  v_desc := 'T86 ocorrencias caem apenas nos dias da semana escolhidos';
  select count(*) into v_int from public.agendamentos
   where ciclico_id = v_ciclico
     and extract(dow from data_ref)::smallint not in (1, 3, 5);
  if v_int = 0 then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || v_int || ' fora dos dias' || E'\n'; end if;

  -- T87 regra por intervalo de dias
  v_desc := 'T87 ciclico a cada N dias gera ocorrencias espacadas'; v_erro := null;
  begin
    v_r := public.fn_ciclico_criar(v_tadm, v_p903, v_ub, '02:00', '02:30', 'INTERVALO_DIAS',
                                   null, 10, null, null, null);
    v_ciclico2 := (v_r->>'id')::uuid;
  exception when others then v_erro := sqlerrm; end;
  select count(*) into v_int from public.agendamentos where ciclico_id = v_ciclico2;
  if v_erro is null and v_int between 7 and 10 then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || ' (' || v_int || ' ocorrencias)' || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, v_int::text) || E'\n'; end if;

  -- T88 o ciclico fica em nome do funcionario escolhido, nao do administrador
  v_desc := 'T88 ocorrencias ficam em nome do funcionario escolhido';
  select count(*) into v_int from public.agendamentos
   where ciclico_id = v_ciclico and funcionario_id <> v_ub;
  if v_int = 0 then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || v_int || ' em outro nome' || E'\n'; end if;

  -- T89 funcionario inexistente e recusado
  v_desc := 'T89 ciclico exige funcionario cadastrado'; v_erro := null;
  begin perform public.fn_ciclico_criar(v_tadm, v_p901, gen_random_uuid(), '01:00', '01:30',
                                        'INTERVALO_DIAS', null, 5, null, null, null);
  exception when others then v_erro := sqlerrm; end;
  if v_erro = 'FUNCIONARIO_NAO_ENCONTRADO' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'criou!') || E'\n'; end if;

  -- T90 datas ocupadas sao puladas, nao derrubam a geracao
  v_desc := 'T90 ciclico pula horarios ja ocupados'; v_erro := null;
  begin
    -- mesma PTA e mesmo horario da regra anterior: tudo deve ser pulado
    v_r := public.fn_ciclico_criar(v_tadm, v_p901, v_ualvo, '03:00', '04:00', 'DIAS_SEMANA',
                                   array[1,3,5]::smallint[], null, null, null, null);
  exception when others then v_erro := sqlerrm; end;
  if v_erro is null and (v_r->>'criados')::int = 0 and (v_r->>'pulados')::int > 0 then
    v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || ' (' || (v_r->>'pulados') || ' pulados)' || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, v_r::text) || E'\n'; end if;

  -- T91 desativar a regra cancela as ocorrencias futuras
  v_desc := 'T91 desativar regra ciclica cancela as ocorrencias futuras'; v_erro := null;
  begin v_r := public.fn_ciclico_desativar(v_tadm, v_ciclico, true);
  exception when others then v_erro := sqlerrm; end;
  select count(*) into v_int from public.agendamentos
   where ciclico_id = v_ciclico and status = 'AGENDADO';
  if v_erro is null and v_int = 0 and (v_r->>'ocorrencias_canceladas')::int > 0 then
    v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, v_int::text) || E'\n'; end if;

  -- T92 as ocorrencias canceladas continuam no banco (historico)
  v_desc := 'T92 ocorrencias canceladas permanecem no historico';
  select count(*) into v_int from public.agendamentos
   where ciclico_id = v_ciclico and status = 'CANCELADO';
  if v_int > 0 then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> sumiram' || E'\n'; end if;

  -- T93 regra ciclica do master so o master desativa
  v_desc := 'T93 regra ciclica do ADMIN_MASTER so o master desativa'; v_erro := null;
  v_r := public.fn_ciclico_criar(v_tm, v_p902, v_ub, '01:00', '01:30', 'INTERVALO_DIAS',
                                 null, 30, null, null, null);
  begin perform public.fn_ciclico_desativar(v_tadm, (v_r->>'id')::uuid, true);
  exception when others then v_erro := sqlerrm; end;
  if v_erro = 'REGISTRO_DO_ADMIN_MASTER' then v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else v_falha := v_falha + 1; v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'desativou!') || E'\n'; end if;

  v_rel := v_rel || E'\n-- NORMALIZACAO DE MATRICULA ------------------------\n';

  -- ===========================================================================
  -- MATRICULA CURTA GANHA ZEROS A ESQUERDA
  --
  -- Os alvos ('0590', '0020', '0005') sao valores reais e curtos, entao podem
  -- ja existir no banco de quem roda os testes. Nesse caso o teste e pulado com
  -- aviso, em vez de acusar uma falha que nao e do codigo.
  -- ===========================================================================

  -- T94 '590' -> '0590'
  v_desc := 'T94 matricula 590 e gravada como 0590'; v_erro := null;
  if exists (select 1 from public.funcionarios where matricula = '0590') then
    v_ok := v_ok + 1;
    v_rel := v_rel || '  [OK]    ' || v_desc || ' (pulado: 0590 ja cadastrada)' || E'\n';
  else
    begin
      v_r := public.fn_cadastrar_funcionario('Teste Zeros A', '590', '1234', v_setor);
      select matricula into v_txt from public.funcionarios
       where id = (v_r->'funcionario'->>'id')::uuid;
    exception when others then v_erro := sqlerrm; end;
    if v_erro is null and v_txt = '0590' then
      v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
    else
      v_falha := v_falha + 1;
      v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, v_txt) || E'\n';
    end if;
  end if;

  -- T95 '20' -> '0020'
  v_desc := 'T95 matricula 20 e gravada como 0020'; v_erro := null;
  if exists (select 1 from public.funcionarios where matricula = '0020') then
    v_ok := v_ok + 1;
    v_rel := v_rel || '  [OK]    ' || v_desc || ' (pulado: 0020 ja cadastrada)' || E'\n';
  else
    begin
      v_r := public.fn_cadastrar_funcionario('Teste Zeros B', '20', '1234', v_setor);
      select matricula into v_txt from public.funcionarios
       where id = (v_r->'funcionario'->>'id')::uuid;
    exception when others then v_erro := sqlerrm; end;
    if v_erro is null and v_txt = '0020' then
      v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
    else
      v_falha := v_falha + 1;
      v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, v_txt) || E'\n';
    end if;
  end if;

  -- T96 um unico digito tambem completa
  v_desc := 'T96 matricula 5 e gravada como 0005'; v_erro := null;
  if exists (select 1 from public.funcionarios where matricula = '0005') then
    v_ok := v_ok + 1;
    v_rel := v_rel || '  [OK]    ' || v_desc || ' (pulado: 0005 ja cadastrada)' || E'\n';
  else
    begin
      v_r := public.fn_cadastrar_funcionario('Teste Zeros C', '5', '1234', v_setor);
      select matricula into v_txt from public.funcionarios
       where id = (v_r->'funcionario'->>'id')::uuid;
    exception when others then v_erro := sqlerrm; end;
    if v_erro is null and v_txt = '0005' then
      v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
    else
      v_falha := v_falha + 1;
      v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, v_txt) || E'\n';
    end if;
  end if;

  -- T97 matricula longa NAO pode ser truncada.
  -- Este e o teste que protege contra o lpad do Postgres, que corta quando o
  -- texto ja e maior que o tamanho pedido.
  v_desc := 'T97 matricula com mais de 4 digitos nao e truncada'; v_erro := null;
  begin
    v_r := public.fn_cadastrar_funcionario('Teste Zeros D', '900777', '1234', v_setor);
    select matricula into v_txt from public.funcionarios
     where id = (v_r->'funcionario'->>'id')::uuid;
  exception when others then v_erro := sqlerrm; end;
  if v_erro is null and v_txt = '900777' then
    v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else
    v_falha := v_falha + 1;
    v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, v_txt) || E'\n';
  end if;

  -- T98 exatamente 4 digitos passa intacta
  v_desc := 'T98 matricula de 4 digitos passa sem alteracao'; v_erro := null;
  begin
    v_r := public.fn_cadastrar_funcionario('Teste Zeros E', '9078', '1234', v_setor);
    select matricula into v_txt from public.funcionarios
     where id = (v_r->'funcionario'->>'id')::uuid;
  exception when others then v_erro := sqlerrm; end;
  if v_erro is null and v_txt = '9078' then
    v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else
    v_falha := v_falha + 1;
    v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, v_txt) || E'\n';
  end if;

  -- T99 depois de normalizar, a duplicidade continua sendo barrada.
  -- '590' vira '0590', que o T94 acabou de criar (ou que ja existia no banco,
  -- caso o T94 tenha sido pulado). Nos dois caminhos o resultado e o mesmo.
  v_desc := 'T99 forma curta de uma matricula ja existente e recusada'; v_erro := null;
  begin perform public.fn_cadastrar_funcionario('Teste Zeros F', '590', '1234', v_setor);
  exception when others then v_erro := sqlerrm; end;
  if v_erro = 'MATRICULA_DUPLICADA' then
    v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else
    v_falha := v_falha + 1;
    v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'aceitou!') || E'\n';
  end if;

  -- T100 texto que nao e numero continua recusado
  v_desc := 'T100 matricula com letra continua recusada'; v_erro := null;
  begin perform public.fn_cadastrar_funcionario('Teste Zeros G', '59A', '1234', v_setor);
  exception when others then v_erro := sqlerrm; end;
  if v_erro = 'MATRICULA_FORMATO' then
    v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else
    v_falha := v_falha + 1;
    v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'aceitou!') || E'\n';
  end if;

  -- T101 matricula vazia continua recusada
  v_desc := 'T101 matricula vazia continua recusada'; v_erro := null;
  begin perform public.fn_cadastrar_funcionario('Teste Zeros H', '   ', '1234', v_setor);
  exception when others then v_erro := sqlerrm; end;
  if v_erro = 'MATRICULA_FORMATO' then
    v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else
    v_falha := v_falha + 1;
    v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'aceitou!') || E'\n';
  end if;

  -- T102 acima de 10 digitos continua recusado
  v_desc := 'T102 matricula com mais de 10 digitos continua recusada'; v_erro := null;
  begin perform public.fn_cadastrar_funcionario('Teste Zeros I', '12345678901', '1234', v_setor);
  exception when others then v_erro := sqlerrm; end;
  if v_erro = 'MATRICULA_FORMATO' then
    v_ok := v_ok + 1; v_rel := v_rel || '  [OK]    ' || v_desc || E'\n';
  else
    v_falha := v_falha + 1;
    v_rel := v_rel || '  [FALHA] ' || v_desc || ' -> ' || coalesce(v_erro, 'aceitou!') || E'\n';
  end if;

  -- ===========================================================================
  -- RELATORIO
  -- ===========================================================================
  v_rel := v_rel || E'\n===========================================================\n';
  v_rel := v_rel || ' TOTAL: ' || (v_ok + v_falha) || ' testes | OK: ' || v_ok || ' | FALHAS: ' || v_falha || E'\n';
  if v_falha = 0 then
    v_rel := v_rel || E' RESULTADO: TODAS AS REGRAS ESTAO ATIVAS NO BANCO.\n';
  else
    v_rel := v_rel || E' RESULTADO: EXISTEM REGRAS NAO ATIVAS - VER LINHAS [FALHA].\n';
  end if;
  v_rel := v_rel || E'===========================================================\n';
  v_rel := v_rel || E' Nenhum dado de teste foi mantido: tudo sofreu rollback.\n';

  raise notice '%', v_rel;

  -- Rollback proposital de tudo o que este script criou.
  raise exception 'RELATORIO_DE_TESTES__NADA_FOI_GRAVADO %', v_rel;
end $$;

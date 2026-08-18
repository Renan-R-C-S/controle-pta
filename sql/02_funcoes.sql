-- =============================================================================
-- SISTEMA DE CONTROLE E AGENDAMENTO DE PTA
-- Arquivo 02 - FUNCOES / RPC
--
-- PRINCIPIO: o frontend NAO escreve diretamente em nenhuma tabela. Todas as
-- operacoes passam por estas funcoes SECURITY DEFINER, que sao o unico lugar
-- onde as regras de negocio sao efetivamente aplicadas. As tabelas ficam com
-- RLS habilitado e sem politicas para os papeis anon/authenticated (03_rls.sql).
--
-- ERROS: as funcoes lancam codigos estaveis em MAIUSCULAS (ex.: PIN_INCORRETO).
-- O frontend traduz esses codigos para mensagens amigaveis (js/erros.js), de
-- modo que nenhuma mensagem tecnica do banco chegue ao usuario (item 36).
-- =============================================================================

-- O search_path abaixo garante que as classes de operador do btree_gist e as
-- funcoes do pgcrypto sejam encontradas, independentemente do schema em que as
-- extensoes foram instaladas neste projeto.
set search_path = public, extensions;

-- =============================================================================
-- AUXILIARES INTERNOS
-- =============================================================================

-- Hora oficial do servidor, ja formatada no fuso do sistema (item 34).
create or replace function public.fn_agora()
returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select jsonb_build_object(
    'utc',      now(),
    'local',    to_char(now() at time zone public.fn_tz(), 'YYYY-MM-DD"T"HH24:MI:SS'),
    'data',     to_char(now() at time zone public.fn_tz(), 'YYYY-MM-DD'),
    'hora',     to_char(now() at time zone public.fn_tz(), 'HH24:MI'),
    'fuso',     public.fn_tz()
  );
$$;

-- Converte data + hora locais (America/Sao_Paulo) para timestamptz.
create or replace function public.fn__local_para_utc(p_data date, p_hora time)
returns timestamptz
language sql stable as $$
  select (p_data + p_hora) at time zone public.fn_tz();
$$;

-- Valida o token de sessao e devolve o funcionario autenticado.
-- Renova o carimbo de ultimo acesso. Lanca SESSAO_INVALIDA quando aplicavel.
create or replace function public.fn__sessao(p_token uuid)
returns public.funcionarios
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_func public.funcionarios;
begin
  if p_token is null then
    raise exception 'SESSAO_INVALIDA' using errcode = 'P0001';
  end if;

  update public.sessoes
     set ultimo_acesso_em = now()
   where token = p_token
     and encerrada_em is null
     and expira_em > now();

  if not found then
    raise exception 'SESSAO_INVALIDA' using errcode = 'P0001';
  end if;

  select f.* into v_func
    from public.funcionarios f
    join public.sessoes s on s.funcionario_id = f.id
   where s.token = p_token
     and f.ativo;

  if v_func.id is null then
    raise exception 'SESSAO_INVALIDA' using errcode = 'P0001';
  end if;

  return v_func;
end $$;

-- Escreve um evento de auditoria (REGRA 15).
create or replace function public.fn__auditar(
  p_usuario_id  uuid,
  p_pta_id      uuid,
  p_tipo_acao   text,
  p_reg_tipo    text,
  p_reg_id      text,
  p_antes       jsonb,
  p_depois      jsonb,
  p_descricao   text
) returns void
language sql security definer set search_path = public, extensions as $$
  insert into public.auditoria (
    usuario_id, pta_id, tipo_acao, registro_tipo, registro_id,
    dados_anteriores, dados_novos, descricao)
  values (
    p_usuario_id, p_pta_id, p_tipo_acao, p_reg_tipo, p_reg_id,
    p_antes, p_depois, p_descricao);
$$;

-- Cria uma sessao nova para o funcionario (12 horas de validade).
create or replace function public.fn__abrir_sessao(p_funcionario_id uuid)
returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_token uuid;
begin
  insert into public.sessoes (funcionario_id, expira_em)
  values (p_funcionario_id, now() + interval '12 hours')
  returning token into v_token;
  return v_token;
end $$;

-- Monta o objeto publico do funcionario (jamais inclui pin_hash).
create or replace function public.fn__func_publico(p_func public.funcionarios)
returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select jsonb_build_object(
    'id',         p_func.id,
    'nome',       p_func.nome,
    'matricula',  p_func.matricula,
    'setor_id',   p_func.setor_id,
    'setor',      (select nome from public.setores where id = p_func.setor_id)
  );
$$;

-- =============================================================================
-- 1) SETORES E FUNCIONARIOS (identificacao - itens 6, 8)
-- =============================================================================

create or replace function public.fn_setores()
returns table (id uuid, nome text)
language sql stable security definer set search_path = public, extensions as $$
  select s.id, s.nome
    from public.setores s
   where s.ativo
   order by s.ordem, s.nome;
$$;

-- Lista de funcionarios de um setor para a tela de selecao rapida (item 8).
-- Expoe apenas nome e matricula - nunca o hash do PIN.
create or replace function public.fn_funcionarios_por_setor(p_setor_id uuid)
returns table (id uuid, nome text, matricula text)
language sql stable security definer set search_path = public, extensions as $$
  select f.id, f.nome, f.matricula
    from public.funcionarios f
   where f.setor_id = p_setor_id
     and f.ativo
   order by f.nome;
$$;

-- Verifica disponibilidade da matricula antes do cadastro (feedback rapido).
-- A garantia real continua sendo a constraint UNIQUE (REGRA 1).
create or replace function public.fn_matricula_disponivel(p_matricula text)
returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select not exists (select 1 from public.funcionarios where matricula = btrim(p_matricula));
$$;

-- Cadastro de funcionario (primeiro acesso - item 6).
-- REGRA 1: matricula unica global. REGRA 2: PIN de exatamente 4 digitos.
-- REGRA 3: grava somente o hash bcrypt do PIN.
create or replace function public.fn_cadastrar_funcionario(
  p_nome       text,
  p_matricula  text,
  p_pin        text,
  p_setor_id   uuid
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_func   public.funcionarios;
  v_token  uuid;
  v_nome   text := btrim(coalesce(p_nome, ''));
  v_matr   text := btrim(coalesce(p_matricula, ''));
begin
  if char_length(v_nome) < 3 or char_length(v_nome) > 80 then
    raise exception 'NOME_INVALIDO' using errcode = 'P0001';
  end if;

  if v_matr !~ '^[0-9]{4,10}$' then
    raise exception 'MATRICULA_FORMATO' using errcode = 'P0001';
  end if;

  -- REGRA 2
  if coalesce(p_pin, '') !~ '^[0-9]{4}$' then
    raise exception 'PIN_FORMATO' using errcode = 'P0001';
  end if;

  if not exists (select 1 from public.setores where id = p_setor_id and ativo) then
    raise exception 'SETOR_INVALIDO' using errcode = 'P0001';
  end if;

  begin
    insert into public.funcionarios (nome, matricula, pin_hash, setor_id)
    values (v_nome, v_matr, crypt(p_pin, gen_salt('bf', 10)), p_setor_id)
    returning * into v_func;
  exception
    when unique_violation then
      -- REGRA 1 aplicada pelo banco, mesmo com corrida entre dois cadastros
      raise exception 'MATRICULA_DUPLICADA' using errcode = 'P0001';
  end;

  perform public.fn__auditar(
    v_func.id, null, 'CADASTRO_USUARIO', 'FUNCIONARIO', v_func.id::text,
    null,
    jsonb_build_object('nome', v_func.nome, 'matricula', v_func.matricula,
                       'setor_id', v_func.setor_id),
    'Cadastro de funcionario no primeiro acesso');

  v_token := public.fn__abrir_sessao(v_func.id);

  return jsonb_build_object(
    'ok',          true,
    'token',       v_token,
    'funcionario', public.fn__func_publico(v_func));
end $$;

-- Login por PIN (item 8). Bloqueio temporario apos 5 tentativas invalidas.
create or replace function public.fn_login(p_funcionario_id uuid, p_pin text)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_func    public.funcionarios;
  v_token   uuid;
  v_max     constant smallint := 5;
  v_janela  constant interval := interval '15 minutes';
begin
  select * into v_func from public.funcionarios where id = p_funcionario_id and ativo;

  if v_func.id is null then
    raise exception 'FUNCIONARIO_NAO_ENCONTRADO' using errcode = 'P0001';
  end if;

  if v_func.bloqueado_ate is not null and v_func.bloqueado_ate > now() then
    raise exception 'CONTA_BLOQUEADA' using errcode = 'P0001';
  end if;

  if coalesce(p_pin, '') !~ '^[0-9]{4}$' then
    raise exception 'PIN_FORMATO' using errcode = 'P0001';
  end if;

  if v_func.pin_hash <> crypt(p_pin, v_func.pin_hash) then
    -- ATENCAO: aqui NAO se pode usar RAISE. Um RAISE aborta a transacao inteira
    -- e desfaria o incremento abaixo, tornando o bloqueio por tentativas
    -- inoperante. Por isso a falha de PIN e devolvida como valor de retorno
    -- ({ok:false, erro:...}) e o wrapper do frontend a converte em excecao.
    update public.funcionarios
       set tentativas_falhas = tentativas_falhas + 1,
           bloqueado_ate = case when tentativas_falhas + 1 >= v_max
                                then now() + v_janela else bloqueado_ate end
     where id = v_func.id;

    perform public.fn__auditar(
      v_func.id, null, 'LOGIN_FALHA', 'FUNCIONARIO', v_func.id::text,
      null, jsonb_build_object('tentativa', v_func.tentativas_falhas + 1),
      'Tentativa de login com PIN incorreto');

    if v_func.tentativas_falhas + 1 >= v_max then
      return jsonb_build_object('ok', false, 'erro', 'CONTA_BLOQUEADA');
    end if;

    return jsonb_build_object(
      'ok', false,
      'erro', 'PIN_INCORRETO',
      'tentativas_restantes', v_max - (v_func.tentativas_falhas + 1));
  end if;

  update public.funcionarios
     set tentativas_falhas = 0, bloqueado_ate = null, ultimo_login_em = now()
   where id = v_func.id
  returning * into v_func;

  perform public.fn__auditar(
    v_func.id, null, 'LOGIN', 'FUNCIONARIO', v_func.id::text,
    null, null, 'Login efetuado');

  v_token := public.fn__abrir_sessao(v_func.id);

  return jsonb_build_object(
    'ok',          true,
    'token',       v_token,
    'funcionario', public.fn__func_publico(v_func));
end $$;

create or replace function public.fn_sessao_info(p_token uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_func public.funcionarios;
begin
  v_func := public.fn__sessao(p_token);
  return jsonb_build_object('funcionario', public.fn__func_publico(v_func));
end $$;

create or replace function public.fn_logout(p_token uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_id uuid;
begin
  update public.sessoes set encerrada_em = now()
   where token = p_token and encerrada_em is null
  returning funcionario_id into v_id;

  if v_id is not null then
    perform public.fn__auditar(v_id, null, 'LOGOUT', 'FUNCIONARIO', v_id::text,
                               null, null, 'Sessao encerrada');
  end if;

  return jsonb_build_object('ok', true);
end $$;

-- =============================================================================
-- 2) PTAs (itens 9, 38, 39)
-- =============================================================================

create or replace function public.fn_ptas()
returns table (id uuid, codigo text, descricao text, local text)
language sql stable security definer set search_path = public, extensions as $$
  select p.id, p.codigo, p.descricao, p.local
    from public.ptas p
   where p.ativo
   order by p.codigo;
$$;

-- Normaliza o parametro do QR Code 1: aceita "PTA001", "pta-001", "PTA-1".
create or replace function public.fn__normalizar_codigo_pta(p_codigo text)
returns text
language plpgsql immutable as $$
declare
  v_num text;
begin
  if p_codigo is null then return null; end if;
  v_num := regexp_replace(upper(btrim(p_codigo)), '[^0-9]', '', 'g');
  if v_num = '' then return upper(btrim(p_codigo)); end if;
  return 'PTA-' || lpad(v_num, 3, '0');
end $$;

-- Situacao completa de uma PTA para o dashboard do QR Code 1 (itens 10 e 38).
create or replace function public.fn_pta_situacao(p_codigo text, p_token uuid default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_pta          public.ptas;
  v_uso          public.usos;
  v_func_uso     public.funcionarios;
  v_sessao_func  uuid;
  v_proximos     jsonb;
begin
  select * into v_pta
    from public.ptas
   where codigo = public.fn__normalizar_codigo_pta(p_codigo) and ativo;

  if v_pta.id is null then
    raise exception 'PTA_NAO_ENCONTRADA' using errcode = 'P0001';
  end if;

  if p_token is not null then
    begin
      v_sessao_func := (public.fn__sessao(p_token)).id;
    exception when others then
      v_sessao_func := null;
    end;
  end if;

  select * into v_uso
    from public.usos
   where pta_id = v_pta.id and status = 'EM_USO'
   limit 1;

  if v_uso.id is not null then
    select * into v_func_uso from public.funcionarios where id = v_uso.funcionario_id;
  end if;

  -- Proximos agendamentos ativos da PTA (para avisar sobre sobrescrita)
  select coalesce(jsonb_agg(x order by x->>'inicio'), '[]'::jsonb) into v_proximos
    from (
      select jsonb_build_object(
               'id', a.id,
               'inicio', to_char(a.inicio_planejado at time zone public.fn_tz(), 'YYYY-MM-DD"T"HH24:MI'),
               'fim',    to_char(a.fim_planejado    at time zone public.fn_tz(), 'YYYY-MM-DD"T"HH24:MI'),
               'funcionario', f.nome,
               'setor', s.nome,
               'proprio', (f.id = v_sessao_func)
             ) as x
        from public.agendamentos a
        join public.funcionarios f on f.id = a.funcionario_id
        join public.setores s      on s.id = f.setor_id
       where a.pta_id = v_pta.id
         and a.status = 'AGENDADO'
         and a.fim_planejado > now()
         and a.inicio_planejado < now() + interval '24 hours'
    ) t;

  return jsonb_build_object(
    'pta', jsonb_build_object(
      'id', v_pta.id, 'codigo', v_pta.codigo,
      'descricao', v_pta.descricao, 'local', v_pta.local),
    'status', case when v_uso.id is null then 'DISPONIVEL' else 'EM_USO' end,
    'uso', case when v_uso.id is null then null else jsonb_build_object(
      'id', v_uso.id,
      'inicio_efetivo', to_char(v_uso.inicio_efetivo at time zone public.fn_tz(), 'YYYY-MM-DD"T"HH24:MI'),
      'fim_pretendido', to_char(v_uso.fim_pretendido at time zone public.fn_tz(), 'YYYY-MM-DD"T"HH24:MI'),
      'atrasado', (now() > v_uso.fim_pretendido),
      'observacao', v_uso.observacao,
      'funcionario_id', v_uso.funcionario_id,
      'funcionario', v_func_uso.nome,
      'matricula', v_func_uso.matricula,
      'meu_uso', (v_uso.funcionario_id = v_sessao_func)) end,
    'proximos_agendamentos', v_proximos,
    'agora', public.fn_agora());
end $$;

-- =============================================================================
-- 3) USO IMEDIATO - QR CODE 1 (itens 11 a 17, REGRAS 5, 7, 8, 9, 12, 18)
-- =============================================================================

create or replace function public.fn_uso_iniciar(
  p_token         uuid,
  p_pta_codigo    text,
  p_fim_pretendido time
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_func        public.funcionarios;
  v_pta         public.ptas;
  v_uso         public.usos;
  v_agora       timestamptz := now();
  v_hoje        date;
  v_fim         timestamptz;
  v_ag          record;
  v_novo_status text;
  v_afetados    int := 0;
  v_origem      uuid;
begin
  v_func := public.fn__sessao(p_token);

  select * into v_pta
    from public.ptas
   where codigo = public.fn__normalizar_codigo_pta(p_pta_codigo) and ativo;

  if v_pta.id is null then
    raise exception 'PTA_NAO_ENCONTRADA' using errcode = 'P0001';
  end if;

  if exists (select 1 from public.usos where pta_id = v_pta.id and status = 'EM_USO') then
    raise exception 'PTA_EM_USO' using errcode = 'P0001';
  end if;

  if exists (select 1 from public.usos where funcionario_id = v_func.id and status = 'EM_USO') then
    raise exception 'USUARIO_COM_USO_ABERTO' using errcode = 'P0001';
  end if;

  if p_fim_pretendido is null then
    raise exception 'HORARIO_INVALIDO' using errcode = 'P0001';
  end if;

  -- REGRA 9: o inicio efetivo e sempre o horario do servidor, nunca o do celular.
  v_hoje := (v_agora at time zone public.fn_tz())::date;
  v_fim  := public.fn__local_para_utc(v_hoje, p_fim_pretendido);

  -- Item 12: o fim pretendido precisa ser posterior ao inicio.
  -- MVP: uso dentro do mesmo dia (decisao documentada em docs/DECISOES.md).
  if v_fim <= v_agora then
    raise exception 'HORARIO_FINAL_ANTERIOR' using errcode = 'P0001';
  end if;

  if v_fim - v_agora > interval '14 hours' then
    raise exception 'DURACAO_EXCESSIVA' using errcode = 'P0001';
  end if;

  insert into public.usos (pta_id, funcionario_id, data_ref, inicio_efetivo, fim_pretendido)
  values (v_pta.id, v_func.id, v_hoje, v_agora, v_fim)
  returning * into v_uso;

  -- REGRA 7 / 18: o uso imediato prevalece sobre agendamentos conflitantes,
  -- mas o agendamento anterior NAO e apagado - apenas marcado e vinculado.
  for v_ag in
    select a.*, f.nome as func_nome
      from public.agendamentos a
      join public.funcionarios f on f.id = a.funcionario_id
     where a.pta_id = v_pta.id
       and a.status = 'AGENDADO'
       and tstzrange(a.inicio_planejado, a.fim_planejado, '[)')
           && tstzrange(v_agora, v_fim, '[)')
     order by a.inicio_planejado
  loop
    -- Se o agendamento e do proprio funcionario, ele apenas substituiu a sua
    -- programacao (SOBRESCRITO). Se e de outra pessoa, o registro fica marcado
    -- como AFETADO_POR_USO_IMEDIATO. Decisao documentada em docs/DECISOES.md.
    if v_ag.funcionario_id = v_func.id then
      v_novo_status := 'SOBRESCRITO';
      v_origem := v_ag.id;
    else
      v_novo_status := 'AFETADO_POR_USO_IMEDIATO';
    end if;

    update public.agendamentos
       set status = v_novo_status,
           motivo_status = 'Uso imediato iniciado por ' || v_func.nome ||
                           ' (matricula ' || v_func.matricula || ') via QR Code 1'
     where id = v_ag.id;

    insert into public.agendamentos_afetados (
      uso_id, agendamento_id, status_anterior, status_novo, causado_por)
    values (v_uso.id, v_ag.id, 'AGENDADO', v_novo_status, v_func.id);

    perform public.fn__auditar(
      v_func.id, v_pta.id, 'AGENDAMENTO_SOBRESCRITO', 'AGENDAMENTO', v_ag.id::text,
      jsonb_build_object(
        'status', 'AGENDADO',
        'funcionario', v_ag.func_nome,
        'inicio_planejado', to_char(v_ag.inicio_planejado at time zone public.fn_tz(), 'YYYY-MM-DD HH24:MI'),
        'fim_planejado',    to_char(v_ag.fim_planejado    at time zone public.fn_tz(), 'YYYY-MM-DD HH24:MI')),
      jsonb_build_object(
        'status', v_novo_status,
        'uso_id', v_uso.id,
        'inicio_efetivo', to_char(v_agora at time zone public.fn_tz(), 'YYYY-MM-DD HH24:MI'),
        'fim_pretendido', to_char(v_fim   at time zone public.fn_tz(), 'YYYY-MM-DD HH24:MI')),
      'Agendamento afetado por uso imediato do QR Code 1 (QR1 tem prioridade sobre QR2)');

    v_afetados := v_afetados + 1;
  end loop;

  if v_origem is not null then
    update public.usos set agendamento_origem_id = v_origem where id = v_uso.id
    returning * into v_uso;
  end if;

  perform public.fn__auditar(
    v_func.id, v_pta.id, 'USO_INICIADO', 'USO', v_uso.id::text,
    null,
    jsonb_build_object(
      'pta', v_pta.codigo,
      'inicio_efetivo', to_char(v_agora at time zone public.fn_tz(), 'YYYY-MM-DD HH24:MI'),
      'fim_pretendido', to_char(v_fim   at time zone public.fn_tz(), 'YYYY-MM-DD HH24:MI'),
      'agendamentos_afetados', v_afetados),
    'Uso imediato iniciado pelo QR Code 1');

  return jsonb_build_object(
    'uso_id', v_uso.id,
    'pta', v_pta.codigo,
    'inicio_efetivo', to_char(v_agora at time zone public.fn_tz(), 'HH24:MI'),
    'fim_pretendido', to_char(v_fim   at time zone public.fn_tz(), 'HH24:MI'),
    'agendamentos_afetados', v_afetados);
end $$;

-- REGRA 10 / 14: fim_efetivo = instante real do clique; abre a janela de 30 min
-- para a observacao. Nao existe finalizacao automatica (REGRA 12 / item 17).
create or replace function public.fn_uso_finalizar(p_token uuid, p_uso_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_func   public.funcionarios;
  v_uso    public.usos;
  v_pta    public.ptas;
  v_agora  timestamptz := now();
begin
  v_func := public.fn__sessao(p_token);

  select * into v_uso from public.usos where id = p_uso_id;
  if v_uso.id is null then
    raise exception 'USO_NAO_ENCONTRADO' using errcode = 'P0001';
  end if;
  if v_uso.status = 'FINALIZADO' then
    raise exception 'USO_JA_FINALIZADO' using errcode = 'P0001';
  end if;
  if v_uso.funcionario_id <> v_func.id then
    raise exception 'SEM_PERMISSAO' using errcode = 'P0001';
  end if;

  select * into v_pta from public.ptas where id = v_uso.pta_id;

  update public.usos
     set fim_efetivo = v_agora,
         status = 'FINALIZADO',
         -- REGRA 14: prazo de edicao da observacao
         limite_edicao_observacao = v_agora + interval '30 minutes'
   where id = v_uso.id
  returning * into v_uso;

  -- Se o uso nasceu de um agendamento do proprio funcionario, o agendamento
  -- passa a CONCLUIDO (a programacao foi de fato cumprida).
  if v_uso.agendamento_origem_id is not null then
    update public.agendamentos
       set status = 'CONCLUIDO',
           motivo_status = 'Programacao cumprida pelo uso ' || v_uso.id::text
     where id = v_uso.agendamento_origem_id
       and status in ('SOBRESCRITO', 'AGENDADO');

    perform public.fn__auditar(
      v_func.id, v_pta.id, 'AGENDAMENTO_CONCLUIDO', 'AGENDAMENTO',
      v_uso.agendamento_origem_id::text,
      jsonb_build_object('status', 'SOBRESCRITO'),
      jsonb_build_object('status', 'CONCLUIDO', 'uso_id', v_uso.id),
      'Agendamento concluido pelo uso efetivo do proprio solicitante');
  end if;

  perform public.fn__auditar(
    v_func.id, v_pta.id, 'USO_FINALIZADO', 'USO', v_uso.id::text,
    jsonb_build_object('status', 'EM_USO', 'fim_efetivo', null),
    jsonb_build_object(
      'status', 'FINALIZADO',
      'fim_efetivo',    to_char(v_uso.fim_efetivo    at time zone public.fn_tz(), 'YYYY-MM-DD HH24:MI'),
      'fim_pretendido', to_char(v_uso.fim_pretendido at time zone public.fn_tz(), 'YYYY-MM-DD HH24:MI'),
      'ultrapassou_previsto', (v_uso.fim_efetivo > v_uso.fim_pretendido)),
    case when v_uso.fim_efetivo > v_uso.fim_pretendido
         then 'Uso finalizado APOS o horario pretendido (item 16)'
         else 'Uso finalizado' end);

  return jsonb_build_object(
    'uso_id', v_uso.id,
    'inicio_efetivo', to_char(v_uso.inicio_efetivo at time zone public.fn_tz(), 'HH24:MI'),
    'fim_pretendido', to_char(v_uso.fim_pretendido at time zone public.fn_tz(), 'HH24:MI'),
    'fim_efetivo',    to_char(v_uso.fim_efetivo    at time zone public.fn_tz(), 'HH24:MI'),
    'ultrapassou_previsto', (v_uso.fim_efetivo > v_uso.fim_pretendido),
    'limite_observacao', to_char(v_uso.limite_edicao_observacao at time zone public.fn_tz(), 'HH24:MI'),
    'duracao_minutos', round(extract(epoch from (v_uso.fim_efetivo - v_uso.inicio_efetivo)) / 60));
end $$;

-- =============================================================================
-- 4) OBSERVACOES (itens 18 e 19, REGRAS 13 e 14)
-- =============================================================================

create or replace function public.fn_observacao_salvar(
  p_token uuid, p_uso_id uuid, p_texto text
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_func   public.funcionarios;
  v_uso    public.usos;
  v_texto  text := nullif(btrim(coalesce(p_texto, '')), '');
  v_antes  text;
  v_acao   text;
begin
  v_func := public.fn__sessao(p_token);

  select * into v_uso from public.usos where id = p_uso_id;
  if v_uso.id is null then
    raise exception 'USO_NAO_ENCONTRADO' using errcode = 'P0001';
  end if;
  if v_uso.funcionario_id <> v_func.id then
    raise exception 'SEM_PERMISSAO' using errcode = 'P0001';
  end if;

  -- REGRA 13
  if v_texto is not null and char_length(v_texto) > 200 then
    raise exception 'OBSERVACAO_LONGA' using errcode = 'P0001';
  end if;

  -- REGRA 14: validacao no banco, nao apenas no frontend.
  -- Enquanto o uso esta aberto a edicao e livre; apos a finalizacao valem
  -- exatamente 30 minutos contados do fim_efetivo.
  if v_uso.status = 'FINALIZADO'
     and v_uso.limite_edicao_observacao is not null
     and now() > v_uso.limite_edicao_observacao then
    raise exception 'OBSERVACAO_PRAZO_EXPIRADO' using errcode = 'P0001';
  end if;

  v_antes := v_uso.observacao;
  v_acao  := case when v_antes is null then 'OBSERVACAO_CRIADA' else 'OBSERVACAO_EDITADA' end;

  update public.usos
     set observacao = v_texto,
         observacao_atualizada_em = now()
   where id = v_uso.id
  returning * into v_uso;

  perform public.fn__auditar(
    v_func.id, v_uso.pta_id, v_acao, 'USO', v_uso.id::text,
    jsonb_build_object('observacao', v_antes),
    jsonb_build_object('observacao', v_texto),
    'Observacao do uso ' || v_uso.id::text);

  return jsonb_build_object(
    'ok', true,
    'observacao', v_uso.observacao,
    'limite_edicao', to_char(v_uso.limite_edicao_observacao at time zone public.fn_tz(), 'YYYY-MM-DD"T"HH24:MI'));
end $$;

-- Situacao do uso + se a observacao ainda pode ser editada (a fonte da verdade
-- do prazo e sempre o relogio do servidor).
create or replace function public.fn_uso_detalhe(p_token uuid, p_uso_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_func public.funcionarios;
  v_uso  public.usos;
  v_pta  public.ptas;
begin
  v_func := public.fn__sessao(p_token);
  select * into v_uso from public.usos where id = p_uso_id;
  if v_uso.id is null then
    raise exception 'USO_NAO_ENCONTRADO' using errcode = 'P0001';
  end if;
  select * into v_pta from public.ptas where id = v_uso.pta_id;

  return jsonb_build_object(
    'id', v_uso.id,
    'pta', v_pta.codigo,
    'status', v_uso.status,
    'meu_uso', (v_uso.funcionario_id = v_func.id),
    'inicio_efetivo', to_char(v_uso.inicio_efetivo at time zone public.fn_tz(), 'YYYY-MM-DD"T"HH24:MI'),
    'fim_pretendido', to_char(v_uso.fim_pretendido at time zone public.fn_tz(), 'YYYY-MM-DD"T"HH24:MI'),
    'fim_efetivo', case when v_uso.fim_efetivo is null then null else
                   to_char(v_uso.fim_efetivo at time zone public.fn_tz(), 'YYYY-MM-DD"T"HH24:MI') end,
    'observacao', v_uso.observacao,
    'limite_edicao_observacao', case when v_uso.limite_edicao_observacao is null then null else
        to_char(v_uso.limite_edicao_observacao at time zone public.fn_tz(), 'YYYY-MM-DD"T"HH24:MI') end,
    'pode_editar_observacao', (
        v_uso.funcionario_id = v_func.id and (
          v_uso.status = 'EM_USO' or
          v_uso.limite_edicao_observacao is null or
          now() <= v_uso.limite_edicao_observacao)),
    'agora', public.fn_agora());
end $$;

-- Uso aberto do funcionario logado, em qualquer PTA (item 10, "MINHA PROGRAMACAO")
create or replace function public.fn_meu_uso_aberto(p_token uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_func public.funcionarios;
  v_uso  public.usos;
  v_pta  public.ptas;
begin
  v_func := public.fn__sessao(p_token);
  select * into v_uso from public.usos
   where funcionario_id = v_func.id and status = 'EM_USO' limit 1;
  if v_uso.id is null then
    return null;
  end if;
  select * into v_pta from public.ptas where id = v_uso.pta_id;
  return jsonb_build_object(
    'id', v_uso.id,
    'pta', v_pta.codigo,
    'inicio_efetivo', to_char(v_uso.inicio_efetivo at time zone public.fn_tz(), 'YYYY-MM-DD"T"HH24:MI'),
    'fim_pretendido', to_char(v_uso.fim_pretendido at time zone public.fn_tz(), 'YYYY-MM-DD"T"HH24:MI'));
end $$;

-- =============================================================================
-- 5) AGENDAMENTOS - QR CODE 2 (itens 20, 22, REGRAS 6 e 17)
-- =============================================================================

create or replace function public.fn_agendamento_criar(
  p_token       uuid,
  p_pta_id      uuid,
  p_data        date,
  p_hora_inicio time,
  p_hora_fim    time
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_func    public.funcionarios;
  v_pta     public.ptas;
  v_ag      public.agendamentos;
  v_inicio  timestamptz;
  v_fim     timestamptz;
begin
  v_func := public.fn__sessao(p_token);

  select * into v_pta from public.ptas where id = p_pta_id and ativo;
  if v_pta.id is null then
    raise exception 'PTA_NAO_ENCONTRADA' using errcode = 'P0001';
  end if;

  if p_data is null or p_hora_inicio is null or p_hora_fim is null then
    raise exception 'HORARIO_INVALIDO' using errcode = 'P0001';
  end if;

  v_inicio := public.fn__local_para_utc(p_data, p_hora_inicio);
  v_fim    := public.fn__local_para_utc(p_data, p_hora_fim);

  if v_fim <= v_inicio then
    raise exception 'HORARIO_FINAL_ANTERIOR' using errcode = 'P0001';
  end if;

  -- REGRA 6: o QR Code 2 serve para programar o futuro.
  if v_inicio <= now() then
    raise exception 'AGENDAMENTO_PASSADO' using errcode = 'P0001';
  end if;

  if v_fim - v_inicio > interval '14 hours' then
    raise exception 'DURACAO_EXCESSIVA' using errcode = 'P0001';
  end if;

  -- Conflito com um uso imediato ainda em aberto na mesma PTA (REGRA 7).
  if exists (
    select 1 from public.usos u
     where u.pta_id = v_pta.id and u.status = 'EM_USO'
       and tstzrange(u.inicio_efetivo, u.fim_pretendido, '[)') && tstzrange(v_inicio, v_fim, '[)')
  ) then
    raise exception 'CONFLITO_COM_USO' using errcode = 'P0001';
  end if;

  begin
    insert into public.agendamentos (
      pta_id, funcionario_id, data_ref, inicio_planejado, fim_planejado)
    values (v_pta.id, v_func.id, p_data, v_inicio, v_fim)
    returning * into v_ag;
  exception
    when exclusion_violation then
      -- REGRA 17 aplicada pelo banco: vale inclusive para gravacoes simultaneas
      raise exception 'CONFLITO_AGENDAMENTO' using errcode = 'P0001';
  end;

  perform public.fn__auditar(
    v_func.id, v_pta.id, 'AGENDAMENTO_CRIADO', 'AGENDAMENTO', v_ag.id::text,
    null,
    jsonb_build_object(
      'pta', v_pta.codigo,
      'data', p_data,
      'inicio_planejado', to_char(v_inicio at time zone public.fn_tz(), 'YYYY-MM-DD HH24:MI'),
      'fim_planejado',    to_char(v_fim    at time zone public.fn_tz(), 'YYYY-MM-DD HH24:MI')),
    'Agendamento criado pelo QR Code 2');

  return jsonb_build_object(
    'id', v_ag.id,
    'pta', v_pta.codigo,
    'data', to_char(p_data, 'DD/MM/YYYY'),
    'inicio', to_char(p_hora_inicio, 'HH24:MI'),
    'fim', to_char(p_hora_fim, 'HH24:MI'));
end $$;

create or replace function public.fn_agendamento_cancelar(p_token uuid, p_agendamento_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_func public.funcionarios;
  v_ag   public.agendamentos;
begin
  v_func := public.fn__sessao(p_token);

  select * into v_ag from public.agendamentos where id = p_agendamento_id;
  if v_ag.id is null then
    raise exception 'AGENDAMENTO_NAO_ENCONTRADO' using errcode = 'P0001';
  end if;
  -- Somente o autor cancela a propria programacao (item 31).
  if v_ag.funcionario_id <> v_func.id then
    raise exception 'SEM_PERMISSAO' using errcode = 'P0001';
  end if;
  if v_ag.status <> 'AGENDADO' then
    raise exception 'AGENDAMENTO_NAO_CANCELAVEL' using errcode = 'P0001';
  end if;

  update public.agendamentos
     set status = 'CANCELADO', cancelado_em = now(),
         motivo_status = 'Cancelado pelo autor'
   where id = v_ag.id;

  perform public.fn__auditar(
    v_func.id, v_ag.pta_id, 'AGENDAMENTO_CANCELADO', 'AGENDAMENTO', v_ag.id::text,
    jsonb_build_object('status', 'AGENDADO'),
    jsonb_build_object('status', 'CANCELADO'),
    'Agendamento cancelado pelo autor');

  return jsonb_build_object('ok', true);
end $$;

-- =============================================================================
-- 6) CALENDARIO E CONSULTAS (itens 26, 27)
-- =============================================================================

-- Linha do tempo de um dia: agendamentos e usos lado a lado, mas nunca
-- misturados (item 21 / REGRA 11). A coluna "tipo" distingue os dois conceitos.
create or replace function public.fn_agenda_dia(p_data date, p_pta_id uuid default null)
returns table (
  tipo            text,
  id              uuid,
  pta_id          uuid,
  pta_codigo      text,
  funcionario     text,
  matricula       text,
  setor           text,
  inicio          text,
  fim             text,
  fim_efetivo     text,
  status          text,
  observacao      text,
  ordem           timestamptz
)
language sql stable security definer set search_path = public, extensions as $$
  select 'AGENDAMENTO'::text,
         a.id, p.id, p.codigo, f.nome, f.matricula, s.nome,
         to_char(a.inicio_planejado at time zone public.fn_tz(), 'HH24:MI'),
         to_char(a.fim_planejado    at time zone public.fn_tz(), 'HH24:MI'),
         null::text,
         a.status,
         a.motivo_status,
         a.inicio_planejado
    from public.agendamentos a
    join public.ptas p         on p.id = a.pta_id
    join public.funcionarios f on f.id = a.funcionario_id
    join public.setores s      on s.id = f.setor_id
   where a.data_ref = p_data
     and (p_pta_id is null or a.pta_id = p_pta_id)
  union all
  select 'USO'::text,
         u.id, p.id, p.codigo, f.nome, f.matricula, s.nome,
         to_char(u.inicio_efetivo at time zone public.fn_tz(), 'HH24:MI'),
         to_char(u.fim_pretendido at time zone public.fn_tz(), 'HH24:MI'),
         case when u.fim_efetivo is null then null
              else to_char(u.fim_efetivo at time zone public.fn_tz(), 'HH24:MI') end,
         u.status,
         u.observacao,
         u.inicio_efetivo
    from public.usos u
    join public.ptas p         on p.id = u.pta_id
    join public.funcionarios f on f.id = u.funcionario_id
    join public.setores s      on s.id = f.setor_id
   where u.data_ref = p_data
     and (p_pta_id is null or u.pta_id = p_pta_id)
   order by 13, 4;
$$;

-- Marcadores do calendario mensal (item 26).
create or replace function public.fn_calendario_mes(p_ano int, p_mes int)
returns table (dia date, agendamentos int, usos int)
language sql stable security definer set search_path = public, extensions as $$
  with periodo as (
    select make_date(p_ano, p_mes, 1) as ini,
           (make_date(p_ano, p_mes, 1) + interval '1 month - 1 day')::date as fim
  ),
  dias as (
    select d::date as dia from periodo, generate_series(periodo.ini, periodo.fim, interval '1 day') d
  )
  select dias.dia,
         (select count(*)::int from public.agendamentos a
           where a.data_ref = dias.dia and a.status in ('AGENDADO','SOBRESCRITO','AFETADO_POR_USO_IMEDIATO','CONCLUIDO')),
         (select count(*)::int from public.usos u where u.data_ref = dias.dia)
    from dias
   order by dias.dia;
$$;

-- Detalhe de um item do calendario, incluindo o rastro de sobrescrita (item 27).
create or replace function public.fn_detalhe_registro(p_tipo text, p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_res jsonb;
begin
  if p_tipo = 'AGENDAMENTO' then
    select jsonb_build_object(
      'tipo', 'AGENDAMENTO',
      'id', a.id,
      'pta', p.codigo,
      'funcionario', f.nome,
      'matricula', f.matricula,
      'setor', s.nome,
      'data', to_char(a.data_ref, 'DD/MM/YYYY'),
      'inicio_planejado', to_char(a.inicio_planejado at time zone public.fn_tz(), 'HH24:MI'),
      'fim_planejado',    to_char(a.fim_planejado    at time zone public.fn_tz(), 'HH24:MI'),
      'status', a.status,
      'motivo_status', a.motivo_status,
      'criado_em', to_char(a.criado_em at time zone public.fn_tz(), 'DD/MM/YYYY HH24:MI'),
      'afetado_por', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'uso_id', af.uso_id,
                 'quando', to_char(af.criado_em at time zone public.fn_tz(), 'DD/MM/YYYY HH24:MI'),
                 'por', fc.nome,
                 'inicio_efetivo', to_char(u.inicio_efetivo at time zone public.fn_tz(), 'HH24:MI'),
                 'fim_pretendido', to_char(u.fim_pretendido at time zone public.fn_tz(), 'HH24:MI'))), '[]'::jsonb)
          from public.agendamentos_afetados af
          join public.usos u on u.id = af.uso_id
          join public.funcionarios fc on fc.id = af.causado_por
         where af.agendamento_id = a.id))
      into v_res
      from public.agendamentos a
      join public.ptas p         on p.id = a.pta_id
      join public.funcionarios f on f.id = a.funcionario_id
      join public.setores s      on s.id = f.setor_id
     where a.id = p_id;

  elsif p_tipo = 'USO' then
    select jsonb_build_object(
      'tipo', 'USO',
      'id', u.id,
      'pta', p.codigo,
      'funcionario', f.nome,
      'matricula', f.matricula,
      'setor', s.nome,
      'data', to_char(u.data_ref, 'DD/MM/YYYY'),
      'inicio_efetivo', to_char(u.inicio_efetivo at time zone public.fn_tz(), 'HH24:MI'),
      'fim_pretendido', to_char(u.fim_pretendido at time zone public.fn_tz(), 'HH24:MI'),
      'fim_efetivo', case when u.fim_efetivo is null then null
                     else to_char(u.fim_efetivo at time zone public.fn_tz(), 'HH24:MI') end,
      'status', u.status,
      'ultrapassou_previsto', (u.fim_efetivo is not null and u.fim_efetivo > u.fim_pretendido),
      'observacao', u.observacao,
      'observacao_atualizada_em', case when u.observacao_atualizada_em is null then null
        else to_char(u.observacao_atualizada_em at time zone public.fn_tz(), 'DD/MM/YYYY HH24:MI') end,
      'agendamentos_afetados', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'agendamento_id', af.agendamento_id,
                 'status_anterior', af.status_anterior,
                 'status_novo', af.status_novo,
                 'funcionario', fa.nome,
                 'inicio_planejado', to_char(a.inicio_planejado at time zone public.fn_tz(), 'HH24:MI'),
                 'fim_planejado',    to_char(a.fim_planejado    at time zone public.fn_tz(), 'HH24:MI'))), '[]'::jsonb)
          from public.agendamentos_afetados af
          join public.agendamentos a  on a.id = af.agendamento_id
          join public.funcionarios fa on fa.id = a.funcionario_id
         where af.uso_id = u.id))
      into v_res
      from public.usos u
      join public.ptas p         on p.id = u.pta_id
      join public.funcionarios f on f.id = u.funcionario_id
      join public.setores s      on s.id = f.setor_id
     where u.id = p_id;
  else
    raise exception 'REGISTRO_NAO_ENCONTRADO' using errcode = 'P0001';
  end if;

  if v_res is null then
    raise exception 'REGISTRO_NAO_ENCONTRADO' using errcode = 'P0001';
  end if;

  return v_res;
end $$;

-- Historico consolidado de utilizacao (item 3 / tela 10).
create or replace function public.fn_historico(
  p_data_ini date default null,
  p_data_fim date default null,
  p_pta_id   uuid default null,
  p_limite   int  default 200
) returns table (
  data          date,
  pta_codigo    text,
  funcionario   text,
  setor         text,
  inicio        text,
  fim_pretendido text,
  fim_efetivo   text,
  status        text,
  ultrapassou   boolean,
  observacao    text
)
language sql stable security definer set search_path = public, extensions as $$
  select u.data_ref, p.codigo, f.nome, s.nome,
         to_char(u.inicio_efetivo at time zone public.fn_tz(), 'HH24:MI'),
         to_char(u.fim_pretendido at time zone public.fn_tz(), 'HH24:MI'),
         case when u.fim_efetivo is null then null
              else to_char(u.fim_efetivo at time zone public.fn_tz(), 'HH24:MI') end,
         u.status,
         (u.fim_efetivo is not null and u.fim_efetivo > u.fim_pretendido),
         u.observacao
    from public.usos u
    join public.ptas p         on p.id = u.pta_id
    join public.funcionarios f on f.id = u.funcionario_id
    join public.setores s      on s.id = f.setor_id
   where (p_data_ini is null or u.data_ref >= p_data_ini)
     and (p_data_fim is null or u.data_ref <= p_data_fim)
     and (p_pta_id   is null or u.pta_id = p_pta_id)
   order by u.inicio_efetivo desc
   limit least(coalesce(p_limite, 200), 500);
$$;

-- Minha programacao: agendamentos futuros + usos recentes do funcionario logado.
create or replace function public.fn_minha_programacao(p_token uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_func public.funcionarios;
begin
  v_func := public.fn__sessao(p_token);
  return jsonb_build_object(
    'agendamentos', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', a.id, 'pta', p.codigo,
               'data', to_char(a.data_ref, 'DD/MM/YYYY'),
               'inicio', to_char(a.inicio_planejado at time zone public.fn_tz(), 'HH24:MI'),
               'fim',    to_char(a.fim_planejado    at time zone public.fn_tz(), 'HH24:MI'),
               'status', a.status) order by a.inicio_planejado), '[]'::jsonb)
        from public.agendamentos a join public.ptas p on p.id = a.pta_id
       where a.funcionario_id = v_func.id and a.fim_planejado > now() - interval '1 day'),
    'usos', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', u.id, 'pta', p.codigo,
               'data', to_char(u.data_ref, 'DD/MM/YYYY'),
               'inicio', to_char(u.inicio_efetivo at time zone public.fn_tz(), 'HH24:MI'),
               'fim_pretendido', to_char(u.fim_pretendido at time zone public.fn_tz(), 'HH24:MI'),
               'fim_efetivo', case when u.fim_efetivo is null then null
                              else to_char(u.fim_efetivo at time zone public.fn_tz(), 'HH24:MI') end,
               'status', u.status,
               'observacao', u.observacao,
               'pode_editar_observacao', (u.status = 'EM_USO' or
                     u.limite_edicao_observacao is null or now() <= u.limite_edicao_observacao)
             ) order by u.inicio_efetivo desc), '[]'::jsonb)
        from (select * from public.usos where funcionario_id = v_func.id
               order by inicio_efetivo desc limit 20) u
        join public.ptas p on p.id = u.pta_id));
end $$;

-- =============================================================================
-- 7) AUDITORIA (item 25) - somente leitura para o frontend
-- =============================================================================

create or replace function public.fn_auditoria(
  p_limite int default 100,
  p_pta_id uuid default null
) returns table (
  quando      text,
  usuario     text,
  pta         text,
  tipo_acao   text,
  registro    text,
  registro_id text,
  descricao   text,
  antes       jsonb,
  depois      jsonb
)
language sql stable security definer set search_path = public, extensions as $$
  select to_char(a.ocorrido_em at time zone public.fn_tz(), 'DD/MM/YYYY HH24:MI:SS'),
         coalesce(f.nome, 'Sistema'),
         coalesce(p.codigo, '-'),
         a.tipo_acao, a.registro_tipo, a.registro_id, a.descricao,
         a.dados_anteriores, a.dados_novos
    from public.auditoria a
    left join public.funcionarios f on f.id = a.usuario_id
    left join public.ptas p         on p.id = a.pta_id
   where (p_pta_id is null or a.pta_id = p_pta_id)
   order by a.ocorrido_em desc, a.id desc
   limit least(coalesce(p_limite, 100), 500);
$$;

-- =============================================================================
-- PERMISSOES DE EXECUCAO
-- Somente estas funcoes ficam acessiveis ao frontend. As auxiliares internas
-- (prefixo fn__) permanecem restritas.
-- =============================================================================
-- fn__abrir_sessao e a mais critica desta lista: se ficasse acessivel, qualquer
-- pessoa poderia emitir um token valido para qualquer funcionario sem o PIN.
-- fn__auditar permitiria forjar linhas na trilha de auditoria.
revoke all on function
  public.fn__sessao(uuid),
  public.fn__auditar(uuid, uuid, text, text, text, jsonb, jsonb, text),
  public.fn__abrir_sessao(uuid),
  public.fn__func_publico(public.funcionarios),
  public.fn__local_para_utc(date, time),
  public.fn__normalizar_codigo_pta(text)
from public, anon, authenticated;

grant execute on function
  public.fn_agora(),
  public.fn_setores(),
  public.fn_funcionarios_por_setor(uuid),
  public.fn_matricula_disponivel(text),
  public.fn_cadastrar_funcionario(text, text, text, uuid),
  public.fn_login(uuid, text),
  public.fn_sessao_info(uuid),
  public.fn_logout(uuid),
  public.fn_ptas(),
  public.fn_pta_situacao(text, uuid),
  public.fn_uso_iniciar(uuid, text, time),
  public.fn_uso_finalizar(uuid, uuid),
  public.fn_uso_detalhe(uuid, uuid),
  public.fn_meu_uso_aberto(uuid),
  public.fn_observacao_salvar(uuid, uuid, text),
  public.fn_agendamento_criar(uuid, uuid, date, time, time),
  public.fn_agendamento_cancelar(uuid, uuid),
  public.fn_agenda_dia(date, uuid),
  public.fn_calendario_mes(int, int),
  public.fn_detalhe_registro(text, uuid),
  public.fn_historico(date, date, uuid, int),
  public.fn_minha_programacao(uuid),
  public.fn_auditoria(int, uuid)
to anon, authenticated;

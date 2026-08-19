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
-- Os campos "admin" e "master" existem apenas para a interface decidir o que
-- desenhar. Eles NAO autorizam nada: toda permissao e reconferida no banco.
create or replace function public.fn__func_publico(p_func public.funcionarios)
returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select jsonb_build_object(
    'id',         p_func.id,
    'nome',       p_func.nome,
    'matricula',  p_func.matricula,
    'setor_id',   p_func.setor_id,
    'setor',      (select nome from public.setores where id = p_func.setor_id),
    'papel',      p_func.papel,
    'admin',      (p_func.papel in ('ADMIN', 'ADMIN_MASTER')),
    'master',     (p_func.papel = 'ADMIN_MASTER'),
    -- PIN definido por um administrador: a tela obriga a troca antes de seguir
    'pin_provisorio', coalesce(p_func.pin_provisorio, false)
  );
$$;

-- Exige papel administrativo. Usada no inicio de toda funcao de administracao.
create or replace function public.fn__exigir_admin(p_func public.funcionarios)
returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_func.papel not in ('ADMIN', 'ADMIN_MASTER') then
    raise exception 'SEM_PERMISSAO_ADMIN' using errcode = 'P0001';
  end if;
end $$;

-- Exige o papel de administrador original (0591 na implantacao).
create or replace function public.fn__exigir_master(p_func public.funcionarios)
returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_func.papel <> 'ADMIN_MASTER' then
    raise exception 'SOMENTE_ADMIN_MASTER' using errcode = 'P0001';
  end if;
end $$;

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
-- A garantia real continua sendo o indice unico parcial (REGRA 1).
--
-- Duas sutilezas moram aqui:
--   * so um cadastro ATIVO ocupa a matricula - a de quem foi excluido volta a
--     ficar livre, e dizer o contrario contradiria a propria regra de reuso;
--   * o valor passa pela mesma normalizacao do cadastro ('590' -> '0590'),
--     senao a checagem olharia um numero e a gravacao outro.
create or replace function public.fn_matricula_disponivel(p_matricula text)
returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select not exists (
    select 1 from public.funcionarios
     where ativo
       and matricula = case
             when char_length(btrim(coalesce(p_matricula, ''))) < 4
             then lpad(btrim(coalesce(p_matricula, '')), 4, '0')
             else btrim(coalesce(p_matricula, ''))
           end);
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
  v_limite int;
  v_ativos int;
  v_papel  text;
begin
  if char_length(v_nome) < 3 or char_length(v_nome) > 80 then
    raise exception 'NOME_INVALIDO' using errcode = 'P0001';
  end if;

  if v_matr !~ '^[0-9]{1,10}$' then
    raise exception 'MATRICULA_FORMATO' using errcode = 'P0001';
  end if;

  -- Matricula curta ganha zeros a esquerda: '590' vira '0590', '20' vira '0020'.
  -- A normalizacao mora aqui, no banco, e nao apenas na tela: assim vale para
  -- qualquer caminho de cadastro, inclusive uma chamada direta ao RPC.
  --
  -- O teste de comprimento e necessario: lpad TRUNCA quando o texto ja e maior
  -- que o tamanho pedido, entao lpad('12345', 4, '0') devolveria '1234' e
  -- silenciosamente trocaria a matricula da pessoa.
  if char_length(v_matr) < 4 then
    v_matr := lpad(v_matr, 4, '0');
  end if;

  -- REGRA 2
  if coalesce(p_pin, '') !~ '^[0-9]{4,10}$' then
    raise exception 'PIN_FORMATO' using errcode = 'P0001';
  end if;

  if not exists (select 1 from public.setores where id = p_setor_id and ativo) then
    raise exception 'SETOR_INVALIDO' using errcode = 'P0001';
  end if;

  -- Serializa os cadastros para que o limite valha mesmo com duas pessoas
  -- se cadastrando no mesmo segundo. O bloqueio cai junto com a transacao.
  perform pg_advisory_xact_lock(hashtext('pta.cadastro_funcionario'));

  select coalesce(nullif(valor, '')::int, 0) into v_limite
    from public.configuracao where chave = 'limite_matriculas';

  if coalesce(v_limite, 0) > 0 then
    select count(*) into v_ativos from public.funcionarios where ativo;
    if v_ativos >= v_limite then
      raise exception 'LIMITE_MATRICULAS_ATINGIDO' using errcode = 'P0001';
    end if;
  end if;

  -- Matriculas reservadas ja nascem com papel administrativo (bootstrap).
  select papel into v_papel
    from public.matriculas_reservadas where matricula = v_matr;

  begin
    insert into public.funcionarios (nome, matricula, pin_hash, setor_id, papel)
    values (v_nome, v_matr, crypt(p_pin, gen_salt('bf', 10)), p_setor_id,
            coalesce(v_papel, 'FUNCIONARIO'))
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
                       'setor_id', v_func.setor_id, 'papel', v_func.papel),
    case when v_func.papel = 'FUNCIONARIO'
         then 'Cadastro de funcionario no primeiro acesso'
         else 'Cadastro de funcionario com papel ' || v_func.papel ||
              ' (matricula reservada)' end);

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

  if coalesce(p_pin, '') !~ '^[0-9]{4,10}$' then
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
      'fornecedor', (select nome from public.fornecedores where id = v_uso.fornecedor_id),
      'meu_uso', (v_uso.funcionario_id = v_sessao_func)) end,
    'proximos_agendamentos', v_proximos,
    'max_horas_uso', (select coalesce(nullif(valor, '')::int, 14)
                        from public.configuracao where chave = 'max_horas_uso_aberto'),
    'agora', public.fn_agora());
end $$;

-- =============================================================================
-- 3) USO IMEDIATO - QR CODE 1 (itens 11 a 17, REGRAS 5, 7, 8, 9, 12, 18)
-- =============================================================================

-- A assinatura mudou (ganhou p_fornecedor_id). Um CREATE OR REPLACE criaria uma
-- SOBRECARGA, deixando duas versoes ativas e tornando a chamada ambigua para o
-- PostgREST. Por isso a versao antiga e removida antes.
drop function if exists public.fn_uso_iniciar(uuid, text, time);

create or replace function public.fn_uso_iniciar(
  p_token          uuid,
  p_pta_codigo     text,
  p_fim_pretendido time,
  p_fornecedor_id  uuid default null
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
  v_max_horas   int;
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

  -- VIRADA DA MEIA-NOITE: as 23h, escolher 01:00 significa a madrugada do dia
  -- SEGUINTE. Antes disso o horario caia no passado e o uso era recusado -
  -- exatamente o caso de quem entra no turno da noite.
  if v_fim <= v_agora then
    v_fim := public.fn__local_para_utc(v_hoje + 1, p_fim_pretendido);
  end if;

  -- Somou um dia e ainda esta no passado: so acontece com relogio fora de
  -- sincronia. Melhor recusar do que gravar um horario incoerente.
  if v_fim <= v_agora then
    raise exception 'HORARIO_FINAL_ANTERIOR' using errcode = 'P0001';
  end if;

  -- Quem escolhe um horario que ja passou hoje recebe o dia seguinte, e o teto
  -- de duracao logo abaixo e que decide se isso e razoavel: as 23h pedir 22:00
  -- vira 23 horas de uso e cai em DURACAO_EXCESSIVA, como deve ser.

  -- Teto de duracao definido pelos administradores (nao mais fixo em 14h).
  select coalesce(nullif(valor, '')::int, 14) into v_max_horas
    from public.configuracao where chave = 'max_horas_uso_aberto';
  v_max_horas := greatest(coalesce(v_max_horas, 14), 1);

  if v_fim - v_agora > make_interval(hours => v_max_horas) then
    raise exception 'DURACAO_EXCESSIVA' using errcode = 'P0001';
  end if;

  if p_fornecedor_id is not null
     and not exists (select 1 from public.fornecedores where id = p_fornecedor_id and ativo) then
    raise exception 'FORNECEDOR_NAO_ENCONTRADO' using errcode = 'P0001';
  end if;

  insert into public.usos (
    pta_id, funcionario_id, data_ref, inicio_efetivo, fim_pretendido, fornecedor_id)
  values (v_pta.id, v_func.id, v_hoje, v_agora, v_fim, p_fornecedor_id)
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

drop function if exists public.fn_agendamento_criar(uuid, uuid, date, time, time);

create or replace function public.fn_agendamento_criar(
  p_token         uuid,
  p_pta_id        uuid,
  p_data          date,
  p_hora_inicio   time,
  p_hora_fim      time,
  p_fornecedor_id uuid default null
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

  if p_fornecedor_id is not null
     and not exists (select 1 from public.fornecedores where id = p_fornecedor_id and ativo) then
    raise exception 'FORNECEDOR_NAO_ENCONTRADO' using errcode = 'P0001';
  end if;

  begin
    insert into public.agendamentos (
      pta_id, funcionario_id, data_ref, inicio_planejado, fim_planejado, fornecedor_id)
    values (v_pta.id, v_func.id, p_data, v_inicio, v_fim, p_fornecedor_id)
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
  v_func      public.funcionarios;
  v_ag        public.agendamentos;
  v_por_admin boolean;
begin
  v_func := public.fn__sessao(p_token);

  select * into v_ag from public.agendamentos where id = p_agendamento_id;
  if v_ag.id is null then
    raise exception 'AGENDAMENTO_NAO_ENCONTRADO' using errcode = 'P0001';
  end if;

  -- O autor cancela a propria programacao; ADMIN cancela a de qualquer um.
  -- Programacao criada pelo administrador principal so ele proprio cancela.
  v_por_admin := (v_ag.funcionario_id <> v_func.id);
  perform public.fn__exigir_gestao(v_func, v_ag.funcionario_id);

  if v_ag.status <> 'AGENDADO' then
    raise exception 'AGENDAMENTO_NAO_CANCELAVEL' using errcode = 'P0001';
  end if;

  -- "Excluir" e sempre marcar como CANCELADO: apagar fisicamente destruiria o
  -- rastro da programacao e a ligacao com eventuais sobrescritas (REGRA 18).
  update public.agendamentos
     set status = 'CANCELADO', cancelado_em = now(),
         motivo_status = case when v_por_admin
              then 'Cancelado pela administracao (' || v_func.nome || ')'
              else 'Cancelado pelo autor' end
   where id = v_ag.id;

  perform public.fn__auditar(
    v_func.id, v_ag.pta_id, 'AGENDAMENTO_CANCELADO', 'AGENDAMENTO', v_ag.id::text,
    jsonb_build_object('status', 'AGENDADO'),
    jsonb_build_object('status', 'CANCELADO', 'por_admin', v_por_admin),
    case when v_por_admin
         then 'Agendamento cancelado pela administracao'
         else 'Agendamento cancelado pelo autor' end);

  return jsonb_build_object('ok', true);
end $$;

-- =============================================================================
-- 6) CALENDARIO E CONSULTAS (itens 26, 27)
-- =============================================================================

-- Linha do tempo de um dia: agendamentos e usos lado a lado, mas nunca
-- misturados (item 21 / REGRA 11). A coluna "tipo" distingue os dois conceitos.
-- Ganhou as colunas fornecedor e ciclico: como o tipo de retorno muda, a versao
-- antiga precisa ser removida antes (CREATE OR REPLACE nao altera assinatura).
drop function if exists public.fn_agenda_dia(date, uuid);

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
  fornecedor      text,
  ciclico         boolean,
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
         fo.nome,
         (a.ciclico_id is not null),
         a.inicio_planejado
    from public.agendamentos a
    join public.ptas p              on p.id = a.pta_id
    join public.funcionarios f      on f.id = a.funcionario_id
    join public.setores s           on s.id = f.setor_id
    left join public.fornecedores fo on fo.id = a.fornecedor_id
   where a.data_ref = p_data
     and (p_pta_id is null or a.pta_id = p_pta_id)
  union all
  -- Usos cancelados tambem entram: o cronograma mostra o que foi encerrado
  -- pela administracao, com etiqueta propria, em vez de simplesmente sumir.
  select 'USO'::text,
         u.id, p.id, p.codigo, f.nome, f.matricula, s.nome,
         to_char(u.inicio_efetivo at time zone public.fn_tz(), 'HH24:MI'),
         to_char(u.fim_pretendido at time zone public.fn_tz(), 'HH24:MI'),
         case when u.fim_efetivo is null then null
              else to_char(u.fim_efetivo at time zone public.fn_tz(), 'HH24:MI') end,
         u.status,
         coalesce(u.observacao, u.motivo_cancelamento),
         fo.nome,
         false,
         u.inicio_efetivo
    from public.usos u
    join public.ptas p              on p.id = u.pta_id
    join public.funcionarios f      on f.id = u.funcionario_id
    join public.setores s           on s.id = f.setor_id
    left join public.fornecedores fo on fo.id = u.fornecedor_id
   where u.data_ref = p_data
     and (p_pta_id is null or u.pta_id = p_pta_id)
   order by 15, 4;
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
      'fornecedor', fo.nome,
      'fornecedor_id', a.fornecedor_id,
      'ciclico', (a.ciclico_id is not null),
      'do_master', (f.papel = 'ADMIN_MASTER'),
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
      join public.ptas p              on p.id = a.pta_id
      join public.funcionarios f      on f.id = a.funcionario_id
      join public.setores s           on s.id = f.setor_id
      left join public.fornecedores fo on fo.id = a.fornecedor_id
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
      'fornecedor', fo.nome,
      'do_master', (f.papel = 'ADMIN_MASTER'),
      'cancelado_por', (select c.nome from public.funcionarios c where c.id = u.cancelado_por),
      'motivo_cancelamento', u.motivo_cancelamento,
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
      join public.ptas p              on p.id = u.pta_id
      join public.funcionarios f      on f.id = u.funcionario_id
      join public.setores s           on s.id = f.setor_id
      left join public.fornecedores fo on fo.id = u.fornecedor_id
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
-- 8) PERFIL DO PROPRIO FUNCIONARIO
-- =============================================================================

-- O funcionario corrige o proprio nome. A MATRICULA nunca muda por aqui: ela e
-- a identidade do registro, referenciada por usos, agendamentos e auditoria.
-- Trocar matricula seria reescrever historico (REGRA 16).
create or replace function public.fn_perfil_alterar_nome(p_token uuid, p_nome text)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_func  public.funcionarios;
  v_nome  text := btrim(coalesce(p_nome, ''));
  v_antes text;
begin
  v_func := public.fn__sessao(p_token);

  if char_length(v_nome) < 3 or char_length(v_nome) > 80 then
    raise exception 'NOME_INVALIDO' using errcode = 'P0001';
  end if;

  if v_nome = v_func.nome then
    return jsonb_build_object('ok', true, 'funcionario', public.fn__func_publico(v_func));
  end if;

  v_antes := v_func.nome;

  update public.funcionarios set nome = v_nome where id = v_func.id
  returning * into v_func;

  perform public.fn__auditar(
    v_func.id, null, 'NOME_ALTERADO', 'FUNCIONARIO', v_func.id::text,
    jsonb_build_object('nome', v_antes),
    jsonb_build_object('nome', v_nome),
    'Funcionario alterou o proprio nome');

  return jsonb_build_object('ok', true, 'funcionario', public.fn__func_publico(v_func));
end $$;

-- =============================================================================
-- 9) ALTERACAO DE PROGRAMACAO
-- =============================================================================

-- O autor ajusta a propria programacao; o ADMIN ajusta a de qualquer um.
-- As mesmas regras de conflito e de horario futuro continuam valendo.
drop function if exists public.fn_agendamento_alterar(uuid, uuid, date, time, time);

create or replace function public.fn_agendamento_alterar(
  p_token          uuid,
  p_agendamento_id uuid,
  p_data           date,
  p_hora_inicio    time,
  p_hora_fim       time,
  p_fornecedor_id  uuid default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_func      public.funcionarios;
  v_ag        public.agendamentos;
  v_inicio    timestamptz;
  v_fim       timestamptz;
  v_por_admin boolean;
begin
  v_func := public.fn__sessao(p_token);

  select * into v_ag from public.agendamentos where id = p_agendamento_id;
  if v_ag.id is null then
    raise exception 'AGENDAMENTO_NAO_ENCONTRADO' using errcode = 'P0001';
  end if;

  v_por_admin := (v_ag.funcionario_id <> v_func.id);
  -- Exige papel administrativo para mexer em registro alheio e protege os
  -- registros do administrador principal (so ele mesmo os altera).
  perform public.fn__exigir_gestao(v_func, v_ag.funcionario_id);

  if p_fornecedor_id is not null
     and not exists (select 1 from public.fornecedores where id = p_fornecedor_id and ativo) then
    raise exception 'FORNECEDOR_NAO_ENCONTRADO' using errcode = 'P0001';
  end if;

  -- So faz sentido mexer no que ainda esta valendo. Uma programacao ja
  -- sobrescrita, concluida ou cancelada e historico.
  if v_ag.status <> 'AGENDADO' then
    raise exception 'AGENDAMENTO_NAO_ALTERAVEL' using errcode = 'P0001';
  end if;

  if p_data is null or p_hora_inicio is null or p_hora_fim is null then
    raise exception 'HORARIO_INVALIDO' using errcode = 'P0001';
  end if;

  v_inicio := public.fn__local_para_utc(p_data, p_hora_inicio);
  v_fim    := public.fn__local_para_utc(p_data, p_hora_fim);

  if v_fim <= v_inicio then
    raise exception 'HORARIO_FINAL_ANTERIOR' using errcode = 'P0001';
  end if;
  if v_inicio <= now() then
    raise exception 'AGENDAMENTO_PASSADO' using errcode = 'P0001';
  end if;
  if v_fim - v_inicio > interval '14 hours' then
    raise exception 'DURACAO_EXCESSIVA' using errcode = 'P0001';
  end if;

  if exists (
    select 1 from public.usos u
     where u.pta_id = v_ag.pta_id and u.status = 'EM_USO'
       and tstzrange(u.inicio_efetivo, u.fim_pretendido, '[)') && tstzrange(v_inicio, v_fim, '[)')
  ) then
    raise exception 'CONFLITO_COM_USO' using errcode = 'P0001';
  end if;

  begin
    update public.agendamentos
       set data_ref = p_data,
           inicio_planejado = v_inicio,
           fim_planejado = v_fim,
           fornecedor_id = p_fornecedor_id,
           motivo_status = case when v_por_admin
                then 'Alterado pela administracao (' || v_func.nome || ')'
                else 'Alterado pelo autor' end
     where id = v_ag.id;
  exception
    when exclusion_violation then
      raise exception 'CONFLITO_AGENDAMENTO' using errcode = 'P0001';
  end;

  perform public.fn__auditar(
    v_func.id, v_ag.pta_id, 'AGENDAMENTO_ALTERADO', 'AGENDAMENTO', v_ag.id::text,
    jsonb_build_object(
      'data', v_ag.data_ref,
      'inicio_planejado', to_char(v_ag.inicio_planejado at time zone public.fn_tz(), 'YYYY-MM-DD HH24:MI'),
      'fim_planejado',    to_char(v_ag.fim_planejado    at time zone public.fn_tz(), 'YYYY-MM-DD HH24:MI')),
    jsonb_build_object(
      'data', p_data,
      'inicio_planejado', to_char(v_inicio at time zone public.fn_tz(), 'YYYY-MM-DD HH24:MI'),
      'fim_planejado',    to_char(v_fim    at time zone public.fn_tz(), 'YYYY-MM-DD HH24:MI'),
      'por_admin', v_por_admin),
    case when v_por_admin
         then 'Programacao alterada pela administracao'
         else 'Programacao alterada pelo autor' end);

  return jsonb_build_object('ok', true, 'id', v_ag.id);
end $$;

-- =============================================================================
-- 10) ADMINISTRACAO
-- =============================================================================

create or replace function public.fn_admin_listar_funcionarios(p_token uuid)
returns table (
  id           uuid,
  nome         text,
  matricula    text,
  setor        text,
  papel        text,
  ativo        boolean,
  ultimo_login text
)
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_func public.funcionarios;
begin
  v_func := public.fn__sessao(p_token);
  perform public.fn__exigir_admin(v_func);

  return query
    select f.id, f.nome, f.matricula, s.nome, f.papel, f.ativo,
           case when f.ultimo_login_em is null then null else
             to_char(f.ultimo_login_em at time zone public.fn_tz(), 'DD/MM/YYYY HH24:MI') end
      from public.funcionarios f
      join public.setores s on s.id = f.setor_id
     order by f.ativo desc,
              case f.papel when 'ADMIN_MASTER' then 0 when 'ADMIN' then 1 else 2 end,
              f.nome;
end $$;

-- Concede ou retira o papel de ADMIN.
--   ADMIN         so CONCEDE (papel destino 'ADMIN')
--   ADMIN_MASTER  concede e RETIRA
-- Ninguem altera o papel do ADMIN_MASTER, nem o proprio.
create or replace function public.fn_admin_definir_papel(
  p_token uuid, p_funcionario_id uuid, p_papel text
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_func  public.funcionarios;
  v_alvo  public.funcionarios;
begin
  v_func := public.fn__sessao(p_token);
  perform public.fn__exigir_admin(v_func);

  if p_papel not in ('FUNCIONARIO', 'ADMIN') then
    raise exception 'PAPEL_INVALIDO' using errcode = 'P0001';
  end if;

  select * into v_alvo from public.funcionarios where id = p_funcionario_id;
  if v_alvo.id is null then
    raise exception 'FUNCIONARIO_NAO_ENCONTRADO' using errcode = 'P0001';
  end if;

  -- O administrador original e intocavel: e ele quem garante que sempre existe
  -- alguem capaz de reorganizar as permissoes.
  if v_alvo.papel = 'ADMIN_MASTER' then
    raise exception 'ADMIN_MASTER_PROTEGIDO' using errcode = 'P0001';
  end if;

  if v_alvo.id = v_func.id then
    raise exception 'PAPEL_PROPRIO_BLOQUEADO' using errcode = 'P0001';
  end if;

  -- Retirar o papel administrativo e privilegio exclusivo do master.
  if p_papel = 'FUNCIONARIO' and v_alvo.papel = 'ADMIN' then
    perform public.fn__exigir_master(v_func);
  end if;

  if v_alvo.papel = p_papel then
    return jsonb_build_object('ok', true, 'papel', p_papel, 'inalterado', true);
  end if;

  update public.funcionarios set papel = p_papel where id = v_alvo.id;

  perform public.fn__auditar(
    v_func.id, null, 'PAPEL_ALTERADO', 'FUNCIONARIO', v_alvo.id::text,
    jsonb_build_object('papel', v_alvo.papel, 'funcionario', v_alvo.nome),
    jsonb_build_object('papel', p_papel, 'funcionario', v_alvo.nome),
    'Papel de ' || v_alvo.nome || ' alterado por ' || v_func.nome);

  return jsonb_build_object('ok', true, 'papel', p_papel);
end $$;

-- "Excluir" um funcionario = desativar.
-- Apagar fisicamente e impossivel sem destruir os usos e a auditoria dele, que
-- sao justamente o que nao pode ser alterado. Desativado, ele some da lista de
-- login, nao consegue mais entrar, tem as sessoes encerradas, as programacoes
-- futuras canceladas e libera vaga no limite de matriculas.
create or replace function public.fn_admin_desativar_funcionario(
  p_token uuid, p_funcionario_id uuid
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_func      public.funcionarios;
  v_alvo      public.funcionarios;
  v_cancelados int := 0;
  v_ag        record;
begin
  v_func := public.fn__sessao(p_token);
  perform public.fn__exigir_admin(v_func);

  select * into v_alvo from public.funcionarios where id = p_funcionario_id;
  if v_alvo.id is null then
    raise exception 'FUNCIONARIO_NAO_ENCONTRADO' using errcode = 'P0001';
  end if;
  if v_alvo.papel = 'ADMIN_MASTER' then
    raise exception 'ADMIN_MASTER_PROTEGIDO' using errcode = 'P0001';
  end if;
  if v_alvo.id = v_func.id then
    raise exception 'EXCLUSAO_PROPRIA_BLOQUEADA' using errcode = 'P0001';
  end if;
  if not v_alvo.ativo then
    return jsonb_build_object('ok', true, 'inalterado', true);
  end if;

  -- Um uso em aberto e uma PTA fisicamente ocupada. Precisa ser encerrado antes.
  if exists (select 1 from public.usos where funcionario_id = v_alvo.id and status = 'EM_USO') then
    raise exception 'FUNCIONARIO_COM_USO_ABERTO' using errcode = 'P0001';
  end if;

  update public.funcionarios
     set ativo = false, desativado_em = now(), desativado_por = v_func.id
   where id = v_alvo.id;

  update public.sessoes set encerrada_em = now()
   where funcionario_id = v_alvo.id and encerrada_em is null;

  -- Libera os horarios que ele tinha reservado daqui pra frente.
  for v_ag in
    select * from public.agendamentos
     where funcionario_id = v_alvo.id and status = 'AGENDADO' and fim_planejado > now()
  loop
    update public.agendamentos
       set status = 'CANCELADO', cancelado_em = now(),
           motivo_status = 'Funcionario desativado pela administracao'
     where id = v_ag.id;

    perform public.fn__auditar(
      v_func.id, v_ag.pta_id, 'AGENDAMENTO_CANCELADO', 'AGENDAMENTO', v_ag.id::text,
      jsonb_build_object('status', 'AGENDADO'),
      jsonb_build_object('status', 'CANCELADO', 'motivo', 'funcionario desativado'),
      'Programacao cancelada junto com a desativacao de ' || v_alvo.nome);

    v_cancelados := v_cancelados + 1;
  end loop;

  perform public.fn__auditar(
    v_func.id, null, 'FUNCIONARIO_DESATIVADO', 'FUNCIONARIO', v_alvo.id::text,
    jsonb_build_object('ativo', true, 'funcionario', v_alvo.nome,
                       'matricula', v_alvo.matricula),
    jsonb_build_object('ativo', false, 'agendamentos_cancelados', v_cancelados),
    'Funcionario ' || v_alvo.nome || ' desativado por ' || v_func.nome);

  return jsonb_build_object('ok', true, 'agendamentos_cancelados', v_cancelados);
end $$;

create or replace function public.fn_admin_reativar_funcionario(
  p_token uuid, p_funcionario_id uuid
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_func   public.funcionarios;
  v_alvo   public.funcionarios;
  v_limite int;
  v_ativos int;
begin
  v_func := public.fn__sessao(p_token);
  perform public.fn__exigir_admin(v_func);

  select * into v_alvo from public.funcionarios where id = p_funcionario_id;
  if v_alvo.id is null then
    raise exception 'FUNCIONARIO_NAO_ENCONTRADO' using errcode = 'P0001';
  end if;
  if v_alvo.ativo then
    return jsonb_build_object('ok', true, 'inalterado', true);
  end if;

  perform pg_advisory_xact_lock(hashtext('pta.cadastro_funcionario'));

  select coalesce(nullif(valor, '')::int, 0) into v_limite
    from public.configuracao where chave = 'limite_matriculas';

  if coalesce(v_limite, 0) > 0 then
    select count(*) into v_ativos from public.funcionarios where ativo;
    if v_ativos >= v_limite then
      raise exception 'LIMITE_MATRICULAS_ATINGIDO' using errcode = 'P0001';
    end if;
  end if;

  update public.funcionarios
     set ativo = true, desativado_em = null, desativado_por = null
   where id = v_alvo.id;

  perform public.fn__auditar(
    v_func.id, null, 'FUNCIONARIO_REATIVADO', 'FUNCIONARIO', v_alvo.id::text,
    jsonb_build_object('ativo', false),
    jsonb_build_object('ativo', true, 'funcionario', v_alvo.nome),
    'Funcionario ' || v_alvo.nome || ' reativado por ' || v_func.nome);

  return jsonb_build_object('ok', true);
end $$;

-- Limite de matriculas: exclusivo do ADMIN_MASTER. 0 = sem limite.
create or replace function public.fn_admin_definir_limite_matriculas(
  p_token uuid, p_limite int
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_func   public.funcionarios;
  v_antes  text;
  v_ativos int;
begin
  v_func := public.fn__sessao(p_token);
  perform public.fn__exigir_master(v_func);

  if p_limite is null or p_limite < 0 then
    raise exception 'LIMITE_INVALIDO' using errcode = 'P0001';
  end if;

  select count(*) into v_ativos from public.funcionarios where ativo;

  -- Nao deixa definir um teto abaixo de quem ja esta ativo: isso deixaria o
  -- sistema num estado invalido sem nenhuma acao capaz de corrigi-lo sozinha.
  if p_limite > 0 and p_limite < v_ativos then
    raise exception 'LIMITE_ABAIXO_DO_ATUAL' using errcode = 'P0001';
  end if;

  select valor into v_antes from public.configuracao where chave = 'limite_matriculas';

  update public.configuracao
     set valor = p_limite::text, atualizado_em = now(), atualizado_por = v_func.id
   where chave = 'limite_matriculas';

  perform public.fn__auditar(
    v_func.id, null, 'LIMITE_MATRICULAS_ALTERADO', 'CONFIGURACAO', 'limite_matriculas',
    jsonb_build_object('limite', v_antes),
    jsonb_build_object('limite', p_limite::text, 'ativos_no_momento', v_ativos),
    'Limite de matriculas alterado por ' || v_func.nome);

  return jsonb_build_object('ok', true, 'limite', p_limite, 'ativos', v_ativos);
end $$;

create or replace function public.fn_admin_configuracao(p_token uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_func   public.funcionarios;
  v_limite int;
  v_ativos int;
begin
  v_func := public.fn__sessao(p_token);
  perform public.fn__exigir_admin(v_func);

  select coalesce(nullif(valor, '')::int, 0) into v_limite
    from public.configuracao where chave = 'limite_matriculas';
  select count(*) into v_ativos from public.funcionarios where ativo;

  return jsonb_build_object(
    'limite_matriculas', coalesce(v_limite, 0),
    'ativos', v_ativos,
    'vagas', case when coalesce(v_limite, 0) = 0 then null
                  else greatest(v_limite - v_ativos, 0) end,
    'pode_alterar_limite', (v_func.papel = 'ADMIN_MASTER'),
    'max_horas_uso_aberto', (select coalesce(nullif(valor, '')::int, 14)
                               from public.configuracao where chave = 'max_horas_uso_aberto'),
    'horizonte_ciclico_dias', (select coalesce(nullif(valor, '')::int, 365)
                                 from public.configuracao where chave = 'horizonte_ciclico_dias'),
    'usos_abertos_excedidos', (
      select count(*) from public.usos u
       where u.status = 'EM_USO'
         and now() - u.inicio_efetivo > make_interval(hours =>
               (select coalesce(nullif(valor, '')::int, 14)
                  from public.configuracao where chave = 'max_horas_uso_aberto'))),
    'matriculas_reservadas', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'matricula', r.matricula,
               'papel', r.papel,
               'cadastrada', exists (select 1 from public.funcionarios f
                                      where f.matricula = r.matricula and f.ativo))
             order by r.matricula), '[]'::jsonb)
        from public.matriculas_reservadas r));
end $$;

-- =============================================================================
-- 11) PROTECAO DOS REGISTROS DO ADMINISTRADOR PRINCIPAL
-- =============================================================================

-- Autoriza uma acao de gestao sobre o registro de outra pessoa.
--   1. mexer no proprio registro sempre pode;
--   2. mexer no de outro exige papel administrativo;
--   3. o que o ADMIN_MASTER criou so ele proprio altera - nem outro ADMIN.
create or replace function public.fn__exigir_gestao(
  p_ator public.funcionarios, p_dono_id uuid
) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_papel_dono text;
begin
  if p_dono_id = p_ator.id then
    return;
  end if;

  perform public.fn__exigir_admin(p_ator);

  select papel into v_papel_dono from public.funcionarios where id = p_dono_id;

  if v_papel_dono = 'ADMIN_MASTER' and p_ator.papel <> 'ADMIN_MASTER' then
    raise exception 'REGISTRO_DO_ADMIN_MASTER' using errcode = 'P0001';
  end if;
end $$;

-- =============================================================================
-- 12) TERCEIROS (FORNECEDORES)
-- =============================================================================

-- Lista/busca fornecedores. Leitura livre: o nome do terceiro aparece no
-- calendario de qualquer forma, e o campo alimenta um seletor com busca.
create or replace function public.fn_fornecedores(p_busca text default null)
returns table (id uuid, nome text, documento text)
language sql stable security definer set search_path = public, extensions as $$
  select f.id, f.nome, f.documento
    from public.fornecedores f
   where f.ativo
     and (p_busca is null or btrim(p_busca) = ''
          or lower(f.nome) like '%' || lower(btrim(p_busca)) || '%'
          or coalesce(f.documento, '') like '%' || btrim(p_busca) || '%')
   order by f.nome
   limit 100;
$$;

-- Cadastra um terceiro. Qualquer funcionario identificado pode, porque quem
-- esta na PTA as 6h da manha precisa registrar a empresa na hora.
-- Nome repetido nao cria duplicata: devolve o cadastro existente.
create or replace function public.fn_fornecedor_criar(
  p_token uuid, p_nome text, p_documento text default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_func public.funcionarios;
  v_forn public.fornecedores;
  v_nome text := btrim(coalesce(p_nome, ''));
begin
  v_func := public.fn__sessao(p_token);

  if char_length(v_nome) < 2 or char_length(v_nome) > 80 then
    raise exception 'FORNECEDOR_NOME_INVALIDO' using errcode = 'P0001';
  end if;

  select * into v_forn from public.fornecedores
   where lower(btrim(nome)) = lower(v_nome);

  if v_forn.id is not null then
    if not v_forn.ativo then
      update public.fornecedores set ativo = true where id = v_forn.id
      returning * into v_forn;
    end if;
    return jsonb_build_object('id', v_forn.id, 'nome', v_forn.nome, 'ja_existia', true);
  end if;

  insert into public.fornecedores (nome, documento, criado_por)
  values (v_nome, nullif(btrim(coalesce(p_documento, '')), ''), v_func.id)
  returning * into v_forn;

  perform public.fn__auditar(
    v_func.id, null, 'FORNECEDOR_CRIADO', 'FORNECEDOR', v_forn.id::text,
    null, jsonb_build_object('nome', v_forn.nome, 'documento', v_forn.documento),
    'Terceiro cadastrado por ' || v_func.nome);

  return jsonb_build_object('id', v_forn.id, 'nome', v_forn.nome, 'ja_existia', false);
end $$;

-- =============================================================================
-- 13) CANCELAMENTO DE USO EM ABERTO (administracao)
-- =============================================================================

-- Encerra um uso que ficou esquecido em aberto. NAO e finalizar: nao existe
-- fim_efetivo, porque ninguem observou o fim real. Registrar um horario
-- inventado como "efetivo" corromperia exatamente o dado que o sistema existe
-- para guardar.
create or replace function public.fn_admin_cancelar_uso(
  p_token uuid, p_uso_id uuid, p_motivo text default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_func   public.funcionarios;
  v_uso    public.usos;
  v_motivo text := nullif(btrim(coalesce(p_motivo, '')), '');
begin
  v_func := public.fn__sessao(p_token);

  select * into v_uso from public.usos where id = p_uso_id;
  if v_uso.id is null then
    raise exception 'USO_NAO_ENCONTRADO' using errcode = 'P0001';
  end if;
  if v_uso.status <> 'EM_USO' then
    raise exception 'USO_NAO_CANCELAVEL' using errcode = 'P0001';
  end if;

  perform public.fn__exigir_gestao(v_func, v_uso.funcionario_id);

  update public.usos
     set status = 'CANCELADO',
         cancelado_em = now(),
         cancelado_por = v_func.id,
         motivo_cancelamento = coalesce(v_motivo, 'Cancelado pela administracao')
   where id = v_uso.id;

  perform public.fn__auditar(
    v_func.id, v_uso.pta_id, 'USO_CANCELADO', 'USO', v_uso.id::text,
    jsonb_build_object(
      'status', 'EM_USO',
      'inicio_efetivo', to_char(v_uso.inicio_efetivo at time zone public.fn_tz(), 'YYYY-MM-DD HH24:MI'),
      'fim_pretendido', to_char(v_uso.fim_pretendido at time zone public.fn_tz(), 'YYYY-MM-DD HH24:MI')),
    jsonb_build_object('status', 'CANCELADO', 'motivo', coalesce(v_motivo, 'Cancelado pela administracao')),
    'Uso em aberto cancelado pela administracao. Sem fim efetivo: o encerramento real nao foi observado.');

  return jsonb_build_object('ok', true);
end $$;

-- =============================================================================
-- 14) LIMITE DE HORAS DE UM USO EM ABERTO
-- =============================================================================

-- Definido por qualquer ADMIN (diferente do limite de matriculas, que e do
-- MASTER). Vale na abertura do uso e serve de referencia para o painel
-- destacar os usos que passaram do teto.
create or replace function public.fn_admin_definir_max_horas_uso(
  p_token uuid, p_horas int
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_func  public.funcionarios;
  v_antes text;
begin
  v_func := public.fn__sessao(p_token);
  perform public.fn__exigir_admin(v_func);

  if p_horas is null or p_horas < 1 or p_horas > 24 then
    raise exception 'HORAS_INVALIDAS' using errcode = 'P0001';
  end if;

  select valor into v_antes from public.configuracao where chave = 'max_horas_uso_aberto';

  update public.configuracao
     set valor = p_horas::text, atualizado_em = now(), atualizado_por = v_func.id
   where chave = 'max_horas_uso_aberto';

  perform public.fn__auditar(
    v_func.id, null, 'CONFIGURACAO_ALTERADA', 'CONFIGURACAO', 'max_horas_uso_aberto',
    jsonb_build_object('horas', v_antes),
    jsonb_build_object('horas', p_horas::text),
    'Limite de horas de uso em aberto alterado por ' || v_func.nome);

  return jsonb_build_object('ok', true, 'horas', p_horas);
end $$;

-- =============================================================================
-- 15) AGENDAMENTOS CICLICOS
-- =============================================================================

-- Materializa as ocorrencias de uma regra ciclica como agendamentos comuns.
-- Datas ja ocupadas sao PULADAS em vez de derrubar a operacao inteira: numa
-- regra de 90 dias, um unico conflito nao pode impedir os outros 89.
create or replace function public.fn__ciclico_gerar(
  p_ciclico_id uuid, p_ate date, p_ator uuid
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_c       public.agendamentos_ciclicos;
  v_dia     date;
  v_inicio  timestamptz;
  v_fim     timestamptz;
  v_de      date;
  v_ate     date := p_ate;
  v_criados int := 0;
  v_pulados int := 0;
begin
  select * into v_c from public.agendamentos_ciclicos where id = p_ciclico_id;
  if v_c.id is null or not v_c.ativo then
    return jsonb_build_object('criados', 0, 'pulados', 0);
  end if;

  -- Comeca de onde parou, nunca antes de hoje nem antes do inicio da regra
  v_de := greatest(
            coalesce(v_c.gerado_ate + 1, v_c.data_inicio),
            v_c.data_inicio,
            (now() at time zone public.fn_tz())::date);

  if v_c.data_fim is not null then
    v_ate := least(v_ate, v_c.data_fim);
  end if;

  v_dia := v_de;
  while v_dia <= v_ate loop
    -- O laco caminha por datas reais, entao 'todo dia 31' simplesmente nao casa
    -- em fevereiro: o mes e pulado, sem empurrar a ocorrencia para o dia 1.
    if (v_c.tipo = 'DIAS_SEMANA'
        and extract(dow from v_dia)::smallint = any(v_c.dias_semana))
       or (v_c.tipo = 'INTERVALO_DIAS'
        and ((v_dia - v_c.data_inicio) % v_c.intervalo_dias) = 0)
       or (v_c.tipo = 'DIA_DO_MES'
        and extract(day from v_dia)::smallint = v_c.dia_do_mes)
    then
      v_inicio := public.fn__local_para_utc(v_dia, v_c.hora_inicio);
      v_fim    := public.fn__local_para_utc(v_dia, v_c.hora_fim);

      -- Nao gera ocorrencia no passado
      if v_inicio > now() then
        begin
          insert into public.agendamentos (
            pta_id, funcionario_id, data_ref, inicio_planejado, fim_planejado,
            fornecedor_id, ciclico_id, motivo_status)
          values (v_c.pta_id, v_c.funcionario_id, v_dia, v_inicio, v_fim,
                  v_c.fornecedor_id, v_c.id, 'Gerado por agendamento ciclico');
          v_criados := v_criados + 1;
        exception
          when exclusion_violation then
            v_pulados := v_pulados + 1;   -- horario ja ocupado nesta PTA
        end;
      end if;
    end if;
    v_dia := v_dia + 1;
  end loop;

  update public.agendamentos_ciclicos
     set gerado_ate = greatest(coalesce(gerado_ate, v_ate), v_ate)
   where id = v_c.id;

  perform public.fn__auditar(
    p_ator, v_c.pta_id, 'CICLICO_GERADO', 'CICLICO', v_c.id::text,
    null,
    jsonb_build_object('ate', v_ate, 'criados', v_criados, 'pulados', v_pulados),
    'Ocorrencias geradas para a regra ciclica');

  return jsonb_build_object('criados', v_criados, 'pulados', v_pulados, 'ate', v_ate);
end $$;

drop function if exists public.fn_ciclico_criar(
  uuid, uuid, uuid, time, time, text, smallint[], int, date, date, uuid);

create or replace function public.fn_ciclico_criar(
  p_token          uuid,
  p_pta_id         uuid,
  p_funcionario_id uuid,
  p_hora_inicio    time,
  p_hora_fim       time,
  p_tipo           text,
  p_dias_semana    smallint[] default null,
  p_intervalo_dias int default null,
  p_dia_do_mes     int default null,
  p_data_inicio    date default null,
  p_data_fim       date default null,
  p_fornecedor_id  uuid default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_func      public.funcionarios;
  v_c         public.agendamentos_ciclicos;
  v_inicio    date := coalesce(p_data_inicio, (now() at time zone public.fn_tz())::date);
  v_horizonte int;
  v_res       jsonb;
begin
  v_func := public.fn__sessao(p_token);
  perform public.fn__exigir_admin(v_func);

  if not exists (select 1 from public.ptas where id = p_pta_id and ativo) then
    raise exception 'PTA_NAO_ENCONTRADA' using errcode = 'P0001';
  end if;

  -- O agendamento fica em nome de um funcionario JA CADASTRADO e ativo.
  if not exists (select 1 from public.funcionarios where id = p_funcionario_id and ativo) then
    raise exception 'FUNCIONARIO_NAO_ENCONTRADO' using errcode = 'P0001';
  end if;

  if p_hora_fim <= p_hora_inicio then
    raise exception 'HORARIO_FINAL_ANTERIOR' using errcode = 'P0001';
  end if;

  if p_tipo not in ('DIAS_SEMANA', 'INTERVALO_DIAS', 'DIA_DO_MES') then
    raise exception 'CICLO_TIPO_INVALIDO' using errcode = 'P0001';
  end if;
  if p_tipo = 'DIA_DO_MES'
     and (p_dia_do_mes is null or p_dia_do_mes < 1 or p_dia_do_mes > 31) then
    raise exception 'CICLO_DIA_DO_MES_INVALIDO' using errcode = 'P0001';
  end if;
  if p_tipo = 'DIAS_SEMANA'
     and (p_dias_semana is null or array_length(p_dias_semana, 1) is null) then
    raise exception 'CICLO_SEM_DIAS' using errcode = 'P0001';
  end if;
  if p_tipo = 'INTERVALO_DIAS'
     and (p_intervalo_dias is null or p_intervalo_dias < 1) then
    raise exception 'CICLO_INTERVALO_INVALIDO' using errcode = 'P0001';
  end if;
  if p_data_fim is not null and p_data_fim < v_inicio then
    raise exception 'CICLO_PERIODO_INVALIDO' using errcode = 'P0001';
  end if;
  if p_fornecedor_id is not null
     and not exists (select 1 from public.fornecedores where id = p_fornecedor_id and ativo) then
    raise exception 'FORNECEDOR_NAO_ENCONTRADO' using errcode = 'P0001';
  end if;

  insert into public.agendamentos_ciclicos (
    pta_id, funcionario_id, hora_inicio, hora_fim, tipo,
    dias_semana, intervalo_dias, dia_do_mes, data_inicio, data_fim,
    fornecedor_id, criado_por)
  values (
    p_pta_id, p_funcionario_id, p_hora_inicio, p_hora_fim, p_tipo,
    case when p_tipo = 'DIAS_SEMANA'    then p_dias_semana end,
    case when p_tipo = 'INTERVALO_DIAS' then p_intervalo_dias::smallint end,
    case when p_tipo = 'DIA_DO_MES'     then p_dia_do_mes::smallint end,
    v_inicio, p_data_fim, p_fornecedor_id, v_func.id)
  returning * into v_c;

  perform public.fn__auditar(
    v_func.id, p_pta_id, 'CICLICO_CRIADO', 'CICLICO', v_c.id::text,
    null,
    jsonb_build_object(
      'tipo', p_tipo, 'dias_semana', p_dias_semana, 'intervalo_dias', p_intervalo_dias,
      'dia_do_mes', p_dia_do_mes,
      'hora_inicio', p_hora_inicio, 'hora_fim', p_hora_fim,
      'data_inicio', v_inicio, 'data_fim', p_data_fim,
      'funcionario_id', p_funcionario_id),
    'Agendamento ciclico criado por ' || v_func.nome);

  select coalesce(nullif(valor, '')::int, 365) into v_horizonte
    from public.configuracao where chave = 'horizonte_ciclico_dias';

  v_res := public.fn__ciclico_gerar(
             v_c.id,
             (now() at time zone public.fn_tz())::date + coalesce(v_horizonte, 365),
             v_func.id);

  return jsonb_build_object(
    'id', v_c.id,
    'criados', v_res->'criados',
    'pulados', v_res->'pulados',
    'ate', v_res->'ate');
end $$;

create or replace function public.fn_ciclico_listar(p_token uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_func public.funcionarios;
begin
  v_func := public.fn__sessao(p_token);
  perform public.fn__exigir_admin(v_func);

  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', c.id,
             'pta', p.codigo,
             'pta_id', c.pta_id,
             'funcionario', f.nome,
             'funcionario_id', c.funcionario_id,
             'matricula', f.matricula,
             'fornecedor', fo.nome,
             'hora_inicio', to_char(c.hora_inicio, 'HH24:MI'),
             'hora_fim', to_char(c.hora_fim, 'HH24:MI'),
             'tipo', c.tipo,
             'dias_semana', c.dias_semana,
             'intervalo_dias', c.intervalo_dias,
             'dia_do_mes', c.dia_do_mes,
             'data_inicio', to_char(c.data_inicio, 'DD/MM/YYYY'),
             'data_fim', case when c.data_fim is null then null else to_char(c.data_fim, 'DD/MM/YYYY') end,
             'gerado_ate', case when c.gerado_ate is null then null else to_char(c.gerado_ate, 'DD/MM/YYYY') end,
             'ativo', c.ativo,
             'criado_por', cp.nome,
             'do_master', (cp.papel = 'ADMIN_MASTER'),
             'ocorrencias_futuras', (
               select count(*) from public.agendamentos a
                where a.ciclico_id = c.id and a.status = 'AGENDADO' and a.fim_planejado > now())
           ) order by c.ativo desc, p.codigo, c.hora_inicio), '[]'::jsonb)
      from public.agendamentos_ciclicos c
      join public.ptas p               on p.id = c.pta_id
      join public.funcionarios f       on f.id = c.funcionario_id
      join public.funcionarios cp      on cp.id = c.criado_por
      left join public.fornecedores fo on fo.id = c.fornecedor_id);
end $$;

-- Desativa a regra. Opcionalmente cancela as ocorrencias futuras ja geradas -
-- as passadas permanecem, porque sao historico.
create or replace function public.fn_ciclico_desativar(
  p_token uuid, p_ciclico_id uuid, p_cancelar_futuros boolean default true
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_func       public.funcionarios;
  v_c          public.agendamentos_ciclicos;
  v_cancelados int := 0;
  v_ag         record;
begin
  v_func := public.fn__sessao(p_token);
  perform public.fn__exigir_admin(v_func);

  select * into v_c from public.agendamentos_ciclicos where id = p_ciclico_id;
  if v_c.id is null then
    raise exception 'CICLICO_NAO_ENCONTRADO' using errcode = 'P0001';
  end if;

  -- Regra criada pelo administrador principal so ele proprio desativa
  perform public.fn__exigir_gestao(v_func, v_c.criado_por);

  update public.agendamentos_ciclicos
     set ativo = false, desativado_em = now(), desativado_por = v_func.id
   where id = v_c.id;

  if p_cancelar_futuros then
    for v_ag in
      select * from public.agendamentos
       where ciclico_id = v_c.id and status = 'AGENDADO' and inicio_planejado > now()
    loop
      update public.agendamentos
         set status = 'CANCELADO', cancelado_em = now(),
             motivo_status = 'Regra ciclica desativada por ' || v_func.nome
       where id = v_ag.id;

      perform public.fn__auditar(
        v_func.id, v_ag.pta_id, 'AGENDAMENTO_CANCELADO', 'AGENDAMENTO', v_ag.id::text,
        jsonb_build_object('status', 'AGENDADO'),
        jsonb_build_object('status', 'CANCELADO', 'motivo', 'regra ciclica desativada'),
        'Ocorrencia cancelada junto com a desativacao da regra ciclica');

      v_cancelados := v_cancelados + 1;
    end loop;
  end if;

  perform public.fn__auditar(
    v_func.id, v_c.pta_id, 'CICLICO_DESATIVADO', 'CICLICO', v_c.id::text,
    jsonb_build_object('ativo', true),
    jsonb_build_object('ativo', false, 'ocorrencias_canceladas', v_cancelados),
    'Agendamento ciclico desativado por ' || v_func.nome);

  return jsonb_build_object('ok', true, 'ocorrencias_canceladas', v_cancelados);
end $$;

-- Estende as ocorrencias ate o horizonte configurado. Sem agendador no plano
-- gratuito do Supabase, quem empurra o horizonte e o administrador, por botao.
create or replace function public.fn_ciclico_estender(p_token uuid, p_ciclico_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_func      public.funcionarios;
  v_c         public.agendamentos_ciclicos;
  v_horizonte int;
begin
  v_func := public.fn__sessao(p_token);
  perform public.fn__exigir_admin(v_func);

  select * into v_c from public.agendamentos_ciclicos where id = p_ciclico_id;
  if v_c.id is null then
    raise exception 'CICLICO_NAO_ENCONTRADO' using errcode = 'P0001';
  end if;
  if not v_c.ativo then
    raise exception 'CICLICO_INATIVO' using errcode = 'P0001';
  end if;

  perform public.fn__exigir_gestao(v_func, v_c.criado_por);

  select coalesce(nullif(valor, '')::int, 365) into v_horizonte
    from public.configuracao where chave = 'horizonte_ciclico_dias';

  return public.fn__ciclico_gerar(
           v_c.id,
           (now() at time zone public.fn_tz())::date + coalesce(v_horizonte, 365),
           v_func.id);
end $$;

-- =============================================================================
-- 16) REDEFINICAO DE PIN
-- =============================================================================

-- Troca do proprio PIN. Exige o PIN atual: sem isso, uma sessao esquecida
-- aberta no celular deixaria qualquer um trocar a senha do dono.
create or replace function public.fn_perfil_trocar_pin(
  p_token uuid, p_pin_atual text, p_pin_novo text
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_func public.funcionarios;
begin
  v_func := public.fn__sessao(p_token);

  if coalesce(p_pin_novo, '') !~ '^[0-9]{4,10}$' then
    raise exception 'PIN_FORMATO' using errcode = 'P0001';
  end if;

  select * into v_func from public.funcionarios where id = v_func.id;

  if v_func.pin_hash <> crypt(coalesce(p_pin_atual, ''), v_func.pin_hash) then
    raise exception 'PIN_ATUAL_INCORRETO' using errcode = 'P0001';
  end if;

  if p_pin_novo = p_pin_atual then
    raise exception 'PIN_IGUAL_AO_ATUAL' using errcode = 'P0001';
  end if;

  update public.funcionarios
     set pin_hash = crypt(p_pin_novo, gen_salt('bf', 10)),
         pin_provisorio = false,
         pin_alterado_em = now()
   where id = v_func.id;

  -- O PIN em si nunca aparece na auditoria - nem o antigo, nem o novo.
  perform public.fn__auditar(
    v_func.id, null, 'PIN_ALTERADO', 'FUNCIONARIO', v_func.id::text,
    null, null, 'PIN alterado pelo proprio colaborador');

  return jsonb_build_object('ok', true);
end $$;

-- Reset feito pela administracao, para quem esqueceu o PIN.
-- O PIN nasce PROVISORIO: a pessoa entra com ele e e obrigada a trocar. Assim o
-- administrador nao segue conhecendo a senha de ninguem.
create or replace function public.fn_admin_resetar_pin(
  p_token uuid, p_funcionario_id uuid, p_pin_novo text
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_func public.funcionarios;
  v_alvo public.funcionarios;
begin
  v_func := public.fn__sessao(p_token);
  perform public.fn__exigir_admin(v_func);

  if coalesce(p_pin_novo, '') !~ '^[0-9]{4,10}$' then
    raise exception 'PIN_FORMATO' using errcode = 'P0001';
  end if;

  select * into v_alvo from public.funcionarios where id = p_funcionario_id;
  if v_alvo.id is null then
    raise exception 'FUNCIONARIO_NAO_ENCONTRADO' using errcode = 'P0001';
  end if;

  -- O PIN do administrador principal so ele proprio troca.
  if v_alvo.papel = 'ADMIN_MASTER' and v_func.papel <> 'ADMIN_MASTER' then
    raise exception 'ADMIN_MASTER_PROTEGIDO' using errcode = 'P0001';
  end if;

  update public.funcionarios
     set pin_hash = crypt(p_pin_novo, gen_salt('bf', 10)),
         pin_provisorio = true,
         pin_alterado_em = now(),
         tentativas_falhas = 0,
         bloqueado_ate = null
   where id = v_alvo.id;

  -- Sessoes abertas do alvo caem: se alguem estava usando a conta, para aqui.
  delete from public.sessoes where funcionario_id = v_alvo.id;

  perform public.fn__auditar(
    v_func.id, null, 'PIN_RESETADO', 'FUNCIONARIO', v_alvo.id::text,
    null, jsonb_build_object('provisorio', true),
    'PIN redefinido por ' || v_func.nome || '. Troca obrigatoria no proximo acesso.');

  return jsonb_build_object('ok', true);
end $$;

-- =============================================================================
-- 17) PTAs GERENCIADAS PELA ADMINISTRACAO
-- =============================================================================

-- Aceita 'PTA-905', 'pta 905' ou simplesmente '905'.
create or replace function public.fn__pta_codigo(p_bruto text)
returns text
language plpgsql immutable as $$
declare
  v text := upper(btrim(coalesce(p_bruto, '')));
  v_num text;
begin
  v_num := regexp_replace(v, '[^0-9]', '', 'g');
  if v_num = '' or char_length(v_num) < 3 or char_length(v_num) > 4 then
    raise exception 'PTA_CODIGO_INVALIDO' using errcode = 'P0001';
  end if;
  return 'PTA-' || v_num;
end $$;

create or replace function public.fn_admin_listar_ptas(p_token uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_func public.funcionarios;
begin
  v_func := public.fn__sessao(p_token);
  perform public.fn__exigir_admin(v_func);

  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', p.id,
             'codigo', p.codigo,
             'descricao', p.descricao,
             'local', p.local,
             'ativo', p.ativo,
             'em_uso', exists (select 1 from public.usos u
                                where u.pta_id = p.id and u.status = 'EM_USO'),
             'programacoes_futuras', (
               select count(*) from public.agendamentos a
                where a.pta_id = p.id and a.status = 'AGENDADO' and a.fim_planejado > now()),
             -- Sem historico nenhum a PTA pode ser apagada de verdade.
             'pode_excluir', not exists (select 1 from public.usos u where u.pta_id = p.id)
                         and not exists (select 1 from public.agendamentos a where a.pta_id = p.id)
                         and not exists (select 1 from public.agendamentos_ciclicos c where c.pta_id = p.id)
           ) order by p.ativo desc, p.codigo), '[]'::jsonb)
      from public.ptas p);
end $$;

create or replace function public.fn_pta_criar(
  p_token uuid, p_codigo text, p_descricao text default null, p_local text default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_func   public.funcionarios;
  v_pta    public.ptas;
  v_codigo text;
begin
  v_func := public.fn__sessao(p_token);
  perform public.fn__exigir_admin(v_func);

  v_codigo := public.fn__pta_codigo(p_codigo);

  if exists (select 1 from public.ptas where codigo = v_codigo) then
    raise exception 'PTA_CODIGO_DUPLICADO' using errcode = 'P0001';
  end if;

  insert into public.ptas (codigo, descricao, local, criado_por)
  values (v_codigo,
          nullif(btrim(coalesce(p_descricao, '')), ''),
          nullif(btrim(coalesce(p_local, '')), ''),
          v_func.id)
  returning * into v_pta;

  perform public.fn__auditar(
    v_func.id, v_pta.id, 'PTA_CRIADA', 'PTA', v_pta.id::text,
    null, jsonb_build_object('codigo', v_pta.codigo, 'descricao', v_pta.descricao, 'local', v_pta.local),
    'PTA cadastrada por ' || v_func.nome);

  return jsonb_build_object('id', v_pta.id, 'codigo', v_pta.codigo);
end $$;

create or replace function public.fn_pta_alterar(
  p_token uuid, p_pta_id uuid, p_codigo text, p_descricao text default null, p_local text default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_func   public.funcionarios;
  v_pta    public.ptas;
  v_codigo text;
begin
  v_func := public.fn__sessao(p_token);
  perform public.fn__exigir_admin(v_func);

  select * into v_pta from public.ptas where id = p_pta_id;
  if v_pta.id is null then
    raise exception 'PTA_NAO_ENCONTRADA' using errcode = 'P0001';
  end if;

  v_codigo := public.fn__pta_codigo(p_codigo);

  if exists (select 1 from public.ptas where codigo = v_codigo and id <> p_pta_id) then
    raise exception 'PTA_CODIGO_DUPLICADO' using errcode = 'P0001';
  end if;

  update public.ptas
     set codigo    = v_codigo,
         descricao = nullif(btrim(coalesce(p_descricao, '')), ''),
         local     = nullif(btrim(coalesce(p_local, '')), '')
   where id = p_pta_id;

  perform public.fn__auditar(
    v_func.id, v_pta.id, 'PTA_ALTERADA', 'PTA', v_pta.id::text,
    jsonb_build_object('codigo', v_pta.codigo, 'descricao', v_pta.descricao, 'local', v_pta.local),
    jsonb_build_object('codigo', v_codigo,
                       'descricao', nullif(btrim(coalesce(p_descricao, '')), ''),
                       'local', nullif(btrim(coalesce(p_local, '')), '')),
    'PTA alterada por ' || v_func.nome);

  return jsonb_build_object('ok', true, 'codigo', v_codigo);
end $$;

-- Habilita/desabilita. Desabilitada, a PTA some das telas de escolha, mas o
-- historico dela continua inteiro.
create or replace function public.fn_pta_definir_ativo(
  p_token uuid, p_pta_id uuid, p_ativo boolean
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_func public.funcionarios;
  v_pta  public.ptas;
begin
  v_func := public.fn__sessao(p_token);
  perform public.fn__exigir_admin(v_func);

  select * into v_pta from public.ptas where id = p_pta_id;
  if v_pta.id is null then
    raise exception 'PTA_NAO_ENCONTRADA' using errcode = 'P0001';
  end if;

  -- Desabilitar uma PTA com uso aberto deixaria alguem preso: alem de sumir da
  -- tela, a pessoa ainda precisa finalizar o que comecou.
  if not p_ativo and exists (
       select 1 from public.usos where pta_id = p_pta_id and status = 'EM_USO') then
    raise exception 'PTA_COM_USO_ABERTO' using errcode = 'P0001';
  end if;

  update public.ptas
     set ativo = p_ativo,
         desativado_em  = case when p_ativo then null else now() end,
         desativado_por = case when p_ativo then null else v_func.id end
   where id = p_pta_id;

  perform public.fn__auditar(
    v_func.id, v_pta.id,
    case when p_ativo then 'PTA_REATIVADA' else 'PTA_DESATIVADA' end,
    'PTA', v_pta.id::text,
    jsonb_build_object('ativo', v_pta.ativo),
    jsonb_build_object('ativo', p_ativo),
    case when p_ativo then 'PTA habilitada por ' else 'PTA desabilitada por ' end || v_func.nome);

  return jsonb_build_object('ok', true, 'ativo', p_ativo);
end $$;

-- Exclusao de verdade, permitida APENAS enquanto a PTA nao tem historico.
-- Com uso ou programacao registrada, apagar destruiria o passado - nesse caso a
-- saida e desabilitar.
create or replace function public.fn_pta_excluir(p_token uuid, p_pta_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_func public.funcionarios;
  v_pta  public.ptas;
begin
  v_func := public.fn__sessao(p_token);
  perform public.fn__exigir_admin(v_func);

  select * into v_pta from public.ptas where id = p_pta_id;
  if v_pta.id is null then
    raise exception 'PTA_NAO_ENCONTRADA' using errcode = 'P0001';
  end if;

  if exists (select 1 from public.usos where pta_id = p_pta_id)
     or exists (select 1 from public.agendamentos where pta_id = p_pta_id)
     or exists (select 1 from public.agendamentos_ciclicos where pta_id = p_pta_id) then
    raise exception 'PTA_COM_HISTORICO' using errcode = 'P0001';
  end if;

  perform public.fn__auditar(
    v_func.id, null, 'PTA_EXCLUIDA', 'PTA', v_pta.id::text,
    jsonb_build_object('codigo', v_pta.codigo, 'descricao', v_pta.descricao, 'local', v_pta.local),
    null, 'PTA excluida por ' || v_func.nome || ' (nunca teve uso nem programacao)');

  delete from public.ptas where id = p_pta_id;

  return jsonb_build_object('ok', true);
end $$;

-- =============================================================================
-- 18) MATRICULAS RESERVADAS (somente ADMIN_MASTER)
-- =============================================================================

create or replace function public.fn_admin_reservadas(p_token uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_func public.funcionarios;
begin
  v_func := public.fn__sessao(p_token);
  perform public.fn__exigir_master(v_func);

  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'matricula', r.matricula,
             'papel', r.papel,
             'observacao', r.observacao,
             -- Reserva ja usada: existe colaborador ATIVO com essa matricula.
             'em_uso_por', (select f.nome from public.funcionarios f
                             where f.matricula = r.matricula and f.ativo limit 1)
           ) order by r.matricula), '[]'::jsonb)
      from public.matriculas_reservadas r);
end $$;

-- Cria ou atualiza uma reserva. A matricula passa pela mesma normalizacao do
-- cadastro ('591' vira '0591'), senao a reserva nunca casaria com a pessoa.
create or replace function public.fn_reservada_salvar(
  p_token uuid, p_matricula text, p_papel text, p_observacao text default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_func  public.funcionarios;
  v_matr  text := btrim(coalesce(p_matricula, ''));
  v_antes public.matriculas_reservadas;
begin
  v_func := public.fn__sessao(p_token);
  perform public.fn__exigir_master(v_func);

  if v_matr !~ '^[0-9]{1,10}$' then
    raise exception 'MATRICULA_FORMATO' using errcode = 'P0001';
  end if;
  if char_length(v_matr) < 4 then
    v_matr := lpad(v_matr, 4, '0');
  end if;

  if p_papel not in ('ADMIN', 'ADMIN_MASTER') then
    raise exception 'PAPEL_INVALIDO' using errcode = 'P0001';
  end if;

  select * into v_antes from public.matriculas_reservadas where matricula = v_matr;

  insert into public.matriculas_reservadas (matricula, papel, observacao)
  values (v_matr, p_papel, nullif(btrim(coalesce(p_observacao, '')), ''))
  on conflict (matricula) do update
    set papel = excluded.papel, observacao = excluded.observacao;

  perform public.fn__auditar(
    v_func.id, null,
    case when v_antes.matricula is null then 'RESERVADA_CRIADA' else 'RESERVADA_ALTERADA' end,
    'RESERVADA', v_matr,
    case when v_antes.matricula is null then null
         else jsonb_build_object('papel', v_antes.papel, 'observacao', v_antes.observacao) end,
    jsonb_build_object('papel', p_papel, 'observacao', nullif(btrim(coalesce(p_observacao, '')), '')),
    'Matricula reservada definida por ' || v_func.nome);

  return jsonb_build_object('ok', true, 'matricula', v_matr);
end $$;

create or replace function public.fn_reservada_excluir(p_token uuid, p_matricula text)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_func  public.funcionarios;
  v_antes public.matriculas_reservadas;
  v_matr  text := btrim(coalesce(p_matricula, ''));
begin
  v_func := public.fn__sessao(p_token);
  perform public.fn__exigir_master(v_func);

  if char_length(v_matr) < 4 then
    v_matr := lpad(v_matr, 4, '0');
  end if;

  select * into v_antes from public.matriculas_reservadas where matricula = v_matr;
  if v_antes.matricula is null then
    raise exception 'RESERVADA_NAO_ENCONTRADA' using errcode = 'P0001';
  end if;

  delete from public.matriculas_reservadas where matricula = v_matr;

  -- Apagar a reserva NAO rebaixa quem ja se cadastrou com ela: o papel de uma
  -- pessoa se muda pela tela de papeis, nao por efeito colateral.
  perform public.fn__auditar(
    v_func.id, null, 'RESERVADA_EXCLUIDA', 'RESERVADA', v_matr,
    jsonb_build_object('papel', v_antes.papel, 'observacao', v_antes.observacao),
    null, 'Reserva removida por ' || v_func.nome);

  return jsonb_build_object('ok', true);
end $$;

-- =============================================================================
-- 19) HORIZONTE DOS CICLICOS (somente ADMIN_MASTER)
-- =============================================================================

create or replace function public.fn_admin_definir_horizonte_ciclico(
  p_token uuid, p_dias int
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_func  public.funcionarios;
  v_antes text;
begin
  v_func := public.fn__sessao(p_token);
  perform public.fn__exigir_master(v_func);

  if p_dias is null or p_dias < 7 or p_dias > 1095 then
    raise exception 'HORIZONTE_INVALIDO' using errcode = 'P0001';
  end if;

  select valor into v_antes from public.configuracao where chave = 'horizonte_ciclico_dias';

  update public.configuracao
     set valor = p_dias::text, atualizado_em = now(), atualizado_por = v_func.id
   where chave = 'horizonte_ciclico_dias';

  perform public.fn__auditar(
    v_func.id, null, 'CONFIGURACAO_ALTERADA', 'CONFIGURACAO', 'horizonte_ciclico_dias',
    jsonb_build_object('dias', v_antes), jsonb_build_object('dias', p_dias::text),
    'Horizonte de geracao dos ciclicos alterado por ' || v_func.nome);

  return jsonb_build_object('ok', true, 'dias', p_dias);
end $$;

-- =============================================================================
-- 20) AVISOS
-- =============================================================================

-- Avisos que alcancam quem esta logado, para o popup pos-login.
-- Sem destino cadastrado o aviso e geral; com destinos, vale a uniao entre
-- setores e pessoas escolhidas.
create or replace function public.fn_avisos_para_mim(p_token uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_func public.funcionarios;
begin
  v_func := public.fn__sessao(p_token);

  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', a.id,
             'titulo', a.titulo,
             'mensagem', a.mensagem,
             'autor', f.nome,
             'criado_em', to_char(a.criado_em at time zone public.fn_tz(), 'DD/MM/YYYY HH24:MI'),
             'fim_em', case when a.fim_em is null then null
                            else to_char(a.fim_em at time zone public.fn_tz(), 'DD/MM/YYYY HH24:MI') end
           ) order by a.criado_em desc), '[]'::jsonb)
      from public.avisos a
      join public.funcionarios f on f.id = a.criado_por
     where a.ativo
       and (a.inicio_em is null or a.inicio_em <= now())
       and (a.fim_em    is null or a.fim_em    >  now())
       and (
             (    not exists (select 1 from public.avisos_setores      s where s.aviso_id = a.id)
              and not exists (select 1 from public.avisos_funcionarios d where d.aviso_id = a.id))
          or exists (select 1 from public.avisos_setores s
                      where s.aviso_id = a.id and s.setor_id = v_func.setor_id)
          or exists (select 1 from public.avisos_funcionarios d
                      where d.aviso_id = a.id and d.funcionario_id = v_func.id)
           ));
end $$;

create or replace function public.fn_aviso_criar(
  p_token      uuid,
  p_titulo     text,
  p_mensagem   text,
  p_setores    uuid[] default null,
  p_pessoas    uuid[] default null,
  p_inicio_em  timestamptz default null,
  p_fim_em     timestamptz default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_func  public.funcionarios;
  v_aviso public.avisos;
  v_tit   text := btrim(coalesce(p_titulo, ''));
  v_msg   text := btrim(coalesce(p_mensagem, ''));
begin
  v_func := public.fn__sessao(p_token);
  perform public.fn__exigir_admin(v_func);

  if char_length(v_tit) < 3 or char_length(v_tit) > 80 then
    raise exception 'AVISO_TITULO_INVALIDO' using errcode = 'P0001';
  end if;
  if char_length(v_msg) < 3 or char_length(v_msg) > 600 then
    raise exception 'AVISO_MENSAGEM_INVALIDA' using errcode = 'P0001';
  end if;
  if p_fim_em is not null and p_fim_em <= coalesce(p_inicio_em, now()) then
    raise exception 'AVISO_PRAZO_INVALIDO' using errcode = 'P0001';
  end if;

  insert into public.avisos (titulo, mensagem, inicio_em, fim_em, criado_por)
  values (v_tit, v_msg, p_inicio_em, p_fim_em, v_func.id)
  returning * into v_aviso;

  if p_setores is not null and array_length(p_setores, 1) > 0 then
    insert into public.avisos_setores (aviso_id, setor_id)
    select v_aviso.id, s.id from public.setores s where s.id = any(p_setores)
    on conflict do nothing;
  end if;

  if p_pessoas is not null and array_length(p_pessoas, 1) > 0 then
    insert into public.avisos_funcionarios (aviso_id, funcionario_id)
    select v_aviso.id, f.id from public.funcionarios f where f.id = any(p_pessoas)
    on conflict do nothing;
  end if;

  perform public.fn__auditar(
    v_func.id, null, 'AVISO_CRIADO', 'AVISO', v_aviso.id::text,
    null,
    jsonb_build_object('titulo', v_tit,
                       'setores', coalesce(array_length(p_setores, 1), 0),
                       'pessoas', coalesce(array_length(p_pessoas, 1), 0),
                       'fim_em', p_fim_em),
    'Aviso criado por ' || v_func.nome);

  return jsonb_build_object('id', v_aviso.id);
end $$;

create or replace function public.fn_aviso_listar(p_token uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_func public.funcionarios;
begin
  v_func := public.fn__sessao(p_token);
  perform public.fn__exigir_admin(v_func);

  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', a.id,
             'titulo', a.titulo,
             'mensagem', a.mensagem,
             'ativo', a.ativo,
             'autor', f.nome,
             'do_master', (f.papel = 'ADMIN_MASTER'),
             'criado_em', to_char(a.criado_em at time zone public.fn_tz(), 'DD/MM/YYYY HH24:MI'),
             'inicio_em', case when a.inicio_em is null then null
                               else to_char(a.inicio_em at time zone public.fn_tz(), 'DD/MM/YYYY HH24:MI') end,
             'fim_em', case when a.fim_em is null then null
                            else to_char(a.fim_em at time zone public.fn_tz(), 'DD/MM/YYYY HH24:MI') end,
             'vigente', (a.ativo
                         and (a.inicio_em is null or a.inicio_em <= now())
                         and (a.fim_em    is null or a.fim_em    >  now())),
             'setores', (select coalesce(jsonb_agg(s.nome order by s.nome), '[]'::jsonb)
                           from public.avisos_setores x
                           join public.setores s on s.id = x.setor_id
                          where x.aviso_id = a.id),
             'pessoas', (select coalesce(jsonb_agg(p.nome order by p.nome), '[]'::jsonb)
                           from public.avisos_funcionarios y
                           join public.funcionarios p on p.id = y.funcionario_id
                          where y.aviso_id = a.id)
           ) order by a.ativo desc, a.criado_em desc), '[]'::jsonb)
      from public.avisos a
      join public.funcionarios f on f.id = a.criado_por);
end $$;

create or replace function public.fn_aviso_definir_ativo(
  p_token uuid, p_aviso_id uuid, p_ativo boolean
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_func  public.funcionarios;
  v_aviso public.avisos;
begin
  v_func := public.fn__sessao(p_token);
  perform public.fn__exigir_admin(v_func);

  select * into v_aviso from public.avisos where id = p_aviso_id;
  if v_aviso.id is null then
    raise exception 'AVISO_NAO_ENCONTRADO' using errcode = 'P0001';
  end if;

  perform public.fn__exigir_gestao(v_func, v_aviso.criado_por);

  update public.avisos
     set ativo = p_ativo,
         atualizado_em = now(),
         desativado_em  = case when p_ativo then null else now() end,
         desativado_por = case when p_ativo then null else v_func.id end
   where id = p_aviso_id;

  perform public.fn__auditar(
    v_func.id, null,
    case when p_ativo then 'AVISO_ALTERADO' else 'AVISO_DESATIVADO' end,
    'AVISO', v_aviso.id::text,
    jsonb_build_object('ativo', v_aviso.ativo), jsonb_build_object('ativo', p_ativo),
    case when p_ativo then 'Aviso reativado por ' else 'Aviso desativado por ' end || v_func.nome);

  return jsonb_build_object('ok', true, 'ativo', p_ativo);
end $$;

create or replace function public.fn_aviso_excluir(p_token uuid, p_aviso_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_func  public.funcionarios;
  v_aviso public.avisos;
begin
  v_func := public.fn__sessao(p_token);
  perform public.fn__exigir_admin(v_func);

  select * into v_aviso from public.avisos where id = p_aviso_id;
  if v_aviso.id is null then
    raise exception 'AVISO_NAO_ENCONTRADO' using errcode = 'P0001';
  end if;

  perform public.fn__exigir_gestao(v_func, v_aviso.criado_por);

  -- Os destinos caem junto por ON DELETE CASCADE. O aviso nao e historico de
  -- operacao da PTA: e comunicado, e some quando deixa de servir.
  perform public.fn__auditar(
    v_func.id, null, 'AVISO_EXCLUIDO', 'AVISO', v_aviso.id::text,
    jsonb_build_object('titulo', v_aviso.titulo, 'mensagem', v_aviso.mensagem),
    null, 'Aviso excluido por ' || v_func.nome);

  delete from public.avisos where id = p_aviso_id;

  return jsonb_build_object('ok', true);
end $$;

-- =============================================================================
-- 21) LISTA "EM USO AGORA"
--
-- Junta as duas origens do que esta acontecendo neste instante:
--   USO          uso real aberto pelo QR Code da PTA
--   PROGRAMACAO  agendamento cujo horario esta correndo agora
--
-- Consulta livre, como o resto do calendario (decisao 4 de docs/DECISOES.md).
-- =============================================================================
create or replace function public.fn_em_uso_agora()
returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  v_lista jsonb;
begin
  select coalesce(jsonb_agg(x.item order by x.ordem, x.codigo), '[]'::jsonb)
    into v_lista
    from (
      select 1 as ordem, p.codigo,
             jsonb_build_object(
               'origem', 'USO',
               'id', u.id,
               'pta', p.codigo,
               'local', p.local,
               'funcionario', f.nome,
               'matricula', f.matricula,
               'setor', s.nome,
               'fornecedor', fo.nome,
               'inicio', to_char(u.inicio_efetivo  at time zone public.fn_tz(), 'HH24:MI'),
               'fim_previsto', to_char(u.fim_pretendido at time zone public.fn_tz(), 'HH24:MI'),
               'atrasado', (u.fim_pretendido < now()),
               'minutos_aberto', floor(extract(epoch from (now() - u.inicio_efetivo)) / 60)::int
             ) as item
        from public.usos u
        join public.ptas p               on p.id = u.pta_id
        join public.funcionarios f       on f.id = u.funcionario_id
        join public.setores s            on s.id = f.setor_id
        left join public.fornecedores fo on fo.id = u.fornecedor_id
       where u.status = 'EM_USO'

      union all

      select 2 as ordem, p.codigo,
             jsonb_build_object(
               'origem', 'PROGRAMACAO',
               'id', a.id,
               'pta', p.codigo,
               'local', p.local,
               'funcionario', f.nome,
               'matricula', f.matricula,
               'setor', s.nome,
               'fornecedor', fo.nome,
               'inicio', to_char(a.inicio_planejado at time zone public.fn_tz(), 'HH24:MI'),
               'fim_previsto', to_char(a.fim_planejado at time zone public.fn_tz(), 'HH24:MI'),
               'atrasado', false,
               'minutos_aberto', null
             ) as item
        from public.agendamentos a
        join public.ptas p               on p.id = a.pta_id
        join public.funcionarios f       on f.id = a.funcionario_id
        join public.setores s            on s.id = f.setor_id
        left join public.fornecedores fo on fo.id = a.fornecedor_id
       where a.status = 'AGENDADO'
         and now() >= a.inicio_planejado
         and now() <  a.fim_planejado
         -- Uso real na mesma PTA manda: nao lista a programacao em duplicidade.
         and not exists (select 1 from public.usos u
                          where u.pta_id = a.pta_id and u.status = 'EM_USO')
    ) x;

  return jsonb_build_object(
    'agora', public.fn_agora(),
    'itens', v_lista,
    'total', jsonb_array_length(v_lista));
end $$;

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
  public.fn__normalizar_codigo_pta(text),
  public.fn__exigir_admin(public.funcionarios),
  public.fn__exigir_master(public.funcionarios),
  public.fn__exigir_gestao(public.funcionarios, uuid),
  public.fn__ciclico_gerar(uuid, date, uuid),
  public.fn__pta_codigo(text)
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
  public.fn_uso_iniciar(uuid, text, time, uuid),
  public.fn_uso_finalizar(uuid, uuid),
  public.fn_uso_detalhe(uuid, uuid),
  public.fn_meu_uso_aberto(uuid),
  public.fn_observacao_salvar(uuid, uuid, text),
  public.fn_agendamento_criar(uuid, uuid, date, time, time, uuid),
  public.fn_agendamento_cancelar(uuid, uuid),
  public.fn_agenda_dia(date, uuid),
  public.fn_calendario_mes(int, int),
  public.fn_detalhe_registro(text, uuid),
  public.fn_historico(date, date, uuid, int),
  public.fn_minha_programacao(uuid),
  public.fn_auditoria(int, uuid),
  public.fn_perfil_alterar_nome(uuid, text),
  public.fn_agendamento_alterar(uuid, uuid, date, time, time, uuid),
  public.fn_admin_listar_funcionarios(uuid),
  public.fn_admin_definir_papel(uuid, uuid, text),
  public.fn_admin_desativar_funcionario(uuid, uuid),
  public.fn_admin_reativar_funcionario(uuid, uuid),
  public.fn_admin_definir_limite_matriculas(uuid, int),
  public.fn_admin_configuracao(uuid),
  public.fn_fornecedores(text),
  public.fn_fornecedor_criar(uuid, text, text),
  public.fn_admin_cancelar_uso(uuid, uuid, text),
  public.fn_admin_definir_max_horas_uso(uuid, int),
  public.fn_ciclico_criar(uuid, uuid, uuid, time, time, text, smallint[], int, int, date, date, uuid),
  public.fn_ciclico_listar(uuid),
  public.fn_ciclico_desativar(uuid, uuid, boolean),
  public.fn_ciclico_estender(uuid, uuid),
  public.fn_perfil_trocar_pin(uuid, text, text),
  public.fn_admin_resetar_pin(uuid, uuid, text),
  public.fn_admin_listar_ptas(uuid),
  public.fn_pta_criar(uuid, text, text, text),
  public.fn_pta_alterar(uuid, uuid, text, text, text),
  public.fn_pta_definir_ativo(uuid, uuid, boolean),
  public.fn_pta_excluir(uuid, uuid),
  public.fn_admin_reservadas(uuid),
  public.fn_reservada_salvar(uuid, text, text, text),
  public.fn_reservada_excluir(uuid, text),
  public.fn_admin_definir_horizonte_ciclico(uuid, int),
  public.fn_avisos_para_mim(uuid),
  public.fn_aviso_criar(uuid, text, text, uuid[], uuid[], timestamptz, timestamptz),
  public.fn_aviso_listar(uuid),
  public.fn_aviso_definir_ativo(uuid, uuid, boolean),
  public.fn_aviso_excluir(uuid, uuid),
  public.fn_em_uso_agora()
to anon, authenticated;

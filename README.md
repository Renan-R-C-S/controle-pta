# Controle e Agendamento de PTA

Sistema web para controlar e registrar o uso de Plataformas de Trabalho em Altura
(PTA) dentro de uma fábrica, com dois pontos de entrada por QR Code:

| | QR Code 1 | QR Code 2 |
|---|---|---|
| Onde fica | colado **na própria PTA** | local geral da fábrica |
| URL | `index.html?modo=uso&pta=PTA-001` | `agenda.html?modo=agenda` |
| Para que serve | uso **imediato**: iniciar, finalizar, observar | **programação** futura e consulta |
| Prioridade | **prevalece** | cede ao QR Code 1 |

A regra central do sistema é **QR Code 1 > QR Code 2**: o uso real tem prioridade
sobre o planejado, mas nunca apaga o registro anterior — o agendamento afetado
fica preservado e marcado no histórico.

---

## 1. Arquitetura

```
Navegador (celular)
      │
      │  HTML + CSS + JavaScript modular (sem framework)
      │  hospedado em GitHub Pages / Netlify
      ▼
Supabase (chave anon)
      │
      │  SOMENTE chamadas RPC — nenhuma tabela é acessada diretamente
      ▼
PostgreSQL
      ├─ RLS habilitado, sem políticas para anon  →  acesso direto negado
      ├─ funções SECURITY DEFINER                 →  onde as regras vivem
      └─ constraints (UNIQUE, CHECK, EXCLUDE)     →  última linha de defesa
```

O ponto que sustenta a segurança: **o frontend não escreve em tabelas**. Como todo
o código é público no GitHub Pages, qualquer proteção que existisse apenas no
JavaScript seria contornável abrindo o DevTools. Por isso o papel `anon` não tem
`SELECT`/`INSERT`/`UPDATE`/`DELETE` em nenhuma tabela: ele só consegue executar a
lista explícita de funções liberadas ao final de `sql/02_funcoes.sql`, e cada uma
delas valida o token de sessão antes de agir.

### Arquivos

```
index.html              QR Code 1 — uso imediato
agenda.html             QR Code 2 — calendário e agendamento
qrcodes.html            gerador de etiquetas para impressão

css/style.css           interface (mobile-first, alvos de toque de 52px+)

js/config.js            credenciais do Supabase e constantes    ← EDITE ESTE
js/api.js               cliente Supabase e wrapper de RPC
js/erros.js             tradução de códigos técnicos → mensagens amigáveis
js/tempo.js             fuso America/Sao_Paulo e relógio do servidor
js/validacoes.js        validações de feedback rápido (não de segurança)
js/auth.js              sessão, cadastro, login, logout
js/login-ui.js          telas de setor → funcionário → PIN → cadastro
js/ptas.js              leitura do parâmetro do QR e situação da PTA
js/usos.js              uso imediato (iniciar, finalizar, histórico)
js/observacoes.js       observação e prazo de 30 minutos
js/agendamentos.js      programação e detecção de conflito
js/auditoria.js         leitura da trilha de auditoria
js/calendario.js        componente de calendário mensal
js/ui.js                DOM, navegação entre telas, avisos, diálogos
js/app-uso.js           controlador da página do QR Code 1
js/app-agenda.js        controlador da página do QR Code 2

sql/01_schema.sql       tabelas, constraints, índices, gatilhos
sql/02_funcoes.sql      funções RPC (regras de negócio)
sql/03_rls.sql          Row Level Security e privilégios
sql/04_seed.sql         dados de teste
sql/05_cenario_demo.sql demonstração da sobrescrita QR1 → QR2
sql/06_testes.sql       40 testes automatizados das regras

docs/DECISOES.md        decisões tomadas em pontos ambíguos do escopo
docs/TESTES.md          roteiro de teste manual pelo navegador
```

---

## 2. Configurar o Supabase

### 2.1 Criar o projeto

1. Acesse [supabase.com](https://supabase.com) e crie um projeto.
2. Escolha a região mais próxima (ex.: `South America (São Paulo)`).
3. Guarde a senha do banco — ela **não** é usada pela aplicação, apenas para
   acesso administrativo.

### 2.2 Executar os scripts SQL

No painel do Supabase, abra **SQL Editor → New query** e execute os arquivos
**nesta ordem**, um de cada vez:

| Ordem | Arquivo | O que faz |
|---|---|---|
| 1 | `sql/01_schema.sql` | cria tabelas, constraints e gatilhos |
| 2 | `sql/02_funcoes.sql` | cria as funções RPC e libera o acesso a elas |
| 3 | `sql/03_rls.sql` | habilita RLS e remove privilégios diretos |
| 4 | `sql/04_seed.sql` | carrega setores, PTAs e funcionários fictícios |
| 5 | `sql/05_cenario_demo.sql` | *(opcional)* gera o cenário de sobrescrita |
| 6 | `sql/06_testes.sql` | *(opcional)* roda os 40 testes automatizados |

> O arquivo `06_testes.sql` **termina com erro de propósito**: é assim que ele
> desfaz tudo o que criou. O relatório dos testes está no corpo dessa mensagem
> de erro. Nenhum dado de teste permanece no banco.

### 2.3 Pegar as credenciais

Em **Project Settings → API**, copie:

- **Project URL** → `SUPABASE_URL`
- **anon public** → `SUPABASE_ANON_KEY`

Cole em `js/config.js`:

```js
export const SUPABASE_URL = 'https://xxxxxxxxxxxx.supabase.co';
export const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6...';
```

> **Nunca** use a chave `service_role` no frontend. Ela ignora todas as políticas
> de segurança do banco. A chave `anon` é pública por natureza e é a correta aqui.

### 2.4 Sobre o plano gratuito

O plano gratuito do Supabase atende este sistema com folga: o banco inteiro,
incluindo anos de auditoria, cabe em poucos megabytes.

Três limites merecem atenção — confira os valores atuais, que mudam com o tempo:

| Limite | Impacto aqui |
|---|---|
| **Projeto pausa após ~7 dias sem uso** | O mais importante. Ver abaixo. |
| Sem *Branching* | A integração nativa com o GitHub não fica disponível. Use o workflow de `.github/workflows/aplicar-sql.yml`, que faz o mesmo. |
| Backup diário limitado | Para produção de verdade, considere exportar o banco periodicamente. |

**A pausa por inatividade é o ponto que pode morder.** Se ninguém usar o sistema
por cerca de uma semana — férias coletivas, parada de manutenção — o projeto é
pausado e os QR Codes param de responder até alguém reativá-lo manualmente no
painel do Supabase. Não há perda de dados, mas há indisponibilidade.

Uso diário normal de fábrica já mantém o projeto ativo. Se houver períodos
previstos de parada, reative o projeto no painel antes do retorno do turno.

### 2.5 Aplicar o SQL sem copiar e colar

Se o projeto estiver num repositório GitHub, o workflow
[`.github/workflows/aplicar-sql.yml`](.github/workflows/aplicar-sql.yml) aplica
os scripts `01` a `04` na ordem, confere o endurecimento de segurança e roda a
bateria de testes — tudo no plano gratuito, sem instalar nada.

Ver a seção **4. Publicar**.

---

## 3. Executar localmente

O projeto usa módulos ES (`import`/`export`), que exigem um servidor HTTP —
abrir o `index.html` com duplo clique **não funciona** (o navegador bloqueia
módulos em `file://`).

Escolha uma das opções:

```bash
python -m http.server 8000
```

```bash
npx serve .
```

Depois acesse:

- QR Code 1: `http://localhost:8000/index.html?modo=uso&pta=PTA-001`
- QR Code 2: `http://localhost:8000/agenda.html?modo=agenda`
- Etiquetas: `http://localhost:8000/qrcodes.html`

Usuários de teste carregados por `04_seed.sql`:

| Nome | Matrícula | PIN | Setor |
|---|---|---|---|
| Joao Silva | 10001 | 1234 | Mecanica |
| Maria Souza | 10002 | 2345 | Eletrica |
| Carlos Santos | 10003 | 3456 | Producao |
| Ana Oliveira | 10004 | 4567 | PCM |

---

## 4. Publicar

### GitHub Pages

```bash
git init
git add .
git commit -m "Sistema de controle de PTA"
git branch -M main
git remote add origin https://github.com/SEU-USUARIO/controle-pta.git
git push -u origin main
```

No repositório: **Settings → Pages → Source: Deploy from a branch →
Branch: `main` / `(root)` → Save**.

Em cerca de um minuto o sistema estará em
`https://SEU-USUARIO.github.io/controle-pta/`.

### Netlify

Arraste a pasta do projeto para [app.netlify.com/drop](https://app.netlify.com/drop),
ou conecte o repositório (sem comando de build; a pasta de publicação é a raiz).

### Depois de publicar

No Supabase, em **Authentication → URL Configuration**, adicione o endereço
publicado à lista de URLs permitidas.

---

## 5. Cadastrar os QR Codes

Abra `qrcodes.html` no sistema já publicado, informe o endereço e os códigos das
PTAs, clique em **GERAR** e depois em **IMPRIMIR**.

O gerador produz:

- **um QR Code 1 por PTA** — `?modo=uso&pta=PTA-00X` — que deve ser plastificado
  e fixado no próprio equipamento;
- **um QR Code 2** — `agenda.html?modo=agenda` — para o quadro de avisos ou
  entrada do setor.

Para cadastrar uma PTA nova, basta inserir a linha no banco e gerar a etiqueta:

```sql
insert into public.ptas (codigo, descricao, local)
values ('PTA-004', 'Plataforma articulada 12m', 'Galpao C');
```

O código precisa seguir o formato `PTA-000`. Na URL o sistema aceita as
variações `PTA001`, `pta-001` e `PTA-1` — todas são normalizadas para `PTA-001`.

---

## 6. Regras de negócio implementadas

| # | Regra | Onde é garantida |
|---|---|---|
| 1 | Matrícula única globalmente | constraint `UNIQUE` + tratamento de `unique_violation` |
| 2 | PIN de exatamente 4 dígitos | regex em `fn_cadastrar_funcionario` e `fn_login` |
| 3 | PIN nunca em texto puro | `crypt(pin, gen_salt('bf', 10))` — bcrypt com salt |
| 4 | QR Code 1 identifica uma PTA | `fn__normalizar_codigo_pta` + parâmetro de URL |
| 5 | QR Code 1 = uso imediato | `fn_uso_iniciar` não aceita data futura |
| 6 | QR Code 2 = programação | `fn_agendamento_criar` recusa horário passado |
| 7 | QR Code 1 tem prioridade | laço de sobrescrita em `fn_uso_iniciar` |
| 8 | Uso tem os três horários | colunas `inicio_efetivo`, `fim_pretendido`, `fim_efetivo` |
| 9 | `inicio_efetivo` automático | `now()` do servidor, não do celular |
| 10 | `fim_efetivo` só na finalização | gravado apenas em `fn_uso_finalizar` |
| 11 | Pretendido ≠ efetivo | colunas separadas; nenhuma sobrescreve a outra |
| 12 | Uso aberto permanece aberto | não existe rotina de fechamento automático |
| 13 | Observação de até 200 caracteres | `CHECK` na tabela + validação na função |
| 14 | 30 minutos para editar observação | `limite_edicao_observacao` conferido com `now()` |
| 15 | Auditoria das ações importantes | `fn__auditar` em todas as funções de escrita |
| 16 | Histórico não pode ser apagado | gatilho que recusa `UPDATE` e `DELETE` |
| 17 | Sem agendamentos conflitantes | `EXCLUDE USING gist` com `tstzrange` |
| 18 | Sobrescrita não apaga nada | status muda + vínculo em `agendamentos_afetados` |

### Os três conceitos separados (item 49)

| Conceito | Tabela | Pergunta que responde |
|---|---|---|
| **Programação** | `agendamentos` | o que estava planejado |
| **Uso** | `usos` | o que efetivamente aconteceu |
| **Auditoria** | `auditoria` | como e quando as informações mudaram |

Essa separação aparece também na interface: no calendário, programação e uso são
cartões distintos, com cores de borda diferentes, e o histórico mostra as duas
faixas de horário lado a lado (`08:00 → 12:00 previsto` / `08:00 → 10:47 efetivo`).

### Sobrescrita, passo a passo

```
1. João agenda a PTA-003 pelo QR Code 2:  14:00 → 16:00        [AGENDADO]

2. Carlos chega às 13:20, lê o QR Code 1 e informa fim às 15:00

3. O sistema, dentro de uma única transação:
   • cria o uso   13:20 → 15:00 (Carlos)                       [EM_USO]
   • marca o agendamento de João      [AFETADO_POR_USO_IMEDIATO]
   • grava o vínculo em agendamentos_afetados
   • grava a auditoria com valor anterior, valor novo, autor e horário

4. O agendamento de João continua existindo e visível no calendário.
```

Se o agendamento sobreposto for **do próprio** funcionário que iniciou o uso, o
status vira `SOBRESCRITO` (ele substituiu a própria programação) e o agendamento
passa a `CONCLUIDO` quando o uso é finalizado. Essa distinção está detalhada em
[docs/DECISOES.md](docs/DECISOES.md).

---

## 7. Segurança

- **PIN**: bcrypt com salt, custo 10. Nunca trafega em URL, nunca aparece no
  HTML, nunca é gravado no `localStorage`.
- **Sessão**: o servidor emite um token opaco (UUID) com validade de 12 horas.
  Só o token e os dados de exibição (nome, matrícula, setor) ficam no
  `localStorage`.
- **Força bruta**: 5 tentativas erradas bloqueiam a conta por 15 minutos. O
  contador é persistido mesmo quando o login falha — detalhe importante, já que
  um `RAISE` no PostgreSQL desfaria a transação inteira e zeraria o contador.
- **Manipulação de IDs**: trocar um `uso_id` no DevTools não adianta —
  `fn_uso_finalizar` compara o dono do registro com o dono da sessão e devolve
  `SEM_PERMISSAO`.
- **Histórico**: `auditoria` e `agendamentos_afetados` recusam `UPDATE` e
  `DELETE` por gatilho, inclusive para o dono do banco. Correções precisam ser
  novos eventos.
- **Concorrência**: dois celulares tentando iniciar o uso da mesma PTA no mesmo
  segundo — o índice único parcial `uq_uso_aberto_por_pta` deixa apenas um
  passar. O mesmo vale para agendamentos, via constraint de exclusão.

### Verificar se o endurecimento está ativo

```sql
-- Não deve retornar nenhuma linha
select table_name, privilege_type
  from information_schema.role_table_grants
 where grantee = 'anon' and table_schema = 'public';
```

---

## 8. Testes

**Automatizados** — rode `sql/06_testes.sql` no SQL Editor. São 40 casos
cobrindo cadastro, matrícula duplicada, PIN inválido, bloqueio por tentativas,
início e finalização de uso (antes e depois do horário pretendido), prazo da
observação, conflito de agendamento, sobrescrita e imutabilidade da auditoria.
O relatório sai na mensagem final e nada é gravado.

**Manuais** — o roteiro passo a passo pelo navegador está em
[docs/TESTES.md](docs/TESTES.md).

---

## 10. Perfis de acesso e administração

Três níveis:

| Papel | Pode |
|---|---|
| **Funcionário** | usar as PTAs, agendar, alterar e cancelar as **próprias** programações, corrigir o próprio nome |
| **Administrador** | tudo acima + alterar e excluir **qualquer** programação, excluir e reativar funcionários, promover alguém a administrador |
| **Administrador principal** | tudo acima + **revogar** o papel de administrador e definir o limite de matrículas |

Nenhum papel altera auditoria ou histórico. Os gatilhos de imutabilidade valem
para todo mundo, incluindo o dono do banco.

### Como o primeiro administrador nasce

Não existe uma tela para "criar o primeiro admin" — seria um buraco de
segurança. Em vez disso, três matrículas já vêm **reservadas** em
`sql/04_seed.sql`:

| Matrícula | Papel |
|---|---|
| `0591` | Administrador principal |
| `0592` | Administrador |
| `0593` | Administrador |

Quando alguém se cadastra com uma dessas matrículas, já entra com o papel.
Daí em diante, o administrador principal promove quem mais precisar pela tela
de administração.

> ⚠️ **Passo obrigatório na implantação.** Quem cadastrar *primeiro* uma dessas
> matrículas assume o papel. Peça a essas três pessoas que façam o primeiro
> acesso **antes** de liberar o QR Code para o resto da fábrica.

Para reservar outras matrículas:

```sql
insert into public.matriculas_reservadas (matricula, papel)
values ('0594', 'ADMIN');
```

### "Excluir" significa desativar

Tanto para funcionários quanto para programações, excluir **não apaga a linha
do banco** — marca como inativo/cancelado.

Isso não é meia-implementação: é a única forma de atender "administradores podem
excluir" e "ninguém altera o histórico" ao mesmo tempo. Apagar um funcionário
destruiria os registros de uso dele; apagar uma programação destruiria o rastro
de quem a sobrescreveu.

Na prática o efeito operacional é o mesmo:

- o funcionário some da lista de login e não consegue mais entrar;
- as sessões abertas dele são encerradas na hora;
- as programações futuras dele são canceladas, liberando os horários;
- a vaga volta a contar no limite de matrículas;
- os usos e a auditoria dele continuam íntegros.

Um funcionário excluído por engano pode ser reativado por qualquer administrador.

### Limite de matrículas

Só o administrador principal define. `0` significa sem limite.

O limite conta funcionários **ativos** — excluir alguém libera vaga. Não é
possível definir um teto abaixo do número atual de ativos, para o sistema nunca
ficar num estado que ele próprio não consegue corrigir.

### Nome sim, matrícula não

Qualquer funcionário corrige o próprio nome em **MEU PERFIL** (erro de digitação,
nome de casada). A troca fica auditada com o valor anterior.

A matrícula não muda por lá, e isso é proposital: ela é a identidade do registro,
referenciada por usos, agendamentos e auditoria. Trocá-la seria reescrever
histórico. Matrícula errada se resolve excluindo o cadastro e criando outro — o
histórico do antigo permanece.

---

## 11. Limites conhecidos deste MVP

Registrados aqui de forma explícita, conforme o item 47 do escopo:

- **Uso dentro do mesmo dia.** Um uso iniciado às 22:00 não pode ter fim
  pretendido às 02:00 do dia seguinte. O campo é apenas `HH:MM` e é sempre
  interpretado como hoje. Turnos que cruzam a meia-noite exigem uma mudança de
  modelo (informar a data junto com a hora).
- **Sem perfil de administrador.** Não há tela para cadastrar PTAs, desativar
  funcionários ou corrigir um uso lançado errado — isso é feito por SQL.
- **Sem notificações.** Um uso que passou do horário pretendido aparece marcado
  na tela, mas ninguém é avisado ativamente.
- **A auditoria é visível a todos.** Qualquer pessoa que leia o QR Code 2 vê a
  trilha completa. Isso é adequado a um quadro de fábrica; se precisar restringir,
  a mudança é em `fn_auditoria`.

O caminho de evolução dessas limitações está em [docs/DECISOES.md](docs/DECISOES.md).

# Decisões de projeto

O item 47 do escopo pede que nenhuma ambiguidade seja resolvida em silêncio.
Este arquivo lista todos os pontos em que o escopo admitia mais de uma leitura,
o que foi decidido, por quê, e o que seria preciso mudar para adotar a outra
interpretação.

---

## 1. Autenticação própria em vez do Supabase Auth

**Ambiguidade.** O escopo pede login por matrícula + PIN (item 8) e, ao mesmo
tempo, "manter a sessão de forma segura utilizando mecanismo apropriado do
Supabase" (item 32).

**Decisão.** Autenticação própria: `fn_login` confere o PIN com bcrypt e emite um
token de sessão (UUID) gravado na tabela `sessoes`, válido por 12 horas.

**Por quê.** O Supabase Auth trabalha com e-mail/telefone + senha ou link mágico.
Nenhum desses caminhos cabe em "ler o QR Code, tocar no nome, digitar 4 dígitos"
— um operador de fábrica não tem e-mail corporativo à mão com luva na mão. Forçar
o Auth exigiria criar e-mails sintéticos (`10001@fabrica.local`), o que é uma
gambiarra com aparência de segurança.

**Consequência.** O token fica no `localStorage`. Ele é um segredo opaco: não
revela o PIN, expira em 12 horas e pode ser invalidado no banco. O que ele
permite é exatamente o que o funcionário já poderia fazer no aparelho dele.

**Como migrar.** Trocar `fn__sessao(p_token)` por `auth.uid()` nas funções de
escrita e ligar `funcionarios.id` ao `auth.users.id`. A estrutura de dados não
muda.

---

## 2. Sobrescrito × Afetado por uso imediato

**Ambiguidade.** O item 24 lista os dois status, mas não diz quando usar cada um.

**Decisão.** Quando o uso imediato colide com um agendamento:

| Dono do agendamento | Status aplicado |
|---|---|
| a **mesma** pessoa que iniciou o uso | `SOBRESCRITO` |
| **outra** pessoa | `AFETADO_POR_USO_IMEDIATO` |

**Por quê.** São situações operacionalmente diferentes. "Eu agendei para as 14:00
e comecei às 13:20" é a própria pessoa ajustando o plano. "O Carlos assumiu a PTA
que o João tinha reservado" é um conflito real entre duas pessoas — e é esse que
o encarregado precisa conseguir localizar no histórico. Um único status
misturaria os dois casos.

**Efeito adicional.** No primeiro caso o uso guarda `agendamento_origem_id`, e ao
ser finalizado o agendamento passa a `CONCLUIDO` — a programação foi cumprida,
não descartada. É o único caminho pelo qual um agendamento chega a `CONCLUIDO`.

---

## 3. Um uso aberto por funcionário

**Ambiguidade.** O escopo impede dois usos simultâneos na mesma PTA, mas não diz
se uma pessoa pode ter usos abertos em PTAs diferentes.

**Decisão.** Não pode. Índice único parcial `uq_uso_aberto_por_funcionario`.

**Por quê.** Ninguém opera duas plataformas de trabalho em altura ao mesmo tempo.
Sem essa restrição, o esquecimento de finalizar um uso vira uma pilha de
registros abertos que corrompe o histórico. Bloquear o segundo uso força a
finalização do primeiro — e a tela ainda oferece o atalho "IR PARA PTA-00X".

**Como reverter.** Remover o índice; nenhuma outra parte do sistema depende dele.

---

## 4. Consulta do QR Code 2 sem login

**Ambiguidade.** O item 3 lista as consultas permitidas pelo QR Code 2 sem dizer
se exigem identificação.

**Decisão.** Consultar (calendário, histórico, auditoria) é livre. Criar ou
cancelar programação exige login.

**Por quê.** O QR Code 2 fica em local de passagem e serve para responder "a
PTA-002 está livre amanhã de manhã?" sem tirar a luva. Já criar um agendamento
grava o nome de alguém no banco — aí a identificação é obrigatória, porque o item
20 exige registrar quem agendou.

**Fluxo.** Ao tocar em **+ AGENDAR** sem estar identificado, o sistema abre o
login e retoma a ação assim que ele termina.

---

## 5. Uso restrito ao mesmo dia

**Ambiguidade.** O item 12 pede para "avaliar corretamente situações envolvendo
mudança de data", mas recomenda o mesmo dia para o MVP.

**Decisão.** Mesmo dia. O campo do fim pretendido é `HH:MM` e sempre se refere a
hoje. Um horário já passado é recusado com `HORARIO_FINAL_ANTERIOR`.

**Por quê.** Aceitar a virada de meia-noite sem pedir a data cria adivinhação: às
23:50, "01:00" pode significar daqui a 70 minutos ou 22 horas atrás. Adivinhar
errado num sistema de auditoria é pior do que recusar.

**O que muda para suportar turno noturno.** Trocar o campo por
`datetime-local` e ajustar `fn_uso_iniciar` para receber `timestamp` em vez de
`time`. O banco já armazena `timestamptz` — nenhuma migração de dados é
necessária.

**Observação.** A restrição vale só para o *fim pretendido*. Um uso que começa às
23:00 e é finalizado às 02:00 funciona: `fim_efetivo` é o instante real do
clique, sem limite de data.

---

## 6. Falha de login devolvida como valor, não como exceção

**Ambiguidade.** Nenhuma — é uma armadilha técnica que merece registro.

**Decisão.** `fn_login` devolve `{ok: false, erro: 'PIN_INCORRETO'}` em vez de
lançar exceção. Todas as outras funções lançam.

**Por quê.** No PostgreSQL, `RAISE EXCEPTION` aborta a transação inteira. Como o
incremento de `tentativas_falhas` acontece na mesma transação, lançar a exceção
desfaria o incremento — e o bloqueio após 5 tentativas nunca funcionaria. O teste
T09 de `sql/06_testes.sql` existe exatamente para vigiar isso.

**Onde aparece no frontend.** O wrapper `rpc()` em `js/api.js` verifica
`ok === false` e converte no mesmo `ErroApp` das exceções, então o restante do
código não precisa saber da diferença.

---

## 7. Prazo da observação contado apenas após a finalização

**Ambiguidade.** O item 19 fixa `fim_efetivo + 30 minutos`, mas não diz o que
vale enquanto o uso está aberto.

**Decisão.** Enquanto o uso está `EM_USO`, a observação é livremente editável. O
cronômetro de 30 minutos começa no clique de finalizar.

**Por quê.** É a leitura literal da regra: sem `fim_efetivo`, não há de onde
contar. Na prática é o que o operador espera — anotar durante o serviço e ainda
ter meia hora depois para completar.

---

## 8. A hora oficial é sempre a do servidor

**Decisão.** Nenhum horário gravado vem do dispositivo. `inicio_efetivo`,
`fim_efetivo` e o limite da observação usam `now()` do PostgreSQL. O frontend
mede o desvio do relógio local uma vez (`sincronizarRelogio`) e o aplica só para
animar a tela.

**Por quê.** Um celular com a hora adiantada em 40 minutos poderia "provar" que a
observação foi feita dentro do prazo. Como a auditoria é o produto final deste
sistema, ela não pode depender do relógio de quem está sendo auditado.

**Efeito visível.** O bloqueio da observação na tela é uma cortesia; a recusa que
vale vem do banco. Por isso, quando o prazo vence entre abrir a tela e salvar, o
usuário recebe `OBSERVACAO_PRAZO_EXPIRADO` mesmo com o botão habilitado.

---

## 9. Fallback quando falta o parâmetro `?pta=`

**Ambiguidade.** O escopo não trata o caso de abrir `index.html` sem o parâmetro
do QR Code (link salvo nos favoritos, por exemplo).

**Decisão.** Em vez de erro, a tela mostra a lista de PTAs ativas para escolha
manual e explica que normalmente o QR Code já traz essa informação.

**Por quê.** Recusar deixaria o operador sem saída no meio do galpão. A escolha
manual não fere a REGRA 4: a PTA continua identificada por um código válido, e
o registro gravado é idêntico.

---

## 10. Duração máxima de 14 horas

**Decisão.** Usos e agendamentos ficam limitados a 14 horas.

**Por quê.** É uma barreira contra erro de digitação (`08:00 → 18:00` virando
`08:00 → 08:00` do dia seguinte), com folga sobre qualquer turno real. Está
implementada como `CHECK` na tabela e verificação nas funções.

**Como alterar.** Constraint `agendamentos_duracao_max` em `sql/01_schema.sql` e
os testes de `DURACAO_EXCESSIVA` nas funções.

---

## 11. Formato do código da PTA

**Decisão.** No banco, `PTA-000` (constraint `ptas_codigo_formato`). Na URL, o
sistema aceita `PTA001`, `pta-001`, `PTA-1` e normaliza tudo para `PTA-001`.

**Por quê.** O escopo mostra os dois formatos (`PTA001` no exemplo de URL,
`PTA-001` na lista de identificadores). Um formato único no banco evita duplicata
com a mesma identidade; a tolerância na URL evita que uma etiqueta impressa fora
do padrão pare de funcionar.

---

## 12. Cancelamento restrito ao autor

**Decisão.** Só o autor cancela a própria programação. E o cancelamento não apaga
nada: o status vira `CANCELADO`, com data e evento de auditoria.

**Por quê.** Coerente com o item 31 ("impedir alteração de registros de outros
usuários"). Um perfil de supervisor com poder de cancelar por terceiros é uma
evolução natural, mas exigiria um modelo de papéis que o MVP não tem.

---

## 13. "Excluir" é desativar, nunca apagar

**Ambiguidade.** O pedido foi que administradores possam *excluir* funcionários
e programações, mas que *não alterem o histórico nem a auditoria*.

**Decisão.** Excluir marca como inativo (funcionário) ou `CANCELADO`
(programação). Nenhuma linha sai do banco.

**Por quê.** Os dois pedidos são incompatíveis se "excluir" for `DELETE`. Um
funcionário é referenciado por `usos`, `agendamentos` e `auditoria`; apagá-lo
exigiria apagar os registros dele — exatamente o histórico que deve ser
preservado. As chaves estrangeiras são `on delete restrict` justamente para
tornar isso impossível por acidente.

**Efeito prático.** Idêntico ao esperado: some da lista, não entra mais, sessões
encerradas, programações futuras canceladas, vaga liberada no limite. E com um
ganho: dá para reativar quem foi excluído por engano.

---

## 14. O administrador principal é intocável

**Decisão.** Ninguém — nem outro administrador, nem ele mesmo — altera o papel
ou desativa quem tem `ADMIN_MASTER`.

**Por quê.** Sem essa trava o sistema pode chegar a um estado do qual não sai
sozinho: dois administradores se revogam mutuamente, ou o único master se
desativa por engano, e não sobra ninguém capaz de conceder papéis. A saída seria
mexer no banco por fora, o que é pior.

**Consequência.** Trocar quem é o administrador principal exige SQL direto —
operação rara e deliberada, como deve ser.

**Também bloqueado:** alterar o próprio papel. Um `ADMIN` que pudesse se promover
tornaria a distinção entre os dois níveis decorativa.

---

## 15. Matrículas administrativas reservadas

**Ambiguidade.** Como as matrículas 0591/0592/0593 viram administradoras se o
sistema é de autocadastro e ninguém é admin no começo?

**Decisão.** Uma tabela `matriculas_reservadas` define, por matrícula, o papel
que a pessoa recebe **no momento do cadastro**.

**Por quê.** As alternativas eram piores: uma tela de "criar primeiro admin"
seria um buraco de segurança aberto; deixar o papel amarrado à string da
matrícula em código espalharia a regra pelo sistema.

**O risco que isso carrega, explicitamente.** Quem se cadastrar *primeiro* com
uma matrícula reservada assume o papel. Num sistema de autocadastro isso é
inevitável — está documentado no README e na própria tela de administração, que
mostra quais reservas ainda não foram usadas.

**Mitigação recomendada:** essas pessoas fazem o primeiro acesso no dia da
implantação, antes de o QR Code ser liberado. Se algo der errado, o
administrador principal exclui o cadastro indevido e a matrícula fica livre de
novo.

---

## 16. Nome é editável, matrícula não

**Decisão.** O funcionário altera o próprio nome. A matrícula não muda por
nenhuma tela.

**Por quê.** O nome é rótulo — erro de digitação, nome de casada, abreviação
ruim. Corrigi-lo não muda o significado de nenhum registro passado, e a troca
fica auditada com o valor anterior.

A matrícula é identidade. É ela que liga o registro à pessoa real da fábrica, e
é por ela que se procura alguém no histórico. Trocá-la faria os usos antigos
passarem a apontar para outra pessoa — reescrita de histórico com outro nome.

**Matrícula errada** se resolve excluindo o cadastro e criando outro. O histórico
do cadastro antigo permanece, corretamente atribuído a ele.

---

## 17. Alteração de programação exige horário futuro

**Decisão.** `fn_agendamento_alterar` recusa mover uma programação para um
horário que já passou, inclusive para administradores.

**Por quê.** Programação é planejamento. Remarcar algo para o passado é registrar
que aconteceu — e o que aconteceu de fato mora em `usos`, alimentado pelo QR
Code 1. Permitir isso abriria a porta para "consertar" o passado pela agenda,
que é justamente o que a separação entre planejado e efetivo existe para evitar.

**Consequência.** Uma programação que não foi cumprida não vira uso. Ela fica
como está, e o histórico mostra a diferença — que é a informação útil.

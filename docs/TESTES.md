# Roteiro de testes manuais

Complementa `sql/06_testes.sql` (40 testes automatizados no banco). Aqui está o
que precisa ser verificado **pelo navegador**, porque envolve a interface.

Pré-requisitos: scripts `01` a `04` executados e `js/config.js` preenchido.

Legenda: ✅ resultado esperado · ⚠️ ponto de atenção

---

## A. Usuário

### A1 — Cadastro no primeiro acesso
1. Abra `index.html?modo=uso&pta=PTA-001`.
2. Toque em **Mecanica** → **Primeiro acesso / não estou na lista**.
3. Preencha: `Pedro Almeida`, matrícula `20001`, PIN `1357`, confirmação `1357`.

✅ Entra direto no painel da PTA-001, já identificado.
⚠️ No celular, os campos de matrícula e PIN devem abrir o **teclado numérico**.

### A2 — Matrícula duplicada
Repita A1 com a matrícula `10001` (já existe, do João).

✅ Mensagem: *"Esta matrícula já está cadastrada."*
⚠️ Não pode aparecer texto de erro do PostgreSQL.

### A3 — PIN inválido
Tente cadastrar com PIN `123`, depois com `12A4`.

✅ *"O PIN deve ter exatamente 4 dígitos."* Em `12A4`, as letras nem devem ser
digitáveis (o campo filtra).

### A4 — Confirmação divergente
PIN `1111`, confirmação `2222`.

✅ *"A confirmação do PIN não confere."*

### A5 — Login correto
Setor **Mecanica** → **Joao Silva** → PIN `1234`.

✅ Entra sem tocar em "Entrar": ao completar o quarto dígito o formulário envia
sozinho.

### A6 — Login incorreto
Mesmo caminho com PIN `9999`.

✅ *"PIN incorreto."* O campo é limpo e recebe o foco de volta.

### A7 — Bloqueio por tentativas
Erre o PIN 5 vezes seguidas do mesmo funcionário.

✅ Na quinta: *"Muitas tentativas incorretas. Aguarde 15 minutos..."*
⚠️ O PIN correto também deve ser recusado durante o bloqueio.

Para desbloquear no teste:
```sql
update funcionarios set tentativas_falhas = 0, bloqueado_ate = null
 where matricula = '10001';
```

---

## B. QR Code 1 — uso imediato

### B1 — PTA válida
`index.html?modo=uso&pta=PTA-001`

✅ Cabeçalho mostra `PTA-001` e a descrição. Status **DISPONIVEL** em verde.

### B2 — Variações do código na URL
Teste `?pta=PTA001`, `?pta=pta-001` e `?pta=PTA-1`.

✅ Todas abrem a mesma PTA-001.

### B3 — PTA inexistente
`?pta=PTA-999`

✅ *"A PTA 'PTA-999' não foi encontrada."* — sem tela quebrada.

### B4 — Sem o parâmetro
`index.html` puro.

✅ Lista de PTAs para escolha manual, com a explicação.

### B5 — Início de uso
Painel → **INICIAR / DEFINIR USO**.

✅ O horário de início aparece preenchido e **não é editável**.
✅ O campo do fim vem sugerido com +2h.
✅ Ao mudar o horário, o texto "Duração prevista" acompanha.
✅ **CONFIRMAR USO** abre o diálogo: *"Você deseja utilizar a PTA: PTA-001 das
HH:MM às HH:MM?"*
⚠️ Depois de confirmar, o início gravado é o do **servidor**, não o exibido antes.

### B6 — Horário final inválido
Informe um horário já passado.

✅ *"O horário final deve ser posterior ao horário inicial."*

### B7 — Retorno ao QR Code (item 38)
Com o uso aberto, recarregue a mesma URL.

✅ Status **EM USO**, com início e fim pretendido.
✅ Botões: **FINALIZAR USO DA PTA** e **OBSERVACAO**.
✅ O botão de iniciar **não aparece**.

### B8 — PTA ocupada por outra pessoa
Faça logout, entre como outro funcionário e abra a mesma PTA.

✅ Aviso de que a PTA está em uso, com o nome e a matrícula de quem está usando.
✅ Nenhum botão de finalizar — só o dono finaliza.

### B9 — Uso aberto em outra PTA
Com uso aberto na PTA-001, abra `?pta=PTA-002`.

✅ *"Você tem um uso em aberto na PTA-001..."* e um atalho para voltar a ela.

### B10 — Finalização antes do previsto
Inicie um uso com fim para daqui a 3 horas e finalize em seguida.

✅ O diálogo mostra o horário do clique.
✅ Aviso: *"Uso finalizado as HH:MM."*
✅ Em **MINHA PROGRAMACAO**, as duas linhas aparecem:
```
08:00 → 12:00 (previsto)
08:00 → 10:47 (efetivo)
```
⚠️ O previsto **não** pode ter sido alterado.

### B11 — Finalização depois do previsto
Inicie um uso com fim daqui a poucos minutos, espere passar e finalize.

✅ *"Uso finalizado as HH:MM (após o horário pretendido de HH:MM)."*
✅ Antes de finalizar, o painel exibe: *"O horário pretendido já passou. O uso
continua aberto até a finalização."*

### B12 — Não existe finalização automática
Deixe passar o horário pretendido sem clicar em nada e recarregue.

✅ O uso continua **EM USO**. Só o clique fecha.

---

## C. Observações

### C1 — Contador
Abra **OBSERVACAO** e digite.

✅ O contador acompanha: `152 / 200 caracteres`.
✅ Ao chegar em 200 o campo para de aceitar e o contador fica destacado.

### C2 — Durante o uso
Salve uma observação com o uso ainda aberto.

✅ Salva. A tela informa que o prazo de 30 minutos começa após a finalização.

### C3 — Dentro dos 30 minutos
Finalize o uso e edite a observação em seguida.

✅ Salva. A tela mostra *"Prazo de edição: até HH:MM (Xmin restantes)"*.

### C4 — Depois dos 30 minutos
Force o vencimento (é o mesmo que esperar meia hora):
```sql
update usos set limite_edicao_observacao = now() - interval '1 minute'
 where id = 'COLE-O-ID-DO-USO';
```
Recarregue a tela da observação.

✅ Campo desabilitado e mensagem *"Seu período de edição da observação já
terminou."*

### C5 — Prazo vencendo com a tela aberta
Abra a observação, rode o UPDATE de C4 em outra aba e só então salve.

✅ O servidor recusa: *"Seu período de edição da observação já terminou."*
⚠️ Este é o teste que prova que a regra não depende do frontend.

---

## D. QR Code 2 — calendário e agendamento

### D1 — Abertura
`agenda.html?modo=agenda`

✅ Calendário do mês atual, **hoje já selecionado** e destacado.
✅ Dias com registros trazem pontos: azul = agendamento, laranja = uso.
✅ Barra superior mostra *"Visitante (somente consulta)"*.

### D2 — Consulta sem login
Navegue entre dias e meses, abra **HISTORICO** e **AUDITORIA**.

✅ Tudo funciona sem identificação.

### D3 — Criar agendamento
Toque em **+ AGENDAR** sem estar logado.

✅ O login aparece e, ao terminar, o formulário abre sozinho.
✅ Após criar: aviso de sucesso e o calendário salta para o dia agendado.

### D4 — Conflito
Crie `PTA-002`, amanhã, `08:00 → 10:00`. Depois tente `09:00 → 11:00` na mesma
PTA e dia.

✅ Aviso vermelho ao preencher os campos (antes de enviar).
✅ Ao insistir: *"Este horário entra em conflito com outra programação."*

### D5 — Horário adjacente
Na mesma PTA, tente `10:00 → 12:00`.

✅ **Permitido** — encostar não é sobrepor.

### D6 — Agendamento no passado
Escolha uma data anterior a hoje.

✅ *"Só é possível agendar para um horário futuro."*
⚠️ O seletor de data também deve impedir, pelo atributo `min`.

### D7 — Detalhe e cancelamento
Toque num cartão de programação sua.

✅ Painel lateral com PTA, autor, setor, horários, situação e criação.
✅ Botão de cancelar aparece **só** nas suas programações ainda `AGENDADO`.
✅ Após cancelar, ela continua na lista, riscada, como `CANCELADO`.

---

## E. Sobrescrita — a regra central

Este é o teste mais importante do sistema.

**Preparação.** Como João (10001), agende a `PTA-003` para **hoje**, começando em
cerca de 30 minutos, duração de 2 horas.

**Execução.** Saia, entre como Carlos (10003), abra `?modo=uso&pta=PTA-003`.

✅ O painel avisa: *"Programações registradas para esta PTA"*, listando a de João,
com a explicação de que iniciar agora tem prioridade e não apaga o registro.

Inicie o uso com fim daqui a 2 horas.

✅ Aviso: *"Uso iniciado. 1 programação(ões) foi(ram) marcada(s) como afetada(s)."*

**Conferência no calendário** (`agenda.html`, dia de hoje):

✅ **Dois** cartões da PTA-003:
- o de João, com borda vermelha e etiqueta **AFETADO POR USO IMEDIATO**;
- o de Carlos, com borda laranja e etiqueta **EM USO**.

⚠️ O agendamento de João **não pode ter sumido**.

Toque no cartão de João:

✅ Seção *"Afetado por uso imediato (QR Code 1)"* com data/hora, autor da
sobrescrita e o horário real do uso.
✅ Frase: *"A programação original permanece registrada. Nada foi apagado."*

Toque no cartão de Carlos:

✅ Seção *"Programações afetadas por este uso"*, com
`AGENDADO → AFETADO_POR_USO_IMEDIATO`.

**Conferência na auditoria** (**AUDITORIA**):

✅ Evento **Agendamento sobrescrito** no topo, com autor, horário e as linhas de
mudança `status: AGENDADO → AFETADO_POR_USO_IMEDIATO`.
✅ Logo abaixo, **Uso iniciado**.

---

## F. Segurança

### F1 — Manipulação de ID
Com o uso de outra pessoa aberto, abra o console e chame diretamente:
```js
const { rpc } = await import('./js/api.js');
await rpc('fn_uso_finalizar', { p_token: JSON.parse(localStorage['pta.sessao']).token,
                                p_uso_id: 'ID-DO-USO-DE-OUTRA-PESSOA' });
```
✅ Erro `SEM_PERMISSAO`.

### F2 — Acesso direto às tabelas
```js
const { supabase } = await import('./js/api.js');
console.log(await supabase().from('funcionarios').select('*'));
```
✅ Retorna erro ou lista vazia — nunca os hashes de PIN.

### F3 — Token adulterado
```js
localStorage['pta.sessao'] = JSON.stringify({
  token: '00000000-0000-0000-0000-000000000000',
  funcionario: { nome: 'Falso' } });
```
Recarregue.

✅ O sistema volta para a tela de setor.

### F4 — Apagar histórico
No SQL Editor: `delete from auditoria;`

✅ Erro `HISTORICO_IMUTAVEL`.

---

## G. Interface

| Verificação | Esperado |
|---|---|
| Celular 360px | sem rolagem horizontal em nenhuma tela |
| Botões de ação | pelo menos 64px de altura |
| Tema escuro do aparelho | cores se adaptam, contraste preservado |
| Navegação por teclado | `Tab` alcança tudo; foco visível |
| Modo avião | *"Sem conexão com o servidor..."* — sem tela em branco |
| `js/config.js` em branco | tela explicando a configuração pendente |
| Impressão do calendário | sai limpo, sem botões |

---

## Checklist final

- [ ] `sql/06_testes.sql` fecha com **0 falhas**
- [ ] Fluxo completo do item 48 (QR1: setor → nome → PIN → uso → finalizar → observação)
- [ ] Fluxo completo do item 48 (QR2: consultar → agendar → sofrer sobrescrita → histórico)
- [ ] Seção E inteira conferida
- [ ] Seção F inteira conferida
- [ ] Testado num celular real, lendo um QR Code impresso

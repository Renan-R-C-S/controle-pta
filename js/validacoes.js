/**
 * VALIDACOES DO FRONTEND
 * ---------------------------------------------------------------------------
 * IMPORTANTE (itens 22 e 31): tudo o que esta aqui existe apenas para dar
 * FEEDBACK RAPIDO ao usuario. Nenhuma destas funcoes protege o sistema.
 * As mesmas regras estao implementadas no banco (sql/01_schema.sql e
 * sql/02_funcoes.sql), que e a autoridade final.
 */

import { APP } from './config.js';
import { ErroApp } from './erros.js';

/** REGRA 2: PIN com exatamente 4 digitos. */
export function pinValido(pin) {
  return new RegExp(`^[0-9]{${APP.digitosPin}}$`).test(pin ?? '');
}

/** Matricula: 4 a 10 digitos numericos. */
export function matriculaValida(matricula) {
  return /^[0-9]{4,10}$/.test((matricula ?? '').trim());
}

export function nomeValido(nome) {
  const limpo = (nome ?? '').trim();
  return limpo.length >= 3 && limpo.length <= 80;
}

/** REGRA 13. */
export function observacaoValida(texto) {
  return (texto ?? '').length <= APP.limiteObservacao;
}

/** "HH:MM" -> minutos desde a meia-noite. */
export function horaEmMinutos(hora) {
  if (!/^\d{2}:\d{2}$/.test(hora ?? '')) return null;
  const [h, m] = hora.split(':').map(Number);
  if (h > 23 || m > 59) return null;
  return h * 60 + m;
}

/** Item 12: o horario final precisa ser posterior ao inicial. */
export function intervaloValido(horaInicio, horaFim) {
  const i = horaEmMinutos(horaInicio);
  const f = horaEmMinutos(horaFim);
  return i !== null && f !== null && f > i;
}

/**
 * Item 22: verifica sobreposicao contra a lista ja carregada na tela.
 * Dois intervalos [a1,a2) e [b1,b2) se sobrepoem quando a1 < b2 e b1 < a2 -
 * por isso 10:00-12:00 logo apos 08:00-10:00 e permitido.
 *
 * A checagem definitiva e feita pela constraint de exclusao do PostgreSQL.
 */
export function conflitaCom(horaInicio, horaFim, ocupados) {
  const i = horaEmMinutos(horaInicio);
  const f = horaEmMinutos(horaFim);
  if (i === null || f === null) return null;

  return (
    ocupados.find((item) => {
      const oi = horaEmMinutos(item.inicio);
      const of = horaEmMinutos(item.fim);
      if (oi === null || of === null) return false;
      return i < of && oi < f;
    }) ?? null
  );
}

/** Valida o formulario de cadastro e lanca ErroApp na primeira falha. */
export function validarCadastro({ nome, matricula, pin, confirmacao }) {
  if (!nomeValido(nome)) throw new ErroApp('NOME_INVALIDO');
  if (!matriculaValida(matricula)) throw new ErroApp('MATRICULA_FORMATO');
  if (!pinValido(pin)) throw new ErroApp('PIN_FORMATO');
  if (pin !== confirmacao) throw new ErroApp('PIN_DIFERENTE');
}

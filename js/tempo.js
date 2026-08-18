/**
 * TEMPO E FUSO HORARIO (item 34)
 * ---------------------------------------------------------------------------
 * A hora oficial vem SEMPRE do servidor (funcao fn_agora do banco). O relogio
 * do celular so e usado para animar o contador entre uma consulta e outra, e
 * nunca para gravar um horario.
 *
 * O deslocamento entre o relogio local e o do servidor e medido uma vez e
 * reaplicado, de modo que um aparelho com a hora errada nao distorce a tela.
 */

import { rpc } from './api.js';
import { APP } from './config.js';

let deslocamentoMs = 0;

/** Le a hora oficial do servidor e calcula o deslocamento do relogio local. */
export async function sincronizarRelogio() {
  const agora = await rpc('fn_agora');
  const servidor = new Date(agora.utc).getTime();
  deslocamentoMs = servidor - Date.now();
  return agora;
}

/** Instante atual corrigido pelo deslocamento do servidor. */
export function agora() {
  return new Date(Date.now() + deslocamentoMs);
}

const FUSO = { timeZone: APP.fusoHorario };

/** "14:35" no fuso oficial. */
export function horaCurta(data = agora()) {
  return new Intl.DateTimeFormat('pt-BR', {
    ...FUSO, hour: '2-digit', minute: '2-digit', hour12: false,
  }).format(data);
}

/** "18/08/2026" no fuso oficial. */
export function dataCurta(data = agora()) {
  return new Intl.DateTimeFormat('pt-BR', {
    ...FUSO, day: '2-digit', month: '2-digit', year: 'numeric',
  }).format(data);
}

/** "14:35" (formato aceito por <input type="time">). */
export function isoHora(data = agora()) {
  return new Intl.DateTimeFormat('en-GB', {
    ...FUSO, hour: '2-digit', minute: '2-digit', hour12: false,
  }).format(data);
}

/** Converte "2026-08-18T14:35" (texto devolvido pelas RPC) em Date. */
export function deTextoLocal(texto) {
  if (!texto) return null;
  // O texto ja vem no fuso oficial; interpretamos como horario local do
  // dispositivo apenas para calcular diferencas em minutos.
  return new Date(texto.replace(' ', 'T'));
}

/** Diferenca em minutos entre dois instantes (b - a). */
export function minutosEntre(a, b) {
  return Math.round((b.getTime() - a.getTime()) / 60000);
}

/** "1h 23min" a partir de uma quantidade de minutos. */
export function duracaoHumana(minutos) {
  const m = Math.max(0, Math.round(minutos));
  const h = Math.floor(m / 60);
  const r = m % 60;
  if (h === 0) return `${r}min`;
  if (r === 0) return `${h}h`;
  return `${h}h ${r}min`;
}

/** "agosto de 2026" */
export function mesAnoExtenso(ano, mes) {
  return new Intl.DateTimeFormat('pt-BR', { month: 'long', year: 'numeric' })
    .format(new Date(ano, mes - 1, 1));
}

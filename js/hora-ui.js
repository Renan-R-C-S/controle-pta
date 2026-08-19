/**
 * SELETOR DE HORARIO EM 12 HORAS (AM/PM)
 * ---------------------------------------------------------------------------
 * Substitui o <input type="time"> na tela de INICIAR/DEFINIR USO.
 *
 * Por que um controle proprio:
 *
 *   1. AM/PM explicito. O campo nativo em pt-BR mostra 24h, e o pedido era
 *      poder escolher AM ou PM.
 *
 *   2. Alvos de toque grandes. A tela e usada em pe, muitas vezes de luva.
 *
 *   3. A VIRADA DA MEIA-NOITE fica visivel. As 23h, escolher 1:00 AM significa
 *      a madrugada seguinte - e o aviso embaixo do controle diz isso com todas
 *      as letras ("amanha, 01:00, daqui a 2h"), antes de a pessoa confirmar.
 *      O banco aplica a mesma regra; aqui e so para ninguem se surpreender.
 *
 * O valor devolvido e sempre "HH:MM" em 24 horas, que e o formato que o banco
 * espera. A conversao 12h -> 24h mora toda aqui dentro.
 */

import { criar, preencher } from './ui.js';
import { agora, duracaoHumana, minutosEntre } from './tempo.js';

const MINUTOS = ['00', '05', '10', '15', '20', '25', '30', '35', '40', '45', '50', '55'];

/** 13:05 -> { hora12: 1, minuto: '05', periodo: 'PM' } */
function de24h(data) {
  const h = data.getHours();
  return {
    hora12: h % 12 === 0 ? 12 : h % 12,
    minuto: String(Math.floor(data.getMinutes() / 5) * 5).padStart(2, '0'),
    periodo: h < 12 ? 'AM' : 'PM',
  };
}

/** 12 AM e meia-noite; 12 PM e meio-dia. E a fonte classica de erro aqui. */
function para24h(hora12, periodo) {
  if (periodo === 'AM') return hora12 === 12 ? 0 : hora12;
  return hora12 === 12 ? 12 : hora12 + 12;
}

/**
 * @param {object}  [opcoes]
 * @param {number}  [opcoes.minutosAdiante] posicao inicial, em minutos a partir de agora
 * @param {Function}[opcoes.aoMudar]        recebe { valor, amanha, minutos }
 * @returns {{ elemento: HTMLElement, valor: () => string, resumo: () => object }}
 */
export function criarSeletorHora({ minutosAdiante = 60, aoMudar = null } = {}) {
  const inicial = de24h(new Date(agora().getTime() + minutosAdiante * 60000));

  const selHora = criar('select', { classe: 'campo campo-hora', 'aria-label': 'Hora' },
    Array.from({ length: 12 }, (_, i) => i + 1).map((h) =>
      criar('option', { value: String(h), texto: String(h).padStart(2, '0'),
                        ...(h === inicial.hora12 ? { selected: true } : {}) })));

  const selMinuto = criar('select', { classe: 'campo campo-hora', 'aria-label': 'Minuto' },
    MINUTOS.map((m) =>
      criar('option', { value: m, texto: m, ...(m === inicial.minuto ? { selected: true } : {}) })));

  let periodo = inicial.periodo;

  const btnAm = criar('button', { classe: 'btn btn-periodo', type: 'button', texto: 'AM' });
  const btnPm = criar('button', { classe: 'btn btn-periodo', type: 'button', texto: 'PM' });

  const aviso = criar('p', { classe: 'dica dica-horario' });

  function calcular() {
    const h24 = para24h(Number(selHora.value), periodo);
    const valor = `${String(h24).padStart(2, '0')}:${selMinuto.value}`;

    const agoraD = agora();
    const alvo = new Date(agoraD);
    alvo.setHours(h24, Number(selMinuto.value), 0, 0);

    // Horario que ja passou hoje significa a madrugada seguinte - a mesma
    // regra que fn_uso_iniciar aplica no banco.
    const amanha = alvo <= agoraD;
    if (amanha) alvo.setDate(alvo.getDate() + 1);

    return { valor, amanha, minutos: minutosEntre(agoraD, alvo), alvo };
  }

  function desenhar() {
    btnAm.classList.toggle('ativo', periodo === 'AM');
    btnPm.classList.toggle('ativo', periodo === 'PM');
    btnAm.setAttribute('aria-pressed', String(periodo === 'AM'));
    btnPm.setAttribute('aria-pressed', String(periodo === 'PM'));

    const r = calcular();
    aviso.textContent = r.amanha
      ? `Amanha, ${r.valor} — daqui a ${duracaoHumana(r.minutos)}.`
      : `Hoje, ${r.valor} — daqui a ${duracaoHumana(r.minutos)}.`;
    aviso.classList.toggle('destaque-amanha', r.amanha);

    aoMudar?.(r);
  }

  btnAm.addEventListener('click', () => { periodo = 'AM'; desenhar(); });
  btnPm.addEventListener('click', () => { periodo = 'PM'; desenhar(); });
  selHora.addEventListener('change', desenhar);
  selMinuto.addEventListener('change', desenhar);

  const elemento = criar('div', { classe: 'bloco-horario' }, [
    criar('div', { classe: 'linha-horario' }, [
      selHora,
      criar('span', { classe: 'sep-horario', texto: ':' }),
      selMinuto,
      criar('div', { classe: 'grupo-periodo' }, [btnAm, btnPm]),
    ]),
    aviso,
  ]);

  desenhar();

  return {
    elemento,
    /** "HH:MM" em 24 horas. */
    valor: () => calcular().valor,
    /** { valor, amanha, minutos, alvo } */
    resumo: calcular,
  };
}

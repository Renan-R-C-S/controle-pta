/**
 * CALENDARIO MENSAL (item 26)
 * ---------------------------------------------------------------------------
 * Componente puro de interface: recebe o mes, os marcadores por dia e os
 * callbacks; nao conhece Supabase nem regras de negocio.
 *
 * O dia de hoje ja vem selecionado quando a tela abre (exigencia do item 26) -
 * quem faz isso e app-agenda.js, usando a data oficial do servidor.
 */

import { criar, preencher } from './ui.js';
import { mesAnoExtenso } from './tempo.js';

const DIAS_SEMANA = ['dom', 'seg', 'ter', 'qua', 'qui', 'sex', 'sab'];

/**
 * @param {object} opcoes
 * @param {HTMLElement} opcoes.container
 * @param {number} opcoes.ano
 * @param {number} opcoes.mes            1-12
 * @param {string} opcoes.diaSelecionado "YYYY-MM-DD"
 * @param {string} opcoes.hoje           "YYYY-MM-DD" (data oficial do servidor)
 * @param {Array}  opcoes.marcadores     [{ dia, agendamentos, usos }]
 * @param {Function} opcoes.aoSelecionarDia
 * @param {Function} opcoes.aoMudarMes   recebe (ano, mes)
 */
export function montarCalendario({
  container,
  ano,
  mes,
  diaSelecionado,
  hoje,
  marcadores = [],
  aoSelecionarDia,
  aoMudarMes,
}) {
  const porDia = new Map(marcadores.map((m) => [m.dia, m]));

  const cabecalho = criar('div', { classe: 'cal-cabecalho' }, [
    criar('button', {
      classe: 'cal-nav',
      type: 'button',
      'aria-label': 'Mes anterior',
      texto: '‹',
      onClick: () => {
        const anterior = mes === 1 ? { ano: ano - 1, mes: 12 } : { ano, mes: mes - 1 };
        aoMudarMes(anterior.ano, anterior.mes);
      },
    }),
    criar('span', { classe: 'cal-titulo', texto: mesAnoExtenso(ano, mes) }),
    criar('button', {
      classe: 'cal-nav',
      type: 'button',
      'aria-label': 'Proximo mes',
      texto: '›',
      onClick: () => {
        const proximo = mes === 12 ? { ano: ano + 1, mes: 1 } : { ano, mes: mes + 1 };
        aoMudarMes(proximo.ano, proximo.mes);
      },
    }),
  ]);

  const grade = criar('div', { classe: 'cal-grade', role: 'grid' });

  for (const dia of DIAS_SEMANA) {
    grade.append(criar('span', { classe: 'cal-dia-semana', texto: dia }));
  }

  // Quantos espacos vazios antes do dia 1 (0 = domingo)
  const primeiroDiaSemana = new Date(ano, mes - 1, 1).getDay();
  const totalDias = new Date(ano, mes, 0).getDate();

  for (let i = 0; i < primeiroDiaSemana; i += 1) {
    grade.append(criar('span', { classe: 'cal-vazio' }));
  }

  for (let dia = 1; dia <= totalDias; dia += 1) {
    const iso = `${ano}-${String(mes).padStart(2, '0')}-${String(dia).padStart(2, '0')}`;
    const marcador = porDia.get(iso);
    const total = (marcador?.agendamentos ?? 0) + (marcador?.usos ?? 0);

    const classes = ['cal-dia'];
    if (iso === diaSelecionado) classes.push('selecionado');
    if (iso === hoje) classes.push('hoje');
    if (total > 0) classes.push('com-registros');

    grade.append(
      criar(
        'button',
        {
          classe: classes.join(' '),
          type: 'button',
          dados: { dia: iso },
          'aria-label': `${dia} - ${total} registro(s)`,
          'aria-pressed': iso === diaSelecionado ? 'true' : 'false',
          onClick: () => aoSelecionarDia(iso),
        },
        [
          criar('span', { classe: 'cal-numero', texto: String(dia) }),
          total > 0
            ? criar('span', { classe: 'cal-pontos' }, [
                marcador.agendamentos > 0
                  ? criar('i', { classe: 'ponto ponto-agendado', title: `${marcador.agendamentos} agendamento(s)` })
                  : null,
                marcador.usos > 0
                  ? criar('i', { classe: 'ponto ponto-uso', title: `${marcador.usos} uso(s)` })
                  : null,
              ])
            : null,
        ],
      ),
    );
  }

  const legenda = criar('div', { classe: 'cal-legenda' }, [
    criar('span', {}, [criar('i', { classe: 'ponto ponto-agendado' }), ' Agendamento']),
    criar('span', {}, [criar('i', { classe: 'ponto ponto-uso' }), ' Uso']),
  ]);

  preencher(container, [cabecalho, grade, legenda]);
}

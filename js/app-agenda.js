/**
 * APLICACAO DO QR CODE 2 - CALENDARIO E AGENDAMENTO (itens 20, 22, 26, 27)
 * ---------------------------------------------------------------------------
 * Aberta pelo QR Code fixado em local geral da fabrica:
 *     https://dominio.com/agenda.html?modo=agenda
 *
 * DECISAO (registrada em docs/DECISOES.md): a CONSULTA do calendario nao exige
 * login - qualquer pessoa que leia o QR Code ve a programacao do dia. Ja para
 * CRIAR ou CANCELAR uma programacao o funcionario precisa se identificar, pois
 * o autor do agendamento e informacao obrigatoria (itens 3 e 20).
 */

import { agendaDoDia, calendarioDoMes, cancelar, criar as criarAgendamento, detalhe, ocupacoesDe } from './agendamentos.js';
import { diferencas, listar as listarAuditoria, rotuloAcao } from './auditoria.js';
import { funcionarioLogado, sair, validarSessao } from './auth.js';
import { montarCalendario } from './calendario.js';
import { configuracaoPendente } from './config.js';
import { criarFluxoLogin } from './login-ui.js';
import { listarPtas } from './ptas.js';
import { sincronizarRelogio } from './tempo.js';
import {
  $, abrirPainel, avisar, carregandoGlobal, comCarregamento, confirmar, criar, etiqueta, fecharPainel,
  mostrarTela, preencher, tratarErro,
} from './ui.js';
import { historico } from './usos.js';
import { conflitaCom, intervaloValido } from './validacoes.js';

/* -------------------------------------------------------------------------- */
/* Estado                                                                      */
/* -------------------------------------------------------------------------- */

const estado = {
  hoje: null,
  diaSelecionado: null,
  ano: null,
  mes: null,
  marcadores: [],
  itensDoDia: [],
  ptas: [],
  filtroPta: null,
  /** Acao a executar assim que o login terminar. */
  aposLogin: null,
};

/* -------------------------------------------------------------------------- */
/* Inicializacao                                                               */
/* -------------------------------------------------------------------------- */

async function iniciarPagina() {
  if (configuracaoPendente()) {
    carregandoGlobal(false);
    mostrarTela('tela-config');
    return;
  }

  carregandoGlobal(true, 'Carregando calendario...');

  try {
    const relogio = await sincronizarRelogio();

    // Item 26: o dia atual (segundo o servidor) ja vem selecionado.
    estado.hoje = relogio.data;
    estado.diaSelecionado = relogio.data;
    const [ano, mes] = relogio.data.split('-').map(Number);
    estado.ano = ano;
    estado.mes = mes;

    estado.ptas = await listarPtas();
    await validarSessao().catch(() => null);

    montarFiltroPtas();
    await Promise.all([carregarMes(), carregarDia()]);
    atualizarBarraUsuario();

    carregandoGlobal(false);
    mostrarTela('tela-calendario');
  } catch (erro) {
    carregandoGlobal(false);
    tratarErro(erro);
    mostrarTela('tela-config');
  }
}

function atualizarBarraUsuario() {
  const funcionario = funcionarioLogado();
  $('#usuario-atual').textContent = funcionario
    ? `${funcionario.nome} • ${funcionario.setor}`
    : 'Visitante (somente consulta)';
  $('#btn-sair').hidden = !funcionario;
}

/**
 * Garante que existe um funcionario identificado antes de uma acao de escrita.
 * Se nao houver, abre o fluxo de login e retoma a acao depois.
 */
function exigirLogin(acao) {
  if (funcionarioLogado()) {
    acao();
    return;
  }
  estado.aposLogin = acao;
  const fluxo = criarFluxoLogin($('#login-container'), {
    subtitulo: 'Identifique-se para registrar uma programacao.',
    aoEntrar: () => {
      atualizarBarraUsuario();
      const pendente = estado.aposLogin;
      estado.aposLogin = null;
      mostrarTela('tela-calendario');
      pendente?.();
    },
  });
  mostrarTela('tela-login');
  fluxo.iniciar();
}

/* -------------------------------------------------------------------------- */
/* Calendario (item 26)                                                        */
/* -------------------------------------------------------------------------- */

async function carregarMes() {
  try {
    estado.marcadores = await calendarioDoMes(estado.ano, estado.mes);
  } catch (erro) {
    tratarErro(erro);
    estado.marcadores = [];
  }
  desenharCalendario();
}

function desenharCalendario() {
  montarCalendario({
    container: $('#calendario'),
    ano: estado.ano,
    mes: estado.mes,
    diaSelecionado: estado.diaSelecionado,
    hoje: estado.hoje,
    marcadores: estado.marcadores,
    aoSelecionarDia: (dia) => {
      estado.diaSelecionado = dia;
      desenharCalendario();
      carregarDia();
    },
    aoMudarMes: (ano, mes) => {
      estado.ano = ano;
      estado.mes = mes;
      carregarMes();
    },
  });
}

/* -------------------------------------------------------------------------- */
/* Lista do dia (item 27)                                                      */
/* -------------------------------------------------------------------------- */

function montarFiltroPtas() {
  const seletor = $('#filtro-pta');
  preencher(seletor, [
    criar('option', { value: '', texto: 'Todas as PTAs' }),
    ...estado.ptas.map((pta) => criar('option', { value: pta.id, texto: pta.codigo })),
  ]);
  seletor.addEventListener('change', () => {
    estado.filtroPta = seletor.value || null;
    carregarDia();
  });
}

async function carregarDia() {
  const lista = $('#lista-dia');
  preencher(lista, criar('p', { classe: 'carregando-texto', texto: 'Carregando...' }));
  $('#titulo-dia').textContent = formatarDiaLongo(estado.diaSelecionado);

  try {
    estado.itensDoDia = await agendaDoDia(estado.diaSelecionado, estado.filtroPta);
  } catch (erro) {
    tratarErro(erro);
    return;
  }

  if (!estado.itensDoDia.length) {
    preencher(lista, criar('p', { classe: 'vazio', texto: 'Nenhum registro para este dia.' }));
    return;
  }

  preencher(
    lista,
    estado.itensDoDia.map((item) => cartaoDeRegistro(item)),
  );
}

/**
 * Item 26: diferenciacao visual entre agendamento, uso em andamento,
 * uso finalizado e agendamento sobrescrito.
 */
function classeDoItem(item) {
  if (item.tipo === 'USO') {
    return item.status === 'EM_USO' ? 'cartao uso-andamento' : 'cartao uso-finalizado';
  }
  if (item.status === 'AGENDADO') return 'cartao agendamento';
  if (item.status === 'CANCELADO') return 'cartao cancelado';
  if (item.status === 'CONCLUIDO') return 'cartao concluido';
  return 'cartao sobrescrito';
}

function cartaoDeRegistro(item) {
  const efetivo = item.tipo === 'USO';

  return criar(
    'button',
    {
      classe: classeDoItem(item),
      type: 'button',
      onClick: () => abrirDetalhe(item.tipo, item.id),
    },
    [
      criar('div', { classe: 'cartao-topo' }, [
        criar('strong', { classe: 'cartao-pta', texto: item.pta_codigo }),
        etiqueta(item.status),
      ]),
      criar('div', { classe: 'cartao-horas' }, [
        criar('span', {
          classe: 'horas-principal',
          texto: `${item.inicio} → ${efetivo && item.fim_efetivo ? item.fim_efetivo : item.fim}`,
        }),
        criar('span', {
          classe: 'horas-tipo',
          texto: efetivo
            ? item.fim_efetivo
              ? `efetivo (pretendido ate ${item.fim})`
              : 'em andamento (pretendido)'
            : 'planejado',
        }),
      ]),
      criar('div', { classe: 'cartao-pessoa' }, [
        criar('span', { texto: item.funcionario }),
        criar('span', { classe: 'cartao-setor', texto: `${item.setor} • ${item.matricula}` }),
      ]),
      item.observacao ? criar('p', { classe: 'cartao-obs', texto: item.observacao }) : null,
    ],
  );
}

/* -------------------------------------------------------------------------- */
/* Detalhe de um registro (item 27)                                            */
/* -------------------------------------------------------------------------- */

async function abrirDetalhe(tipo, id) {
  try {
    const dados = await detalhe(tipo, id);
    abrirPainel(tipo === 'USO' ? 'Detalhe do uso' : 'Detalhe da programacao', conteudoDetalhe(dados));
  } catch (erro) {
    tratarErro(erro);
  }
}

function conteudoDetalhe(dados) {
  const linhas = [
    linha('PTA', dados.pta),
    linha('Funcionario', `${dados.funcionario} (${dados.matricula})`),
    linha('Setor', dados.setor),
    linha('Data', dados.data),
  ];

  if (dados.tipo === 'AGENDAMENTO') {
    linhas.push(
      linha('Planejado', `${dados.inicio_planejado} → ${dados.fim_planejado}`),
      linha('Situacao', dados.status),
      linha('Criado em', dados.criado_em),
    );
    if (dados.motivo_status) linhas.push(linha('Motivo', dados.motivo_status));

    if (dados.afetado_por?.length) {
      linhas.push(
        criar('h4', { classe: 'secao', texto: 'Afetado por uso imediato (QR Code 1)' }),
        criar(
          'ul',
          { classe: 'lista-simples' },
          dados.afetado_por.map((evento) =>
            criar('li', {
              texto: `${evento.quando} • ${evento.por} • uso real ${evento.inicio_efetivo} → ${evento.fim_pretendido}`,
            }),
          ),
        ),
        criar('p', {
          classe: 'dica',
          texto: 'A programacao original permanece registrada. Nada foi apagado.',
        }),
      );
    }
  } else {
    linhas.push(
      linha('Inicio efetivo', dados.inicio_efetivo),
      linha('Fim pretendido', dados.fim_pretendido),
      linha('Fim efetivo', dados.fim_efetivo ?? 'em aberto'),
      linha('Situacao', dados.status),
    );
    if (dados.ultrapassou_previsto) {
      linhas.push(criar('p', { classe: 'alerta', texto: 'O uso ultrapassou o horario pretendido.' }));
    }
    if (dados.observacao) {
      linhas.push(
        criar('h4', { classe: 'secao', texto: 'Observacao' }),
        criar('p', { classe: 'registro-obs', texto: dados.observacao }),
        dados.observacao_atualizada_em
          ? criar('p', { classe: 'dica', texto: `Atualizada em ${dados.observacao_atualizada_em}` })
          : null,
      );
    }
    if (dados.agendamentos_afetados?.length) {
      linhas.push(
        criar('h4', { classe: 'secao', texto: 'Programacoes afetadas por este uso' }),
        criar(
          'ul',
          { classe: 'lista-simples' },
          dados.agendamentos_afetados.map((item) =>
            criar('li', {
              texto: `${item.funcionario} • ${item.inicio_planejado} → ${item.fim_planejado} • ${item.status_anterior} → ${item.status_novo}`,
            }),
          ),
        ),
      );
    }
  }

  // Cancelamento so aparece para o autor de uma programacao ainda ativa.
  const funcionario = funcionarioLogado();
  if (
    dados.tipo === 'AGENDAMENTO' &&
    dados.status === 'AGENDADO' &&
    funcionario &&
    dados.matricula === funcionario.matricula
  ) {
    linhas.push(
      criar('button', {
        classe: 'btn btn-secundario btn-largo',
        type: 'button',
        texto: 'Cancelar esta programacao',
        onClick: async (evento) => {
          const ok = await confirmar({
            titulo: 'Cancelar programacao',
            corpo: [criar('p', { texto: 'A programacao ficara registrada como CANCELADA no historico.' })],
            textoOk: 'Cancelar programacao',
            textoCancelar: 'Voltar',
          });
          if (!ok) return;
          try {
            await comCarregamento(evento.currentTarget, () => cancelar(dados.id));
            avisar('Programacao cancelada.', 'ok');
            fecharPainel();
            await Promise.all([carregarMes(), carregarDia()]);
          } catch (erro) {
            tratarErro(erro);
          }
        },
      }),
    );
  }

  return linhas.filter(Boolean);
}

function linha(rotulo, valor) {
  return criar('div', { classe: 'linha-detalhe' }, [
    criar('span', { classe: 'rotulo-mini', texto: rotulo }),
    criar('strong', { texto: String(valor ?? '-') }),
  ]);
}

/* -------------------------------------------------------------------------- */
/* Novo agendamento (itens 20 e 22)                                            */
/* -------------------------------------------------------------------------- */

function abrirNovoAgendamento() {
  const seletorPta = criar(
    'select',
    { classe: 'campo', id: 'ag-pta', 'data-foco': 'true' },
    estado.ptas.map((pta) => criar('option', { value: pta.id, texto: `${pta.codigo} — ${pta.descricao ?? ''}` })),
  );
  if (estado.filtroPta) seletorPta.value = estado.filtroPta;

  const campoData = criar('input', {
    classe: 'campo',
    id: 'ag-data',
    type: 'date',
    value: estado.diaSelecionado,
    min: estado.hoje,
  });
  const campoInicio = criar('input', { classe: 'campo', id: 'ag-inicio', type: 'time', value: '08:00' });
  const campoFim = criar('input', { classe: 'campo', id: 'ag-fim', type: 'time', value: '10:00' });

  const avisoConflito = criar('p', { classe: 'aviso-conflito' });

  /** Item 22: aviso imediato; a decisao final e do banco. */
  async function checarConflito() {
    avisoConflito.textContent = '';
    avisoConflito.classList.remove('visivel');
    if (!campoData.value || !campoInicio.value || !campoFim.value) return;

    try {
      const itens = await agendaDoDia(campoData.value, seletorPta.value);
      const ocupados = ocupacoesDe(itens, seletorPta.value);
      const choque = conflitaCom(campoInicio.value, campoFim.value, ocupados);
      if (choque) {
        avisoConflito.textContent = `Conflito com ${choque.rotulo}.`;
        avisoConflito.classList.add('visivel');
      }
    } catch {
      /* aviso e opcional: se falhar, o banco ainda barra o conflito */
    }
  }

  for (const campo of [seletorPta, campoData, campoInicio, campoFim]) {
    campo.addEventListener('change', checarConflito);
  }

  const botao = criar('button', { classe: 'btn btn-primario btn-largo', type: 'submit', texto: 'AGENDAR' });

  const formulario = criar('form', { classe: 'form-agendamento', novalidate: true }, [
    bloco('PTA', seletorPta, 'ag-pta'),
    bloco('Data', campoData, 'ag-data'),
    criar('div', { classe: 'linha-campos' }, [
      bloco('Inicio', campoInicio, 'ag-inicio'),
      bloco('Fim', campoFim, 'ag-fim'),
    ]),
    avisoConflito,
    criar('p', {
      classe: 'dica',
      texto: 'Esta e uma PROGRAMACAO. O uso real e registrado pelo QR Code da propria PTA e tem prioridade sobre o que foi planejado.',
    }),
    botao,
    criar('button', {
      classe: 'btn btn-texto',
      type: 'button',
      texto: 'Voltar ao calendario',
      onClick: () => mostrarTela('tela-calendario'),
    }),
  ]);

  formulario.addEventListener('submit', async (evento) => {
    evento.preventDefault();

    if (!intervaloValido(campoInicio.value, campoFim.value)) {
      avisar('O horario final deve ser posterior ao horario inicial.', 'erro');
      return;
    }

    try {
      await comCarregamento(botao, async () => {
        const criado = await criarAgendamento({
          ptaId: seletorPta.value,
          data: campoData.value,
          horaInicio: campoInicio.value,
          horaFim: campoFim.value,
        });
        avisar(`Programacao criada: ${criado.pta} em ${criado.data}, ${criado.inicio} - ${criado.fim}.`, 'ok');

        estado.diaSelecionado = campoData.value;
        const [ano, mes] = campoData.value.split('-').map(Number);
        estado.ano = ano;
        estado.mes = mes;

        await Promise.all([carregarMes(), carregarDia()]);
        mostrarTela('tela-calendario');
      });
    } catch (erro) {
      tratarErro(erro);
    }
  });

  preencher($('#novo-corpo'), formulario);
  mostrarTela('tela-novo');
  checarConflito();
}

function bloco(rotulo, campo, id) {
  return criar('div', { classe: 'campo-bloco' }, [
    criar('label', { classe: 'rotulo', for: id, texto: rotulo }),
    campo,
  ]);
}

/* -------------------------------------------------------------------------- */
/* Historico e auditoria (itens 3 e 25)                                        */
/* -------------------------------------------------------------------------- */

async function abrirHistorico() {
  mostrarTela('tela-historico');
  preencher($('#historico-corpo'), criar('p', { classe: 'carregando-texto', texto: 'Carregando...' }));

  try {
    const linhas = await historico({ ptaId: estado.filtroPta, limite: 200 });

    if (!linhas.length) {
      preencher($('#historico-corpo'), criar('p', { classe: 'vazio', texto: 'Nenhum uso registrado ainda.' }));
      return;
    }

    const tabela = criar('table', { classe: 'tabela' }, [
      criar('thead', {}, [
        criar('tr', {}, [
          criar('th', { texto: 'Data' }),
          criar('th', { texto: 'PTA' }),
          criar('th', { texto: 'Funcionario' }),
          criar('th', { texto: 'Previsto' }),
          criar('th', { texto: 'Efetivo' }),
          criar('th', { texto: 'Situacao' }),
        ]),
      ]),
      criar(
        'tbody',
        {},
        linhas.map((item) =>
          criar('tr', { classe: item.ultrapassou ? 'linha-atencao' : '' }, [
            criar('td', { texto: formatarDataBr(item.data) }),
            criar('td', { texto: item.pta_codigo }),
            criar('td', {}, [
              criar('span', { texto: item.funcionario }),
              criar('span', { classe: 'celula-secundaria', texto: item.setor }),
            ]),
            criar('td', { texto: `${item.inicio} → ${item.fim_pretendido}` }),
            criar('td', { texto: item.fim_efetivo ? `${item.inicio} → ${item.fim_efetivo}` : 'em aberto' }),
            criar('td', {}, [etiqueta(item.status)]),
          ]),
        ),
      ),
    ]);

    preencher($('#historico-corpo'), [
      criar('p', { classe: 'dica', texto: 'Previsto = o que foi planejado. Efetivo = o que aconteceu. As linhas destacadas ultrapassaram o horario pretendido.' }),
      criar('div', { classe: 'tabela-rolagem' }, tabela),
    ]);
  } catch (erro) {
    tratarErro(erro);
  }
}

async function abrirAuditoria() {
  mostrarTela('tela-auditoria');
  preencher($('#auditoria-corpo'), criar('p', { classe: 'carregando-texto', texto: 'Carregando...' }));

  try {
    const eventos = await listarAuditoria({ limite: 150, ptaId: estado.filtroPta });

    if (!eventos.length) {
      preencher($('#auditoria-corpo'), criar('p', { classe: 'vazio', texto: 'Nenhum evento registrado.' }));
      return;
    }

    preencher($('#auditoria-corpo'), [
      criar('p', {
        classe: 'dica',
        texto: 'Registro imutavel de todas as acoes relevantes. Nao pode ser editado nem apagado por nenhum usuario do sistema.',
      }),
      criar(
        'ul',
        { classe: 'linha-tempo' },
        eventos.map((evento) => {
          const mudancas = diferencas(evento.antes, evento.depois);
          return criar('li', { classe: 'evento' }, [
            criar('div', { classe: 'evento-topo' }, [
              criar('strong', { texto: rotuloAcao(evento.tipo_acao) }),
              criar('span', { classe: 'evento-quando', texto: evento.quando }),
            ]),
            criar('span', { classe: 'evento-quem', texto: `${evento.usuario} • ${evento.pta}` }),
            evento.descricao ? criar('p', { classe: 'evento-descricao', texto: evento.descricao }) : null,
            mudancas.length
              ? criar(
                  'ul',
                  { classe: 'lista-mudancas' },
                  mudancas.map((m) => criar('li', { texto: `${m.campo}: ${m.de} → ${m.para}` })),
                )
              : null,
          ]);
        }),
      ),
    ]);
  } catch (erro) {
    tratarErro(erro);
  }
}

/* -------------------------------------------------------------------------- */
/* Apoio                                                                       */
/* -------------------------------------------------------------------------- */

function formatarDataBr(iso) {
  if (!iso) return '-';
  const [ano, mes, dia] = String(iso).slice(0, 10).split('-');
  return `${dia}/${mes}/${ano}`;
}

function formatarDiaLongo(iso) {
  const [ano, mes, dia] = iso.split('-').map(Number);
  const data = new Date(ano, mes - 1, dia);
  const texto = new Intl.DateTimeFormat('pt-BR', {
    weekday: 'long', day: '2-digit', month: 'long', year: 'numeric',
  }).format(data);
  return texto.charAt(0).toUpperCase() + texto.slice(1);
}

/* -------------------------------------------------------------------------- */
/* Ligacoes globais                                                            */
/* -------------------------------------------------------------------------- */

document.addEventListener('DOMContentLoaded', () => {
  $('#btn-novo').addEventListener('click', () => exigirLogin(abrirNovoAgendamento));
  $('#btn-historico').addEventListener('click', abrirHistorico);
  $('#btn-auditoria').addEventListener('click', abrirAuditoria);
  $('#btn-hoje').addEventListener('click', () => {
    estado.diaSelecionado = estado.hoje;
    const [ano, mes] = estado.hoje.split('-').map(Number);
    estado.ano = ano;
    estado.mes = mes;
    carregarMes();
    carregarDia();
    mostrarTela('tela-calendario');
  });
  $('#painel-fechar').addEventListener('click', fecharPainel);
  $('#btn-sair').addEventListener('click', async () => {
    await sair();
    atualizarBarraUsuario();
    avisar('Voce saiu do sistema.', 'info');
  });

  for (const botao of document.querySelectorAll('[data-voltar-calendario]')) {
    botao.addEventListener('click', () => mostrarTela('tela-calendario'));
  }

  iniciarPagina();
});


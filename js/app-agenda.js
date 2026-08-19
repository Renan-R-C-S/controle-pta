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

import {
  agendaDoDia, alterar as alterarAgendamento, calendarioDoMes, cancelar,
  criar as criarAgendamento, detalhe, ocupacoesDe,
} from './agendamentos.js';
import {
  cancelarUso, configuracao, definirHorizonteCiclico, definirLimiteMatriculas,
  definirMaxHorasUso, definirPapel, excluirFuncionario, excluirReservada,
  listarFuncionarios as adminListarFuncionarios, listarReservadas, reativarFuncionario,
  rotuloPapel, salvarReservada, souAdmin, souMaster,
} from './admin.js';
import {
  criar as criarAviso, definirAtivo as definirAvisoAtivo, excluir as excluirAviso,
  listar as listarAvisos,
} from './avisos.js';
import {
  DIAS, criar as criarCiclico, desativar as desativarCiclico, descreverRegra,
  estender as estenderCiclico, listar as listarCiclicos,
} from './ciclicos.js';
import { criarSeletorTerceiro } from './fornecedor-ui.js';
import { mostrarAvisosDoLogin } from './aviso-ui.js';
import { diferencas, listar as listarAuditoria, rotuloAcao } from './auditoria.js';
import { funcionarioLogado, listarSetores, sair, validarSessao } from './auth.js';
import { exigirTrocaPinProvisorio, montarPerfil } from './perfil-ui.js';
import { montarCalendario } from './calendario.js';
import { APP, configuracaoPendente } from './config.js';
import { criarFluxoLogin } from './login-ui.js';
import {
  alterarPta, criarPta, definirAtivo as definirPtaAtiva, emUsoAgora, excluirPta,
  listarParaAdmin as listarPtasAdmin, listarPtas,
} from './ptas.js';
import { sincronizarRelogio } from './tempo.js';
import {
  $, abrirPainel, avisar, carregandoGlobal, comCarregamento, confirmar, criar, etiqueta, fecharPainel,
  mostrarTela, pessoaComTerceiro, preencher, tratarErro,
} from './ui.js';
import { finalizar as finalizarUso, historico } from './usos.js';
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
  setores: [],
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
    estado.setores = await listarSetores().catch(() => []);
    await validarSessao().catch(() => null);

    montarFiltroPtas();
    montarBotaoEmUso();
    await Promise.all([carregarMes(), carregarDia()]);
    atualizarBarraUsuario();

    carregandoGlobal(false);
    mostrarTela('tela-calendario');
    convidarIdentificacao();
  } catch (erro) {
    carregandoGlobal(false);
    tratarErro(erro);
    mostrarTela('tela-config');
  }
}

/** Marca, na aba atual, que o convite ja foi mostrado. */
const CHAVE_CONVITE = 'pta.convite';

/**
 * Convite de identificacao na chegada.
 *
 * DISPENSAVEL de proposito. A decisao 4 de docs/DECISOES.md mantem a consulta
 * livre: o QR Code 2 fica em local de passagem e precisa responder "a PTA esta
 * livre?" sem burocracia. O popup convida quem chega a se identificar - nao
 * barra a leitura de quem so quer olhar o dia.
 */
function convidarIdentificacao() {
  if (funcionarioLogado()) return;

  // A marca tem dois valores, e a diferenca entre eles e o item 4:
  //
  //   'visto'   a pessoa dispensou o convite de proposito -> nao volta mais
  //   'tentou'  ela abriu o cadastro e nao terminou       -> volta a aparecer
  //
  // Assim quem desistiu no meio do cadastro reencontra o convite ao voltar,
  // enquanto quem so queria consultar nao e importunado de novo.
  if (sessionStorage.getItem(CHAVE_CONVITE) === 'visto') return;
  sessionStorage.setItem(CHAVE_CONVITE, 'visto');

  const popup = criar('dialog', { classe: 'dialogo' });
  const fechar = () => {
    popup.close();
    popup.remove();
  };

  preencher(popup, [
    criar('h3', { texto: 'Identifique-se' }),
    criar('p', {
      texto: 'Para agendar uma PTA ou registrar uso, entre com sua matricula e PIN.',
    }),
    criar('p', {
      classe: 'dica',
      texto: 'Ainda nao tem cadastro? O primeiro acesso fica na mesma tela, '
           + 'depois de escolher o setor.',
    }),
    criar('div', { classe: 'dialogo-acoes empilhado' }, [
      criar('button', {
        classe: 'btn btn-primario btn-largo',
        type: 'button',
        texto: 'ENTRAR OU CADASTRAR',
        onClick: () => {
          fechar();
          // Se abandonar o cadastro, o convite reaparece ao voltar (item 4).
          sessionStorage.setItem(CHAVE_CONVITE, 'tentou');
          exigirLogin(() => {}, 'Entre com seu cadastro ou use o primeiro acesso.');
        },
      }),
      criar('button', {
        classe: 'btn btn-texto',
        type: 'button',
        texto: 'So quero consultar',
        onClick: fechar,
      }),
    ]),
  ]);

  popup.addEventListener('cancel', fechar);   // tecla Esc
  document.body.append(popup);
  popup.showModal();
}

function atualizarBarraUsuario() {
  const funcionario = funcionarioLogado();

  $('#usuario-atual').textContent = funcionario
    ? `${funcionario.nome} • ${funcionario.setor}`
      + (funcionario.admin ? ` • ${rotuloPapel(funcionario.papel)}` : '')
    : 'Visitante (somente consulta)';

  $('#btn-sair').hidden = !funcionario;
  $('#btn-perfil').hidden = !funcionario;
  // Esconder o botao e conveniencia, nao seguranca: quem chamar a funcao pelo
  // console recebe SEM_PERMISSAO_ADMIN do banco do mesmo jeito.
  $('#btn-admin').hidden = !souAdmin();
}

/**
 * Garante que existe um funcionario identificado antes de uma acao de escrita.
 * Se nao houver, abre o fluxo de login e retoma a acao depois.
 */
function exigirLogin(acao, subtitulo = 'Identifique-se para registrar uma programacao.') {
  if (funcionarioLogado()) {
    acao();
    return;
  }
  estado.aposLogin = acao;
  const fluxo = criarFluxoLogin($('#login-container'), {
    subtitulo,
    aoEntrar: async () => {
      // Quem esta com PIN provisorio troca antes de qualquer outra coisa.
      const trocou = await exigirTrocaPinProvisorio();
      if (!trocou) {
        sair();
        return;
      }
      sessionStorage.removeItem(CHAVE_CONVITE);   // entrou: o convite cumpriu o papel
      atualizarBarraUsuario();
      const pendente = estado.aposLogin;
      estado.aposLogin = null;
      mostrarTela('tela-calendario');
      pendente?.();
      mostrarAvisosDoLogin();
    },
  });
  mostrarTela('tela-login');
  fluxo.iniciar();
  montarVoltarDoLogin();
}

/**
 * "Voltar ao calendario" na tela de login.
 *
 * Fica FORA de #login-container de proposito: o fluxo de login reescreve aquele
 * elemento a cada passo, e o botao sumiria junto. Quem volta por aqui sem ter
 * entrado reencontra o convite, que e o item 4.
 */
function montarVoltarDoLogin() {
  const secao = $('#tela-login');
  if (secao.querySelector('.voltar-login')) return;

  secao.append(criar('button', {
    classe: 'btn btn-texto btn-largo voltar-login',
    type: 'button',
    texto: 'Voltar ao calendario',
    onClick: () => {
      estado.aposLogin = null;
      mostrarTela('tela-calendario');
      convidarIdentificacao();
    },
  }));
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
/* Lista "Em Uso" (item 13)                                                    */
/* -------------------------------------------------------------------------- */

/**
 * Botao discreto ao lado do filtro. Consulta livre, sem login: e a mesma
 * pergunta que o calendario responde ("a PTA esta livre?"), so que agora.
 */
function montarBotaoEmUso() {
  const barra = document.querySelector('.barra-acoes');
  if (!barra || barra.querySelector('.btn-em-uso')) return;

  barra.append(criar('button', {
    classe: 'btn btn-texto btn-em-uso',
    type: 'button',
    texto: 'Lista: Em Uso',
    onClick: abrirListaEmUso,
  }));
}

async function abrirListaEmUso() {
  abrirPainel('Em uso agora', criar('p', { classe: 'carregando-texto', texto: 'Carregando...' }));

  let dados;
  try {
    dados = await emUsoAgora();
  } catch (erro) {
    tratarErro(erro);
    fecharPainel();
    return;
  }

  const itens = dados.itens ?? [];

  if (!itens.length) {
    abrirPainel('Em uso agora', [
      criar('p', { classe: 'vazio', texto: 'Nenhuma PTA em uso neste momento.' }),
      criar('p', { classe: 'dica', texto: `Consultado as ${dados.agora?.hora ?? ''}.` }),
    ]);
    return;
  }

  abrirPainel(`Em uso agora (${itens.length})`, [
    criar('ul', { classe: 'lista-registros' }, itens.map((i) =>
      criar('li', { classe: i.origem === 'USO' ? 'registro em-uso-real' : 'registro em-uso-previsto' }, [
        criar('div', { classe: 'registro-topo' }, [
          criar('strong', { texto: i.pta }),
          criar('span', {
            classe: `etiqueta ${i.origem === 'USO' ? 'st-em_uso' : 'st-agendado'}`,
            // A distincao importa: um e uso registrado de verdade, o outro e so
            // uma programacao cujo horario esta correndo.
            texto: i.origem === 'USO' ? 'Uso registrado' : 'Programado',
          }),
        ]),
        criar('span', { classe: 'registro-horas' }, [
          pessoaComTerceiro(i.funcionario, i.fornecedor),
          ` • ${i.setor}`,
        ]),
        criar('span', {
          classe: 'registro-horas',
          texto: `${i.inicio} → ${i.fim_previsto}`
               + (i.minutos_aberto != null ? ` • aberto ha ${Math.floor(i.minutos_aberto / 60)}h${String(i.minutos_aberto % 60).padStart(2, '0')}` : '')
               + (i.local ? ` • ${i.local}` : ''),
        }),
        i.atrasado
          ? criar('p', { classe: 'alerta', texto: 'Passou do horario previsto.' })
          : null,
      ]))),
    criar('p', { classe: 'dica', texto: `Consultado as ${dados.agora?.hora ?? ''}.` }),
  ]);
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
    if (item.status === 'CANCELADO') return 'cartao cancelado';
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
        criar('span', { classe: 'cartao-etiquetas' }, [
          item.ciclico ? criar('span', { classe: 'etiqueta et-ciclico', texto: 'Ciclico' }) : null,
          etiqueta(item.status),
        ]),
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
        pessoaComTerceiro(item.funcionario, item.fornecedor),
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
    linha('Colaborador', `${dados.funcionario} (${dados.matricula})`),
    linha('Setor', dados.setor),
    linha('Data', dados.data),
  ];

  if (dados.fornecedor) {
    linhas.push(criar('div', { classe: 'linha-detalhe' }, [
      criar('span', { classe: 'rotulo-mini', texto: 'Terceiro incluido' }),
      criar('strong', { classe: 'terceiro-inline', texto: dados.fornecedor }),
    ]));
  }

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
    if (dados.status === 'CANCELADO') {
      linhas.push(criar('p', {
        classe: 'bloco-aviso',
        texto: `Cancelado pela administracao${dados.cancelado_por ? ` (${dados.cancelado_por})` : ''}. `
             + `${dados.motivo_cancelamento ?? ''} Sem horario final efetivo: o encerramento real nao foi observado.`,
      }));
    }

    // Item 12: quem abriu o uso finaliza por aqui tambem, sem precisar voltar
    // ate o QR Code da PTA. So o dono - o banco aplica a mesma regra.
    if (dados.status === 'EM_USO' && dados.funcionario_id === funcionarioLogado()?.id) {
      linhas.push(criar('button', {
        classe: 'btn btn-primario btn-largo',
        type: 'button',
        texto: 'FINALIZAR ESTE USO',
        onClick: async (evento) => {
          const ok = await confirmar({
            titulo: 'Finalizar uso',
            corpo: [
              criar('p', { texto: `Encerrar o uso da ${dados.pta} agora?` }),
              criar('p', { classe: 'dica', texto: 'O horario final gravado e o deste instante, medido no servidor.' }),
            ],
            textoOk: 'Finalizar',
            textoCancelar: 'Voltar',
          });
          if (!ok) return;
          try {
            await comCarregamento(evento.currentTarget, () => finalizarUso(dados.id));
            avisar('Uso finalizado.', 'ok');
            fecharPainel();
            await Promise.all([carregarMes(), carregarDia()]);
          } catch (erro) {
            tratarErro(erro);
          }
        },
      }));
    }

    // Um uso esquecido em aberto pode ser encerrado pela administracao.
    if (dados.status === 'EM_USO' && souAdmin()) {
      linhas.push(criar('button', {
        classe: 'btn btn-secundario btn-largo btn-perigo',
        type: 'button',
        texto: 'Cancelar este uso em aberto',
        onClick: async (evento) => {
          const ok = await confirmar({
            titulo: 'Cancelar uso em aberto',
            corpo: [
              criar('p', { texto: 'A PTA fica liberada e o registro passa a CANCELADA no cronograma.' }),
              criar('p', {
                classe: 'dica',
                texto: 'Nenhum horario final efetivo sera gravado: ninguem observou o fim real, '
                     + 'e inventar um horario corromperia o historico.',
              }),
            ],
            textoOk: 'Cancelar uso',
            textoCancelar: 'Voltar',
          });
          if (!ok) return;
          try {
            await comCarregamento(evento.currentTarget, () => cancelarUso(dados.id));
            avisar('Uso cancelado.', 'ok');
            fecharPainel();
            await Promise.all([carregarMes(), carregarDia()]);
          } catch (erro) {
            tratarErro(erro);
          }
        },
      }));
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

  // Alterar e cancelar aparecem para o AUTOR da programacao e para qualquer
  // ADMINISTRADOR. Quem decide de verdade e o banco, a cada chamada.
  const funcionario = funcionarioLogado();
  const souAutor = funcionario && dados.matricula === funcionario.matricula;

  if (dados.tipo === 'AGENDAMENTO' && dados.status === 'AGENDADO' && (souAutor || souAdmin())) {
    if (!souAutor) {
      linhas.push(criar('p', {
        classe: 'bloco-aviso',
        texto: 'Voce esta agindo como administrador sobre a programacao de outra pessoa. '
             + 'A alteracao fica registrada na auditoria com o seu nome.',
      }));
    }

    linhas.push(
      criar('button', {
        classe: 'btn btn-primario btn-largo',
        type: 'button',
        texto: 'Alterar horario',
        onClick: () => {
          fecharPainel();
          abrirAlterarAgendamento(dados);
        },
      }),
      criar('button', {
        classe: 'btn btn-secundario btn-largo',
        type: 'button',
        texto: 'Excluir esta programacao',
        onClick: async (evento) => {
          const ok = await confirmar({
            titulo: 'Excluir programacao',
            corpo: [
              criar('p', { texto: 'O horario sera liberado para outras pessoas.' }),
              criar('p', {
                classe: 'dica',
                texto: 'A programacao continua visivel no historico, marcada como CANCELADA. '
                     + 'Registros nao sao apagados fisicamente.',
              }),
            ],
            textoOk: 'Excluir',
            textoCancelar: 'Voltar',
          });
          if (!ok) return;
          try {
            await comCarregamento(evento.currentTarget, () => cancelar(dados.id));
            avisar('Programacao excluida.', 'ok');
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
  const terceiro = criarSeletorTerceiro();

  const formulario = criar('form', { classe: 'form-agendamento', novalidate: true }, [
    bloco('PTA', seletorPta, 'ag-pta'),
    bloco('Data', campoData, 'ag-data'),
    criar('div', { classe: 'linha-campos' }, [
      bloco('Inicio', campoInicio, 'ag-inicio'),
      bloco('Fim', campoFim, 'ag-fim'),
    ]),
    avisoConflito,
    terceiro.elemento,
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
          fornecedorId: terceiro.valor(),
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
  $('#tela-novo').querySelector('.titulo-passo').textContent = 'Nova programacao';
  mostrarTela('tela-novo');
  checarConflito();
}

function bloco(rotulo, campo, id) {
  return criar('div', { classe: 'campo-bloco' }, [
    criar('label', { classe: 'rotulo', for: id, texto: rotulo }),
    campo,
  ]);
}

/**
 * Altera data e horario de uma programacao existente.
 * A PTA nao muda aqui: trocar de equipamento e outra programacao, nao um ajuste
 * da mesma. Para isso, exclua esta e crie outra.
 */
function abrirAlterarAgendamento(dados) {
  const [dia, mes, ano] = String(dados.data).split('/');
  const dataIso = `${ano}-${mes}-${dia}`;

  const campoData = criar('input', { classe: 'campo', id: 'alt-data', type: 'date', value: dataIso, min: estado.hoje });
  const campoInicio = criar('input', { classe: 'campo', id: 'alt-inicio', type: 'time', value: dados.inicio_planejado });
  const campoFim = criar('input', { classe: 'campo', id: 'alt-fim', type: 'time', value: dados.fim_planejado });

  const botao = criar('button', { classe: 'btn btn-primario btn-largo', type: 'submit', texto: 'SALVAR ALTERACAO' });
  const terceiro = criarSeletorTerceiro({
    selecionadoId: dados.fornecedor_id ?? null,
    selecionadoNome: dados.fornecedor ?? null,
  });

  const formulario = criar('form', { classe: 'form-agendamento', novalidate: true }, [
    criar('div', { classe: 'bloco-identidade' }, [
      criar('div', {}, [criar('span', { classe: 'rotulo-mini', texto: 'PTA' }), criar('strong', { texto: dados.pta })]),
      criar('div', {}, [criar('span', { classe: 'rotulo-mini', texto: 'Autor' }), criar('strong', { texto: dados.funcionario })]),
      criar('div', {}, [criar('span', { classe: 'rotulo-mini', texto: 'Original' }),
        criar('strong', { texto: `${dados.inicio_planejado}-${dados.fim_planejado}` })]),
    ]),
    bloco('Data', campoData, 'alt-data'),
    criar('div', { classe: 'linha-campos' }, [
      bloco('Inicio', campoInicio, 'alt-inicio'),
      bloco('Fim', campoFim, 'alt-fim'),
    ]),
    terceiro.elemento,
    criar('p', { classe: 'dica', texto: 'O horario anterior e o novo ficam registrados na auditoria.' }),
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
        await alterarAgendamento({
          agendamentoId: dados.id,
          data: campoData.value,
          horaInicio: campoInicio.value,
          horaFim: campoFim.value,
          fornecedorId: terceiro.valor(),
        });
        avisar('Programacao alterada.', 'ok');

        estado.diaSelecionado = campoData.value;
        const [a, m] = campoData.value.split('-').map(Number);
        estado.ano = a;
        estado.mes = m;

        await Promise.all([carregarMes(), carregarDia()]);
        mostrarTela('tela-calendario');
      });
    } catch (erro) {
      tratarErro(erro);
    }
  });

  preencher($('#novo-corpo'), formulario);
  $('#tela-novo').querySelector('.titulo-passo').textContent = 'Alterar programacao';
  mostrarTela('tela-novo');
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
          criar('th', { texto: 'Colaborador' }),
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
/* Meu perfil                                                                  */
/* -------------------------------------------------------------------------- */

function abrirPerfil() {
  mostrarTela('tela-perfil');
  montarPerfil($('#perfil-container'), {
    aoAlterar: () => {
      atualizarBarraUsuario();
      carregarDia();
    },
  });
}

/* -------------------------------------------------------------------------- */
/* Administracao                                                               */
/* -------------------------------------------------------------------------- */

async function abrirAdmin() {
  mostrarTela('tela-admin');
  preencher($('#admin-corpo'), criar('p', { classe: 'carregando-texto', texto: 'Carregando...' }));

  let config;
  let pessoas;
  try {
    [config, pessoas] = await Promise.all([configuracao(), adminListarFuncionarios()]);
  } catch (erro) {
    tratarErro(erro);
    mostrarTela('tela-calendario');
    return;
  }

  const listaEl = criar('ul', { classe: 'lista-registros' });
  const busca = criar('input', {
    classe: 'campo campo-busca',
    type: 'search',
    autocomplete: 'off',
    placeholder: 'Buscar por nome ou matricula',
    'aria-label': 'Buscar colaborador',
  });

  const desenhar = () => {
    const termo = busca.value.trim().toLowerCase();
    const filtrados = termo
      ? pessoas.filter(
          (p) => p.nome.toLowerCase().includes(termo) || p.matricula.includes(termo),
        )
      : pessoas;
    preencher(listaEl, filtrados.length
      ? filtrados.map(linhaFuncionario)
      : criar('li', {}, [criar('p', { classe: 'vazio', texto: 'Nenhum colaborador encontrado.' })]));
  };
  busca.addEventListener('input', desenhar);

  const areaPtas       = criar('div', { classe: 'area-admin' });
  const areaAvisos     = criar('div', { classe: 'area-admin' });
  const areaReservadas = criar('div', { classe: 'area-admin' });
  const areaCiclicos   = criar('div', { classe: 'area-ciclicos' });

  preencher($('#admin-corpo'), [
    cartaoConfiguracao(config),
    areaPtas,
    areaAvisos,
    areaCiclicos,
    areaReservadas,
    criar('h3', { classe: 'secao', texto: `Colaboradores (${pessoas.length})` }),
    busca,
    listaEl,
  ]);
  desenhar();
  montarPtas(areaPtas);
  montarAvisos(areaAvisos, pessoas);
  montarCiclicos(areaCiclicos, pessoas);
  montarReservadas(areaReservadas);
}

/** Cartao de limite de matriculas. Somente o ADMIN_MASTER pode alterar. */
function cartaoConfiguracao(config) {
  const semLimite = config.limite_matriculas === 0;

  const resumo = criar('div', { classe: 'bloco-identidade' }, [
    criar('div', {}, [
      criar('span', { classe: 'rotulo-mini', texto: 'Ativos' }),
      criar('strong', { texto: String(config.ativos) }),
    ]),
    criar('div', {}, [
      criar('span', { classe: 'rotulo-mini', texto: 'Limite' }),
      criar('strong', { texto: semLimite ? 'sem limite' : String(config.limite_matriculas) }),
    ]),
    criar('div', {}, [
      criar('span', { classe: 'rotulo-mini', texto: 'Vagas' }),
      criar('strong', { texto: config.vagas === null ? '—' : String(config.vagas) }),
    ]),
  ]);

  // Teto de horas de um uso em aberto: qualquer administrador define.
  const campoHoras = criar('input', {
    classe: 'campo', id: 'max-horas', type: 'number', min: '1', max: '24', step: '1',
    value: String(config.max_horas_uso_aberto ?? 14),
  });
  const botaoHoras = criar('button', {
    classe: 'btn btn-primario btn-largo', type: 'submit', texto: 'SALVAR LIMITE DE HORAS',
  });
  const formHoras = criar('form', { classe: 'form-limite', novalidate: true }, [
    criar('label', { classe: 'rotulo', for: 'max-horas',
      texto: 'Maximo de horas que um uso pode ficar aberto' }),
    campoHoras,
    criar('p', { classe: 'dica',
      texto: 'Vale na abertura do uso. Nao encerra nada sozinho: usos que passam do limite '
           + 'aparecem destacados para a administracao decidir.' }),
    config.usos_abertos_excedidos > 0
      ? criar('p', { classe: 'erro-bloco',
          texto: `${config.usos_abertos_excedidos} uso(s) em aberto ja passaram do limite. `
               + 'Abra o dia no calendario e cancele pelo detalhe do registro.' })
      : null,
    botaoHoras,
  ]);
  formHoras.addEventListener('submit', async (evento) => {
    evento.preventDefault();
    try {
      await comCarregamento(botaoHoras, async () => {
        const r = await definirMaxHorasUso(Number(campoHoras.value));
        avisar(`Limite definido em ${r.horas} hora(s).`, 'ok');
        await abrirAdmin();
      });
    } catch (erro) {
      tratarErro(erro);
    }
  });

  const blocoHoras = criar('div', {}, [
    criar('h3', { classe: 'secao', texto: 'Uso em aberto' }),
    formHoras,
  ]);

  // Horizonte de geracao dos ciclicos: so o administrador principal muda.
  const campoHorizonte = criar('input', {
    classe: 'campo', id: 'horizonte-ciclico', type: 'number', min: '7', max: '1095', step: '1',
    value: String(config.horizonte_ciclico_dias ?? 365),
  });
  const botaoHorizonte = criar('button', {
    classe: 'btn btn-primario btn-largo', type: 'submit', texto: 'SALVAR HORIZONTE',
  });
  const formHorizonte = criar('form', { classe: 'form-limite', novalidate: true }, [
    criar('label', { classe: 'rotulo', for: 'horizonte-ciclico',
      texto: 'Ate quantos dias a frente gerar as ocorrencias ciclicas' }),
    campoHorizonte,
    criar('p', { classe: 'dica',
      texto: 'Padrao de 365 dias (1 ano). Aceita de 7 a 1095. Regras ja criadas nao sao '
           + 'regeradas sozinhas — use "Estender" na regra para empurrar o horizonte dela.' }),
    botaoHorizonte,
  ]);
  formHorizonte.addEventListener('submit', async (evento) => {
    evento.preventDefault();
    try {
      await comCarregamento(botaoHorizonte, async () => {
        const r = await definirHorizonteCiclico(Number(campoHorizonte.value));
        avisar(`Horizonte definido em ${r.dias} dias.`, 'ok');
        await abrirAdmin();
      });
    } catch (erro) {
      tratarErro(erro);
    }
  });

  const blocoHorizonte = souMaster()
    ? criar('div', {}, [
        criar('h3', { classe: 'secao', texto: 'Agendamentos ciclicos' }),
        formHorizonte,
      ])
    : null;

  const reservadas = config.matriculas_reservadas?.length
    ? criar('div', { classe: 'bloco-aviso' }, [
        criar('strong', { texto: 'Matriculas administrativas reservadas' }),
        criar(
          'ul',
          { classe: 'lista-simples' },
          config.matriculas_reservadas.map((r) =>
            criar('li', {
              texto: `${r.matricula} — ${rotuloPapel(r.papel)}${
                r.cadastrada ? ' (ja cadastrada)' : ' — AINDA NAO CADASTRADA'
              }`,
            }),
          ),
        ),
        criar('p', {
          classe: 'dica',
          texto: 'Quem cadastrar primeiro uma destas matriculas assume o papel. '
               + 'Garanta que sejam as pessoas certas antes de liberar o QR Code.',
        }),
      ])
    : null;

  if (!config.pode_alterar_limite) {
    return criar('div', {}, [
      criar('h3', { classe: 'secao', texto: 'Limite de matriculas' }),
      resumo,
      criar('p', { classe: 'dica', texto: 'Somente o administrador principal altera este limite.' }),
      blocoHoras,
      blocoHorizonte,
      reservadas,
    ]);
  }

  const campo = criar('input', {
    classe: 'campo',
    id: 'limite-matriculas',
    type: 'number',
    min: '0',
    step: '1',
    value: String(config.limite_matriculas),
  });

  const botao = criar('button', { classe: 'btn btn-primario btn-largo', type: 'submit', texto: 'SALVAR LIMITE' });

  const formulario = criar('form', { classe: 'form-limite', novalidate: true }, [
    criar('label', { classe: 'rotulo', for: 'limite-matriculas', texto: 'Maximo de colaboradores ativos' }),
    campo,
    criar('p', { classe: 'dica', texto: 'Use 0 para nao ter limite. Excluir um colaborador libera vaga.' }),
    botao,
  ]);

  formulario.addEventListener('submit', async (evento) => {
    evento.preventDefault();
    try {
      await comCarregamento(botao, async () => {
        const r = await definirLimiteMatriculas(Number(campo.value));
        avisar(
          r.limite === 0
            ? 'Limite removido: cadastros liberados.'
            : `Limite definido em ${r.limite} (${r.ativos} ativos).`,
          'ok',
        );
        await abrirAdmin();
      });
    } catch (erro) {
      tratarErro(erro);
    }
  });

  return criar('div', {}, [
    criar('h3', { classe: 'secao', texto: 'Limite de matriculas' }),
    resumo,
    formulario,
    blocoHoras,
    blocoHorizonte,
    reservadas,
  ]);
}

/** Uma linha da lista de funcionarios, com as acoes permitidas ao papel atual. */
function linhaFuncionario(pessoa) {
  const eu = funcionarioLogado();
  const souEu = pessoa.id === eu?.id;
  const master = pessoa.papel === 'ADMIN_MASTER';
  const acoes = [];

  if (pessoa.ativo && !master && !souEu) {
    if (pessoa.papel === 'FUNCIONARIO') {
      acoes.push(botaoAcao('Tornar administrador', async () => {
        await definirPapel(pessoa.id, 'ADMIN');
        avisar(`${pessoa.nome} agora e administrador.`, 'ok');
      }));
    } else if (pessoa.papel === 'ADMIN' && souMaster()) {
      acoes.push(botaoAcao('Remover administrador', async () => {
        await definirPapel(pessoa.id, 'FUNCIONARIO');
        avisar(`${pessoa.nome} voltou a ser funcionario comum.`, 'ok');
      }));
    }

    acoes.push(botaoAcao('Excluir', async () => {
      const ok = await confirmar({
        titulo: `Excluir ${pessoa.nome}?`,
        corpo: [
          criar('p', { texto: 'O colaborador deixa de aparecer na lista e nao consegue mais entrar. '
                            + 'As programacoes futuras dele sao canceladas e a vaga e liberada.' }),
          criar('p', { classe: 'dica', texto: 'Os usos e a auditoria dele permanecem: o historico do '
                                            + 'sistema nao pode ser apagado por ninguem.' }),
        ],
        textoOk: 'Excluir',
        textoCancelar: 'Voltar',
      });
      if (!ok) return false;
      const r = await excluirFuncionario(pessoa.id);
      avisar(
        r.agendamentos_cancelados > 0
          ? `${pessoa.nome} excluido. ${r.agendamentos_cancelados} programacao(oes) cancelada(s).`
          : `${pessoa.nome} excluido.`,
        'ok',
      );
      return true;
    }, 'perigo'));
  }

  if (!pessoa.ativo) {
    acoes.push(botaoAcao('Reativar', async () => {
      await reativarFuncionario(pessoa.id);
      avisar(`${pessoa.nome} reativado.`, 'ok');
    }));
  }

  return criar('li', { classe: pessoa.ativo ? 'registro' : 'registro inativo' }, [
    criar('div', { classe: 'registro-topo' }, [
      criar('strong', { texto: pessoa.nome + (souEu ? ' (voce)' : '') }),
      criar('span', { classe: `etiqueta papel-${pessoa.papel.toLowerCase()}`, texto: rotuloPapel(pessoa.papel) }),
    ]),
    criar('span', {
      classe: 'registro-horas',
      texto: `Matricula ${pessoa.matricula} • ${pessoa.setor}`
           + (pessoa.ultimo_login ? ` • ultimo acesso ${pessoa.ultimo_login}` : ' • nunca acessou'),
    }),
    pessoa.ativo ? null : criar('span', { classe: 'registro-horas forte', texto: 'EXCLUIDO (inativo)' }),
    acoes.length ? criar('div', { classe: 'acoes-linha' }, acoes) : null,
  ]);
}

/** Botao de acao que recarrega a tela quando a operacao muda alguma coisa. */
function botaoAcao(texto, acao, variante) {
  return criar('button', {
    classe: `btn btn-texto${variante === 'perigo' ? ' btn-perigo' : ''}`,
    type: 'button',
    texto,
    onClick: async (evento) => {
      try {
        await comCarregamento(evento.currentTarget, async () => {
          const seguiu = await acao();
          if (seguiu !== false) await abrirAdmin();
        });
      } catch (erro) {
        tratarErro(erro);
      }
    },
  });
}


/* -------------------------------------------------------------------------- */
/* Agendamentos ciclicos (administracao)                                       */
/* -------------------------------------------------------------------------- */

/**
 * Lista as regras de repeticao e oferece o cadastro de novas.
 * As ocorrencias viram programacoes comuns no calendario - por isso a checagem
 * de conflito e a prioridade do QR Code 1 continuam valendo sem caso especial.
 */
async function montarCiclicos(container, pessoas) {
  preencher(container, [
    criar('h3', { classe: 'secao', texto: 'Agendamentos ciclicos' }),
    criar('p', { classe: 'carregando-texto', texto: 'Carregando...' }),
  ]);

  let regras;
  try {
    regras = await listarCiclicos();
  } catch (erro) {
    tratarErro(erro);
    return;
  }

  const lista = regras.length
    ? criar('ul', { classe: 'lista-registros' }, regras.map((r) => linhaCiclico(r, container, pessoas)))
    : criar('p', { classe: 'vazio', texto: 'Nenhuma regra de repeticao cadastrada.' });

  preencher(container, [
    criar('h3', { classe: 'secao', texto: `Agendamentos ciclicos (${regras.length})` }),
    criar('button', {
      classe: 'btn btn-primario btn-largo',
      type: 'button',
      texto: '+ NOVA REGRA DE REPETICAO',
      onClick: () => formularioCiclico(container, pessoas),
    }),
    lista,
  ]);
}

function linhaCiclico(regra, container, pessoas) {
  const acoes = [];

  if (regra.ativo) {
    acoes.push(
      criar('button', {
        classe: 'btn btn-texto',
        type: 'button',
        texto: 'Estender',
        onClick: async (evento) => {
          try {
            await comCarregamento(evento.currentTarget, async () => {
              const r = await estenderCiclico(regra.id);
              avisar(
                r.criados > 0
                  ? `${r.criados} ocorrencia(s) criada(s)${r.pulados > 0 ? `, ${r.pulados} pulada(s) por conflito` : ''}.`
                  : 'Nenhuma ocorrencia nova: o horizonte ja estava coberto.',
                'ok',
              );
              await montarCiclicos(container, pessoas);
            });
          } catch (erro) {
            tratarErro(erro);
          }
        },
      }),
      criar('button', {
        classe: 'btn btn-texto btn-perigo',
        type: 'button',
        texto: 'Desativar',
        onClick: async (evento) => {
          const ok = await confirmar({
            titulo: 'Desativar regra de repeticao',
            corpo: [
              criar('p', { texto: 'As ocorrencias futuras serao canceladas e os horarios liberados.' }),
              criar('p', { classe: 'dica', texto: 'As ocorrencias passadas permanecem: sao historico.' }),
            ],
            textoOk: 'Desativar',
            textoCancelar: 'Voltar',
          });
          if (!ok) return;
          try {
            await comCarregamento(evento.currentTarget, async () => {
              const r = await desativarCiclico(regra.id, true);
              avisar(`Regra desativada. ${r.ocorrencias_canceladas} ocorrencia(s) cancelada(s).`, 'ok');
              await montarCiclicos(container, pessoas);
              await Promise.all([carregarMes(), carregarDia()]);
            });
          } catch (erro) {
            tratarErro(erro);
          }
        },
      }),
    );
  }

  return criar('li', { classe: regra.ativo ? 'registro' : 'registro inativo' }, [
    criar('div', { classe: 'registro-topo' }, [
      criar('strong', { texto: `${regra.pta} • ${regra.hora_inicio}–${regra.hora_fim}` }),
      criar('span', {
        classe: `etiqueta ${regra.ativo ? 'et-ciclico' : ''}`,
        texto: regra.ativo ? descreverRegra(regra) : 'Desativada',
      }),
    ]),
    criar('span', { classe: 'registro-horas' }, [
      pessoaComTerceiro(regra.funcionario, regra.fornecedor),
      ` • matricula ${regra.matricula}`,
    ]),
    criar('span', {
      classe: 'registro-horas',
      texto: `${regra.ocorrencias_futuras} ocorrencia(s) futura(s)`
           + (regra.gerado_ate ? ` • gerado ate ${regra.gerado_ate}` : '')
           + (regra.data_fim ? ` • termina em ${regra.data_fim}` : ''),
    }),
    criar('span', {
      classe: 'registro-horas',
      texto: `Criada por ${regra.criado_por}${regra.do_master ? ' (administrador principal)' : ''}`,
    }),
    acoes.length ? criar('div', { classe: 'acoes-linha' }, acoes) : null,
  ]);
}

function formularioCiclico(container, pessoas) {
  const ativos = pessoas.filter((p) => p.ativo);

  const seletorPta = criar('select', { classe: 'campo', id: 'cic-pta' },
    estado.ptas.map((pta) => criar('option', { value: pta.id, texto: pta.codigo })));

  // O ciclico fica em nome de um colaborador JA CADASTRADO, escolhido aqui.
  const seletorPessoa = criar('select', { classe: 'campo', id: 'cic-pessoa' },
    ativos.map((p) => criar('option', { value: p.id, texto: `${p.nome} — ${p.matricula}` })));

  const campoInicio = criar('input', { classe: 'campo', id: 'cic-inicio', type: 'time', value: '08:00' });
  const campoFim = criar('input', { classe: 'campo', id: 'cic-fim', type: 'time', value: '10:00' });

  const campoDataInicio = criar('input', { classe: 'campo', id: 'cic-de', type: 'date', value: estado.hoje });
  const campoDataFim = criar('input', { classe: 'campo', id: 'cic-ate', type: 'date' });

  /* ------------------------------------------------ como a repeticao ocorre */

  const caixasDias = DIAS.map((d) => {
    const cx = criar('input', { classe: 'cx-dia', type: 'checkbox', id: `dia-${d.valor}`, value: String(d.valor) });
    return { d, cx, bloco: criar('label', { classe: 'rotulo-dia', for: `dia-${d.valor}` }, [cx, d.curto]) };
  });
  const blocoDias = criar('div', { classe: 'grade-dias' }, caixasDias.map((x) => x.bloco));

  const campoIntervalo = criar('input', {
    classe: 'campo', id: 'cic-intervalo', type: 'number', min: '1', max: '365', step: '1', value: '7',
  });
  const blocoIntervalo = criar('div', { classe: 'campo-bloco', hidden: true }, [
    criar('label', { classe: 'rotulo', for: 'cic-intervalo', texto: 'Repetir a cada quantos dias' }),
    campoIntervalo,
  ]);

  const campoDiaMes = criar('input', {
    classe: 'campo', id: 'cic-dia-mes', type: 'number', min: '1', max: '31', step: '1', value: '1',
  });
  const blocoDiaMes = criar('div', { classe: 'campo-bloco', hidden: true }, [
    criar('label', { classe: 'rotulo', for: 'cic-dia-mes', texto: 'Dia do mes' }),
    campoDiaMes,
    criar('p', {
      classe: 'dica',
      texto: 'Dias 29, 30 e 31 nao existem em todo mes. Nesses casos o mes e PULADO, '
           + 'em vez de a ocorrencia cair no dia 1 do mes seguinte.',
    }),
  ]);

  const radioDias = criar('input', { type: 'radio', name: 'cic-tipo', id: 'tipo-dias', value: 'DIAS_SEMANA', checked: true });
  const radioIntervalo = criar('input', { type: 'radio', name: 'cic-tipo', id: 'tipo-intervalo', value: 'INTERVALO_DIAS' });
  const radioDiaMes = criar('input', { type: 'radio', name: 'cic-tipo', id: 'tipo-dia-mes', value: 'DIA_DO_MES' });

  const tipoEscolhido = () => {
    if (radioIntervalo.checked) return 'INTERVALO_DIAS';
    if (radioDiaMes.checked) return 'DIA_DO_MES';
    return 'DIAS_SEMANA';
  };

  const alternar = () => {
    const tipo = tipoEscolhido();
    blocoDias.hidden = tipo !== 'DIAS_SEMANA';
    blocoIntervalo.hidden = tipo !== 'INTERVALO_DIAS';
    blocoDiaMes.hidden = tipo !== 'DIA_DO_MES';
  };
  radioDias.addEventListener('change', alternar);
  radioIntervalo.addEventListener('change', alternar);
  radioDiaMes.addEventListener('change', alternar);

  const terceiro = criarSeletorTerceiro();
  const botao = criar('button', { classe: 'btn btn-primario btn-largo', type: 'submit', texto: 'CRIAR REGRA' });

  const formulario = criar('form', { classe: 'form-agendamento', novalidate: true }, [
    bloco('PTA', seletorPta, 'cic-pta'),
    bloco('Colaborador responsavel', seletorPessoa, 'cic-pessoa'),
    criar('div', { classe: 'linha-campos' }, [
      bloco('Inicio', campoInicio, 'cic-inicio'),
      bloco('Fim', campoFim, 'cic-fim'),
    ]),

    criar('h4', { classe: 'secao', texto: 'Como se repete' }),
    criar('div', { classe: 'grupo-radio' }, [
      criar('label', { classe: 'rotulo-radio', for: 'tipo-dias' }, [radioDias, ' Em dias da semana']),
      criar('label', { classe: 'rotulo-radio', for: 'tipo-intervalo' }, [radioIntervalo, ' A cada N dias']),
      criar('label', { classe: 'rotulo-radio', for: 'tipo-dia-mes' }, [radioDiaMes, ' Em um dia do mes']),
    ]),
    blocoDias,
    blocoIntervalo,
    blocoDiaMes,

    criar('div', { classe: 'linha-campos' }, [
      bloco('A partir de', campoDataInicio, 'cic-de'),
      bloco('Ate (opcional)', campoDataFim, 'cic-ate'),
    ]),

    terceiro.elemento,
    criar('p', {
      classe: 'dica',
      texto: 'As ocorrencias sao criadas para os proximos 90 dias. Datas ja ocupadas na mesma PTA '
           + 'sao puladas, e o total pulado aparece no aviso.',
    }),
    botao,
    criar('button', {
      classe: 'btn btn-texto',
      type: 'button',
      texto: 'Cancelar',
      onClick: () => montarCiclicos(container, pessoas),
    }),
  ]);

  formulario.addEventListener('submit', async (evento) => {
    evento.preventDefault();

    if (!intervaloValido(campoInicio.value, campoFim.value)) {
      avisar('O horario final deve ser posterior ao horario inicial.', 'erro');
      return;
    }
    const dias = caixasDias.filter((x) => x.cx.checked).map((x) => x.d.valor);
    if (radioDias.checked && !dias.length) {
      avisar('Selecione ao menos um dia da semana.', 'erro');
      return;
    }
    if (radioDiaMes.checked && (Number(campoDiaMes.value) < 1 || Number(campoDiaMes.value) > 31)) {
      avisar('Informe um dia do mes entre 1 e 31.', 'erro');
      return;
    }

    try {
      await comCarregamento(botao, async () => {
        const r = await criarCiclico({
          ptaId: seletorPta.value,
          funcionarioId: seletorPessoa.value,
          horaInicio: campoInicio.value,
          horaFim: campoFim.value,
          tipo: tipoEscolhido(),
          diasSemana: dias,
          intervaloDias: Number(campoIntervalo.value),
          diaDoMes: Number(campoDiaMes.value),
          dataInicio: campoDataInicio.value || null,
          dataFim: campoDataFim.value || null,
          fornecedorId: terceiro.valor(),
        });
        avisar(
          `Regra criada: ${r.criados} ocorrencia(s)`
          + (r.pulados > 0 ? `, ${r.pulados} pulada(s) por conflito de horario.` : '.'),
          'ok',
        );
        await montarCiclicos(container, pessoas);
        await Promise.all([carregarMes(), carregarDia()]);
      });
    } catch (erro) {
      tratarErro(erro);
    }
  });

  preencher(container, [
    criar('h3', { classe: 'secao', texto: 'Nova regra de repeticao' }),
    formulario,
  ]);
  alternar();
}


/* -------------------------------------------------------------------------- */
/* PTAs (item 5)                                                               */
/* -------------------------------------------------------------------------- */

/**
 * Gestao das PTAs disponiveis.
 *
 * Duas acoes diferentes, de proposito:
 *   DESABILITAR  some das telas de escolha, historico intacto - o caso comum,
 *                para plataforma em manutencao ou fora de operacao;
 *   EXCLUIR      apaga de verdade, e so funciona enquanto a PTA nunca teve uso,
 *                programacao ou regra ciclica - serve para corrigir um cadastro
 *                errado, nao para sumir com o passado.
 *
 * A propria listagem diz qual das duas esta disponivel, via `pode_excluir`.
 */
async function montarPtas(container) {
  preencher(container, [
    criar('h3', { classe: 'secao', texto: 'PTAs' }),
    criar('p', { classe: 'carregando-texto', texto: 'Carregando...' }),
  ]);

  let ptas;
  try {
    ptas = await listarPtasAdmin();
  } catch (erro) {
    tratarErro(erro);
    return;
  }

  preencher(container, [
    criar('h3', { classe: 'secao', texto: `PTAs (${ptas.length})` }),
    criar('button', {
      classe: 'btn btn-primario btn-largo',
      type: 'button',
      texto: '+ NOVA PTA',
      onClick: () => formularioPta(container, null),
    }),
    ptas.length
      ? criar('ul', { classe: 'lista-registros' }, ptas.map((p) => linhaPta(p, container)))
      : criar('p', { classe: 'vazio', texto: 'Nenhuma PTA cadastrada.' }),
  ]);
}

function linhaPta(pta, container) {
  const acoes = [
    criar('button', {
      classe: 'btn btn-texto',
      type: 'button',
      texto: 'Editar',
      onClick: () => formularioPta(container, pta),
    }),
    criar('button', {
      classe: 'btn btn-texto',
      type: 'button',
      texto: pta.ativo ? 'Desabilitar' : 'Habilitar',
      onClick: async (evento) => {
        try {
          await comCarregamento(evento.currentTarget, async () => {
            await definirPtaAtiva(pta.id, !pta.ativo);
            avisar(pta.ativo ? 'PTA desabilitada.' : 'PTA habilitada.', 'ok');
            await montarPtas(container);
            estado.ptas = await listarPtas();
            montarFiltroPtas();
          });
        } catch (erro) {
          tratarErro(erro);
        }
      },
    }),
  ];

  if (pta.pode_excluir) {
    acoes.push(criar('button', {
      classe: 'btn btn-texto btn-perigo',
      type: 'button',
      texto: 'Excluir',
      onClick: async (evento) => {
        const ok = await confirmar({
          titulo: `Excluir ${pta.codigo}`,
          corpo: [
            criar('p', { texto: 'Esta PTA nunca teve uso, programacao nem regra ciclica, entao pode ser apagada.' }),
            criar('p', { classe: 'dica', texto: 'A acao nao tem volta. Para tirar de circulacao sem apagar, use Desabilitar.' }),
          ],
          textoOk: 'Excluir',
          textoCancelar: 'Voltar',
        });
        if (!ok) return;
        try {
          await comCarregamento(evento.currentTarget, async () => {
            await excluirPta(pta.id);
            avisar('PTA excluida.', 'ok');
            await montarPtas(container);
            estado.ptas = await listarPtas();
            montarFiltroPtas();
          });
        } catch (erro) {
          tratarErro(erro);
        }
      },
    }));
  }

  return criar('li', { classe: pta.ativo ? 'registro' : 'registro inativo' }, [
    criar('div', { classe: 'registro-topo' }, [
      criar('strong', { texto: pta.codigo }),
      criar('span', {
        classe: `etiqueta ${pta.ativo ? 'st-agendado' : ''}`,
        texto: pta.ativo ? (pta.em_uso ? 'Em uso' : 'Disponivel') : 'Desabilitada',
      }),
    ]),
    criar('span', { classe: 'registro-horas', texto: [pta.descricao, pta.local].filter(Boolean).join(' • ') || '—' }),
    criar('span', {
      classe: 'registro-horas',
      texto: pta.programacoes_futuras > 0
        ? `${pta.programacoes_futuras} programacao(oes) futura(s)`
        : (pta.pode_excluir ? 'Sem historico — pode ser excluida' : 'Com historico registrado'),
    }),
    criar('div', { classe: 'acoes-linha' }, acoes),
  ]);
}

function formularioPta(container, pta) {
  const editando = Boolean(pta);

  const campoCodigo = criar('input', {
    classe: 'campo', id: 'pta-codigo', type: 'text', maxlength: '10',
    inputmode: 'numeric', value: pta?.codigo ?? '', placeholder: 'PTA-905 ou apenas 905',
  });
  const campoDescricao = criar('input', {
    classe: 'campo', id: 'pta-descricao', type: 'text', maxlength: '80',
    value: pta?.descricao ?? '', placeholder: 'Plataforma tesoura 10m',
  });
  const campoLocal = criar('input', {
    classe: 'campo', id: 'pta-local', type: 'text', maxlength: '80',
    value: pta?.local ?? '', placeholder: 'Galpao A - Linha 1',
  });

  const botao = criar('button', {
    classe: 'btn btn-primario btn-largo', type: 'submit',
    texto: editando ? 'SALVAR ALTERACOES' : 'CADASTRAR PTA',
  });

  const formulario = criar('form', { classe: 'form-agendamento', novalidate: true }, [
    bloco('Codigo', campoCodigo, 'pta-codigo'),
    criar('p', { classe: 'dica', texto: 'Pode digitar so o numero: 905 vira PTA-905.' }),
    bloco('Nome / descricao', campoDescricao, 'pta-descricao'),
    bloco('Local', campoLocal, 'pta-local'),
    botao,
    criar('button', {
      classe: 'btn btn-texto', type: 'button', texto: 'Cancelar',
      onClick: () => montarPtas(container),
    }),
  ]);

  formulario.addEventListener('submit', async (evento) => {
    evento.preventDefault();
    if (!campoCodigo.value.trim()) {
      avisar('Informe o codigo da PTA.', 'erro');
      return;
    }
    try {
      await comCarregamento(botao, async () => {
        const dados = {
          codigo: campoCodigo.value,
          descricao: campoDescricao.value,
          local: campoLocal.value,
        };
        if (editando) {
          await alterarPta({ id: pta.id, ...dados });
          avisar('PTA atualizada.', 'ok');
        } else {
          const nova = await criarPta(dados);
          avisar(`${nova.codigo} cadastrada.`, 'ok');
        }
        await montarPtas(container);
        estado.ptas = await listarPtas();
        montarFiltroPtas();
      });
    } catch (erro) {
      tratarErro(erro);
    }
  });

  preencher(container, [
    criar('h3', { classe: 'secao', texto: editando ? `Editar ${pta.codigo}` : 'Nova PTA' }),
    formulario,
  ]);
}

/* -------------------------------------------------------------------------- */
/* Matriculas reservadas (item 6 - somente ADMIN_MASTER)                       */
/* -------------------------------------------------------------------------- */

/**
 * Matricula reservada concede papel administrativo a quem se cadastrar com ela.
 * E o mecanismo de implantacao: permite criar o primeiro administrador sem
 * ninguem precisar mexer no banco.
 */
async function montarReservadas(container) {
  if (!souMaster()) return;

  preencher(container, [
    criar('h3', { classe: 'secao', texto: 'Matriculas reservadas' }),
    criar('p', { classe: 'carregando-texto', texto: 'Carregando...' }),
  ]);

  let reservas;
  try {
    reservas = await listarReservadas();
  } catch (erro) {
    tratarErro(erro);
    return;
  }

  const campoMatricula = criar('input', {
    classe: 'campo', id: 'res-matricula', type: 'text', inputmode: 'numeric',
    maxlength: '10', placeholder: '0591 ou 591',
  });
  const seletorPapel = criar('select', { classe: 'campo', id: 'res-papel' }, [
    criar('option', { value: 'ADMIN', texto: 'Administrador' }),
    criar('option', { value: 'ADMIN_MASTER', texto: 'Administrador principal' }),
  ]);
  const campoObs = criar('input', {
    classe: 'campo', id: 'res-obs', type: 'text', maxlength: '120',
    placeholder: 'Para que serve esta reserva',
  });
  const botao = criar('button', { classe: 'btn btn-primario btn-largo', type: 'submit', texto: 'SALVAR RESERVA' });

  const formulario = criar('form', { classe: 'form-agendamento', novalidate: true }, [
    bloco('Matricula', campoMatricula, 'res-matricula'),
    bloco('Papel concedido', seletorPapel, 'res-papel'),
    bloco('Observacao', campoObs, 'res-obs'),
    criar('p', {
      classe: 'dica',
      texto: 'Matricula curta ganha zeros a esquerda, igual ao cadastro. Salvar uma matricula '
           + 'que ja esta na lista atualiza o papel dela.',
    }),
    botao,
  ]);

  formulario.addEventListener('submit', async (evento) => {
    evento.preventDefault();
    try {
      await comCarregamento(botao, async () => {
        const r = await salvarReservada({
          matricula: campoMatricula.value,
          papel: seletorPapel.value,
          observacao: campoObs.value,
        });
        avisar(`Reserva ${r.matricula} salva.`, 'ok');
        campoMatricula.value = ''; campoObs.value = '';
        await montarReservadas(container);
      });
    } catch (erro) {
      tratarErro(erro);
    }
  });

  preencher(container, [
    criar('h3', { classe: 'secao', texto: `Matriculas reservadas (${reservas.length})` }),
    reservas.length
      ? criar('ul', { classe: 'lista-registros' }, reservas.map((r) =>
          criar('li', { classe: 'registro' }, [
            criar('div', { classe: 'registro-topo' }, [
              criar('strong', { texto: r.matricula }),
              criar('span', { classe: 'etiqueta', texto: rotuloPapel(r.papel) }),
            ]),
            criar('span', { classe: 'registro-horas', texto: r.observacao ?? '—' }),
            criar('span', {
              classe: 'registro-horas',
              texto: r.em_uso_por ? `Ja usada por ${r.em_uso_por}` : 'Ainda nao usada',
            }),
            criar('div', { classe: 'acoes-linha' }, [
              criar('button', {
                classe: 'btn btn-texto btn-perigo',
                type: 'button',
                texto: 'Remover',
                onClick: async (evento) => {
                  const ok = await confirmar({
                    titulo: `Remover a reserva ${r.matricula}`,
                    corpo: [
                      criar('p', { texto: 'Quem ainda nao se cadastrou com ela deixa de receber o papel automaticamente.' }),
                      criar('p', {
                        classe: 'dica',
                        texto: 'Quem JA se cadastrou continua com o papel atual. Para rebaixar alguem, '
                             + 'use a lista de colaboradores — nao um efeito colateral daqui.',
                      }),
                    ],
                    textoOk: 'Remover',
                    textoCancelar: 'Voltar',
                  });
                  if (!ok) return;
                  try {
                    await comCarregamento(evento.currentTarget, async () => {
                      await excluirReservada(r.matricula);
                      avisar('Reserva removida.', 'ok');
                      await montarReservadas(container);
                    });
                  } catch (erro) {
                    tratarErro(erro);
                  }
                },
              }),
            ]),
          ])))
      : criar('p', { classe: 'vazio', texto: 'Nenhuma matricula reservada.' }),
    formulario,
  ]);
}

/* -------------------------------------------------------------------------- */
/* Avisos (item 9)                                                             */
/* -------------------------------------------------------------------------- */

async function montarAvisos(container, pessoas) {
  preencher(container, [
    criar('h3', { classe: 'secao', texto: 'Avisos' }),
    criar('p', { classe: 'carregando-texto', texto: 'Carregando...' }),
  ]);

  let avisos;
  try {
    avisos = await listarAvisos();
  } catch (erro) {
    tratarErro(erro);
    return;
  }

  preencher(container, [
    criar('h3', { classe: 'secao', texto: `Avisos (${avisos.length})` }),
    criar('button', {
      classe: 'btn btn-primario btn-largo',
      type: 'button',
      texto: '+ NOVO AVISO',
      onClick: () => formularioAviso(container, pessoas),
    }),
    avisos.length
      ? criar('ul', { classe: 'lista-registros' }, avisos.map((a) => linhaAviso(a, container, pessoas)))
      : criar('p', { classe: 'vazio', texto: 'Nenhum aviso cadastrado.' }),
  ]);
}

function linhaAviso(aviso, container, pessoas) {
  const alcance = [];
  if (aviso.setores?.length) alcance.push(`Setores: ${aviso.setores.join(', ')}`);
  if (aviso.pessoas?.length) alcance.push(`Pessoas: ${aviso.pessoas.join(', ')}`);
  if (!alcance.length) alcance.push('Todos os colaboradores');

  const prazo = aviso.fim_em
    ? `${aviso.inicio_em ? `de ${aviso.inicio_em} ` : ''}ate ${aviso.fim_em}`
    : (aviso.inicio_em ? `a partir de ${aviso.inicio_em}` : 'prazo indefinido');

  return criar('li', { classe: aviso.vigente ? 'registro' : 'registro inativo' }, [
    criar('div', { classe: 'registro-topo' }, [
      criar('strong', { texto: aviso.titulo }),
      criar('span', {
        classe: `etiqueta ${aviso.vigente ? 'st-em_uso' : ''}`,
        texto: aviso.vigente ? 'Aparecendo' : (aviso.ativo ? 'Fora do prazo' : 'Desativado'),
      }),
    ]),
    criar('span', { classe: 'registro-horas', texto: aviso.mensagem }),
    criar('span', { classe: 'registro-horas', texto: alcance.join(' • ') }),
    criar('span', {
      classe: 'registro-horas',
      texto: `${prazo} • por ${aviso.autor}${aviso.do_master ? ' (administrador principal)' : ''}`,
    }),
    criar('div', { classe: 'acoes-linha' }, [
      criar('button', {
        classe: 'btn btn-texto',
        type: 'button',
        texto: aviso.ativo ? 'Desativar' : 'Reativar',
        onClick: async (evento) => {
          try {
            await comCarregamento(evento.currentTarget, async () => {
              await definirAvisoAtivo(aviso.id, !aviso.ativo);
              avisar(aviso.ativo ? 'Aviso desativado.' : 'Aviso reativado.', 'ok');
              await montarAvisos(container, pessoas);
            });
          } catch (erro) {
            tratarErro(erro);
          }
        },
      }),
      criar('button', {
        classe: 'btn btn-texto btn-perigo',
        type: 'button',
        texto: 'Excluir',
        onClick: async (evento) => {
          const ok = await confirmar({
            titulo: 'Excluir aviso',
            corpo: [
              criar('p', { texto: `"${aviso.titulo}" sera apagado.` }),
              criar('p', {
                classe: 'dica',
                texto: 'Aviso e comunicado, nao historico de operacao da PTA — por isso pode ser apagado. '
                     + 'Para so parar de exibir, use Desativar.',
              }),
            ],
            textoOk: 'Excluir',
            textoCancelar: 'Voltar',
          });
          if (!ok) return;
          try {
            await comCarregamento(evento.currentTarget, async () => {
              await excluirAviso(aviso.id);
              avisar('Aviso excluido.', 'ok');
              await montarAvisos(container, pessoas);
            });
          } catch (erro) {
            tratarErro(erro);
          }
        },
      }),
    ]),
  ]);
}

function formularioAviso(container, pessoas) {
  const ativos = pessoas.filter((p) => p.ativo);

  const campoTitulo = criar('input', {
    classe: 'campo', id: 'aviso-titulo', type: 'text', maxlength: '80',
    placeholder: 'Parada geral de energia',
  });
  const campoMensagem = criar('textarea', {
    classe: 'campo campo-area', id: 'aviso-mensagem', maxlength: '600', rows: '4',
    placeholder: 'Escreva o comunicado que aparecera no login.',
  });

  // Setores: caixas grandes, no mesmo estilo dos dias da semana do ciclico.
  const caixasSetor = estado.setores.map((s) => {
    const cx = criar('input', { classe: 'cx-dia', type: 'checkbox', id: `set-${s.id}`, value: s.id });
    return { s, cx, bloco: criar('label', { classe: 'rotulo-dia', for: `set-${s.id}` }, [cx, s.nome]) };
  });

  const seletorPessoas = criar('select', {
    classe: 'campo campo-multi', id: 'aviso-pessoas', multiple: true, size: '6',
    'aria-label': 'Colaboradores destinatarios',
  }, ativos.map((p) => criar('option', { value: p.id, texto: `${p.nome} — ${p.matricula}` })));

  const campoInicio = criar('input', { classe: 'campo', id: 'aviso-de', type: 'datetime-local' });
  const campoFim = criar('input', { classe: 'campo', id: 'aviso-ate', type: 'datetime-local' });

  const botao = criar('button', { classe: 'btn btn-primario btn-largo', type: 'submit', texto: 'CRIAR AVISO' });

  const formulario = criar('form', { classe: 'form-agendamento', novalidate: true }, [
    bloco('Titulo', campoTitulo, 'aviso-titulo'),
    bloco('Mensagem', campoMensagem, 'aviso-mensagem'),

    criar('h4', { classe: 'secao', texto: 'Para quem' }),
    criar('p', {
      classe: 'dica',
      texto: 'Sem nenhuma marcacao, o aviso vale para todos. Marcando setores e/ou pessoas, '
           + 'ele alcanca a soma dos escolhidos.',
    }),
    criar('label', { classe: 'rotulo', texto: 'Setores' }),
    criar('div', { classe: 'grade-dias' }, caixasSetor.map((x) => x.bloco)),
    bloco('Pessoas especificas', seletorPessoas, 'aviso-pessoas'),
    criar('p', { classe: 'dica', texto: 'Segure Ctrl (ou toque) para escolher mais de uma.' }),

    criar('h4', { classe: 'secao', texto: 'Prazo' }),
    criar('div', { classe: 'linha-campos' }, [
      bloco('Comeca em', campoInicio, 'aviso-de'),
      bloco('Termina em', campoFim, 'aviso-ate'),
    ]),
    criar('p', { classe: 'dica', texto: 'Deixe ambos vazios para prazo indefinido — nesse caso o aviso so para quando for desativado.' }),

    botao,
    criar('button', {
      classe: 'btn btn-texto', type: 'button', texto: 'Cancelar',
      onClick: () => montarAvisos(container, pessoas),
    }),
  ]);

  formulario.addEventListener('submit', async (evento) => {
    evento.preventDefault();

    if (campoTitulo.value.trim().length < 3) {
      avisar('Informe um titulo com pelo menos 3 caracteres.', 'erro');
      return;
    }
    if (campoMensagem.value.trim().length < 3) {
      avisar('Escreva a mensagem do aviso.', 'erro');
      return;
    }

    try {
      await comCarregamento(botao, async () => {
        await criarAviso({
          titulo: campoTitulo.value,
          mensagem: campoMensagem.value,
          setores: caixasSetor.filter((x) => x.cx.checked).map((x) => x.s.id),
          pessoas: [...seletorPessoas.selectedOptions].map((o) => o.value),
          inicioEm: campoInicio.value ? new Date(campoInicio.value).toISOString() : null,
          fimEm: campoFim.value ? new Date(campoFim.value).toISOString() : null,
        });
        avisar('Aviso criado.', 'ok');
        await montarAvisos(container, pessoas);
      });
    } catch (erro) {
      tratarErro(erro);
    }
  });

  preencher(container, [
    criar('h3', { classe: 'secao', texto: 'Novo aviso' }),
    formulario,
  ]);
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
  $('#btn-perfil').addEventListener('click', () => exigirLogin(abrirPerfil));
  $('#btn-admin').addEventListener('click', () => exigirLogin(abrirAdmin));
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

  // O calendario e uma leitura ao vivo do banco, mas a tela so consultava ao
  // abrir. Quem deixasse esta pagina aberta e fosse iniciar um uso pelo QR Code
  // 1, ao voltar continuaria vendo a situacao antiga - dando a impressao de que
  // o uso nao tinha entrado na programacao. Reconsultamos ao reexibir a aba.
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) return;
    if (!$('#tela-calendario')?.classList.contains('ativa')) return;
    carregarMes();
    carregarDia();
  });

  // Enquanto a agenda fica visivel, acompanha usos que comecam ou terminam
  // agora - util no quadro de avisos, onde a tela fica aberta o tempo todo.
  setInterval(() => {
    if (document.hidden) return;
    if (!$('#tela-calendario')?.classList.contains('ativa')) return;
    carregarDia();
  }, APP.intervaloAtualizacao);

  iniciarPagina();
});


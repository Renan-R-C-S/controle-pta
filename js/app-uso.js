/**
 * APLICACAO DO QR CODE 1 - USO IMEDIATO (itens 10 a 19, 38)
 * ---------------------------------------------------------------------------
 * Esta pagina e aberta pelo QR Code afixado na propria PTA:
 *     https://dominio.com/?modo=uso&pta=PTA001
 *
 * Ela NAO permite agendamento futuro (REGRA 5). Tudo o que acontece aqui parte
 * do instante em que o QR Code foi lido.
 *
 * Sequencia da tela:
 *     QR -> setor -> nome -> PIN -> dashboard da PTA -> acao
 */

import { descartarSessao, funcionarioLogado, sair, validarSessao } from './auth.js';
import { APP, configuracaoPendente } from './config.js';
import { criarFluxoLogin } from './login-ui.js';
import { MINUTOS_DE_PRAZO, prazo, restantes, salvar as salvarObservacao } from './observacoes.js';
import { listarPtas, normalizarCodigo, parametrosDaUrl, situacao } from './ptas.js';
import { criarSeletorTerceiro } from './fornecedor-ui.js';
import { montarPerfil } from './perfil-ui.js';
import { agora, dataCurta, duracaoHumana, horaCurta, isoHora, minutosEntre, sincronizarRelogio } from './tempo.js';
import {
  $, avisar, carregandoGlobal, comCarregamento, confirmar, criar, etiqueta, pessoaComTerceiro,
  preencher, mostrarTela, tratarErro,
} from './ui.js';
import { detalhe as detalheUso, finalizar, iniciar, meuUsoAberto, minhaProgramacao } from './usos.js';

/* -------------------------------------------------------------------------- */
/* Estado da pagina                                                            */
/* -------------------------------------------------------------------------- */

const estado = {
  codigoPta: null,
  situacao: null,
  usoAbertoEmOutraPta: null,
  temporizador: null,
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

  carregandoGlobal(true, 'Conectando...');

  try {
    await sincronizarRelogio();
  } catch (erro) {
    carregandoGlobal(false);
    tratarErro(erro);
    mostrarTela('tela-config');
    return;
  }

  const { pta } = parametrosDaUrl();
  estado.codigoPta = pta ? normalizarCodigo(pta) : null;

  // Sem o parametro do QR Code nao ha PTA identificada. Em vez de travar, a
  // tela oferece a lista de PTAs ativas (decisao registrada em DECISOES.md).
  if (!estado.codigoPta) {
    carregandoGlobal(false);
    await telaEscolherPta();
    return;
  }

  const logado = await validarSessao().catch(() => null);
  carregandoGlobal(false);

  if (logado) {
    await abrirDashboard();
  } else {
    abrirLogin();
  }
}

function abrirLogin() {
  const fluxo = criarFluxoLogin($('#login-container'), {
    subtitulo: estado.codigoPta ? `Você está na ${estado.codigoPta}` : undefined,
    aoEntrar: () => abrirDashboard(),
  });
  mostrarTela('tela-login');
  fluxo.iniciar();
}

/** Fallback: a pagina foi aberta sem o parametro ?pta= do QR Code. */
async function telaEscolherPta() {
  try {
    const ptas = await listarPtas();
    preencher($('#escolher-pta-lista'), [
      criar(
        'div',
        { classe: 'grade-opcoes' },
        ptas.map((pta) =>
          criar('button', {
            classe: 'btn btn-opcao',
            type: 'button',
            texto: pta.codigo,
            onClick: () => {
              window.location.search = `?modo=uso&pta=${encodeURIComponent(pta.codigo)}`;
            },
          }),
        ),
      ),
    ]);
  } catch (erro) {
    tratarErro(erro);
  }
  mostrarTela('tela-escolher-pta');
}

/* -------------------------------------------------------------------------- */
/* Dashboard da PTA (itens 10 e 38)                                            */
/* -------------------------------------------------------------------------- */

async function abrirDashboard() {
  mostrarTela('tela-dashboard');
  await atualizarDashboard();

  clearInterval(estado.temporizador);
  estado.temporizador = setInterval(() => {
    if ($('#tela-dashboard').classList.contains('ativa')) atualizarDashboard({ silencioso: true });
  }, APP.intervaloAtualizacao);
}

async function atualizarDashboard({ silencioso = false } = {}) {
  const funcionario = funcionarioLogado();
  if (!funcionario) return abrirLogin();

  if (!silencioso) {
    preencher($('#dashboard-corpo'), criar('p', { classe: 'carregando-texto', texto: 'Carregando...' }));
  }

  try {
    estado.situacao = await situacao(estado.codigoPta);
    estado.usoAbertoEmOutraPta = await meuUsoAberto();
  } catch (erro) {
    const tratado = tratarErro(erro);
    if (tratado.codigo === 'SESSAO_INVALIDA') {
      descartarSessao();
      return abrirLogin();
    }
    if (tratado.codigo === 'PTA_NAO_ENCONTRADA') {
      preencher($('#dashboard-corpo'), [
        criar('p', { classe: 'erro-bloco', texto: `A PTA "${estado.codigoPta}" nao foi encontrada.` }),
        criar('p', { classe: 'dica', texto: 'Confira o QR Code afixado no equipamento.' }),
      ]);
    }
    return undefined;
  }

  desenharDashboard(funcionario, estado.situacao);
  return undefined;
}

function desenharDashboard(funcionario, dados) {
  const emUso = dados.status === 'EM_USO';
  const uso = dados.uso;
  const meuUso = Boolean(uso?.meu_uso);
  const usoEmOutraPta = estado.usoAbertoEmOutraPta && estado.usoAbertoEmOutraPta.pta !== dados.pta.codigo;

  $('#pta-codigo').textContent = dados.pta.codigo;
  $('#pta-local').textContent = [dados.pta.descricao, dados.pta.local].filter(Boolean).join(' • ');
  $('#relogio').textContent = `${dataCurta()} ${horaCurta()}`;

  const identidade = criar('div', { classe: 'bloco-identidade' }, [
    criar('div', {}, [
      criar('span', { classe: 'rotulo-mini', texto: 'Usuario' }),
      criar('strong', { texto: funcionario.nome }),
    ]),
    criar('div', {}, [
      criar('span', { classe: 'rotulo-mini', texto: 'Matricula' }),
      criar('strong', { texto: funcionario.matricula }),
    ]),
    criar('div', {}, [
      criar('span', { classe: 'rotulo-mini', texto: 'Setor' }),
      criar('strong', { texto: funcionario.setor }),
    ]),
  ]);

  const painelStatus = criar('div', { classe: `painel-status ${emUso ? 'ocupado' : 'livre'}` }, [
    criar('span', { classe: 'rotulo-mini', texto: 'Status da PTA' }),
    criar('strong', { classe: 'status-texto', texto: emUso ? 'EM USO' : 'DISPONIVEL' }),
    emUso
      ? criar('div', { classe: 'status-detalhe' }, [
          criar('p', {}, [
            meuUso
              ? criar('span', {}, ['Uso em andamento (seu)',
                  uso.fornecedor ? criar('span', {}, [' / ',
                    criar('strong', { classe: 'terceiro-inline', texto: uso.fornecedor })]) : null])
              : criar('span', {}, ['Em uso por ', pessoaComTerceiro(uso.funcionario, uso.fornecedor)]),
          ]),
          criar('p', { classe: 'linha-horarios' }, [
            criar('span', {}, [criar('em', { texto: 'Inicio efetivo: ' }), horaDe(uso.inicio_efetivo)]),
            criar('span', {}, [criar('em', { texto: 'Fim pretendido: ' }), horaDe(uso.fim_pretendido)]),
          ]),
          uso.atrasado
            ? criar('p', { classe: 'alerta', texto: 'O horario pretendido ja passou. O uso continua aberto ate a finalizacao.' })
            : null,
        ])
      : null,
  ]);

  // Item 23: avisa que iniciar o uso agora vai afetar programacoes existentes.
  const agendamentos = dados.proximos_agendamentos ?? [];
  const avisoAgenda = agendamentos.length
    ? criar('div', { classe: 'bloco-aviso' }, [
        criar('strong', { texto: 'Programacoes registradas para esta PTA' }),
        criar(
          'ul',
          { classe: 'lista-simples' },
          agendamentos.map((item) =>
            criar('li', {
              texto: `${horaSimples(item.inicio)} - ${horaSimples(item.fim)} • ${item.funcionario} (${item.setor})${
                item.proprio ? ' • sua programacao' : ''
              }`,
            }),
          ),
        ),
        criar('p', {
          classe: 'dica',
          texto: 'Iniciar o uso agora tem prioridade sobre a programacao. O registro anterior nao e apagado: fica marcado no historico.',
        }),
      ])
    : null;

  /* --------------------------------- Botoes adaptados ao estado (item 10) */

  const botoes = [];

  if (emUso && meuUso) {
    botoes.push(
      criar('button', {
        classe: 'btn btn-primario btn-acao',
        type: 'button',
        texto: 'FINALIZAR USO DA PTA',
        onClick: (evento) => finalizarUso(evento.currentTarget, uso.id),
      }),
      criar('button', {
        classe: 'btn btn-secundario btn-acao',
        type: 'button',
        texto: 'OBSERVACAO',
        onClick: () => abrirObservacao(uso.id),
      }),
    );
  } else if (emUso && !meuUso) {
    botoes.push(
      criar('p', {
        classe: 'erro-bloco',
        texto: `Esta PTA esta em uso por ${uso.funcionario} (matricula ${uso.matricula}). Somente essa pessoa pode finalizar o uso.`,
      }),
    );
  } else if (usoEmOutraPta) {
    botoes.push(
      criar('p', {
        classe: 'erro-bloco',
        texto: `Voce tem um uso em aberto na ${estado.usoAbertoEmOutraPta.pta}. Finalize-o antes de iniciar outro.`,
      }),
      criar('button', {
        classe: 'btn btn-secundario btn-acao',
        type: 'button',
        texto: `IR PARA ${estado.usoAbertoEmOutraPta.pta}`,
        onClick: () => {
          window.location.search = `?modo=uso&pta=${encodeURIComponent(estado.usoAbertoEmOutraPta.pta)}`;
        },
      }),
    );
  } else {
    botoes.push(
      criar('button', {
        classe: 'btn btn-primario btn-acao',
        type: 'button',
        texto: 'INICIAR / DEFINIR USO',
        onClick: abrirInicioDeUso,
      }),
    );
  }

  botoes.push(
    criar('button', {
      classe: 'btn btn-secundario btn-acao',
      type: 'button',
      texto: 'MINHA PROGRAMACAO',
      onClick: abrirProgramacao,
    }),
    criar('button', {
      classe: 'btn btn-secundario btn-acao',
      type: 'button',
      texto: 'MEU PERFIL',
      onClick: abrirPerfil,
    }),
  );

  preencher($('#dashboard-corpo'), [identidade, painelStatus, avisoAgenda, criar('div', { classe: 'grupo-botoes' }, botoes)]);
}

/* -------------------------------------------------------------------------- */
/* Inicio do uso (itens 11 e 12)                                               */
/* -------------------------------------------------------------------------- */

function abrirInicioDeUso() {
  const inicio = agora();

  // Sugestao de 2 horas apenas para preencher o campo; o funcionario decide.
  const sugestao = new Date(inicio.getTime() + 2 * 60 * 60 * 1000);

  const campoFim = criar('input', {
    classe: 'campo campo-hora',
    id: 'hora-fim',
    type: 'time',
    required: true,
    value: isoHora(sugestao),
    'data-foco': 'true',
  });

  const resumo = criar('p', { classe: 'resumo-periodo' });
  const atualizarResumo = () => {
    if (!campoFim.value) {
      resumo.textContent = '';
      return;
    }
    const [h, m] = campoFim.value.split(':').map(Number);
    const fim = new Date(inicio);
    fim.setHours(h, m, 0, 0);
    const minutos = minutosEntre(inicio, fim);
    resumo.textContent = minutos > 0
      ? `Duracao prevista: ${duracaoHumana(minutos)}`
      : 'O horario final deve ser posterior ao horario de inicio.';
    resumo.classList.toggle('invalido', minutos <= 0);
  };
  campoFim.addEventListener('input', atualizarResumo);

  const botao = criar('button', { classe: 'btn btn-primario btn-largo', type: 'submit', texto: 'CONFIRMAR USO' });

  // Opcao secundaria: incluir a empresa terceira que vai trabalhar junto.
  const terceiro = criarSeletorTerceiro();

  const formulario = criar('form', { classe: 'form-uso', novalidate: true }, [
    criar('div', { classe: 'cartao-horario' }, [
      criar('div', {}, [
        criar('span', { classe: 'rotulo-mini', texto: 'Hoje' }),
        criar('strong', { texto: dataCurta(inicio) }),
      ]),
      criar('div', {}, [
        criar('span', { classe: 'rotulo-mini', texto: 'Inicio' }),
        criar('strong', { classe: 'hora-grande', texto: horaCurta(inicio) }),
      ]),
    ]),
    criar('p', {
      classe: 'dica',
      texto: 'O horario de inicio e registrado automaticamente pelo servidor no momento da confirmacao.',
    }),
    criar('label', { classe: 'rotulo', for: 'hora-fim', texto: 'Horario final pretendido' }),
    campoFim,
    resumo,
    terceiro.elemento,
    botao,
  ]);

  formulario.addEventListener('submit', async (evento) => {
    evento.preventDefault();
    if (!campoFim.value) return avisar('Informe o horario final pretendido.', 'erro');

    const confirmado = await confirmar({
      titulo: 'Confirmar uso',
      corpo: [
        criar('p', { texto: 'Voce deseja utilizar a PTA:' }),
        criar('p', { classe: 'confirmacao-destaque', texto: estado.codigoPta }),
        criar('p', { texto: `Das ${horaCurta(agora())} as ${campoFim.value}?` }),
        terceiro.valor()
          ? criar('p', { classe: 'dica', texto: 'Com terceiro incluido.' })
          : null,
      ],
      textoOk: 'CONFIRMAR USO',
      textoCancelar: 'CANCELAR',
    });
    if (!confirmado) return undefined;

    try {
      await comCarregamento(botao, async () => {
        const resultado = await iniciar(estado.codigoPta, campoFim.value, terceiro.valor());

        if (resultado.agendamentos_afetados > 0) {
          avisar(
            `Uso iniciado. ${resultado.agendamentos_afetados} programacao(oes) foi(ram) marcada(s) como afetada(s).`,
            'ok',
          );
        } else {
          avisar(`Uso iniciado as ${resultado.inicio_efetivo}.`, 'ok');
        }
        await abrirDashboard();
      });
    } catch (erro) {
      tratarErro(erro);
    }
    return undefined;
  });

  preencher($('#iniciar-corpo'), formulario);
  atualizarResumo();
  mostrarTela('tela-iniciar');
}

/* -------------------------------------------------------------------------- */
/* Finalizacao (itens 14, 15, 16)                                              */
/* -------------------------------------------------------------------------- */

async function finalizarUso(botao, usoId) {
  const uso = estado.situacao?.uso;

  const confirmado = await confirmar({
    titulo: 'Finalizar uso da PTA',
    corpo: [
      criar('p', { texto: 'O horario final efetivo sera o instante deste clique.' }),
      criar('p', { classe: 'confirmacao-destaque', texto: horaCurta(agora()) }),
      uso
        ? criar('p', {
            classe: 'dica',
            texto: `Horario pretendido: ${horaSimples(uso.fim_pretendido)} (permanece registrado como previsto).`,
          })
        : null,
    ],
    textoOk: 'FINALIZAR',
    textoCancelar: 'VOLTAR',
  });
  if (!confirmado) return;

  try {
    await comCarregamento(botao, async () => {
      const resultado = await finalizar(usoId);

      const mensagem = resultado.ultrapassou_previsto
        ? `Uso finalizado as ${resultado.fim_efetivo} (apos o horario pretendido de ${resultado.fim_pretendido}).`
        : `Uso finalizado as ${resultado.fim_efetivo}.`;
      avisar(mensagem, 'ok');

      // Item 19: a janela de observacao abre agora.
      await abrirObservacao(usoId, {
        aviso: `Voce pode registrar ou editar a observacao ate as ${resultado.limite_observacao}.`,
      });
    });
  } catch (erro) {
    tratarErro(erro);
    await atualizarDashboard();
  }
}

/* -------------------------------------------------------------------------- */
/* Observacao (itens 18 e 19)                                                  */
/* -------------------------------------------------------------------------- */

async function abrirObservacao(usoId, { aviso } = {}) {
  mostrarTela('tela-observacao');
  preencher($('#observacao-corpo'), criar('p', { classe: 'carregando-texto', texto: 'Carregando...' }));

  let uso;
  try {
    uso = await detalheUso(usoId);
  } catch (erro) {
    tratarErro(erro);
    await abrirDashboard();
    return;
  }

  const situacaoPrazo = prazo(uso);
  const liberado = uso.pode_editar_observacao && situacaoPrazo.liberado;

  const area = criar('textarea', {
    classe: 'campo campo-observacao',
    id: 'texto-observacao',
    maxlength: String(APP.limiteObservacao),
    rows: '5',
    placeholder: 'Ex.: Necessario reposicionar a PTA devido a interferencia do equipamento.',
    ...(liberado ? { 'data-foco': 'true' } : { disabled: true }),
  });
  area.value = uso.observacao ?? '';

  const contador = criar('span', { classe: 'contador' });
  const atualizarContador = () => {
    contador.textContent = `${area.value.length} / ${APP.limiteObservacao} caracteres`;
    contador.classList.toggle('no-limite', restantes(area.value) === 0);
  };
  area.addEventListener('input', atualizarContador);

  const botao = criar('button', {
    classe: 'btn btn-primario btn-largo',
    type: 'submit',
    texto: 'SALVAR OBSERVACAO',
    ...(liberado ? {} : { disabled: true }),
  });

  const formulario = criar('form', { classe: 'form-observacao', novalidate: true }, [
    criar('div', { classe: 'cartao-horario' }, [
      criar('div', {}, [criar('span', { classe: 'rotulo-mini', texto: 'PTA' }), criar('strong', { texto: uso.pta })]),
      criar('div', {}, [
        criar('span', { classe: 'rotulo-mini', texto: 'Periodo' }),
        criar('strong', {
          texto: `${horaSimples(uso.inicio_efetivo)} - ${
            uso.fim_efetivo ? horaSimples(uso.fim_efetivo) : 'em aberto'
          }`,
        }),
      ]),
    ]),
    aviso ? criar('p', { classe: 'bloco-aviso', texto: aviso }) : null,
    textoDoPrazo(uso, situacaoPrazo),
    criar('label', { classe: 'rotulo', for: 'texto-observacao', texto: 'Observacao' }),
    area,
    contador,
    botao,
    criar('button', {
      classe: 'btn btn-texto',
      type: 'button',
      texto: 'Voltar ao painel da PTA',
      onClick: () => abrirDashboard(),
    }),
  ]);

  formulario.addEventListener('submit', async (evento) => {
    evento.preventDefault();
    try {
      await comCarregamento(botao, async () => {
        await salvarObservacao(usoId, area.value);
        avisar('Observacao salva.', 'ok');
      });
    } catch (erro) {
      // Se o prazo venceu entre abrir a tela e salvar, quem avisa e o servidor.
      tratarErro(erro);
      await abrirObservacao(usoId);
    }
  });

  preencher($('#observacao-corpo'), formulario);
  atualizarContador();
}

function textoDoPrazo(uso, situacaoPrazo) {
  if (uso.status === 'EM_USO') {
    return criar('p', {
      classe: 'dica',
      texto: `A observacao pode ser editada durante o uso e ate ${MINUTOS_DE_PRAZO} minutos apos a finalizacao.`,
    });
  }
  if (!situacaoPrazo.liberado) {
    return criar('p', {
      classe: 'erro-bloco',
      texto: 'Seu periodo de edicao da observacao ja terminou.',
    });
  }
  return criar('p', {
    classe: 'bloco-aviso',
    texto: `Prazo de edicao: ate ${horaSimples(uso.limite_edicao_observacao)} (${duracaoHumana(
      situacaoPrazo.minutosRestantes,
    )} restantes).`,
  });
}

/* -------------------------------------------------------------------------- */
/* Minha programacao                                                           */
/* -------------------------------------------------------------------------- */

async function abrirProgramacao() {
  mostrarTela('tela-programacao');
  preencher($('#programacao-corpo'), criar('p', { classe: 'carregando-texto', texto: 'Carregando...' }));

  try {
    const dados = await minhaProgramacao();

    const agendamentos = dados.agendamentos.length
      ? criar(
          'ul',
          { classe: 'lista-registros' },
          dados.agendamentos.map((item) =>
            criar('li', { classe: 'registro' }, [
              criar('div', { classe: 'registro-topo' }, [
                criar('strong', { texto: `${item.pta} • ${item.data}` }),
                etiqueta(item.status),
              ]),
              criar('span', { classe: 'registro-horas', texto: `${item.inicio} → ${item.fim} (previsto)` }),
            ]),
          ),
        )
      : criar('p', { classe: 'vazio', texto: 'Nenhuma programacao futura.' });

    const usos = dados.usos.length
      ? criar(
          'ul',
          { classe: 'lista-registros' },
          dados.usos.map((item) =>
            criar('li', { classe: 'registro' }, [
              criar('div', { classe: 'registro-topo' }, [
                criar('strong', { texto: `${item.pta} • ${item.data}` }),
                etiqueta(item.status),
              ]),
              criar('span', {
                classe: 'registro-horas',
                texto: `${item.inicio} → ${item.fim_pretendido} (previsto)`,
              }),
              criar('span', {
                classe: 'registro-horas forte',
                texto: item.fim_efetivo
                  ? `${item.inicio} → ${item.fim_efetivo} (efetivo)`
                  : 'Uso em aberto - aguardando finalizacao',
              }),
              item.observacao ? criar('p', { classe: 'registro-obs', texto: item.observacao }) : null,
              item.pode_editar_observacao
                ? criar('button', {
                    classe: 'btn btn-texto',
                    type: 'button',
                    texto: item.observacao ? 'Editar observacao' : 'Adicionar observacao',
                    onClick: () => abrirObservacao(item.id),
                  })
                : null,
            ]),
          ),
        )
      : criar('p', { classe: 'vazio', texto: 'Nenhum uso registrado.' });

    preencher($('#programacao-corpo'), [
      criar('h3', { classe: 'secao', texto: 'Programacoes (planejado)' }),
      agendamentos,
      criar('h3', { classe: 'secao', texto: 'Usos (efetivo)' }),
      usos,
      criar('button', {
        classe: 'btn btn-texto',
        type: 'button',
        texto: 'Voltar ao painel da PTA',
        onClick: () => abrirDashboard(),
      }),
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
    // O painel mostra o nome do funcionario; redesenha para refletir a mudanca.
    aoAlterar: () => abrirDashboard(),
  });

  $('#perfil-container').append(
    criar('button', {
      classe: 'btn btn-texto',
      type: 'button',
      texto: 'Voltar ao painel da PTA',
      onClick: () => abrirDashboard(),
    }),
  );
}

/* -------------------------------------------------------------------------- */
/* Apoio                                                                       */
/* -------------------------------------------------------------------------- */

/** Extrai "HH:MM" de um texto "YYYY-MM-DDTHH:MM" devolvido pelas RPC. */
function horaSimples(texto) {
  if (!texto) return '--:--';
  const partes = String(texto).split('T');
  return partes[1] ?? partes[0];
}

function horaDe(texto) {
  return criar('strong', { texto: horaSimples(texto) });
}

/* -------------------------------------------------------------------------- */
/* Ligacoes globais                                                            */
/* -------------------------------------------------------------------------- */

document.addEventListener('DOMContentLoaded', () => {
  $('#btn-sair')?.addEventListener('click', async () => {
    await sair();
    window.location.reload();
  });

  $('#btn-atualizar')?.addEventListener('click', () => atualizarDashboard());

  // Ao voltar para a aba (novo escaneamento do QR), reconsulta a situacao.
  document.addEventListener('visibilitychange', () => {
    if (!document.hidden && $('#tela-dashboard')?.classList.contains('ativa')) {
      atualizarDashboard({ silencioso: true });
    }
  });

  iniciarPagina();
});

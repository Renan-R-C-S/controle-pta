/**
 * SELETOR DE TERCEIROS - "+ INCLUIR TERCEIROS"
 * ---------------------------------------------------------------------------
 * Componente compartilhado pelo INICIAR/DEFINIR USO (QR Code 1) e pelo
 * + AGENDAR (QR Code 2).
 *
 * Comeca fechado, como opcao secundaria: a maioria dos usos nao envolve
 * terceiro, e quem esta na PTA nao pode ser obrigado a passar por um campo que
 * nao lhe diz respeito. Ao abrir, oferece busca sobre os ja cadastrados e o
 * cadastro na hora de um novo.
 */

import { criar, preencher, avisar, comCarregamento, tratarErro } from './ui.js';
import { criar as criarFornecedor, listar as listarFornecedores } from './fornecedores.js';

/**
 * @param {object} [opcoes]
 * @param {string} [opcoes.selecionadoId] terceiro ja vinculado (modo edicao)
 * @param {string} [opcoes.selecionadoNome]
 * @returns {{ elemento: HTMLElement, valor: () => string|null }}
 */
export function criarSeletorTerceiro({ selecionadoId = null, selecionadoNome = null } = {}) {
  let escolhido = selecionadoId ? { id: selecionadoId, nome: selecionadoNome } : null;
  let aberto = Boolean(selecionadoId);

  const painel = criar('div', { classe: 'terceiro-painel', hidden: !aberto });
  const resumo = criar('div', { classe: 'terceiro-resumo', hidden: !escolhido });

  const botaoAbrir = criar('button', {
    classe: 'btn btn-secundario btn-largo btn-terceiro',
    type: 'button',
    texto: '+ INCLUIR TERCEIROS',
  });

  /* ------------------------------------------------------------- Resumo */

  function desenharResumo() {
    resumo.hidden = !escolhido;
    if (!escolhido) return;
    preencher(resumo, [
      criar('span', { classe: 'rotulo-mini', texto: 'Terceiro incluido' }),
      criar('strong', { classe: 'terceiro-nome', texto: escolhido.nome }),
      criar('button', {
        classe: 'btn btn-texto btn-perigo',
        type: 'button',
        texto: 'Remover',
        onClick: () => {
          escolhido = null;
          desenharResumo();
          desenharBusca();
        },
      }),
    ]);
  }

  /* -------------------------------------------------------------- Busca */

  const campoBusca = criar('input', {
    classe: 'campo campo-busca',
    type: 'search',
    autocomplete: 'off',
    placeholder: 'Buscar terceiro por nome',
    'aria-label': 'Buscar terceiro por nome',
  });

  const lista = criar('ul', { classe: 'lista-funcionarios lista-terceiros' });
  const vazio = criar('p', { classe: 'dica', hidden: true });

  let timer = null;
  let ultimos = [];

  async function buscar() {
    try {
      ultimos = await listarFornecedores(campoBusca.value.trim() || null);
    } catch (erro) {
      tratarErro(erro);
      ultimos = [];
    }
    desenharLista();
  }

  function desenharLista() {
    preencher(
      lista,
      ultimos.map((f) =>
        criar('li', {}, [
          criar('button', {
            classe: 'item-funcionario',
            type: 'button',
            onClick: () => {
              escolhido = { id: f.id, nome: f.nome };
              desenharResumo();
              desenharBusca();
            },
          }, [
            criar('span', { classe: 'if-nome', texto: f.nome }),
            f.documento ? criar('span', { classe: 'if-matricula', texto: f.documento }) : null,
          ]),
        ]),
      ),
    );

    const termo = campoBusca.value.trim();
    vazio.hidden = ultimos.length > 0;
    vazio.textContent = termo
      ? `Nenhum terceiro encontrado para "${termo}". Use o botao abaixo para cadastrar.`
      : 'Nenhum terceiro cadastrado ainda. Use o botao abaixo para cadastrar o primeiro.';
  }

  campoBusca.addEventListener('input', () => {
    clearTimeout(timer);
    timer = setTimeout(buscar, 250);
  });

  /* ----------------------------------------------------------- Cadastro */

  const campoNovo = criar('input', {
    classe: 'campo',
    type: 'text',
    maxlength: '80',
    placeholder: 'Nome do novo terceiro',
    'aria-label': 'Nome do novo terceiro',
  });

  const botaoCadastrar = criar('button', {
    classe: 'btn btn-secundario btn-largo',
    type: 'button',
    texto: 'CADASTRAR TERCEIRO',
    onClick: async (evento) => {
      const nome = campoNovo.value.trim();
      if (nome.length < 2) {
        avisar('Informe o nome do terceiro.', 'erro');
        return;
      }
      try {
        await comCarregamento(evento.currentTarget, async () => {
          const novo = await criarFornecedor(nome);
          escolhido = { id: novo.id, nome: novo.nome };
          campoNovo.value = '';
          avisar(
            novo.ja_existia
              ? `"${novo.nome}" ja estava cadastrado e foi selecionado.`
              : `"${novo.nome}" cadastrado e selecionado.`,
            'ok',
          );
          desenharResumo();
          desenharBusca();
        });
      } catch (erro) {
        tratarErro(erro);
      }
    },
  });

  /* ------------------------------------------------------------ Montagem */

  // Com um terceiro escolhido, a area de busca se recolhe: o resumo ja diz tudo.
  function desenharBusca() {
    const escondido = Boolean(escolhido);
    campoBusca.hidden = escondido;
    lista.hidden = escondido;
    vazio.hidden = escondido || ultimos.length > 0;
    campoNovo.hidden = escondido;
    botaoCadastrar.hidden = escondido;
  }

  preencher(painel, [
    criar('p', {
      classe: 'dica',
      texto: 'Opcional. O nome do terceiro aparece no calendario ao lado do seu.',
    }),
    campoBusca, lista, vazio, campoNovo, botaoCadastrar,
  ]);

  botaoAbrir.addEventListener('click', () => {
    aberto = !aberto;
    painel.hidden = !aberto;
    botaoAbrir.textContent = aberto ? '− TERCEIROS' : '+ INCLUIR TERCEIROS';
    if (aberto && !ultimos.length) buscar();
  });

  const elemento = criar('div', { classe: 'bloco-terceiro' }, [botaoAbrir, resumo, painel]);

  desenharResumo();
  desenharBusca();
  if (aberto) buscar();

  return {
    elemento,
    /** id do terceiro escolhido, ou null. */
    valor: () => escolhido?.id ?? null,
  };
}

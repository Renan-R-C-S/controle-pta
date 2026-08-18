/**
 * CAMADA DE INTERFACE (item 28)
 * ---------------------------------------------------------------------------
 * Utilitarios de DOM compartilhados pelas duas paginas. Nao contem regra de
 * negocio: apenas navegacao entre telas, avisos, dialogos e formatacao.
 */

import { normalizarErro } from './erros.js';

/* -------------------------------------------------------------------------- */
/* DOM                                                                         */
/* -------------------------------------------------------------------------- */

export const $ = (seletor, raiz = document) => raiz.querySelector(seletor);
export const $$ = (seletor, raiz = document) => [...raiz.querySelectorAll(seletor)];

/** Cria um elemento com atributos e filhos. */
export function criar(tag, props = {}, filhos = []) {
  const elemento = document.createElement(tag);

  for (const [chave, valor] of Object.entries(props)) {
    if (valor === null || valor === undefined || valor === false) continue;
    if (chave === 'classe') elemento.className = valor;
    else if (chave === 'texto') elemento.textContent = valor;
    else if (chave === 'dados') Object.assign(elemento.dataset, valor);
    else if (chave.startsWith('on')) elemento.addEventListener(chave.slice(2).toLowerCase(), valor);
    else elemento.setAttribute(chave, valor === true ? '' : valor);
  }

  for (const filho of [].concat(filhos)) {
    if (filho === null || filho === undefined || filho === false) continue;
    elemento.append(typeof filho === 'string' ? document.createTextNode(filho) : filho);
  }

  return elemento;
}

/** Substitui todo o conteudo de um elemento. */
export function preencher(elemento, conteudo) {
  elemento.replaceChildren(...[].concat(conteudo).filter(Boolean));
}

/* -------------------------------------------------------------------------- */
/* Navegacao entre telas                                                       */
/* -------------------------------------------------------------------------- */

/** Mostra apenas a tela informada (elementos com a classe "tela"). */
export function mostrarTela(id) {
  $$('.tela').forEach((tela) => tela.classList.toggle('ativa', tela.id === id));
  const atual = document.getElementById(id);
  if (atual) {
    atual.scrollIntoView({ block: 'start' });
    const foco = atual.querySelector('[data-foco]');
    if (foco) setTimeout(() => foco.focus(), 60);
  }
  window.scrollTo({ top: 0 });
}

/* -------------------------------------------------------------------------- */
/* Avisos e estados                                                            */
/* -------------------------------------------------------------------------- */

let timerAviso = null;

/** Aviso temporario no rodape. tipo: "ok" | "erro" | "info" */
export function avisar(mensagem, tipo = 'info') {
  const caixa = $('#aviso');
  if (!caixa) return;

  caixa.textContent = mensagem;
  caixa.className = `aviso visivel ${tipo}`;
  caixa.setAttribute('role', tipo === 'erro' ? 'alert' : 'status');

  clearTimeout(timerAviso);
  timerAviso = setTimeout(() => caixa.classList.remove('visivel'), 5000);
}

/** Converte qualquer erro em mensagem amigavel e o registra no console. */
export function tratarErro(erro) {
  const tratado = normalizarErro(erro);
  console.error('[PTA]', tratado.codigo, tratado.detalheTecnico ?? tratado);
  avisar(tratado.message, 'erro');
  return tratado;
}

/** Marca um botao como ocupado enquanto a promessa nao resolve. */
export async function comCarregamento(botao, tarefa) {
  const textoOriginal = botao?.textContent;
  if (botao) {
    botao.disabled = true;
    botao.dataset.carregando = 'true';
    botao.textContent = 'Aguarde...';
  }
  try {
    return await tarefa();
  } finally {
    if (botao) {
      botao.disabled = false;
      delete botao.dataset.carregando;
      botao.textContent = textoOriginal;
    }
  }
}

/** Bloqueio de tela inteira durante o carregamento inicial. */
export function carregandoGlobal(ativo, mensagem = 'Carregando...') {
  const capa = $('#carregando');
  if (!capa) return;
  $('#carregando-texto').textContent = mensagem;
  capa.classList.toggle('visivel', ativo);
}

/* -------------------------------------------------------------------------- */
/* Dialogo de confirmacao                                                      */
/* -------------------------------------------------------------------------- */

/** Confirmacao em modal. Devolve Promise<boolean>. */
export function confirmar({ titulo, corpo, textoOk = 'Confirmar', textoCancelar = 'Cancelar' }) {
  return new Promise((resolver) => {
    const dialogo = $('#dialogo');
    $('#dialogo-titulo').textContent = titulo;
    preencher($('#dialogo-corpo'), corpo);
    $('#dialogo-ok').textContent = textoOk;
    $('#dialogo-cancelar').textContent = textoCancelar;

    const fechar = (resposta) => {
      dialogo.close();
      $('#dialogo-ok').removeEventListener('click', aoConfirmar);
      $('#dialogo-cancelar').removeEventListener('click', aoCancelar);
      dialogo.removeEventListener('cancel', aoCancelar);
      resolver(resposta);
    };

    const aoConfirmar = () => fechar(true);
    const aoCancelar = (evento) => {
      evento?.preventDefault?.();
      fechar(false);
    };

    $('#dialogo-ok').addEventListener('click', aoConfirmar);
    $('#dialogo-cancelar').addEventListener('click', aoCancelar);
    dialogo.addEventListener('cancel', aoCancelar);
    dialogo.showModal();
  });
}

/** Painel lateral de detalhes (somente leitura). */
export function abrirPainel(titulo, conteudo) {
  const painel = $('#painel');
  $('#painel-titulo').textContent = titulo;
  preencher($('#painel-corpo'), conteudo);
  painel.classList.add('visivel');
}

export function fecharPainel() {
  $('#painel')?.classList.remove('visivel');
}

/* -------------------------------------------------------------------------- */
/* Formatacao                                                                  */
/* -------------------------------------------------------------------------- */

/** Rotulos legiveis dos status usados no banco (item 24). */
export const ROTULOS_STATUS = {
  AGENDADO: 'Agendado',
  SOBRESCRITO: 'Sobrescrito',
  CANCELADO: 'Cancelado',
  CONCLUIDO: 'Concluido',
  AFETADO_POR_USO_IMEDIATO: 'Afetado por uso imediato',
  EM_USO: 'Em uso',
  FINALIZADO: 'Finalizado',
  DISPONIVEL: 'Disponivel',
};

export function rotuloStatus(status) {
  return ROTULOS_STATUS[status] ?? status;
}

/** Classe CSS da etiqueta de status. */
export function classeStatus(status) {
  return `etiqueta st-${String(status ?? '').toLowerCase()}`;
}

export function etiqueta(status) {
  return criar('span', { classe: classeStatus(status), texto: rotuloStatus(status) });
}

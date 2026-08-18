/**
 * AUTENTICACAO E ESTADO DO USUARIO (itens 6, 7, 8, 32)
 * ---------------------------------------------------------------------------
 * O que fica gravado no dispositivo:
 *   - o token de sessao (segredo opaco, gerado pelo servidor, valido 12h);
 *   - nome, matricula e setor, apenas para desenhar a tela.
 *
 * O que NUNCA fica gravado no dispositivo:
 *   - o PIN (nem em texto puro, nem em hash);
 *   - qualquer dado que permita agir em nome de outro funcionario.
 *
 * O PIN tambem nao trafega em URL e nao aparece no HTML: os campos usam
 * inputmode numerico e type="password".
 */

import { rpc } from './api.js';
import { APP } from './config.js';
import { ErroApp } from './erros.js';
import { pinValido, validarCadastro } from './validacoes.js';

let sessaoAtual = null;

/* -------------------------------------------------------------------------- */
/* Persistencia local                                                          */
/* -------------------------------------------------------------------------- */

function gravarSessao(sessao) {
  sessaoAtual = sessao;
  try {
    localStorage.setItem(APP.chaveSessao, JSON.stringify(sessao));
  } catch {
    /* modo privado do navegador: a sessao vale apenas para esta aba */
  }
}

function lerSessaoLocal() {
  if (sessaoAtual) return sessaoAtual;
  try {
    const bruto = localStorage.getItem(APP.chaveSessao);
    if (!bruto) return null;
    sessaoAtual = JSON.parse(bruto);
    return sessaoAtual;
  } catch {
    return null;
  }
}

function limparSessaoLocal() {
  sessaoAtual = null;
  try {
    localStorage.removeItem(APP.chaveSessao);
  } catch {
    /* ignora */
  }
}

/* -------------------------------------------------------------------------- */
/* Consultas                                                                   */
/* -------------------------------------------------------------------------- */

export function funcionarioLogado() {
  return lerSessaoLocal()?.funcionario ?? null;
}

export function tokenAtual() {
  return lerSessaoLocal()?.token ?? null;
}

/**
 * Confirma no servidor que o token continua valido.
 * Sessao vencida e descartada silenciosamente para que a tela volte ao inicio.
 */
export async function validarSessao() {
  const token = tokenAtual();
  if (!token) return null;
  try {
    const dados = await rpc('fn_sessao_info', { p_token: token });
    gravarSessao({ token, funcionario: dados.funcionario });
    return dados.funcionario;
  } catch (erro) {
    if (erro instanceof ErroApp && erro.codigo === 'SESSAO_INVALIDA') {
      limparSessaoLocal();
      return null;
    }
    throw erro;
  }
}

export async function listarSetores() {
  return rpc('fn_setores');
}

export async function listarFuncionarios(setorId) {
  return rpc('fn_funcionarios_por_setor', { p_setor_id: setorId });
}

export async function matriculaDisponivel(matricula) {
  return rpc('fn_matricula_disponivel', { p_matricula: matricula });
}

/* -------------------------------------------------------------------------- */
/* Acoes                                                                       */
/* -------------------------------------------------------------------------- */

/** Primeiro acesso (item 6). A unicidade da matricula e garantida pelo banco. */
export async function cadastrar({ nome, matricula, pin, confirmacao, setorId }) {
  validarCadastro({ nome, matricula, pin, confirmacao });

  const resposta = await rpc('fn_cadastrar_funcionario', {
    p_nome: nome.trim(),
    p_matricula: matricula.trim(),
    p_pin: pin,
    p_setor_id: setorId,
  });

  gravarSessao({ token: resposta.token, funcionario: resposta.funcionario });
  return resposta.funcionario;
}

/** Login por PIN (item 8). */
export async function entrar(funcionarioId, pin) {
  if (!pinValido(pin)) throw new ErroApp('PIN_FORMATO');

  const resposta = await rpc('fn_login', {
    p_funcionario_id: funcionarioId,
    p_pin: pin,
  });

  gravarSessao({ token: resposta.token, funcionario: resposta.funcionario });
  return resposta.funcionario;
}

export async function sair() {
  const token = tokenAtual();
  limparSessaoLocal();
  if (token) {
    try {
      await rpc('fn_logout', { p_token: token });
    } catch {
      /* encerrar a sessao local ja e suficiente para o usuario */
    }
  }
}

/** Descarta a sessao local sem chamar o servidor (usado quando o token vence). */
export function descartarSessao() {
  limparSessaoLocal();
}

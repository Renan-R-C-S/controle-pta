/**
 * TELA DE PERFIL - componente compartilhado pelas duas paginas.
 *
 * Mostra os dados do colaborador logado e permite corrigir o NOME e trocar o
 * PIN. Matricula e setor aparecem como texto fixo, com a explicacao do porque.
 */

import { atualizarFuncionarioLocal, funcionarioLogado } from './auth.js';
import { alterarNome, trocarPin } from './perfil.js';
import { rotuloPapel } from './admin.js';
import { avisar, comCarregamento, criar, preencher, tratarErro } from './ui.js';

/**
 * @param {HTMLElement} container
 * @param {Function} [aoAlterar]  chamado com o funcionario atualizado
 */
export function montarPerfil(container, { aoAlterar } = {}) {
  const funcionario = funcionarioLogado();

  if (!funcionario) {
    preencher(container, criar('p', { classe: 'vazio', texto: 'Voce precisa entrar para ver seu perfil.' }));
    return;
  }

  const campoNome = criar('input', {
    classe: 'campo',
    id: 'perfil-nome',
    type: 'text',
    autocomplete: 'name',
    maxlength: '80',
    value: funcionario.nome,
    'data-foco': 'true',
  });

  const botao = criar('button', {
    classe: 'btn btn-primario btn-largo',
    type: 'submit',
    texto: 'SALVAR NOME',
  });

  const formulario = criar('form', { classe: 'form-perfil', novalidate: true }, [
    criar('div', { classe: 'bloco-identidade' }, [
      criar('div', {}, [
        criar('span', { classe: 'rotulo-mini', texto: 'Matricula' }),
        criar('strong', { texto: funcionario.matricula }),
      ]),
      criar('div', {}, [
        criar('span', { classe: 'rotulo-mini', texto: 'Setor' }),
        criar('strong', { texto: funcionario.setor }),
      ]),
      criar('div', {}, [
        criar('span', { classe: 'rotulo-mini', texto: 'Acesso' }),
        criar('strong', { texto: rotuloPapel(funcionario.papel) }),
      ]),
    ]),

    criar('label', { classe: 'rotulo', for: 'perfil-nome', texto: 'Nome completo' }),
    campoNome,

    criar('p', {
      classe: 'dica',
      texto: 'A matricula nao pode ser alterada: e ela que liga voce aos registros de uso e ao historico. '
           + 'Se estiver errada, procure a administracao.',
    }),

    botao,
  ]);

  formulario.addEventListener('submit', async (evento) => {
    evento.preventDefault();

    const nome = campoNome.value.trim();
    if (nome === funcionario.nome) {
      avisar('O nome continua o mesmo.', 'info');
      return;
    }

    try {
      await comCarregamento(botao, async () => {
        const resposta = await alterarNome(nome);
        atualizarFuncionarioLocal(resposta.funcionario);
        avisar('Nome atualizado.', 'ok');
        aoAlterar?.(resposta.funcionario);
      });
    } catch (erro) {
      campoNome.value = funcionario.nome;
      tratarErro(erro);
    }
  });

  preencher(container, [formulario, blocoTrocaPin()]);
}

/**
 * Troca do proprio PIN.
 * Pede o PIN atual de proposito: sem isso, um celular deixado desbloqueado com
 * a sessao aberta permitiria a qualquer um trocar a senha do dono.
 */
function blocoTrocaPin() {
  const campo = (id, rotulo) => criar('input', {
    classe: 'campo', id, type: 'password', inputmode: 'numeric',
    autocomplete: 'off', maxlength: '10', 'aria-label': rotulo,
  });

  const atual = campo('pin-atual', 'PIN atual');
  const novo = campo('pin-novo', 'PIN novo');
  const confirma = campo('pin-confirma', 'Confirmar PIN novo');

  const botao = criar('button', {
    classe: 'btn btn-primario btn-largo', type: 'submit', texto: 'TROCAR PIN',
  });

  const formulario = criar('form', { classe: 'form-perfil', novalidate: true }, [
    criar('h3', { classe: 'secao', texto: 'Trocar PIN' }),
    criar('label', { classe: 'rotulo', for: 'pin-atual', texto: 'PIN atual' }),
    atual,
    criar('label', { classe: 'rotulo', for: 'pin-novo', texto: 'PIN novo' }),
    novo,
    criar('label', { classe: 'rotulo', for: 'pin-confirma', texto: 'Confirmar o PIN novo' }),
    confirma,
    criar('p', { classe: 'dica', texto: 'De 4 a 10 digitos. Quatro continua valendo; use mais se quiser.' }),
    botao,
  ]);

  formulario.addEventListener('submit', async (evento) => {
    evento.preventDefault();
    try {
      await comCarregamento(botao, async () => {
        await trocarPin({ atual: atual.value, novo: novo.value, confirmacao: confirma.value });
        atual.value = ''; novo.value = ''; confirma.value = '';
        avisar('PIN alterado.', 'ok');
      });
    } catch (erro) {
      tratarErro(erro);
    }
  });

  return formulario;
}

/**
 * Troca obrigatoria do PIN provisorio.
 *
 * Quando um administrador reseta o PIN de alguem, ele nasce provisorio. A
 * pessoa entra com ele e precisa trocar antes de seguir - assim o administrador
 * nao continua conhecendo a senha de ninguem.
 *
 * O dialogo NAO tem botao de fechar, e Esc nao encerra: e o unico popup do
 * sistema que barra mesmo, porque seguir com uma senha que outra pessoa conhece
 * derrubaria a garantia de que cada registro de uso tem dono.
 *
 * @returns {Promise<boolean>} true se trocou; false se o usuario desistiu e saiu
 */
export function exigirTrocaPinProvisorio() {
  const funcionario = funcionarioLogado();
  if (!funcionario?.pin_provisorio) return Promise.resolve(true);

  return new Promise((resolver) => {
    const campo = (id, rotulo) => criar('input', {
      classe: 'campo', id, type: 'password', inputmode: 'numeric',
      autocomplete: 'off', maxlength: '10', 'aria-label': rotulo,
    });

    const atual = campo('prov-atual', 'PIN provisorio recebido');
    const novo = campo('prov-novo', 'PIN novo');
    const confirma = campo('prov-confirma', 'Confirmar PIN novo');

    const botao = criar('button', {
      classe: 'btn btn-primario btn-largo', type: 'submit', texto: 'DEFINIR MEU PIN',
    });

    const popup = criar('dialog', { classe: 'dialogo' });

    const formulario = criar('form', { classe: 'form-perfil', novalidate: true }, [
      criar('h3', { texto: 'Defina um PIN so seu' }),
      criar('p', {
        texto: 'A administracao redefiniu o seu PIN. Escolha um novo agora — '
             + 'enquanto o provisorio valer, outra pessoa conhece a sua senha.',
      }),
      criar('label', { classe: 'rotulo', for: 'prov-atual', texto: 'PIN provisorio' }),
      atual,
      criar('label', { classe: 'rotulo', for: 'prov-novo', texto: 'PIN novo' }),
      novo,
      criar('label', { classe: 'rotulo', for: 'prov-confirma', texto: 'Confirmar o PIN novo' }),
      confirma,
      criar('p', { classe: 'dica', texto: 'De 4 a 10 digitos.' }),
      botao,
      criar('button', {
        classe: 'btn btn-texto',
        type: 'button',
        texto: 'Sair sem trocar',
        onClick: () => { popup.close(); popup.remove(); resolver(false); },
      }),
    ]);

    formulario.addEventListener('submit', async (evento) => {
      evento.preventDefault();
      try {
        await comCarregamento(botao, async () => {
          await trocarPin({ atual: atual.value, novo: novo.value, confirmacao: confirma.value });
          atualizarFuncionarioLocal({ ...funcionarioLogado(), pin_provisorio: false });
          avisar('PIN definido.', 'ok');
          popup.close(); popup.remove(); resolver(true);
        });
      } catch (erro) {
        tratarErro(erro);
      }
    });

    // Esc nao fecha: a troca e obrigatoria.
    popup.addEventListener('cancel', (e) => e.preventDefault());

    preencher(popup, formulario);
    document.body.append(popup);
    popup.showModal();
  });
}

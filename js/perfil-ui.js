/**
 * TELA DE PERFIL - componente compartilhado pelas duas paginas.
 *
 * Mostra os dados do funcionario logado e permite corrigir apenas o NOME.
 * Matricula e setor aparecem como texto fixo, com a explicacao do porque.
 */

import { atualizarFuncionarioLocal, funcionarioLogado } from './auth.js';
import { alterarNome } from './perfil.js';
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

  preencher(container, formulario);
}

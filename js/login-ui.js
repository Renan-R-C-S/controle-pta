/**
 * FLUXO DE IDENTIFICACAO - TELAS 1, 2 e 3 (itens 6, 8, 37)
 * ---------------------------------------------------------------------------
 * Componente reaproveitado pelas duas paginas (QR Code 1 e QR Code 2), para
 * que o caminho "setor -> nome -> PIN" seja identico nos dois acessos.
 *
 * Passos:
 *     Setor  ->  Lista de funcionarios  ->  PIN     (quem ja tem cadastro)
 *     Setor  ->  Primeiro acesso        ->  Cadastro (quem ainda nao tem)
 *
 * Minimiza digitacao (item 37): so o primeiro acesso exige teclado; nas vezes
 * seguintes sao dois toques e 4 digitos.
 */

import { cadastrar, entrar, listarFuncionarios, listarSetores, matriculaDisponivel } from './auth.js';
import { APP } from './config.js';
import { avisar, comCarregamento, criar, preencher, tratarErro } from './ui.js';
import { matriculaValida, nomeValido, pinValido } from './validacoes.js';

export function criarFluxoLogin(container, { aoEntrar, subtitulo } = {}) {
  const estado = { setor: null, setores: [], funcionarios: [], funcionario: null };

  /* ---------------------------------------------------------------- Setor */

  async function passoSetor() {
    preencher(container, criar('p', { classe: 'carregando-texto', texto: 'Carregando setores...' }));

    try {
      estado.setores = await listarSetores();
    } catch (erro) {
      preencher(container, [
        criar('p', { classe: 'erro-bloco', texto: tratarErro(erro).message }),
        criar('button', { classe: 'btn btn-secundario', type: 'button', texto: 'Tentar de novo', onClick: passoSetor }),
      ]);
      return;
    }

    preencher(container, [
      criar('h2', { classe: 'titulo-passo', texto: 'Selecione seu setor' }),
      subtitulo ? criar('p', { classe: 'subtitulo-passo', texto: subtitulo }) : null,
      criar(
        'div',
        { classe: 'grade-opcoes' },
        estado.setores.map((setor) =>
          criar('button', {
            classe: 'btn btn-opcao',
            type: 'button',
            texto: setor.nome,
            onClick: () => passoFuncionarios(setor),
          }),
        ),
      ),
    ]);
  }

  /* -------------------------------------------------- Lista de funcionarios */

  async function passoFuncionarios(setor) {
    estado.setor = setor;
    preencher(container, criar('p', { classe: 'carregando-texto', texto: 'Carregando colaboradores...' }));

    try {
      estado.funcionarios = await listarFuncionarios(setor.id);
    } catch (erro) {
      tratarErro(erro);
      passoSetor();
      return;
    }

    // Setor ainda sem ninguem cadastrado: nao ha o que buscar.
    if (!estado.funcionarios.length) {
      preencher(container, [
        cabecalhoPasso(`Setor: ${setor.nome}`, passoSetor),
        criar('h2', { classe: 'titulo-passo', texto: 'Colaboradores cadastrados' }),
        criar('p', { classe: 'vazio', texto: 'Nenhum colaborador cadastrado neste setor ainda.' }),
        criar('button', {
          classe: 'btn btn-secundario btn-largo',
          type: 'button',
          texto: 'Primeiro acesso / nao estou na lista',
          onClick: passoCadastro,
        }),
      ]);
      return;
    }

    const listaEl = criar('ul', { classe: 'lista-funcionarios' });
    const semResultado = criar('p', {
      classe: 'vazio',
      hidden: true,
      texto: 'Nenhum colaborador encontrado com esse termo.',
    });

    // Busca por nome ou matricula. O campo e opcional: a lista completa
    // continua logo abaixo, entao quem tem o setor pequeno nao precisa digitar.
    const campoBusca = criar('input', {
      classe: 'campo campo-busca',
      type: 'search',
      autocomplete: 'off',
      placeholder: 'Buscar por nome ou matricula',
      'aria-label': 'Buscar colaborador por nome ou matricula',
      'aria-controls': 'lista-funcionarios',
    });
    listaEl.id = 'lista-funcionarios';

    const contador = criar('span', { classe: 'contador-busca' });

    function desenharLista() {
      const termo = semAcento(campoBusca.value.trim());

      const filtrados = termo
        ? estado.funcionarios.filter(
            (f) => semAcento(f.nome).includes(termo) || f.matricula.includes(termo),
          )
        : estado.funcionarios;

      preencher(
        listaEl,
        filtrados.map((funcionario) =>
          criar('li', {}, [
            criar(
              'button',
              { classe: 'item-funcionario', type: 'button', onClick: () => passoPin(funcionario) },
              [
                criar('span', { classe: 'if-nome', texto: funcionario.nome }),
                criar('span', { classe: 'if-matricula', texto: funcionario.matricula }),
              ],
            ),
          ]),
        ),
      );

      semResultado.hidden = filtrados.length > 0;
      contador.textContent = termo
        ? `${filtrados.length} de ${estado.funcionarios.length}`
        : `${estado.funcionarios.length} colaborador(es)`;
    }

    campoBusca.addEventListener('input', desenharLista);

    // Se a busca deixou uma pessoa so, Enter ja entra no PIN dela.
    campoBusca.addEventListener('keydown', (evento) => {
      if (evento.key !== 'Enter') return;
      evento.preventDefault();
      const unico = listaEl.querySelectorAll('.item-funcionario');
      if (unico.length === 1) unico[0].click();
    });

    preencher(container, [
      cabecalhoPasso(`Setor: ${setor.nome}`, passoSetor),
      criar('h2', { classe: 'titulo-passo', texto: 'Colaboradores cadastrados' }),
      campoBusca,
      contador,
      listaEl,
      semResultado,
      criar('button', {
        classe: 'btn btn-secundario btn-largo',
        type: 'button',
        texto: 'Primeiro acesso / nao estou na lista',
        onClick: passoCadastro,
      }),
    ]);

    desenharLista();
  }

  /* ------------------------------------------------------------------ PIN */

  function passoPin(funcionario) {
    estado.funcionario = funcionario;

    const campo = criar('input', {
      classe: 'campo-pin',
      type: 'password',
      inputmode: 'numeric',
      pattern: '[0-9]*',
      autocomplete: 'off',
      maxlength: String(APP.digitosPin),
      placeholder: '••••',
      'aria-label': 'PIN de 4 digitos',
      'data-foco': 'true',
    });

    const botao = criar('button', { classe: 'btn btn-primario btn-largo', type: 'submit', texto: 'ENTRAR' });

    const formulario = criar('form', { classe: 'form-pin', novalidate: true }, [
      criar('div', { classe: 'cartao-identidade' }, [
        criar('strong', { texto: funcionario.nome }),
        criar('span', { texto: `Matricula ${funcionario.matricula} • ${estado.setor.nome}` }),
      ]),
      criar('label', { classe: 'rotulo', for: 'pin', texto: 'Digite seu PIN' }),
      campo,
      botao,
      criar('button', {
        classe: 'btn btn-texto',
        type: 'button',
        texto: 'Nao sou eu',
        onClick: () => passoFuncionarios(estado.setor),
      }),
    ]);

    // So aceita digitos; envia sozinho ao completar os 4 (item 37).
    campo.addEventListener('input', () => {
      campo.value = campo.value.replace(/\D/g, '').slice(0, APP.digitosPin);
      if (campo.value.length === APP.digitosPin) {
        formulario.requestSubmit();
      }
    });

    formulario.addEventListener('submit', async (evento) => {
      evento.preventDefault();
      if (!pinValido(campo.value)) {
        avisar('O PIN deve ter exatamente 4 digitos.', 'erro');
        return;
      }
      try {
        await comCarregamento(botao, async () => {
          const logado = await entrar(funcionario.id, campo.value);
          aoEntrar?.(logado);
        });
      } catch (erro) {
        campo.value = '';
        campo.focus();
        tratarErro(erro);
      }
    });

    preencher(container, [cabecalhoPasso(`Setor: ${estado.setor.nome}`, () => passoFuncionarios(estado.setor)), formulario]);
    setTimeout(() => campo.focus(), 80);
  }

  /* -------------------------------------------------------------- Cadastro */

  function passoCadastro() {
    const nome = campoTexto({ id: 'cad-nome', rotulo: 'Nome completo', autocomplete: 'name', foco: true });
    const matricula = campoTexto({
      id: 'cad-matricula',
      rotulo: 'Matricula',
      // item 37: teclado numerico no celular
      type: 'tel',
      inputmode: 'numeric',
      maxlength: '10',
    });
    const pin = campoTexto({
      id: 'cad-pin',
      rotulo: 'PIN de 4 digitos',
      type: 'password',
      inputmode: 'numeric',
      maxlength: '4',
    });
    const confirmacao = campoTexto({
      id: 'cad-pin2',
      rotulo: 'Confirme o PIN',
      type: 'password',
      inputmode: 'numeric',
      maxlength: '4',
    });

    for (const campo of [matricula.input, pin.input, confirmacao.input]) {
      campo.addEventListener('input', () => {
        campo.value = campo.value.replace(/\D/g, '');
      });
    }

    // Avisa sobre matricula ja cadastrada assim que o campo perde o foco, para
    // que a pessoa nao chegue a escolher um PIN antes de descobrir o problema.
    // A garantia da unicidade continua sendo a constraint UNIQUE (REGRA 1).
    const avisoMatricula = criar('p', { classe: 'erro-bloco', hidden: true });
    matricula.bloco.append(avisoMatricula);
    matricula.input.addEventListener('blur', async () => {
      avisoMatricula.hidden = true;
      if (!matriculaValida(matricula.input.value)) return;
      try {
        const livre = await matriculaDisponivel(matricula.input.value);
        if (!livre) {
          avisoMatricula.textContent =
            'Esta matricula ja esta cadastrada. Volte e selecione seu nome na lista.';
          avisoMatricula.hidden = false;
        }
      } catch {
        /* apenas um aviso antecipado: se falhar, o cadastro ainda sera validado */
      }
    });

    const dica = criar('p', { classe: 'dica', texto: 'O PIN protege seus registros. Nao compartilhe.' });
    const botao = criar('button', { classe: 'btn btn-primario btn-largo', type: 'submit', texto: 'CADASTRAR E ENTRAR' });

    const formulario = criar('form', { classe: 'form-cadastro', novalidate: true }, [
      criar('h2', { classe: 'titulo-passo', texto: 'Primeiro acesso' }),
      criar('p', { classe: 'subtitulo-passo', texto: `Voce sera cadastrado no setor ${estado.setor.nome}.` }),
      nome.bloco,
      matricula.bloco,
      pin.bloco,
      confirmacao.bloco,
      dica,
      botao,
      criar('button', {
        classe: 'btn btn-texto',
        type: 'button',
        texto: 'Voltar',
        onClick: () => passoFuncionarios(estado.setor),
      }),
    ]);

    formulario.addEventListener('submit', async (evento) => {
      evento.preventDefault();

      // Feedback imediato; a validacao que vale e a do banco (REGRAS 1 e 2).
      if (!nomeValido(nome.input.value)) return avisar('Informe o nome completo.', 'erro');
      if (!matriculaValida(matricula.input.value)) return avisar('Matricula invalida (4 a 10 digitos).', 'erro');
      if (!pinValido(pin.input.value)) return avisar('O PIN deve ter exatamente 4 digitos.', 'erro');
      if (pin.input.value !== confirmacao.input.value) return avisar('A confirmacao do PIN nao confere.', 'erro');

      try {
        await comCarregamento(botao, async () => {
          const novo = await cadastrar({
            nome: nome.input.value,
            matricula: matricula.input.value,
            pin: pin.input.value,
            confirmacao: confirmacao.input.value,
            setorId: estado.setor.id,
          });
          avisar('Cadastro concluido.', 'ok');
          aoEntrar?.(novo);
        });
      } catch (erro) {
        tratarErro(erro);
      }
      return undefined;
    });

    preencher(container, [cabecalhoPasso(`Setor: ${estado.setor.nome}`, () => passoFuncionarios(estado.setor)), formulario]);
  }

  /* ---------------------------------------------------------------- Apoio */

  /**
   * Normaliza texto para busca: sem acento e em minusculas.
   * Assim "Joao" encontra "João" e vice-versa - importante porque o cadastro
   * e digitado por pessoas diferentes, com e sem acento.
   */
  function semAcento(texto) {
    return (texto ?? '')
      .normalize('NFD')
      .replace(/[\u0300-\u036f]/g, '')
      .toLowerCase();
  }

  function cabecalhoPasso(texto, aoVoltar) {
    return criar('div', { classe: 'passo-topo' }, [
      criar('button', { classe: 'btn btn-voltar', type: 'button', texto: '‹ Voltar', onClick: aoVoltar }),
      criar('span', { classe: 'passo-contexto', texto }),
    ]);
  }

  function campoTexto({ id, rotulo, type = 'text', foco = false, ...resto }) {
    const input = criar('input', { id, classe: 'campo', type, ...resto, ...(foco ? { 'data-foco': 'true' } : {}) });
    const bloco = criar('div', { classe: 'campo-bloco' }, [
      criar('label', { classe: 'rotulo', for: id, texto: rotulo }),
      input,
    ]);
    return { bloco, input };
  }

  return { iniciar: passoSetor };
}

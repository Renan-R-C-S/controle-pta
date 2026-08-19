/**
 * POPUP DE AVISOS APOS O LOGIN
 * ---------------------------------------------------------------------------
 * Mostra os comunicados vigentes que alcancam quem acabou de entrar.
 *
 * Aparece a CADA login, de proposito: e o que foi pedido, e tambem o que faz
 * sentido para recado de fabrica - quem entra no turno da noite precisa ver o
 * aviso mesmo que ja o tenha visto de manha. Por isso nao existe "nao mostrar
 * de novo": marcar leitura daria a falsa impressao de confirmacao de ciencia,
 * que este sistema nao coleta.
 *
 * O fundo e branco fixo, inclusive no modo escuro, para o aviso destoar do
 * resto da tela e nao passar batido.
 */

import { criar, preencher } from './ui.js';
import { paraMim } from './avisos.js';

/**
 * Busca os avisos e, havendo algum, abre o popup.
 * Falha em silencio: um problema ao buscar comunicado nao pode impedir alguem
 * de registrar o uso de uma plataforma.
 */
export async function mostrarAvisosDoLogin() {
  let avisos;
  try {
    avisos = await paraMim();
  } catch (erro) {
    console.warn('[PTA] Nao foi possivel carregar os avisos:', erro);
    return;
  }
  if (!avisos?.length) return;

  const popup = criar('dialog', { classe: 'dialogo dialogo-aviso' });
  const fechar = () => { popup.close(); popup.remove(); };

  preencher(popup, [
    criar('div', { classe: 'aviso-cabecalho' }, [
      criar('span', { classe: 'aviso-selo', texto: avisos.length > 1 ? `${avisos.length} avisos` : 'Aviso' }),
    ]),

    ...avisos.map((a) =>
      criar('article', { classe: 'aviso-item' }, [
        criar('h3', { classe: 'aviso-titulo', texto: a.titulo }),
        criar('p', { classe: 'aviso-mensagem', texto: a.mensagem }),
        criar('p', { classe: 'aviso-rodape', texto:
          `${a.autor} • ${a.criado_em}${a.fim_em ? ` • vale ate ${a.fim_em}` : ''}` }),
      ])),

    criar('div', { classe: 'dialogo-acoes' }, [
      criar('button', {
        classe: 'btn btn-primario btn-largo',
        type: 'button',
        texto: 'ENTENDI',
        onClick: fechar,
      }),
    ]),
  ]);

  popup.addEventListener('cancel', fechar);   // tecla Esc
  document.body.append(popup);
  popup.showModal();
}

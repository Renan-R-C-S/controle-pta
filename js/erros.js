/**
 * TRATAMENTO DE ERROS (item 36)
 * ---------------------------------------------------------------------------
 * O banco devolve codigos estaveis em MAIUSCULAS (ex.: PIN_INCORRETO).
 * Este modulo traduz esses codigos em mensagens amigaveis.
 *
 * Nenhuma mensagem tecnica do PostgreSQL chega a tela: o texto tecnico vai
 * apenas para o console, para diagnostico durante o desenvolvimento.
 */

/** Erro da aplicacao com codigo conhecido. */
export class ErroApp extends Error {
  constructor(codigo, detalheTecnico) {
    super(mensagemDe(codigo));
    this.name = 'ErroApp';
    this.codigo = codigo;
    this.detalheTecnico = detalheTecnico ?? null;
  }
}

const MENSAGENS = {
  // Sessao e cadastro
  SESSAO_INVALIDA: 'Sua sessao expirou. Entre novamente.',
  FUNCIONARIO_NAO_ENCONTRADO: 'Colaborador nao encontrado.',
  NOME_INVALIDO: 'Informe o nome completo (minimo 3 caracteres).',
  MATRICULA_FORMATO: 'A matricula deve ter de 4 a 10 digitos numericos.',
  MATRICULA_DUPLICADA: 'Esta matricula ja esta cadastrada.',
  PIN_FORMATO: 'O PIN deve ter exatamente 4 digitos numericos.',
  PIN_INCORRETO: 'PIN incorreto.',
  PIN_DIFERENTE: 'A confirmacao do PIN nao confere.',
  CONTA_BLOQUEADA: 'Muitas tentativas incorretas. Aguarde 15 minutos e tente novamente.',
  SETOR_INVALIDO: 'Selecione um setor valido.',
  SEM_PERMISSAO: 'Este registro pertence a outro colaborador.',

  // PTA e uso imediato
  PTA_NAO_ENCONTRADA: 'Esta PTA nao foi encontrada.',
  PTA_EM_USO: 'Esta PTA ja esta em uso por outro colaborador.',
  USUARIO_COM_USO_ABERTO: 'Voce ja possui um uso em aberto. Finalize-o antes de iniciar outro.',
  USO_NAO_ENCONTRADO: 'Registro de uso nao encontrado.',
  USO_JA_FINALIZADO: 'Este uso ja foi finalizado.',
  HORARIO_INVALIDO: 'Informe um horario valido.',
  HORARIO_FINAL_ANTERIOR: 'O horario final deve ser posterior ao horario inicial.',
  DURACAO_EXCESSIVA: 'O periodo informado passa do limite de horas definido pela administracao.',

  // Observacoes
  OBSERVACAO_LONGA: 'A observacao deve ter no maximo 200 caracteres.',
  OBSERVACAO_PRAZO_EXPIRADO: 'Seu periodo de edicao da observacao ja terminou.',

  // Agendamentos
  CONFLITO_AGENDAMENTO: 'Este horario entra em conflito com outra programacao.',
  CONFLITO_COM_USO: 'Este horario entra em conflito com um uso em andamento nesta PTA.',
  AGENDAMENTO_PASSADO: 'So e possivel agendar para um horario futuro.',
  AGENDAMENTO_NAO_ENCONTRADO: 'Programacao nao encontrada.',
  AGENDAMENTO_NAO_CANCELAVEL: 'Esta programacao nao pode mais ser cancelada.',
  REGISTRO_NAO_ENCONTRADO: 'Registro nao encontrado.',

  AGENDAMENTO_NAO_ALTERAVEL: 'Esta programacao nao pode mais ser alterada.',

  // Administracao
  SEM_PERMISSAO_ADMIN: 'Esta acao e restrita aos administradores.',
  SOMENTE_ADMIN_MASTER: 'Somente o administrador principal pode fazer isso.',
  ADMIN_MASTER_PROTEGIDO: 'O administrador principal nao pode ser alterado nem excluido.',
  PAPEL_PROPRIO_BLOQUEADO: 'Voce nao pode alterar o seu proprio nivel de acesso.',
  EXCLUSAO_PROPRIA_BLOQUEADA: 'Voce nao pode excluir a sua propria conta.',
  PAPEL_INVALIDO: 'Nivel de acesso invalido.',
  FUNCIONARIO_COM_USO_ABERTO: 'Este colaborador tem um uso em aberto. Ele precisa finalizar antes de ser excluido.',
  LIMITE_MATRICULAS_ATINGIDO: 'O limite de matriculas do sistema foi atingido. Procure o administrador.',
  LIMITE_INVALIDO: 'Informe um limite valido (0 ou mais).',
  LIMITE_ABAIXO_DO_ATUAL: 'O limite nao pode ser menor que o numero de colaboradores ativos.',

  REGISTRO_DO_ADMIN_MASTER: 'Este registro foi criado pelo administrador principal. Somente ele pode altera-lo.',
  USO_NAO_CANCELAVEL: 'Este uso nao esta em aberto, entao nao pode ser cancelado.',
  HORAS_INVALIDAS: 'Informe um limite entre 1 e 24 horas.',

  // Terceiros
  FORNECEDOR_NAO_ENCONTRADO: 'Terceiro nao encontrado.',
  FORNECEDOR_NOME_INVALIDO: 'O nome do terceiro deve ter de 2 a 80 caracteres.',

  // Agendamentos ciclicos
  CICLICO_NAO_ENCONTRADO: 'Regra de repeticao nao encontrada.',
  CICLICO_INATIVO: 'Esta regra de repeticao ja esta desativada.',
  CICLO_TIPO_INVALIDO: 'Escolha como a repeticao acontece.',
  CICLO_SEM_DIAS: 'Selecione ao menos um dia da semana.',
  CICLO_INTERVALO_INVALIDO: 'Informe de quantos em quantos dias a repeticao acontece.',
  CICLO_PERIODO_INVALIDO: 'A data final nao pode ser anterior a inicial.',

  // Historico
  HISTORICO_IMUTAVEL: 'O historico do sistema nao pode ser alterado.',

  // Infraestrutura
  SEM_CONEXAO: 'Sem conexao com o servidor. Verifique a rede e tente de novo.',
  NAO_CONFIGURADO: 'O sistema ainda nao foi conectado ao banco de dados.',
  DESCONHECIDO: 'Nao foi possivel concluir a operacao.',
};

export function mensagemDe(codigo) {
  return MENSAGENS[codigo] ?? MENSAGENS.DESCONHECIDO;
}

/**
 * Converte qualquer erro (do supabase-js, de rede ou da aplicacao) em ErroApp.
 * O texto original e preservado apenas no console.
 */
export function normalizarErro(erro) {
  if (erro instanceof ErroApp) return erro;

  const bruto = erro?.message ?? String(erro ?? '');

  // Os codigos vem em MAIUSCULAS; algumas versoes do PostgREST prefixam a
  // mensagem, entao procuramos o codigo dentro do texto recebido.
  const achado = Object.keys(MENSAGENS).find((codigo) =>
    new RegExp(`\\b${codigo}\\b`).test(bruto),
  );

  if (achado) return new ErroApp(achado, bruto);

  if (/failed to fetch|networkerror|load failed/i.test(bruto)) {
    return new ErroApp('SEM_CONEXAO', bruto);
  }

  console.error('[PTA] Erro tecnico nao mapeado:', erro);
  return new ErroApp('DESCONHECIDO', bruto);
}

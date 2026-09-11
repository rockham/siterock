-- =====================================================================
-- O PAINEL DE SITES — schema completo, em projeto próprio
-- ---------------------------------------------------------------------
-- Projeto: SITEROCK (a criar). Decisão do Felipe, 10/09/2026:
-- "vou criar outra supabase para não misturar as coisas".
--
-- A PRIMEIRA VERSÃO DISTO RODOU DENTRO DO PROJETO DO ROCKSEO, e foi engano —
-- dele e meu. O ROCKSEO tem regra escrita no CLAUDE.md dele: painel anônimo,
-- sem login, e NÃO ligar RLS nas tabelas que ele lê. Estas tabelas fazem o
-- oposto: RLS ligada, ninguém anônimo lê. Dois produtos com regras opostas no
-- mesmo banco é onde alguém, um dia, aplica a regra de um na tabela do outro —
-- e isso não dá erro, dá vazamento silencioso ou leitura zerada.
--
-- Backup, restore e PITR também são por projeto: voltar o ROCKSEO no tempo por
-- um problema de SEO levaria os sites junto.
--
-- MUDANÇA EM RELAÇÃO À PRIMEIRA VERSÃO: `site_clientes` é própria, em vez de
-- apontar para a `clientes` do ROCKSEO. Eu tinha defendido o reaproveitamento
-- com o argumento de "duas listas que se separam" — e ele valia menos do que
-- eu disse: os clientes de lá são de SEO, carregam senha de WordPress e
-- provedor de imagem, e a Rosa & Nascimento nem está entre eles. São
-- populações diferentes.
--
-- A ponte fica como `rockseo_cliente_id`: um uuid solto, sem FK, porque FK
-- entre dois projetos Postgres não existe. Quem quiser cruzar, cruza pelo id.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. O CLIENTE — o escritório
-- ---------------------------------------------------------------------
create table if not exists public.site_clientes (
  id            uuid primary key default gen_random_uuid(),
  nome          text not null,
  slug          text not null unique,
  dominio       text,
  cidade_uf     text,
  -- a ponte com o outro produto, quando o mesmo escritório for cliente dos dois
  rockseo_cliente_id uuid,
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 2. O PROJETO DE SITE — um por cliente
--
-- Três documentos, e são coisas diferentes de propósito:
--
--   briefing    o que o escritório INFORMOU (telefone, OAB, áreas, história)
--   conteudo    a COPY estruturada, no formato dos slots dos blocos
--   identidade  cores e referências dos arquivos de marca
--
-- O `conteudo` NÃO é gerado aqui. Decisão do Felipe, 10/09: "não precisa criar
-- isso, projeto que eu tenho dentro do Claude, ele que vai gerar o texto".
-- Este campo é uma CAIXA DE ENTRADA: o painel recebe a copy pronta, deixa
-- editar, e é ela que alimenta a geração.
-- ---------------------------------------------------------------------
create table if not exists public.site_projetos (
  id            uuid primary key default gen_random_uuid(),
  cliente_id    uuid not null references public.site_clientes(id) on delete cascade,
  briefing      jsonb not null default '{}'::jsonb,
  conteudo      jsonb not null default '{}'::jsonb,
  identidade    jsonb not null default '{}'::jsonb,
  -- a marca de tokens que este cliente usa (tokens/<marca>.css na VPS)
  marca         text  not null default 'rn',
  estado        text  not null default 'em-desenvolvimento',
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  -- um projeto de site por cliente: dois seriam duas verdades sobre a mesma firma
  constraint site_projetos_cliente_unico unique (cliente_id)
);

-- ---------------------------------------------------------------------
-- 3. O HISTÓRICO DA COPY
--
-- "Quero poder visualizar, editar, salvar, regenerar, manter histórico de
--  versões se for simples implementar." É simples: uma linha por salvamento.
--
-- Guardar o documento inteiro a cada versão, e não um diff, é escolha: o
-- documento tem alguns kB, e comparar duas versões precisa das duas inteiras.
-- Diff economizaria bytes e cobraria reconstrução em toda leitura.
-- ---------------------------------------------------------------------
create table if not exists public.site_conteudo_versoes (
  id         uuid primary key default gen_random_uuid(),
  projeto_id uuid not null references public.site_projetos(id) on delete cascade,
  versao     integer not null,
  conteudo   jsonb not null,
  origem     text not null default 'painel',   -- painel | claude | importado
  nota       text,
  criado_em  timestamptz not null default now(),
  constraint site_conteudo_versao_unica unique (projeto_id, versao)
);

-- ---------------------------------------------------------------------
-- 4. AS PÁGINAS GERADAS
--
-- Uma linha por geração. NUNCA um update sobre a anterior — pedido explícito:
-- "não sobrescreva automaticamente a versão anterior. Quero poder comparar
--  versões. Home 03 — V1, V2, V3."
--
-- `token` é o mesmo token que a rk-api grava em preview/variacoes/<token>.json
-- e que o preview/server.js serve em /p/<token>/. O banco guarda o rastro; o
-- HTML continua morando na VPS, ao lado dos blocos que o produziram.
--
-- `problemas` guarda a reprovação dos validadores quando a geração sai
-- parcial. Geração que falha em silêncio é pior que geração que não aconteceu:
-- alguém aprova uma home com uma seção a menos sem notar.
--
-- `tipo` já prevê as outras páginas (blog, área, serviço, sobre, equipe,
-- contato) porque o pedido pede a arquitetura pronta para elas — mesmo que só
-- a home exista hoje.
-- ---------------------------------------------------------------------
create table if not exists public.site_geracoes (
  id          uuid primary key default gen_random_uuid(),
  projeto_id  uuid not null references public.site_projetos(id) on delete cascade,
  tipo        text not null default 'home',
  modelo      text not null,                   -- o arranjo: a, b, c...
  versao      integer not null,
  marca       text not null,
  token       text not null unique,            -- o endereço público, não adivinhável
  secoes      jsonb not null default '[]'::jsonb,
  problemas   jsonb not null default '[]'::jsonb,
  parametros  jsonb not null default '{}'::jsonb, -- o que foi pedido no REGENERAR
  criado_em   timestamptz not null default now(),
  constraint site_geracao_versao_unica unique (projeto_id, tipo, modelo, versao)
);

-- A PÁGINA APROVADA é uma referência à geração, e não uma cópia dela.
-- "Quando eu marcar uma versão como aprovada, ela passa a ser a REFERÊNCIA
--  VISUAL do projeto." Referência se aponta; cópia se desatualiza.
alter table public.site_projetos
  add column if not exists geracao_aprovada_id uuid
  references public.site_geracoes(id) on delete set null;

-- ---------------------------------------------------------------------
-- ÍNDICES — só os que respondem a uma pergunta que o painel faz sempre
-- ---------------------------------------------------------------------
create index if not exists site_geracoes_projeto_idx
  on public.site_geracoes (projeto_id, tipo, criado_em desc);
create index if not exists site_conteudo_versoes_projeto_idx
  on public.site_conteudo_versoes (projeto_id, versao desc);
create index if not exists site_clientes_slug_idx
  on public.site_clientes (slug);

-- ---------------------------------------------------------------------
-- RLS: ligada, sem política. Quem lê é a rk-api, com a chave de serviço, na
-- VPS. RLS ligada sem política = negado para anon, que é o que se quer: o
-- navegador nunca recebe chave, e é regra do pedido.
--
-- No dia em que o painel ganhar login próprio, as políticas entram aqui — e
-- não no front-end.
-- ---------------------------------------------------------------------
alter table public.site_clientes          enable row level security;
alter table public.site_projetos          enable row level security;
alter table public.site_conteudo_versoes  enable row level security;
alter table public.site_geracoes          enable row level security;

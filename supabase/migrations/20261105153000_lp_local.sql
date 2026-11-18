-- =====================================================================
-- PAGINAS LOCAIS (biblioteca de landing pages) — o que o Site Rock recebe do Rock SEO, aprova e publica
-- ---------------------------------------------------------------------
-- VERSAO FINAL (05/11/2026), escrita ANTES de ser aplicada: depois de aplicada, qualquer mudanca vira a 008.
-- Opcao D (01/11/2026): o Rock SEO escreve a copy e entrega o JSON `lp-local@1` VERSIONADO; o Site Rock so veste, aprova e publica.
-- Banco separado, sem chamada ao Rock SEO na renderizacao.
--
-- Por que tabela nova e nao `site_projetos.conteudo`: o projeto e UM por cliente e guarda UMA copy; a LP local e uma pagina
-- por cidade (e por palavra-chave), cada uma com versoes. `conteudo` continua sendo a caixa de entrada da home.
--
--   site_lp_paginas   uma pagina (cliente x slug): template, estado, indexacao, configuracao de renderizacao e os PONTEIROS do fluxo
--                     (previa corrente, aprovacao visual, publicacao no WordPress)
--   site_lp_versoes   o JSON de cada entrega. IMUTAVEL; o mesmo hash nao entra duas vezes
--
-- O FLUXO (o painel pede por site_pedidos; quem escreve e o worker, com a chave de servico)
--   receber        pedido { tipo: 'lp-local', operacao: 'receber', pacote, config? }       -> pagina + versao (estado `recebida`)
--   gerar_previa   pedido { tipo: 'lp-local', operacao: 'gerar_previa', pagina_id }       -> UMA linha em site_geracoes (tipo 'lp-local');
--                                                                                           previa_geracao_id aponta para ela
--   aprovar        RPC aprovar_lp_visual(pagina, geracao)                                 -> estado `aprovada_visual`
--   publicar       pedido { tipo: 'wordpress', operacao: 'publicar', geracao }            -> estado `publicada` (o worker confere de novo a trava)
--
-- ESTADOS: recebida -> aprovada_visual -> publicada. `publicada_sem_conferencia` = esta no ar no WordPress, mas o servidor NAO conseguiu confirmar o robots no que o
-- visitante recebe (<head>/cabecalho publico): confira a URL, o plugin de SEO e o cache; publicar de novo, depois de arrumar, volta a `publicada`. `arquivada` nao tem
-- escritor ainda (reservado). Uma versao nova de pagina `publicada` (ou `publicada_sem_conferencia`) NAO a rebaixa (o WordPress segue com a versao publicada): so
-- versao_atual anda; versao_publicada diz o que esta no ar.
-- Versao nova, ou configuracao nova, apaga previa_geracao_id e a aprovacao visual: eram do conteudo/botao antigos.
--
-- ONDE MORA CADA COISA (a razao do desenho): o trigger abaixo proibe todo UPDATE em site_lp_versoes, entao o que muda com o fluxo (previa, aprovacao,
-- publicacao) mora em site_lp_paginas (ponteiros) e em site_geracoes (o render: html_path, token, problemas, parametros.lp).
--
-- `indexacao` nasce 'noindex' e so muda por uma operacao propria do servidor (fase 2, ainda nao escrita): previa e pagina em revisao nunca
-- sao indexaveis.
--
-- O painel (logado) so LE as duas tabelas. As unicas escritas dele sao as RPCs abaixo (security definer, validam tudo): um UPDATE livre deixaria
-- aprovar qualquer uuid. Isto vale em TRES camadas (a revisao de 05/11 achou que so a RLS segurava):
--   1. PRIVILEGIO: `authenticated` so tem SELECT nas duas tabelas (e `anon` nada); INSERT/UPDATE/DELETE/TRUNCATE sao revogados. TRUNCATE ignora RLS,
--      entao so o REVOKE o impede (os grants default do Supabase dao tudo a anon/authenticated).
--   2. RLS: a unica policy e a de leitura de `authenticated`.
--   3. CASCATA: `site_lp_paginas.cliente_id` e ON DELETE RESTRICT. A policy `painel_tudo` de site_clientes (002) deixa o painel apagar um cliente, e o
--      DELETE em cascata ignora os privilegios das tabelas filhas: com CASCADE, um clique apagaria todas as paginas e versoes do cliente (inclusive
--      wp_pagina_id/wp_url das publicadas), sem trilha. Com RESTRICT o banco recusa apagar cliente que tem pagina local; quem remove pagina e o
--      servidor (service_role). As versoes continuam em CASCADE da PAGINA: so o servidor apaga pagina, e o trigger de imutabilidade cobre so UPDATE.
-- =====================================================================

create table if not exists public.site_lp_paginas (
  id                  uuid primary key default gen_random_uuid(),
  cliente_id          uuid not null references public.site_clientes(id) on delete restrict,   -- RESTRICT de proposito: ver o cabecalho (cascata do painel)
  slug                text not null,
  cidade              text not null,
  uf                  text not null check (uf ~ '^[A-Z]{2}$'),
  palavra_chave       text not null,
  template_id         text not null default 'rk-lp-a',
  estado              text not null default 'recebida'
                      check (estado in ('recebida', 'aprovada_visual', 'publicada', 'publicada_sem_conferencia', 'arquivada')),
  indexacao           text not null default 'noindex' check (indexacao in ('noindex', 'index')),
  versao_atual        integer not null default 0,
  rockseo_lp_local_id uuid,                       -- a ponte com lp_locais (outro projeto): uuid solto, sem FK
  -- configuracao de renderizacao (NAO e copy): { cta: { conversao_primaria: { destino }, conversao_secundaria? }, grafismo?, fotos? }.
  -- O pacote do Rock SEO nao a traz; o operador a fornece (pedido `receber`) ou a muda pela RPC definir_lp_config. O mapa nao entra aqui:
  -- o worker o acha/gera e o grava em site_geracoes.parametros.lp.config_aplicada.
  config              jsonb not null default '{}'::jsonb,
  -- a pagina de que esta e variante/duplicata: o SEO publica `rel=canonical` para a url dela (teste A/B nao pode gerar URLs organicas iguais)
  canonical_de        uuid references public.site_lp_paginas(id) on delete set null,
  -- os ponteiros do fluxo
  previa_geracao_id          uuid references public.site_geracoes(id) on delete set null,   -- a ULTIMA previa (e a unica que se pode aprovar)
  aprovada_visual_geracao_id uuid references public.site_geracoes(id) on delete set null,
  aprovada_visual_por        uuid,                                                          -- auth.uid() de quem aprovou
  aprovada_visual_em         timestamptz,
  publicada_geracao_id       uuid references public.site_geracoes(id) on delete set null,
  versao_publicada           integer,                                                       -- a versao do CONTEUDO que esta no WordPress
  wp_pagina_id               bigint,
  wp_url                     text,
  publicada_em               timestamptz,
  criado_em           timestamptz not null default now(),
  atualizado_em       timestamptz not null default now(),
  constraint site_lp_pagina_unica unique (cliente_id, slug),
  constraint site_lp_canonical_nao_e_ela_mesma check (canonical_de is distinct from id)
);

create table if not exists public.site_lp_versoes (
  id           uuid primary key default gen_random_uuid(),
  pagina_id    uuid not null references public.site_lp_paginas(id) on delete cascade,
  versao       integer not null check (versao >= 1),
  hash         text not null check (hash ~ '^[0-9a-f]{64}$'),
  conteudo     jsonb not null,                    -- contrato lp-local@1 completo
  aprovacao    jsonb,                             -- {por, em, versao} dada no Rock SEO
  -- os caminhos (a partir da raiz do contrato) das afirmacoes `pendente` que o responsavel confirmou no Rock SEO; o worker as usa para
  -- liberar `publicavel` na previa. O hash cobre so o `conteudo`: o worker e a aprovacao visual cobrem o resto.
  afirmacoes_confirmadas jsonb not null default '[]'::jsonb,
  origem       text not null default 'rockseo',
  rockseo_versao integer,
  recebido_em  timestamptz not null default now(),
  constraint site_lp_versao_unica unique (pagina_id, versao),
  constraint site_lp_hash_unico unique (pagina_id, hash)
);

create index if not exists site_lp_versoes_pagina_idx on public.site_lp_versoes (pagina_id, versao desc);

create or replace function public.site_lp_versoes_imutavel() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'site_lp_versoes e imutavel: receba uma nova versao';
end $$;
drop trigger if exists site_lp_versoes_no_update on public.site_lp_versoes;
create trigger site_lp_versoes_no_update before update on public.site_lp_versoes
  for each row execute function public.site_lp_versoes_imutavel();

alter table public.site_lp_paginas enable row level security;
alter table public.site_lp_versoes enable row level security;

drop policy if exists painel_le on public.site_lp_paginas;
create policy painel_le on public.site_lp_paginas for select to authenticated using (true);
drop policy if exists painel_le on public.site_lp_versoes;
create policy painel_le on public.site_lp_versoes for select to authenticated using (true);
-- anonimo: nenhuma policy = nem le nem grava (a mesma regra das demais tabelas do SITEROCK)

-- PRIVILEGIOS (a 1a camada): o Supabase concede tudo a anon/authenticated por default (alter default privileges), e TRUNCATE nao passa pela RLS.
-- Revoga tudo e devolve so SELECT ao painel logado. O service_role (o worker) fica com o que tem, e as funcoes security definer rodam como dono.
revoke all on public.site_lp_paginas from public, anon, authenticated;
revoke all on public.site_lp_versoes from public, anon, authenticated;
grant select on public.site_lp_paginas to authenticated;
grant select on public.site_lp_versoes to authenticated;

-- ---------------------------------------------------------------------
-- RPC 1 — APROVAR A PREVIA (aprovacao visual)
-- Mesma ideia de aprovar_site_geracao (005): um UPDATE direto da tela deixaria aprovar uma geracao de outro projeto, ou uma previa velha.
-- O que a funcao exige:
--   1. a geracao e DESTA pagina (tipo 'lp-local', parametros.lp.pagina_id) e de um projeto do MESMO cliente;
--   2. e a ULTIMA previa da pagina (previa_geracao_id): mudou a versao ou a configuracao, a previa corrente some e esta nao se aprova;
--   3. foi renderizada com a versao atual do conteudo;
--   4. tem html_path, parametros.lp.publicavel = true e nenhum problema `erro_bloqueante` (afirmacao pendente sem confirmacao trava `publicavel`).
--   5. foi renderizada com a configuracao ATUAL da pagina (parametros.lp.config_aplicada sem o `mapa` = site_lp_paginas.config): fecha a corrida em que o
--      operador troca o botao enquanto a previa renderiza com o antigo.
-- Uma pagina ja `publicada` (ou `publicada_sem_conferencia`) continua como esta (o WordPress segue no ar); a aprovacao e para a PROXIMA publicacao.
-- ---------------------------------------------------------------------
create or replace function public.aprovar_lp_visual(p_pagina_id uuid, p_geracao_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pagina  public.site_lp_paginas%rowtype;
  v_ger     public.site_geracoes%rowtype;
  v_cliente uuid;
begin
  select * into v_pagina from public.site_lp_paginas where id = p_pagina_id for update;
  if not found then
    raise exception 'pagina nao encontrada: %', p_pagina_id;
  end if;
  select * into v_ger from public.site_geracoes where id = p_geracao_id;
  if not found then
    raise exception 'geracao nao encontrada: %', p_geracao_id;
  end if;
  select p.cliente_id into v_cliente from public.site_projetos p where p.id = v_ger.projeto_id;

  if v_pagina.estado = 'arquivada' then
    raise exception 'a pagina esta arquivada';
  end if;
  if v_ger.tipo <> 'lp-local' or v_cliente is distinct from v_pagina.cliente_id
     or (v_ger.parametros -> 'lp' ->> 'pagina_id') is distinct from p_pagina_id::text then
    raise exception 'a geracao % nao e uma previa desta pagina', p_geracao_id;
  end if;
  if v_pagina.previa_geracao_id is distinct from p_geracao_id then
    raise exception 'so a ultima previa da pagina pode ser aprovada: gere a previa de novo';
  end if;
  if (v_ger.parametros -> 'lp' ->> 'versao_conteudo') is distinct from v_pagina.versao_atual::text then
    raise exception 'a previa e de outra versao do conteudo (a pagina esta na %)', v_pagina.versao_atual;
  end if;
  if v_ger.html_path is null or btrim(v_ger.html_path) = '' then
    raise exception 'a previa nao tem HTML gerado';
  end if;
  if (v_ger.parametros -> 'lp' ->> 'publicavel') is distinct from 'true' then
    raise exception 'a previa ainda tem pendencia (afirmacao sem confirmacao ou erro): nao pode ser aprovada';
  end if;
  if jsonb_typeof(v_ger.problemas) <> 'array' or exists (
    select 1 from jsonb_array_elements(v_ger.problemas) x where x ->> 'classificacao' = 'erro_bloqueante'
  ) then
    raise exception 'a previa tem erro bloqueante: nao pode ser aprovada';
  end if;
  -- corrida previa x configuracao: o worker confere a config no fim do render, mas o operador pode salvar o botao novo ENTRE essa conferencia e o PATCH que aponta
  -- previa_geracao_id (a RPC definir_lp_config zera o ponteiro, o PATCH o poe de volta). Aqui, com a linha travada, a config aplicada na previa (sem o mapa, que o
  -- worker gera) tem de ser a config ATUAL da pagina; sem config_aplicada, tambem nao aprova.
  if (case when jsonb_typeof(v_ger.parametros -> 'lp' -> 'config_aplicada') = 'object'
           then ((v_ger.parametros -> 'lp' -> 'config_aplicada') - 'mapa') = v_pagina.config
           else false end) is not true then
    raise exception 'a previa foi renderizada com outra configuracao (botao, fotos ou grafismo) que a atual da pagina: gere a previa de novo';
  end if;

  update public.site_lp_paginas
  set estado                     = case when estado in ('publicada', 'publicada_sem_conferencia') then estado else 'aprovada_visual' end,
      aprovada_visual_geracao_id = p_geracao_id,
      aprovada_visual_por        = auth.uid(),
      aprovada_visual_em         = now(),
      atualizado_em              = now()
  where id = p_pagina_id;
end;
$$;

-- ---------------------------------------------------------------------
-- RPC 2 — DEFINIR A CONFIGURACAO DE RENDERIZACAO (destino do botao etc.)
-- As MESMAS regras de app/api/lp-local-config.js (validarConfig): a RPC nao pode aceitar o que o worker depois recusa (o gerar_previa revalida e fecha
-- em erro). Os dois lados sao provados com os mesmos casos (test/fixtures/lp-local-config-casos.json). O destino:
--   - comeca com `https://`, so caracteres que NAO sao espaco, aspas, `<` nem `>`; espaco = o `\s` do JavaScript, ENUMERADO aqui (NBSP, BOM, o
--     espaco ideografico etc. tambem): `[[:space:]]` dependeria da locale do banco e deixaria o NBSP passar;
--   - de 12 a 498 caracteres (code points, como o regex com flag `u` do JS). O Postgres recusa repeticao > 255, entao o limite superior e o char_length.
-- fotos e grafismo so valem na pasta do PROPRIO cliente da pagina (site_clientes.slug): senao o arquivo de outro cliente seria embutido na previa.
-- Mudar a configuracao invalida a previa e a aprovacao visual (viraram do botao antigo): a pagina `aprovada_visual` volta a `recebida`; a
-- `publicada` segue publicada. Configuracao igual a que ja esta: nada muda.
-- ---------------------------------------------------------------------
create or replace function public.definir_lp_config(p_pagina_id uuid, p_config jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pagina  public.site_lp_paginas%rowtype;
  v_papel   text;
  v_cta     jsonb;
  v_item    jsonb;
  v_destino text;
  v_slug    text;
begin
  select * into v_pagina from public.site_lp_paginas where id = p_pagina_id for update;
  if not found then
    raise exception 'pagina nao encontrada: %', p_pagina_id;
  end if;
  if v_pagina.estado = 'arquivada' then
    raise exception 'a pagina esta arquivada';
  end if;
  if p_config is null or jsonb_typeof(p_config) <> 'object' then
    raise exception 'a configuracao precisa ser um objeto';
  end if;
  if (p_config - array['cta', 'grafismo', 'fotos']) <> '{}'::jsonb then
    raise exception 'configuracao com chave desconhecida (aceitas: cta, grafismo, fotos; o mapa nao se digita)';
  end if;
  select c.slug into v_slug from public.site_clientes c where c.id = v_pagina.cliente_id;
  v_slug := coalesce(v_slug, '');
  if p_config ? 'cta' then
    v_cta := p_config -> 'cta';
    if jsonb_typeof(v_cta) <> 'object' then
      raise exception 'cta so aceita conversao_primaria e conversao_secundaria';
    end if;
    if (v_cta - array['conversao_primaria', 'conversao_secundaria']) <> '{}'::jsonb then
      raise exception 'cta so aceita conversao_primaria e conversao_secundaria';
    end if;
    foreach v_papel in array array['conversao_primaria', 'conversao_secundaria'] loop
      if v_cta ? v_papel then
        v_item := v_cta -> v_papel;
        if jsonb_typeof(v_item) <> 'object' then
          raise exception 'cta.%.destino precisa ser um endereco https:// (sem espacos nem aspas)', v_papel;
        end if;
        v_destino := case when jsonb_typeof(v_item -> 'destino') = 'string' then v_item ->> 'destino' end;
        if (v_item - 'destino') <> '{}'::jsonb
           or v_destino is null
           or v_destino !~ '^https://[^\t\n\v\f\r \u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff"''<>]+$'
           or char_length(v_destino) not between 12 and 498 then
          raise exception 'cta.%.destino precisa ser um endereco https:// (sem espacos nem aspas)', v_papel;
        end if;
      end if;
    end loop;
  end if;
  if p_config ? 'grafismo' then
    if jsonb_typeof(p_config -> 'grafismo') <> 'string' or (p_config ->> 'grafismo') !~ '^/marca/[a-z0-9-]+/[a-z0-9._-]+$' then
      raise exception 'grafismo precisa ser um caminho /marca/<cliente>/<arquivo>';
    end if;
    if left(p_config ->> 'grafismo', char_length('/marca/' || v_slug || '/')) <> '/marca/' || v_slug || '/' then
      raise exception 'grafismo precisa estar na pasta do cliente desta pagina (/marca/%/<arquivo>), nao na de outro cliente', v_slug;
    end if;
  end if;
  if p_config ? 'fotos' then
    if jsonb_typeof(p_config -> 'fotos') <> 'string' or (p_config ->> 'fotos') !~ '^/fotos/[a-z0-9-]+$' then
      raise exception 'fotos precisa ser um caminho /fotos/<cliente>';
    end if;
    if (p_config ->> 'fotos') <> '/fotos/' || v_slug then
      raise exception 'fotos precisa ser a pasta do cliente desta pagina (/fotos/%), nao a de outro cliente', v_slug;
    end if;
  end if;

  if v_pagina.config = p_config then
    return;
  end if;
  update public.site_lp_paginas
  set config                     = p_config,
      previa_geracao_id          = null,
      aprovada_visual_geracao_id = null,
      aprovada_visual_por        = null,
      aprovada_visual_em         = null,
      estado                     = case when estado = 'aprovada_visual' then 'recebida' else estado end,
      atualizado_em              = now()
  where id = p_pagina_id;
end;
$$;

-- ---------------------------------------------------------------------
-- RPC 3 — DEFINIR DE QUEM A PAGINA E VARIANTE (canonical)
-- A outra pagina tem de ser do MESMO cliente, nao a propria e nao arquivada (a pagina arquivada tambem nao muda); NULL limpa. Recusa CICLO de qualquer
-- tamanho (A->B->A, A->B->C->A): as duas paginas publicariam rel=canonical uma para a outra e o Google ignoraria os dois sinais. Cadeia sem ciclo
-- (A->B->C) e aceita: o SEO de A aponta para B. So muda o SEO da PROXIMA publicacao (nao o HTML aprovado).
-- As duas linhas sao travadas sempre na ordem do id: duas chamadas cruzadas (A->B e B->A ao mesmo tempo) nao conseguem se ultrapassar; so um ciclo
-- de 3 chamadas simultaneas poderia furar a checagem (alguem clicando em tres telas ao mesmo tempo).
-- ---------------------------------------------------------------------
create or replace function public.definir_lp_canonical(p_pagina_id uuid, p_canonical_de uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pagina public.site_lp_paginas%rowtype;
  v_outra  public.site_lp_paginas%rowtype;
  v_atual  uuid;
  v_passos integer := 0;
begin
  perform 1 from public.site_lp_paginas where id in (p_pagina_id, p_canonical_de) order by id for update;
  select * into v_pagina from public.site_lp_paginas where id = p_pagina_id;
  if not found then
    raise exception 'pagina nao encontrada: %', p_pagina_id;
  end if;
  if v_pagina.estado = 'arquivada' then
    raise exception 'a pagina esta arquivada';
  end if;
  if p_canonical_de is not null then
    if p_canonical_de = p_pagina_id then
      raise exception 'a pagina nao pode ser canonical dela mesma';
    end if;
    select * into v_outra from public.site_lp_paginas o where o.id = p_canonical_de and o.cliente_id = v_pagina.cliente_id;
    if not found then
      raise exception 'a outra pagina nao existe neste cliente: %', p_canonical_de;
    end if;
    if v_outra.estado = 'arquivada' then
      raise exception 'a outra pagina esta arquivada: ela nao pode ser o canonical';
    end if;
    v_atual := v_outra.canonical_de;
    while v_atual is not null loop
      if v_atual = p_pagina_id then
        raise exception 'ciclo de canonical: a outra pagina ja aponta (direta ou indiretamente) para esta';
      end if;
      v_passos := v_passos + 1;
      if v_passos > 50 then
        raise exception 'cadeia de canonical longa demais (mais de 50 paginas)';
      end if;
      select o.canonical_de into v_atual from public.site_lp_paginas o where o.id = v_atual;
    end loop;
  end if;
  update public.site_lp_paginas set canonical_de = p_canonical_de, atualizado_em = now() where id = p_pagina_id;
end;
$$;

-- ---------------------------------------------------------------------
-- PERMISSOES DAS FUNCOES — nenhum role herda execute por default; so quem esta logado no painel (e o worker, que ignora a RLS de qualquer jeito)
-- ---------------------------------------------------------------------
revoke all on function public.aprovar_lp_visual(uuid, uuid) from public;
revoke all on function public.aprovar_lp_visual(uuid, uuid) from anon;
grant execute on function public.aprovar_lp_visual(uuid, uuid) to authenticated, service_role;

revoke all on function public.definir_lp_config(uuid, jsonb) from public;
revoke all on function public.definir_lp_config(uuid, jsonb) from anon;
grant execute on function public.definir_lp_config(uuid, jsonb) to authenticated, service_role;

revoke all on function public.definir_lp_canonical(uuid, uuid) from public;
revoke all on function public.definir_lp_canonical(uuid, uuid) from anon;
grant execute on function public.definir_lp_canonical(uuid, uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- O CATALOGO GANHA lp_modelos (05/11/2026) — os modelos de landing page da biblioteca (biblioteca/lp-local) que o painel lista
-- O painel nao le arquivo da VPS: quem publica a linha e `app/api/publicar-catalogo.js` (chave `lp_modelos`), a partir dos MESMOS arquivos que montam a galeria
-- assinada do servidor de previa. Sem esta linha no CHECK o POST do catalogo e recusado (site_catalogo_chave_check) e o publicador, que ja trata a recusa, deixa
-- `lp_modelos` de fora e DIZ isso: o resto do catalogo nao cai. Idempotente (drop if exists + add), como a 004 e a 006; mantem as cinco chaves de antes.
-- A policy do catalogo (003) segue a mesma: o painel LOGADO le (`to authenticated`), ninguem mais; quem escreve e a VPS, com a chave de servico. A linha traz
-- links ASSINADOS da biblioteca: a assinatura e o controle de acesso, e so quem esta logado no painel os le.
-- ---------------------------------------------------------------------
alter table public.site_catalogo drop constraint if exists site_catalogo_chave_check;
alter table public.site_catalogo
  add constraint site_catalogo_chave_check
  check (chave in ('modelos', 'blocos', 'marcas', 'estilos', 'fontes', 'lp_modelos'));

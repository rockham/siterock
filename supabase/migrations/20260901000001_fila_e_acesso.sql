-- =====================================================================
-- A FILA E O ACESSO — o que o Lovable precisa para operar o painel
-- ---------------------------------------------------------------------
-- Decisão do Felipe, 11/09/2026: "siga o plano, front-end na Lovable". O
-- PLANO.md já dizia desde agosto: o Lovable faz as telas e LÊ o banco; as
-- tabelas, o compilador e os blocos nascem no rk-core.
--
-- ISTO DESFAZ UMA DECISÃO MINHA DE 10/09. Eu tinha ligado RLS sem política
-- nenhuma e escrito "quem fala com o banco é a rk-api, o navegador nunca vê
-- chave". Com o front no Lovable, é o navegador que fala com o banco — então
-- sem política ele não lê nada. As políticas abaixo abrem o acesso, e só para
-- quem está LOGADO.
--
-- POR QUE LOGADO, E NÃO ANÔNIMO COMO O PAINEL DO ROCKSEO
-- A chave publishable vai dentro do JavaScript do Lovable, e qualquer um que
-- abra o site a lê. Com política para `anon`, quem tivesse a URL leria o
-- briefing de todos os escritórios — telefone, OAB, fotos — e poderia disparar
-- geração na VPS. Com política para `authenticated`, a chave publishable sozinha
-- não abre nada: precisa de uma conta criada no Auth deste projeto.
--
-- COMO O LOVABLE DISPARA TRABALHO PESADO — o padrão do ROCKSEO, sem HTTP
-- O compilador roda na VPS e lê blocos do disco; não cabe em Edge Function. O
-- ROCKSEO já resolveu isso: o Lovable faz INSERT numa tabela de pedidos, um
-- worker na VPS faz o CLAIM atômico (pendente -> rodando, só um vence), executa
-- e grava o resultado. O Lovable acompanha o status. Nenhuma porta aberta na
-- VPS, e a fila sobrevive a worker fora do ar: o pedido espera.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. A FILA
-- ---------------------------------------------------------------------
create table if not exists public.site_pedidos (
  id           uuid primary key default gen_random_uuid(),
  projeto_id   uuid not null references public.site_projetos(id) on delete cascade,
  -- gerar: uma home de um modelo | gerar_todas: todos os modelos de uma vez
  acao         text not null check (acao in ('gerar', 'gerar_todas')),
  -- o que o painel pediu: modelo, marca, cores, observação do REGENERAR
  payload      jsonb not null default '{}'::jsonb,
  status       text not null default 'pendente'
               check (status in ('pendente', 'rodando', 'feito', 'erro')),
  -- as gerações que este pedido produziu (gerar_todas produz várias)
  resultado    jsonb,
  erro         text,
  criado_por   uuid default auth.uid(),
  criado_em    timestamptz not null default now(),
  iniciado_em  timestamptz,
  concluido_em timestamptz
);

create index if not exists site_pedidos_pendentes_idx
  on public.site_pedidos (criado_em) where status = 'pendente';

-- A GERAÇÃO PASSA A SABER ONDE O HTML DELA ESTÁ NO STORAGE, para o painel
-- mostrar o preview sem depender do DNS de preview.rockham.com.br.
alter table public.site_geracoes
  add column if not exists html_path text;

alter table public.site_pedidos enable row level security;

-- ---------------------------------------------------------------------
-- 2. AS POLÍTICAS — só para quem está logado
--
-- O que o painel ESCREVE direto: cliente, projeto (briefing, copy,
-- identidade, home aprovada), versão da copy, e o PEDIDO.
--
-- O que ele SÓ LÊ: as gerações e o andamento do pedido. Quem grava geração é o
-- worker, com a chave de serviço — se o painel pudesse gravar, uma "versão"
-- poderia existir sem ter passado pelo compilador e pelos 30 validadores.
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['site_clientes', 'site_projetos', 'site_conteudo_versoes'] loop
    execute format('drop policy if exists painel_tudo on public.%I', t);
    execute format(
      'create policy painel_tudo on public.%I for all to authenticated using (true) with check (true)', t);
  end loop;
end $$;

drop policy if exists painel_le on public.site_geracoes;
create policy painel_le on public.site_geracoes
  for select to authenticated using (true);

drop policy if exists painel_le on public.site_pedidos;
create policy painel_le on public.site_pedidos
  for select to authenticated using (true);

-- o pedido NASCE pendente pelo painel, e só isso: status, resultado e erro
-- são do worker. Um INSERT com status 'feito' seria uma geração que nunca
-- aconteceu aparecendo como pronta.
drop policy if exists painel_pede on public.site_pedidos;
create policy painel_pede on public.site_pedidos
  for insert to authenticated
  with check (status = 'pendente' and resultado is null and erro is null);

-- ---------------------------------------------------------------------
-- 3. O STORAGE
--
-- site-marca     logo e fotos: o painel sobe, todo mundo lê (público — o
--                preview mostra a logo para o advogado).
-- site-previews  o HTML montado de cada geração. PRIVADO: o painel baixa pela
--                API e mostra num iframe srcdoc.
--
-- Por que o HTML não pode ser público no Storage: medido em 11/09, a Supabase
-- serve .html como `text/plain` com `content-security-policy: default-src
-- 'none'; sandbox`. É proteção deliberada deles: link direto NÃO renderiza. O
-- link público para o advogado continua sendo o preview/server.js da VPS.
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit)
values ('site-previews', 'site-previews', false, 20971520)
on conflict (id) do nothing;

drop policy if exists painel_sobe_marca on storage.objects;
create policy painel_sobe_marca on storage.objects
  for insert to authenticated with check (bucket_id = 'site-marca');

drop policy if exists painel_troca_marca on storage.objects;
create policy painel_troca_marca on storage.objects
  for update to authenticated using (bucket_id = 'site-marca');

drop policy if exists painel_apaga_marca on storage.objects;
create policy painel_apaga_marca on storage.objects
  for delete to authenticated using (bucket_id = 'site-marca');

drop policy if exists painel_le_previews on storage.objects;
create policy painel_le_previews on storage.objects
  for select to authenticated using (bucket_id in ('site-marca', 'site-previews'));

-- ---------------------------------------------------------------------
-- 4. REALTIME na fila, para o painel ver o pedido andar sem polling
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and tablename = 'site_pedidos') then
    execute 'alter publication supabase_realtime add table public.site_pedidos';
  end if;
end $$;

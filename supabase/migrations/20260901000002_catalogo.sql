-- =====================================================================
-- O CATÁLOGO — o que o painel precisa saber e que só existe no disco da VPS
-- ---------------------------------------------------------------------
-- O painel é do Lovable, roda no navegador, e não lê arquivo da VPS. Mas para
-- desenhar as telas ele precisa de três listas que moram lá:
--
--   modelos   os modelos de home (arranjos A, B, C) e as seções de cada um
--   blocos    os campos de cada seção — rótulo, tipo, limite, ajuda — que são
--             o contrato do `blocks/<bloco>/meta.json`
--   marcas    as identidades de tokens disponíveis
--
-- A alternativa era o Lovable escrever essas listas no código dele, e aí o
-- painel mostraria um campo que o compilador não conhece — ou esconderia um que
-- ele exige, e a geração reprovaria sem o Felipe entender por quê. O pedido
-- dizia: "não invente campos arbitrariamente". Então quem publica é a VPS
-- (`app/api/publicar-catalogo.js`), a partir dos mesmos arquivos que o
-- compilador lê, e o painel só lê.
--
-- Uma linha por lista. O worker republica ao subir, então o catálogo nunca fica
-- mais velho que o motor que está rodando.
-- =====================================================================

create table if not exists public.site_catalogo (
  chave         text primary key check (chave in ('modelos', 'blocos', 'marcas')),
  dados         jsonb not null,
  atualizado_em timestamptz not null default now()
);

alter table public.site_catalogo enable row level security;

-- o painel LÊ; quem escreve é a VPS, com a chave de serviço
drop policy if exists painel_le on public.site_catalogo;
create policy painel_le on public.site_catalogo
  for select to authenticated using (true);

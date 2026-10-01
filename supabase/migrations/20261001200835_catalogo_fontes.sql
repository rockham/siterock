-- =====================================================================
-- O CATÁLOGO GANHA AS FONTES PADRÃO
-- ---------------------------------------------------------------------
-- Pedido do Felipe, 01/10/2026: toda identidade poder trocar de fonte
-- (título e texto) e comparar as 17 opções padrão — sem precisar de
-- licença própria para cada escritório. As fontes (com arquivo, licença e
-- pilha de CSS) já existiam no disco desde 01/10 (fontes-padrao/LEIA.md);
-- quem publica é a VPS, a partir de estilos/fontes-padrao.json — o painel
-- só lê, do mesmo jeito que já lê modelos, blocos, marcas e estilos.
-- =====================================================================

alter table public.site_catalogo drop constraint if exists site_catalogo_chave_check;
alter table public.site_catalogo
  add constraint site_catalogo_chave_check
  check (chave in ('modelos', 'blocos', 'marcas', 'estilos', 'fontes'));

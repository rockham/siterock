-- =====================================================================
-- O CATÁLOGO GANHA OS ESTILOS
-- ---------------------------------------------------------------------
-- Pedido do Felipe, 11/09/2026: no REGENERAR, "mesmo layout com outra cor ou
-- layout diferente seguindo o mesmo padrão — tipo futurista, minimalista".
-- Os quatro estilos já estavam escritos em estilos/*.md desde 20/08; agora
-- viram opção do painel. Quem publica é a VPS, a partir de
-- estilos/estilos.json; o painel só lê.
-- =====================================================================

alter table public.site_catalogo drop constraint if exists site_catalogo_chave_check;
alter table public.site_catalogo
  add constraint site_catalogo_chave_check
  check (chave in ('modelos', 'blocos', 'marcas', 'estilos'));

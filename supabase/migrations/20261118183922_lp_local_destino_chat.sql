-- =====================================================================
-- 008 — DESTINO "#abrir-chat" NA CONFIGURACAO DE RENDERIZACAO DAS LPs LOCAIS (18/11/2026, pedido do dono)
-- O botao da capa pode abrir o chat do Rock Leads em vez de levar a um endereco https://: o destino aceita, ALEM de https://, a ancora FIXA
-- `#abrir-chat` (igualdade exata; qualquer outra ancora continua recusada). Mesma regra de app/api/lp-local-config.js (DESTINO_CHAT), provada
-- com os mesmos casos (test/fixtures/lp-local-config-casos.js). So recria a RPC definir_lp_config: assinatura igual, entao os privilegios que a
-- 007 concedeu seguem valendo. Idempotente (create or replace). Nada de tabela, dado ou privilegio novo.
-- =====================================================================

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
          raise exception 'cta.%.destino precisa ser um endereco https:// (sem espacos nem aspas) ou #abrir-chat', v_papel;
        end if;
        v_destino := case when jsonb_typeof(v_item -> 'destino') = 'string' then v_item ->> 'destino' end;
        if (v_item - 'destino') <> '{}'::jsonb
           or v_destino is null
           or (v_destino <> '#abrir-chat'
               and (v_destino !~ '^https://[^\t\n\v\f\r \u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff"''<>]+$'
                    or char_length(v_destino) not between 12 and 498)) then
          raise exception 'cta.%.destino precisa ser um endereco https:// (sem espacos nem aspas) ou #abrir-chat', v_papel;
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

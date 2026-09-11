# siterock-schema

O schema do banco do **painel de sites** da Rockham (projeto Supabase
**SITEROCK**, `jbsrobnhwvcvjgvtyzel`).

## O que é este repositório

Só o schema (`supabase/migrations/`). O código do painel vive no Lovable; o
código do compilador e do worker vive na VPS (`rk-core` / `SITE ROCK`), que
**não** está neste repositório.

## Como uma migração chega aqui

As migrações **nascem** em `app/banco/*.sql` no repositório `rk-core`, na VPS,
com o histórico completo do porquê de cada tabela e cada política — o
comentário de cada arquivo é a documentação da decisão. Este repositório
recebe uma **cópia**, renomeada para o formato que o Supabase CLI espera
(`<timestamp>_<nome>.sql`), sempre que uma migração nova é escrita.

## Integração com o Supabase

Este repositório está ligado ao projeto SITEROCK pela integração oficial do
Supabase (Project Settings → Integrations → GitHub). **O modo de aplicação
(automática ou não) é uma decisão a confirmar com o Felipe** — ver o aviso no
histórico do rk-core sobre o risco de dois caminhos de migração divergirem.

Enquanto isso não for decidido, este repositório é **espelho e histórico**:
o schema de verdade continua sendo aplicado pela VPS.

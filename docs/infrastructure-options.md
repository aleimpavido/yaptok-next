# Infrastructure options for YapTok (November 2026)

## Target and non-negotiable constraints

YapTok should support roughly 100 active users on an average day, with occasional peaks above that, while keeping the monthly bill at **€0**. Video delivery is the largest uncertainty: storage, egress, and transcoding can exceed free quotas much sooner than chat traffic.

A free plan is not an unlimited plan. Providers may pause projects, reject requests, or freeze features when quotas are exhausted. Do not configure a payment method or enable usage-based billing without the owner's explicit approval.

## Shortlist

| Option | Useful free allowance (current published plan) | What it would mean for YapTok |
|---|---|---|
| Supabase Free | 500 MB Postgres, 50,000 MAU, 5 GB egress, 1 GB file storage, 200 peak Realtime connections, 2 million Realtime messages/month; projects pause after one week of inactivity | Best fit with the existing code: Postgres functions, RLS, Supabase Auth and Realtime already match the data model. Main risks are database size, egress, lack of automatic backups and inactivity pause. |
| Appwrite Cloud Free | 75,000 MAU, 2 GB storage, 5 GB bandwidth, 750,000 executions, one database, one bucket, two functions; 250 concurrent Realtime connections and 2 million Realtime messages/month | A credible managed alternative, but it is not a drop-in Supabase replacement. The current Postgres schema, SQL functions, RLS rules and migration/test tooling would need substantial redesign. Free projects pause after one week of inactivity and reaching limits can disable API, Realtime or functions. |
| Cloudflare Workers + D1 + Durable Objects | Workers: 100,000 requests/day. D1 Free: 5 GB total storage, 5 million rows read/day, 100,000 rows written/day. Durable Objects Free: 100,000 requests/day and 13,000 GB-seconds/day | Potentially the most integrated low-cost edge stack, especially alongside R2. But it requires rewriting Postgres SQL/RLS and authentication, replacing Supabase Realtime, and validating Next.js deployment compatibility. Long-lived chat connections must use WebSocket Hibernation to stay within compute limits. |
| Convex Free | 0.5 GB database, 1 million function calls/month, 1 GB file storage and 1 GB database I/O/month | Strong reactive programming model for chat and live UI. However, it uses a different data model and requires moving database logic from SQL into TypeScript functions. It is not a small migration. |
| Neon Free | Managed Postgres with a free allowance | Could replace only the database layer, not Supabase Auth, Storage or Realtime. It would add integration work without solving the current main bottleneck. |

## Recommendation

**Keep Supabase for the first YapChat release. Do not migrate the backend during the messaging implementation.**

Reasons:

1. The current project already relies on Postgres functions and row-level security for authorization. Replacing these prematurely would create a large security-sensitive rewrite.
2. Supabase Free's published Realtime allowance (200 peak connections and 2 million messages/month) is a reasonable starting point for a 100-user community, provided the app subscribes only to the user's own channel and sends tiny event payloads.
3. Cloudflare R2 is already integrated for media and is a strong candidate to retain. Its free tier includes 10 GB-month storage, 1 million Class A operations, 10 million Class B operations and no egress charges.
4. The best immediate cost reduction is to remove paid Hetzner dependencies and test the existing Next.js app on Cloudflare Workers, rather than replacing a working database/auth stack at the same time. Cloudflare now recommends vinext for Next.js 16+, but vinext is still beta; its own documentation says to run the compatibility check and review gaps before production. OpenNext is the documented adapter for maintaining existing applications, but Cloudflare recommends moving to vinext when compatibility allows. The project uses Next.js proxy/middleware and Node.js packages, so this must be tested in a separate preview deployment before replacing the current host.

## Migration gates

Reconsider a provider only when one of these is true:

- Measured Supabase usage repeatedly approaches a free quota.
- A free hosting target cannot run the current Next.js application reliably.
- A tested alternative demonstrates lower operational complexity or materially better performance.

Before any backend migration, require:

- A schema and data export with a verified restore test.
- Equivalent authorization tests for every private table and RPC.
- Load tests for 100 concurrent users and realistic chat/video usage.
- A staged migration with a rollback path.
- A cost guardrail that cannot silently enable paid overages.

## Official references

- Supabase pricing: https://supabase.com/pricing
- Supabase Realtime Broadcast: https://supabase.com/docs/guides/realtime/broadcast
- Appwrite pricing: https://appwrite.io/pricing
- Appwrite Free plan behavior: https://appwrite.io/docs/advanced/billing/free
- Appwrite Realtime quotas: https://appwrite.io/changelog/entry/2026-03-19
- Cloudflare Workers pricing: https://www.cloudflare.com/plans/\n- Cloudflare Next.js / vinext deployment guide: https://developers.cloudflare.com/workers/framework-guides/web-apps/nextjs/\n- Cloudflare OpenNext adapter guide: https://developers.cloudflare.com/workers/framework-guides/web-apps/opennext/
- Cloudflare D1 pricing: https://developers.cloudflare.com/d1/platform/pricing/
- Cloudflare Durable Objects pricing: https://developers.cloudflare.com/durable-objects/platform/pricing/
- Convex limits: https://docs.convex.dev/production/state/limits
- Convex pricing: https://www.convex.dev/pricing
- Cloudflare R2 pricing: https://developers.cloudflare.com/r2/pricing/

-- Exact row counts of ONE database, as `key|value` rows (run with psql -At -F'|').
-- Shared by pg-counts.sh (any database, own transaction) and backup-pg-dev.sh (inside the
-- dump's exported snapshot, so the manifest matches the dump exactly).
--   <schema>.<table>   COUNT(*) of every ordinary table outside the system schemas
--   ~relkind.<k>       user relations by kind (r table, i index, S sequence, v view, m matview, p partitioned)
-- The ~relkind rows make an EMPTY database verifiable too.
SELECT n.nspname || '.' || c.relname,
  (xpath('/row/c/text()',
     query_to_xml(format('select count(*) c from %I.%I', n.nspname, c.relname),
                  false, true, '')))[1]::text::bigint
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast');
SELECT '~relkind.' || c.relkind::text, count(*)
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'i', 'S', 'v', 'm', 'p')
  AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
GROUP BY c.relkind;

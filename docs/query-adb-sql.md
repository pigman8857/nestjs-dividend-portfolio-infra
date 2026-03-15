# Querying ADB MongoDB Data via SQL

Access: OCI Console → Autonomous Database → Database Actions → SQL (sign in as **ADMIN**)

## Basic query

```sql
SELECT json_serialize(d.data PRETTY)
FROM MONGOAPP.<TABLE_NAME> d;
```

## All collections

```sql
SELECT json_serialize(d.data PRETTY) FROM MONGOAPP.TRADES d;
SELECT json_serialize(d.data PRETTY) FROM MONGOAPP.ASSETS d;
SELECT json_serialize(d.data PRETTY) FROM MONGOAPP.PORTFOLIOS d;
SELECT json_serialize(d.data PRETTY) FROM MONGOAPP.DIVIDENDS d;
SELECT json_serialize(d.data PRETTY) FROM MONGOAPP.USERS d;
SELECT json_serialize(d.data PRETTY) FROM MONGOAPP.ALERTS d;
SELECT json_serialize(d.data PRETTY) FROM MONGOAPP.PRICE_TICKS d;
```

## Filter by field

```sql
SELECT json_serialize(d.data PRETTY)
FROM MONGOAPP.TRADES d
WHERE json_value(d.data, '$.type') = 'buy';
```

## Tips

- Always prefix with `MONGOAPP.` — the SQL session runs as ADMIN, not MONGOAPP
- No quotes around table names (they are uppercase)
- Omit `PRETTY` for compact single-line JSON output
- Each row has system columns (`ID`, `CREATED_ON`, `LAST_MODIFIED`, `VERSION`) plus `DATA` which holds the actual MongoDB document

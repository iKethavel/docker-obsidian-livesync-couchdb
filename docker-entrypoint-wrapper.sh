#!/bin/bash
set -e

# Run the original deno setup for couchdb config
echo "Running initial CouchDB configuration setup..."
deno -A /scripts/couchdb-setup.ts

if [ -n "$HEADLESS_SYNC_DBS" ]; then
  # Default interval to 30 seconds if not provided
  SYNC_INTERVAL="${SYNC_INTERVAL:-30}"
  SERVER_URL="${SERVER_URL:-http://127.0.0.1:5984}"

  if [[ "$HEADLESS_SYNC_DBS" == *","* ]]; then
    # Multiple databases -> use subdirectories
    IFS=',' read -ra DB_ARRAY <<< "$HEADLESS_SYNC_DBS"
    USE_SUBDIRS=true
  else
    # Single database specified -> use root directory
    DB_ARRAY=("$HEADLESS_SYNC_DBS")
    USE_SUBDIRS=false
  fi

  # Start the sync coordinator in the background
  (
    echo "Waiting for CouchDB to accept connections..."
    until curl -s "${SERVER_URL}/" > /dev/null; do
      sleep 2
    done
    echo "CouchDB is up."

    for DB in "${DB_ARRAY[@]}"; do
      # Trim whitespace
      DB=$(echo "$DB" | xargs)
      [ -z "$DB" ] && continue

      if [ "$USE_SUBDIRS" = true ]; then
        VAULT_PATH="/opt/headless/data/$DB"
      else
        VAULT_PATH="/opt/headless/data"
      fi

      echo "Configuring headless sync loop for database '$DB' mapping to '$VAULT_PATH'..."
      mkdir -p "$VAULT_PATH/.livesync/db"
      
      # Precompute the encrypt boolean (must be before the heredoc)
      if [ -n "$SYNC_PASSPHRASE" ]; then ENCRYPT_VAL="true"; else ENCRYPT_VAL="false"; fi

      # Always write settings.json fresh from current env vars
      echo "Writing settings.json for '$DB'..."
      cat <<EOF > "$VAULT_PATH/.livesync/settings.json"
{
    "couchDB_URI": "${SERVER_URL}",
    "couchDB_USER": "${COUCHDB_USER}",
    "couchDB_PASSWORD": "${COUCHDB_PASSWORD}",
    "couchDB_DBNAME": "${DB}",
    "encrypt": ${ENCRYPT_VAL},
    "passphrase": "${SYNC_PASSPHRASE}",
    "usePathObfuscation": false,
    "usePluginSync": false,
    "isConfigured": true
}
EOF

      # Start infinite sync loop for this database
      (
        cd /opt/obsidian-livesync/src/apps/cli
        while true; do
          # Step 1: pull from remote CouchDB into local PouchDB cache
          node dist/index.cjs "$VAULT_PATH" --settings "$VAULT_PATH/.livesync/settings.json" sync || echo "Sync for '$DB' encountered an error, will retry..."
          # Step 2: write local PouchDB cache to filesystem as actual files
          node dist/index.cjs "$VAULT_PATH" --settings "$VAULT_PATH/.livesync/settings.json" mirror || echo "Mirror for '$DB' encountered an error, will retry..."
          sleep "$SYNC_INTERVAL"
        done
      ) &
    done
  ) &
fi

# Finally, execute the original couchdb entrypoint
echo "Starting CouchDB..."
exec tini -- /docker-entrypoint.sh /opt/couchdb/bin/couchdb

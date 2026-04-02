#!/bin/bash
set -e

# Run the original deno setup for couchdb config
echo "Running initial CouchDB configuration setup..."
deno -A /scripts/couchdb-setup.ts

if [ -n "$HEADLESS_SYNC_DBS" ]; then
  # Default interval to 30 seconds if not provided
  SYNC_INTERVAL="${SYNC_INTERVAL:-30}"
  SERVER_URL="${SERVER_URL:-http://127.0.0.1:5984}"

  # Always use subdirectories named after the database
  IFS=',' read -ra DB_ARRAY <<< "$HEADLESS_SYNC_DBS"
  
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

      VAULT_PATH="/opt/headless/data/$DB"

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

      # Git initialization if GIT_REMOTE_URL is provided
      if [ -n "$GIT_REMOTE_URL" ]; then
        echo "Initializing Git for vault at '$VAULT_PATH'..."
        GIT_BRANCH="${GIT_BRANCH:-main}"
        GIT_USER_NAME="${GIT_USER_NAME:-Obsidian LiveSync Bot}"
        GIT_USER_EMAIL="${GIT_USER_EMAIL:-obsidian-livesync@bot.local}"

        # Ensure directory is safe for Git (handles permission issues in Docker volumes)
        git config --global --add safe.directory "$VAULT_PATH"

        cd "$VAULT_PATH"
        if [ ! -d ".git" ]; then
          git init
          git remote add origin "$GIT_REMOTE_URL"
          # Ensure .livesync is ignored
          if ! grep -q ".livesync" .gitignore 2>/dev/null; then
            echo ".livesync/" >> .gitignore
          fi
          # Fetch and align with remote if it exists
          git fetch origin "$GIT_BRANCH" 2>/dev/null || true
          if git ls-remote --exit-code origin "$GIT_BRANCH" >/dev/null 2>&1; then
            git checkout "$GIT_BRANCH" || git checkout -b "$GIT_BRANCH"
            git reset --mixed "origin/$GIT_BRANCH"
          else
            git checkout -b "$GIT_BRANCH"
          fi
        fi
        git config user.name "$GIT_USER_NAME"
        git config user.email "$GIT_USER_EMAIL"
      fi

      # Start infinite sync loop for this database
      (
        while true; do
          # Step 1: pull from remote CouchDB into local PouchDB cache
          cd /opt/obsidian-livesync/src/apps/cli
          node dist/index.cjs "$VAULT_PATH" --settings "$VAULT_PATH/.livesync/settings.json" sync || echo "Sync for '$DB' encountered an error, will retry..."
          
          # Step 2: write local PouchDB cache to filesystem as actual files
          node dist/index.cjs "$VAULT_PATH" --settings "$VAULT_PATH/.livesync/settings.json" mirror || echo "Mirror for '$DB' encountered an error, will retry..."
          
          # Step 3: Git sync if GIT_REMOTE_URL is provided
          if [ -n "$GIT_REMOTE_URL" ]; then
            cd "$VAULT_PATH"
            git add .
            if ! git diff --staged --quiet; then
              echo "[Git] Changes detected for '$DB', committing..."
              git commit -m "Obsidian LiveSync Mirror Update: $(date)"
              echo "[Git] Pushing changes for '$DB' to origin/$GIT_BRANCH..."
              git push origin "$GIT_BRANCH" || echo "[Git] Push failed for '$DB', will retry next cycle..."
            fi
          fi

          sleep "$SYNC_INTERVAL"
        done
      ) &
    done
  ) &
fi

# Finally, execute the original couchdb entrypoint
echo "Starting CouchDB..."
exec tini -- /docker-entrypoint.sh /opt/couchdb/bin/couchdb

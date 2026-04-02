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

    # Git initialization once for the entire volume if GIT_REMOTE_URL is provided
    VOLUME_ROOT="/opt/headless/data"
    if [ -n "$GIT_REMOTE_URL" ]; then
      echo "Initializing volume-wide Git at '$VOLUME_ROOT'..."
      GIT_BRANCH="${GIT_BRANCH:-main}"
      GIT_USER_NAME="${GIT_USER_NAME:-Obsidian LiveSync Bot}"
      GIT_USER_EMAIL="${GIT_USER_EMAIL:-obsidian-livesync@bot.local}"

      # Ensure volume root is safe for Git
      git config --global --add safe.directory "$VOLUME_ROOT"

      cd "$VOLUME_ROOT"
      if [ ! -d ".git" ]; then
        echo "[Git] Initializing new repository at volume root..."
        git init
        git remote add origin "$GIT_REMOTE_URL"
        
        echo "[Git] Fetching remote branch '$GIT_BRANCH'..."
        if git fetch origin "$GIT_BRANCH" 2>/dev/null; then
          echo "[Git] Remote branch found, aligning local state..."
          git checkout -B "$GIT_BRANCH" "origin/$GIT_BRANCH"
          git reset --mixed "origin/$GIT_BRANCH"
        else
          echo "[Git] Remote branch not found or empty, starting fresh..."
          git checkout -b "$GIT_BRANCH"
        fi
      fi
      
      # Ensure internal metadata is ignored across all vaults
      if ! grep -q "\.livesync/" .gitignore 2>/dev/null; then
        echo "**/.livesync/" >> .gitignore
        git add .gitignore
        git commit -m "chore: ignore livesync internals globally" || true
      fi

      git config user.name "$GIT_USER_NAME"
      git config user.email "$GIT_USER_EMAIL"
      echo "[Git] Volume-wide configuration complete."
    fi

    for DB in "${DB_ARRAY[@]}"; do
      # Trim whitespace
      DB=$(echo "$DB" | xargs)
      [ -z "$DB" ] && continue

      VAULT_PATH="$VOLUME_ROOT/$DB"

      echo "Configuring headless sync loop for database '$DB' mapping to '$VAULT_PATH'..."
      mkdir -p "$VAULT_PATH/.livesync/db"
      
      # Precompute the encrypt boolean
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
        while true; do
          # Step 1: pull from remote CouchDB into local PouchDB cache
          cd /opt/obsidian-livesync/src/apps/cli
          node dist/index.cjs "$VAULT_PATH" --settings "$VAULT_PATH/.livesync/settings.json" sync || echo "Sync for '$DB' encountered an error, will retry..."
          
          # Step 2: write local PouchDB cache to filesystem as actual files
          node dist/index.cjs "$VAULT_PATH" --settings "$VAULT_PATH/.livesync/settings.json" mirror || echo "Mirror for '$DB' encountered an error, will retry..."
          
          sleep "$SYNC_INTERVAL"
        done
      ) &
    done

    # Start a single Git synchronization loop for the entire volume
    if [ -n "$GIT_REMOTE_URL" ]; then
      echo "Starting volume-wide Git synchronization loop (Source of Truth: CouchDB)..."
      (
        while true; do
          cd "$VOLUME_ROOT"
          
          # 1. Fetch latest changes from remote
          git fetch origin "$GIT_BRANCH" > /dev/null 2>&1 || echo "[Git] Fetch failed, will retry..."

          # 2. Add any MIRROR changes from CouchDB to the index
          git add .
          
          # 3. Commit local mirror changes
          if ! git diff --staged --quiet; then
            echo "[Git] Mirror changes detected, committing..."
            git commit -m "Obsidian LiveSync Mirror Update: $(date)" || echo "[Git] Commit failed"
          fi

          # 4. Integrate remote changes (like Quartz config), but prioritize local (CouchDB) notes in case of conflict
          if ! git merge -X ours "origin/$GIT_BRANCH" -m "chore: sync with remote changes" > /dev/null 2>&1; then
             echo "[Git] Auto-merge encountered conflicts; resolved using local (CouchDB) versions."
          fi

          # 5. Push final state to remote
          if ! git diff origin/"$GIT_BRANCH" --quiet; then
             echo "[Git] Pushing volume updates to origin/$GIT_BRANCH..."
             if git push origin "$GIT_BRANCH" 2>&1; then
                echo "[Git] Push successful."
             else
                echo "[Git] Push failed; will retry in next cycle."
             fi
          fi

          sleep "$SYNC_INTERVAL"
        done
      ) &
    fi
  ) &
fi

# Finally, execute the original couchdb entrypoint
echo "Starting CouchDB..."
exec tini -- /docker-entrypoint.sh /opt/couchdb/bin/couchdb

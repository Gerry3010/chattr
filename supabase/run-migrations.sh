#!/bin/bash
set -e

MIGRATIONS_DIR="/migrations"
TRACKING_FILE="/migrations/.migration_history"

# Create tracking file if it doesn't exist
if [ ! -f "$TRACKING_FILE" ]; then
  echo "# Migration History" > "$TRACKING_FILE"
  echo "# Format: YYYY-MM-DD HH:MM:SS | migration_file.sql" >> "$TRACKING_FILE"
fi

# Function to check if migration was already run
migration_already_run() {
  local migration_file="$1"
  grep -q "| $migration_file$" "$TRACKING_FILE"
}

# Function to mark migration as completed
mark_migration_completed() {
  local migration_file="$1"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "$timestamp | $migration_file" >> "$TRACKING_FILE"
}

echo "===================================="
echo "Running Database Migrations"
echo "===================================="

# Count total and new migrations
total_migrations=0
new_migrations=0
skipped_migrations=0

# Process each SQL file in order
for migration_file in $(ls -1 "$MIGRATIONS_DIR"/*.sql 2>/dev/null | sort); do
  filename=$(basename "$migration_file")
  total_migrations=$((total_migrations + 1))
  
  if migration_already_run "$filename"; then
    echo "⏭  Skipping $filename (already applied)"
    skipped_migrations=$((skipped_migrations + 1))
  else
    echo "🔄 Running $filename..."
    
    # Run the migration
    if psql "$DATABASE_URL" -f "$migration_file"; then
      mark_migration_completed "$filename"
      echo "✅ Completed $filename"
      new_migrations=$((new_migrations + 1))
    else
      echo "❌ Failed to run $filename"
      exit 1
    fi
  fi
done

echo "===================================="
echo "Migration Summary:"
echo "  Total migrations: $total_migrations"
echo "  New migrations applied: $new_migrations"
echo "  Skipped (already applied): $skipped_migrations"
echo "===================================="

if [ $new_migrations -eq 0 ]; then
  echo "✅ Database is up to date!"
else
  # PostgREST caches the DB schema: without a reload it silently DROPS
  # unknown columns from request bodies and 404s new RPCs — new migrations
  # would appear applied but the API would keep serving the old schema.
  echo "🔄 Reloading PostgREST schema cache..."
  psql "$DATABASE_URL" -c "NOTIFY pgrst, 'reload schema';" || \
    echo "⚠️  PostgREST reload notify failed — restart the rest container manually"
  echo "✅ Successfully applied $new_migrations new migration(s)!"
fi

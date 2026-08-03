#!/bin/bash

# Chattr Development Tunnel Script
# Starts ngrok tunnels for Supabase and Flutter Web

set -e

ENV_FILE=".env"
ENV_BACKUP=".env.backup"

echo "🚀 Starting Chattr development tunnels..."
echo ""

# Backup current .env file
if [ -f "$ENV_FILE" ]; then
    echo "💾 Backing up $ENV_FILE to $ENV_BACKUP..."
    cp "$ENV_FILE" "$ENV_BACKUP"
    echo "✅ Backup created"
else
    echo "⚠️  No $ENV_FILE found, will create new one"
fi
echo ""

# Kill any existing ngrok processes
pkill -f ngrok || true
sleep 2

# Start ngrok for Supabase (port 54321) with fixed URL in background
echo "📡 Starting ngrok tunnel for Supabase (port 54321)..."
ngrok http --url=supa.gh-chattr-test.ngrok.app 54321 --log=stdout > /tmp/ngrok-supabase.log 2>&1 &
NGROK_SUPABASE_PID=$!

# Wait a moment for ngrok to start
sleep 3

# Use fixed Supabase ngrok URL
SUPABASE_URL="https://supa.gh-chattr-test.ngrok.app"
echo "✅ Supabase tunnel: $SUPABASE_URL"
echo ""

# Update .env file with ngrok URL
echo "🔧 Updating $ENV_FILE with ngrok URL..."
ANON_KEY=$(grep SUPABASE_ANON_KEY "$ENV_BACKUP" 2>/dev/null | cut -d '=' -f 2 || echo "sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH")
cat > "$ENV_FILE" << EOF
# Supabase Configuration (NGROK TUNNEL MODE)
# Original .env backed up to $ENV_BACKUP
# This file will be automatically restored when stopping the tunnel

# Supabase URL (Desktop/iOS) - ngrok tunnel
SUPABASE_URL=$SUPABASE_URL

# Supabase URL (Android Emulator) - ngrok tunnel
SUPABASE_ANDROID_URL=$SUPABASE_URL

# Supabase Anonymous Key
SUPABASE_ANON_KEY=$ANON_KEY
EOF
echo "✅ $ENV_FILE updated with ngrok URL"
echo ""

# Build Flutter web
echo "🌐 Building Flutter web app..."
flutter build web --release > /tmp/flutter-build.log 2>&1
if [ $? -ne 0 ]; then
    echo "❌ Flutter build failed! Check /tmp/flutter-build.log"
    tail -20 /tmp/flutter-build.log
    cleanup
fi
echo "✅ Flutter web built successfully"

# Start Python HTTP server to serve Flutter web
echo "🐍 Starting HTTP server on port 8080..."
WEB_DIR="$(pwd)/build/web"
cd "$WEB_DIR"
python3 -m http.server 8080 > /tmp/flutter-web.log 2>&1 &
FLUTTER_PID=$!
cd - > /dev/null

# Wait for server to start
echo "⏳ Waiting for HTTP server to start..."
sleep 3
echo "✅ HTTP server started (PID: $FLUTTER_PID)"

# Start ngrok for Flutter Web (port 8080) with fixed URL in background
echo "📡 Starting ngrok tunnel for Flutter Web (port 8080)..."
ngrok http --url=gh-chattr-test.ngrok.app 8080 --log=stdout > /tmp/ngrok-flutter.log 2>&1 &
NGROK_FLUTTER_PID=$!

# Wait a moment for second ngrok to start
sleep 3

# Use fixed Flutter Web ngrok URL
FLUTTER_URL="https://gh-chattr-test.ngrok.app"
echo "✅ Flutter Web tunnel: $FLUTTER_URL"
echo ""

echo "════════════════════════════════════════════════════"
echo "🎉 All tunnels are running!"
echo "════════════════════════════════════════════════════"
echo ""
echo "📱 Supabase API:    $SUPABASE_URL"
echo "🌐 Flutter Web App: $FLUTTER_URL"
echo ""
echo "Your .env file has been updated with the ngrok Supabase URL."
echo "You can now:"
echo "  - Open $FLUTTER_URL in your phone's browser"
echo "  - Or build and install the app to test natively"
echo ""
echo "Press Ctrl+C to stop all tunnels and restore original .env"
echo "════════════════════════════════════════════════════"
echo ""

# Function to cleanup on exit
cleanup() {
    echo ""
    echo "🛑 Stopping all tunnels..."
    kill $NGROK_SUPABASE_PID 2>/dev/null || true
    kill $NGROK_FLUTTER_PID 2>/dev/null || true
    kill $FLUTTER_PID 2>/dev/null || true
    pkill -f ngrok || true
    
    # Restore original .env file
    if [ -f "$ENV_BACKUP" ]; then
        echo "🔄 Restoring original $ENV_FILE..."
        mv "$ENV_BACKUP" "$ENV_FILE"
        echo "✅ $ENV_FILE restored"
    fi
    
    echo "✅ Cleanup complete"
    exit 0
}

# Trap Ctrl+C and cleanup
trap cleanup INT TERM

# Keep script running
while true; do
    sleep 1
done

#!/bin/bash

set -e

echo "🚀 Setting up Chattr..."

# Flutter check
if ! command -v flutter &> /dev/null; then
  echo "❌ Flutter not found"
  exit 1
fi

flutter doctor

# Supabase
if ! command -v supabase &> /dev/null; then
  echo "❌ Supabase CLI not installed"
  exit 1
fi

# Project deps
flutter pub get

# Supabase local
supabase start

echo "✅ Setup complete!"
echo "Supabase Dashboard: http://localhost:54323"

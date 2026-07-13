#!/bin/bash
set -euo pipefail

# Deploy a Supabase edge function.
# Usage:
#   ./deploy-edge.sh                       # defaults to create-checkout-session
#   ./deploy-edge.sh stripe-webhook        # any function name in supabase/functions/
#
# One-time setup:
#   brew install supabase/tap/supabase
#   supabase login
#   supabase link --project-ref <your-project-ref>
#
# Project ref is in the Supabase dashboard URL after "/project/".

FN="${1:-create-checkout-session}"

if ! command -v supabase >/dev/null 2>&1; then
  echo "supabase CLI not found."
  echo
  echo "Install:"
  echo "  brew install supabase/tap/supabase"
  echo
  echo "Then one-time setup:"
  echo "  supabase login"
  echo "  supabase link --project-ref <your-project-ref>"
  exit 1
fi

cd "$(dirname "$0")"

if [ ! -d "supabase/functions/$FN" ]; then
  echo "No function directory found: supabase/functions/$FN"
  echo
  echo "Available functions:"
  ls supabase/functions/ 2>/dev/null || echo "  (none)"
  exit 1
fi

echo "Deploying edge function: $FN"
supabase functions deploy "$FN"
echo "Done. Function $FN is live."

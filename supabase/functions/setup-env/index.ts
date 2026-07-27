// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

/**
 * Setup Environment Variables
 * 
 * This function loads environment variables into the Supabase Vault
 * so they can be accessed by database functions via vault.get_secret()
 * 
 * Should be called on startup/deployment
 */

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

interface VaultSecret {
  name: string;
  value: string;
}

// Exported so the auth gate is unit-testable without binding a port; the
// server is only started when this module is run as the entry point.
export async function handler(req: Request): Promise<Response> {
  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

  // Authorization: this function writes secrets (incl. the service-role key) into
  // the Vault and must only be invoked by an operator holding the service-role key.
  // Reject any other caller (anon/user JWT) to prevent secret/config tampering.
  const authHeader = req.headers.get("Authorization") ?? "";
  const token = authHeader.replace(/^Bearer\s+/i, "");
  if (!serviceRoleKey || token !== serviceRoleKey) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 401,
    });
  }

  try {
    const supabaseClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      serviceRoleKey,
      {
        auth: {
          autoRefreshToken: false,
          persistSession: false,
        },
      }
    );

    // Define environment variables to be stored in Vault
    const secrets: VaultSecret[] = [
      {
        name: "edge_function_url",
        value: Deno.env.get("SUPABASE_URL")?.replace("/rest/v1", "") ?? "",
      },
      {
        name: "service_role_key",
        value: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
      },
    ];

    const results = [];

    // Store each secret in Vault
    for (const secret of secrets) {
      try {
        // Insert or update secret in vault.secrets
        const { data, error } = await supabaseClient.rpc("vault.create_secret", {
          secret: secret.value,
          name: secret.name,
        });

        if (error) {
          console.error(`Failed to store secret ${secret.name}:`, error);
          results.push({
            name: secret.name,
            success: false,
            error: error.message,
          });
        } else {
          console.log(`Successfully stored secret: ${secret.name}`);
          results.push({
            name: secret.name,
            success: true,
          });
        }
      } catch (error) {
        console.error(`Exception storing secret ${secret.name}:`, error);
        results.push({
          name: secret.name,
          success: false,
          error: error.message,
        });
      }
    }

    // Set PostgreSQL runtime setting for edge_function_url (non-sensitive)
    // Service role key should only be accessed via vault.decrypted_secrets
    try {
      await supabaseClient.rpc("set_config", {
        setting_name: "app.settings.edge_function_url",
        new_value: secrets[0].value,
        is_local: false,
      });

      console.log("Successfully set PostgreSQL runtime setting for edge_function_url");
    } catch (error) {
      console.warn("Could not set PostgreSQL setting (may not be supported):", error);
    }

    const allSuccess = results.every((r) => r.success);

    return new Response(
      JSON.stringify({
        success: allSuccess,
        message: allSuccess
          ? "All environment variables loaded successfully"
          : "Some environment variables failed to load",
        results,
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: allSuccess ? 200 : 207, // 207 Multi-Status for partial success
      }
    );
  } catch (error) {
    console.error("Error in setup-env:", error);
    return new Response(
      JSON.stringify({
        success: false,
        error: error.message,
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 500,
      }
    );
  }
}

if (import.meta.main) serve(handler);

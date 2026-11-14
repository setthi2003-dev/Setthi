import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@^2.45.4";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const MAX_MESSAGES_PER_BATCH = 25;
const MAX_BODY_CHARS_PER_EMAIL = 4000;

interface EmailMessageInput {
  id: string;
  subject?: string;
  from?: string;
  date?: string;
  body?: string;
}

interface ClassifyRequestPayload {
  messages?: EmailMessageInput[];
  timezone?: string;
  include_decisions?: boolean;
  user_id?: string;
}

function stripHtmlAndTrim(raw: string, maxLen = MAX_BODY_CHARS_PER_EMAIL): string {
  if (!raw) return "";
  // Strip style and script tags and contents
  let text = raw.replace(/<style[^>]*>[\s\S]*?<\/style>/gi, " ");
  text = text.replace(/<script[^>]*>[\s\S]*?<\/script>/gi, " ");
  // Strip all remaining HTML tags
  text = text.replace(/<[^>]+>/g, " ");
  // Decode common HTML entities
  text = text
    .replace(/&nbsp;/gi, " ")
    .replace(/&amp;/gi, "&")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">")
    .replace(/&#39;/gi, "'")
    .replace(/&quot;/gi, '"');
  // Normalize whitespace
  text = text.replace(/\s+/g, " ").trim();
  if (text.length > maxLen) {
    text = text.slice(0, maxLen);
  }
  return text;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return new Response(
      JSON.stringify({ error: "Method not allowed", message: "Only POST is supported" }),
      { status: 405, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabaseAdmin = createClient(supabaseUrl, serviceRoleKey);

    // 1. Verify User Authentication via Bearer token
    const authHeader = req.headers.get("Authorization") ?? "";
    const token = authHeader.replace(/^Bearer\s+/i, "").trim();

    if (!token) {
      return new Response(
        JSON.stringify({ error: "Unauthorized", message: "Missing Bearer token in Authorization header" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // 2. Parse and Validate Request Body
    let payload: ClassifyRequestPayload;
    try {
      payload = await req.json();
    } catch (_) {
      return new Response(
        JSON.stringify({ error: "Bad Request", message: "Invalid JSON request body" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    let userId: string;
    // Check if the caller is using the service_role key directly (e.g. background job/script)
    if (token === serviceRoleKey) {
      userId = (payload.user_id && String(payload.user_id).trim()) || "system_service_role";
    } else {
      const {
        data: { user },
        error: userError,
      } = await supabaseAdmin.auth.getUser(token);

      if (userError || !user) {
        return new Response(
          JSON.stringify({ error: "Unauthorized", message: userError?.message ?? "Invalid user session" }),
          { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      userId = user.id;
    }

    const rawMessages = payload.messages;
    if (!Array.isArray(rawMessages) || rawMessages.length === 0) {
      return new Response(
        JSON.stringify({ error: "Bad Request", message: "'messages' array is required and must not be empty" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (rawMessages.length > MAX_MESSAGES_PER_BATCH) {
      return new Response(
        JSON.stringify({
          error: "Bad Request",
          message: `Batch size exceeds limit: ${rawMessages.length} messages received, max allowed is ${MAX_MESSAGES_PER_BATCH}`,
        }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const timezone = (payload.timezone && payload.timezone.trim()) || "Asia/Kolkata";

    // 3. Sanitize and Format Messages for Modal
    const sanitizedMessages = rawMessages.map((msg, idx) => {
      const msgId = (msg.id && String(msg.id).trim()) || `msg_${Date.now()}_${idx}`;
      const subject = (msg.subject && String(msg.subject).trim()) || "";
      const from = (msg.from && String(msg.from).trim()) || "";
      const date = (msg.date && String(msg.date).trim()) || new Date().toISOString();
      const bodyText = stripHtmlAndTrim(msg.body || "");

      return {
        id: msgId,
        subject,
        from,
        date,
        body: bodyText,
      };
    });

    // 4. Resolve Modal Credentials
    let modalUrl =
      Deno.env.get("MODAL_CLASSIFIER_URL") ||
      Deno.env.get("SETTHI_URL") ||
      "";

    // Migrate from the deprecated setthi-finance-classifier app to the active v6.6 app
    if (!modalUrl || modalUrl.includes("setthi-finance-classifier")) {
      modalUrl = "https://setthi2003--setthi-email-mvp-v6-6-http-api.us-east.modal.run/classify";
    }

    if (modalUrl.endsWith("/v1/classify")) {
      modalUrl = modalUrl.replace(/\/v1\/classify$/, "/classify");
    } else if (!modalUrl.endsWith("/classify")) {
      modalUrl = modalUrl.replace(/\/+$/, "") + "/classify";
    }

    const modalKey = Deno.env.get("MODAL_KEY");
    const modalSecret = Deno.env.get("MODAL_SECRET");

    if (!modalKey || !modalSecret) {
      console.error("[classify-emails] Missing MODAL_KEY or MODAL_SECRET in Supabase Secrets");
      return new Response(
        JSON.stringify({
          error: "Server Configuration Error",
          message: "Modal credentials are not configured on the backend.",
        }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    console.log(
      `[classify-emails] Calling Modal API at ${modalUrl} with ${sanitizedMessages.length} messages (user: ${userId})...`
    );

    // 5. Call Modal ML Classifier with Timeout Safeguard (120s for GPU spinup)
    const abortController = new AbortController();
    const timeoutHandle = setTimeout(() => abortController.abort(), 120000);

    let modalResp: Response;
    try {
      modalResp = await fetch(modalUrl, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Modal-Key": modalKey,
          "Modal-Secret": modalSecret,
        },
        body: JSON.stringify({
          timezone,
          include_decisions: Boolean(payload.include_decisions),
          messages: sanitizedMessages,
        }),
        signal: abortController.signal,
      });
    } catch (fetchErr: any) {
      clearTimeout(timeoutHandle);
      const isAbort = fetchErr?.name === "AbortError";
      console.error("[classify-emails] Modal API fetch failed:", fetchErr);
      return new Response(
        JSON.stringify({
          error: "Modal Connection Error",
          message: isAbort ? "Modal classification timed out (120s)" : String(fetchErr?.message || fetchErr),
        }),
        { status: 504, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    } finally {
      clearTimeout(timeoutHandle);
    }

    if (!modalResp.ok && modalResp.status !== 207) {
      const errText = await modalResp.text();
      console.error(`[classify-emails] Modal returned HTTP ${modalResp.status}: ${errText}`);
      return new Response(
        JSON.stringify({
          error: "Classification Service Error",
          status: modalResp.status,
          details: errText,
        }),
        { status: 502, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const modalData = await modalResp.json();
    const alerts: any[] = Array.isArray(modalData.alerts) ? modalData.alerts : [];
    const summary = modalData.summary || {};
    const errors = modalData.errors || [];

    console.log(
      `[classify-emails] Modal returned ${alerts.length} alerts for user ${userId}. Saving to Supabase reminders table...`
    );

    // 6. Direct Backend Deduplication & Persistence: Upsert Alerts into public.reminders
    let savedCount = 0;
    if (alerts.length > 0 && userId !== "system_service_role") {
      const nowUtc = new Date().toISOString();
      const sanitizedMap = new Map<string, any>();
      for (const m of sanitizedMessages) {
        sanitizedMap.set(m.id, m);
      }

      for (const alert of alerts) {
        const sourceIds: string[] = Array.isArray(alert.source_message_ids) && alert.source_message_ids.length > 0
          ? alert.source_message_ids
          : [alert.message_id || ""].filter(Boolean);

        // Find associated sanitized messages to extract email details & dates
        const matchedMsgs = sourceIds.map((id) => sanitizedMap.get(id)).filter(Boolean);
        const primaryMsg = matchedMsgs[0] || sanitizedMap.get(alert.message_id) || sanitizedMessages[0];

        let parsedAmount: number | null = null;
        if (alert.amount_numeric !== undefined && alert.amount_numeric !== null) {
          const n = Number(alert.amount_numeric);
          if (!isNaN(n)) parsedAmount = n;
        } else if (alert.amount !== undefined && alert.amount !== null) {
          const n = Number(alert.amount);
          if (!isNaN(n)) {
            parsedAmount = n;
          } else if (typeof alert.amount === "string") {
            const cleaned = alert.amount.replace(/[^0-9.]/g, "");
            const parsed = parseFloat(cleaned);
            if (!isNaN(parsed)) parsedAmount = parsed;
          }
        }

        // Extract sub-service identity for aggregator / platform providers
        const rawProvider = (alert.provider || "Unknown Provider").trim();
        let serviceIdentity = rawProvider.toLowerCase();
        let displayProvider = rawProvider;

        const isAggregator = [
          "google.com", "play.google.com", "apple.com", "razorpay.com", 
          "paytm.com", "stripe.com", "billdesk.com", "cashfree.com"
        ].some((p) => rawProvider.toLowerCase().includes(p));

        const textToScan = `${primaryMsg?.subject || ""} ${primaryMsg?.body?.slice(0, 300) || ""}`.toLowerCase();
        
        const knownServices = [
          { key: "chatgpt", name: "ChatGPT" },
          { key: "youtube", name: "YouTube" },
          { key: "netflix", name: "Netflix" },
          { key: "spotify", name: "Spotify" },
          { key: "google one", name: "Google One" },
          { key: "icloud", name: "iCloud" },
          { key: "disney", name: "Disney+ Hotstar" },
          { key: "hotstar", name: "Hotstar" },
          { key: "prime", name: "Amazon Prime" },
          { key: "linkedin", name: "LinkedIn" },
          { key: "canva", name: "Canva" },
          { key: "github", name: "GitHub" },
          { key: "claude", name: "Claude" },
          { key: "duolingo", name: "Duolingo" },
        ];

        let detectedSubService: string | null = null;
        for (const s of knownServices) {
          if (textToScan.includes(s.key)) {
            detectedSubService = s.name;
            serviceIdentity = `${rawProvider.toLowerCase()}:${s.key.replace(/\s+/g, "_")}`;
            break;
          }
        }

        if (detectedSubService && isAggregator) {
          displayProvider = `${detectedSubService} (${rawProvider})`;
        }

        // Determine billing period (YYYY-MM)
        const emailDate = primaryMsg?.date || nowUtc;
        const dueDate = alert.date || null;
        let billingPeriod: string | null = null;
        if (dueDate && /^\d{4}-\d{2}/.test(dueDate)) {
          billingPeriod = dueDate.substring(0, 7);
        } else if (emailDate && /^\d{4}-\d{2}/.test(emailDate)) {
          billingPeriod = emailDate.substring(0, 7);
        }

        // Source email objects
        const sourceEmails = matchedMsgs.map((m) => ({
          message_id: m.id,
          subject: m.subject || "",
          from: m.from || "",
          date: m.date || nowUtc,
          amount: parsedAmount,
          currency: alert.currency || "INR",
        }));

        if (sourceEmails.length === 0 && primaryMsg) {
          sourceEmails.push({
            message_id: primaryMsg.id,
            subject: primaryMsg.subject || "",
            from: primaryMsg.from || "",
            date: primaryMsg.date || nowUtc,
            amount: parsedAmount,
            currency: alert.currency || "INR",
          });
        }

        const reminderPayload = {
          user_id: userId,
          reminder_id: alert.reminder_id,
          type: alert.type,
          provider: displayProvider,
          due_date: dueDate,
          timing: alert.timing || "unknown",
          amount: parsedAmount,
          currency: alert.currency || "INR",
          amount_source: alert.amount_source || "gliner2.5",
          amount_evidence: alert.amount_evidence || null,
          review: Boolean(alert.review),
          reminder_eligible: Boolean(alert.reminder_eligible),
          source_message_ids: sourceIds,
          metadata: {
            service_identity: serviceIdentity,
            billing_period: billingPeriod,
            email_timestamp: emailDate,
            source_emails: sourceEmails,
            amount_extraction_status: alert.amount_extraction_status,
            attachment_present: alert.attachment_present,
            ownership_unverified: alert.ownership_unverified,
          },
        };

        const { data: rpcData, error: rpcError } = await supabaseAdmin.rpc(
          "upsert_deduplicated_reminder",
          { p_reminder: reminderPayload }
        );

        if (rpcError) {
          console.error(`[classify-emails] Error calling upsert_deduplicated_reminder:`, rpcError);
        } else {
          savedCount++;
          console.log(
            `[classify-emails] Deduplicated reminder ${alert.reminder_id} -> ${rpcData?.action} (id: ${rpcData?.id}, count: ${rpcData?.source_message_count})`
          );
        }
      }
      console.log(`[classify-emails] Successfully persisted/deduplicated ${savedCount} reminders in public.reminders`);
    }

    // 7. Return Final Success Response
    return new Response(
      JSON.stringify({
        success: true,
        saved_count: savedCount,
        summary,
        alerts,
        errors,
      }),
      {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  } catch (err: any) {
    console.error("[classify-emails] Unexpected error in Edge Function:", err);
    return new Response(
      JSON.stringify({ error: "Internal Server Error", message: String(err?.message || err) }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});

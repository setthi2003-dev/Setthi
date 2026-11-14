import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@^2.45.4";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const DEFAULT_MODAL_STATEMENT_URL =
  "https://setthi2003--financial-statement-intelligence-create-asgi.us-east.modal.run";

interface StatementRequestPayload {
  action?: "submit" | "poll";
  storage_path?: string;
  filename?: string;
  password?: string;
  job_id?: string;
  message_id?: string; // Optional Gmail message id if triggered from Gmail sync
  user_id?: string;
  wait_for_completion?: boolean; // Default true: polls Modal for up to 60s
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

    const modalKey = Deno.env.get("MODAL_KEY");
    const modalSecret = Deno.env.get("MODAL_SECRET");
    const modalBaseUrl =
      Deno.env.get("STATEMENT_API_URL") || DEFAULT_MODAL_STATEMENT_URL;

    if (!modalKey || !modalSecret) {
      console.error("[process-statement] Missing MODAL_KEY or MODAL_SECRET in environment");
      return new Response(
        JSON.stringify({
          error: "Server Configuration Error",
          message: "Modal authentication credentials are not configured.",
        }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // 1. Verify User Authentication
    const authHeader = req.headers.get("Authorization") ?? "";
    const token = authHeader.replace(/^Bearer\s+/i, "").trim();

    if (!token) {
      return new Response(
        JSON.stringify({ error: "Unauthorized", message: "Missing Bearer token" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    let payload: StatementRequestPayload;
    try {
      payload = await req.json();
    } catch (_) {
      return new Response(
        JSON.stringify({ error: "Bad Request", message: "Invalid JSON request body" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    let userId: string;
    if (token === serviceRoleKey) {
      userId = (payload.user_id && String(payload.user_id).trim()) || "system_service_role";
    } else {
      const {
        data: { user },
        error: userError,
      } = await supabaseAdmin.auth.getUser(token);

      if (userError || !user) {
        return new Response(
          JSON.stringify({ error: "Unauthorized", message: "Invalid or expired user session" }),
          { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      userId = user.id;
    }

    const action = payload.action ?? (payload.job_id ? "poll" : "submit");

    // =========================================================================
    // ACTION: POLL
    // =========================================================================
    if (action === "poll") {
      const jobId = payload.job_id;
      if (!jobId) {
        return new Response(
          JSON.stringify({ error: "Bad Request", message: "Missing job_id for poll action" }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      // Look up job token from statement_jobs
      const { data: jobRecord, error: jobErr } = await supabaseAdmin
        .from("statement_jobs")
        .select("*")
        .eq("user_id", userId)
        .eq("job_id", jobId)
        .maybeSingle();

      if (jobErr || !jobRecord) {
        return new Response(
          JSON.stringify({ error: "Not Found", message: `Statement job ${jobId} not found` }),
          { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      // If already marked completed or failed in DB, return stored status
      if (jobRecord.status === "completed" || jobRecord.status === "failed") {
        return new Response(
          JSON.stringify({
            status: jobRecord.status,
            job_id: jobId,
            document_type: jobRecord.document_type,
            issuer_or_bank: jobRecord.issuer_or_bank,
            total_transactions: jobRecord.total_transactions,
            error_message: jobRecord.error_message,
          }),
          { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      // Call Modal poll endpoint
      const modalRes = await fetch(`${modalBaseUrl}/v1/extractions/${jobId}`, {
        method: "GET",
        headers: {
          "Modal-Key": modalKey,
          "Modal-Secret": modalSecret,
          "X-Job-Token": jobRecord.job_token,
        },
      });

      if (modalRes.status === 202) {
        return new Response(
          JSON.stringify({ status: "processing", job_id: jobId }),
          { status: 202, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      if (modalRes.status === 200) {
        const modalData = await modalRes.json();
        return await handleCompletedExtraction(
          supabaseAdmin,
          userId,
          jobRecord,
          modalData
        );
      }

      const errText = await modalRes.text();
      console.error(`[process-statement] Modal poll error (${modalRes.status}): ${errText}`);
      return new Response(
        JSON.stringify({ error: "Extraction Error", message: errText }),
        { status: modalRes.status, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // =========================================================================
    // ACTION: SUBMIT
    // =========================================================================
    const storagePath = payload.storage_path;
    if (!storagePath) {
      return new Response(
        JSON.stringify({ error: "Bad Request", message: "Missing storage_path in request payload" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    console.log(`[process-statement] Downloading statement from storage: ${storagePath} for user ${userId}`);
    const { data: fileBlob, error: downloadErr } = await supabaseAdmin.storage
      .from("statements")
      .download(storagePath);

    if (downloadErr || !fileBlob) {
      console.error(`[process-statement] Failed to download storage path ${storagePath}:`, downloadErr);
      return new Response(
        JSON.stringify({
          error: "Storage Download Failed",
          message: `Could not retrieve file at '${storagePath}' from statements bucket: ${downloadErr?.message}`,
        }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const safeFilename = payload.filename || storagePath.split("/").pop() || "statement.pdf";
    const password = payload.password || "";

    // Build multipart/form-data for Modal
    const formData = new FormData();
    formData.append(
      "file",
      new File([fileBlob], safeFilename, { type: "application/pdf" })
    );
    if (password) {
      formData.append("password", password);
    }

    console.log(`[process-statement] Submitting statement to Modal API: ${modalBaseUrl}/v1/extractions`);
    const submitRes = await fetch(`${modalBaseUrl}/v1/extractions`, {
      method: "POST",
      headers: {
        "Modal-Key": modalKey,
        "Modal-Secret": modalSecret,
      },
      body: formData,
    });

    if (submitRes.status !== 202 && submitRes.status !== 200) {
      const errBody = await submitRes.text();
      console.error(`[process-statement] Modal submission failed (${submitRes.status}):`, errBody);
      return new Response(
        JSON.stringify({
          error: "Modal Submission Failed",
          status: submitRes.status,
          message: errBody,
        }),
        { status: submitRes.status, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const submitJson = await submitRes.json();
    const jobId = submitJson.job_id;
    const jobToken = submitJson.job_token;

    console.log(`[process-statement] Modal job spawned successfully: ${jobId}`);

    // Create job record in statement_jobs table
    const { data: insertedJob, error: insertJobErr } = await supabaseAdmin
      .from("statement_jobs")
      .upsert(
        {
          user_id: userId,
          job_id: jobId,
          job_token: jobToken,
          status: "processing",
          filename: safeFilename,
          storage_path: storagePath,
          updated_at: new Date().toISOString(),
        },
        { onConflict: "user_id,job_id" }
      )
      .select()
      .single();

    if (insertJobErr) {
      console.warn(`[process-statement] Warning: Could not record statement_jobs row:`, insertJobErr);
    }

    // If caller explicitly requested async/fire-and-forget, return 202 immediately
    const waitForCompletion = payload.wait_for_completion !== false;
    if (!waitForCompletion) {
      return new Response(
        JSON.stringify({
          status: "processing",
          job_id: jobId,
          message: "Statement submission accepted. Processing in cloud.",
        }),
        { status: 202, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // =========================================================================
    // INLINE POLLING (Up to 55 seconds)
    // =========================================================================
    const pollStart = Date.now();
    const maxPollMs = 55000; // Keep within Edge Function limits
    let lastModalStatus = "processing";

    while (Date.now() - pollStart < maxPollMs) {
      await new Promise((resolve) => setTimeout(resolve, 2500));

      const pollRes = await fetch(`${modalBaseUrl}/v1/extractions/${jobId}`, {
        method: "GET",
        headers: {
          "Modal-Key": modalKey,
          "Modal-Secret": modalSecret,
          "X-Job-Token": jobToken,
        },
      });

      if (pollRes.status === 200) {
        const modalData = await pollRes.json();
        return await handleCompletedExtraction(
          supabaseAdmin,
          userId,
          insertedJob || { user_id: userId, job_id: jobId, job_token: jobToken, storage_path: storagePath },
          modalData,
          payload.message_id
        );
      }

      if (pollRes.status === 202) {
        lastModalStatus = "processing";
        continue;
      }

      const pollErrText = await pollRes.text();
      console.error(`[process-statement] Modal poll error (${pollRes.status}):`, pollErrText);
      await supabaseAdmin
        .from("statement_jobs")
        .update({
          status: "failed",
          error_message: pollErrText,
          updated_at: new Date().toISOString(),
        })
        .eq("user_id", userId)
        .eq("job_id", jobId);

      return new Response(
        JSON.stringify({
          status: "failed",
          job_id: jobId,
          error: "Extraction polling failed",
          message: pollErrText,
        }),
        { status: pollRes.status, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Timed out waiting inline - client or background worker will continue polling
    return new Response(
      JSON.stringify({
        status: "processing",
        job_id: jobId,
        message: "Statement is still processing in cloud OCR engine. Job ID recorded.",
      }),
      { status: 202, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (err) {
    console.error("[process-statement] Unhandled exception:", err);
    return new Response(
      JSON.stringify({ error: "Internal Server Error", message: String(err) }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});

/**
 * Handles completed Modal response, extracts database_payload, and batch upserts
 * into public.bank_transactions or public.credit_card_transactions.
 */
async function handleCompletedExtraction(
  supabaseAdmin: any,
  userId: string,
  jobRecord: any,
  modalData: any,
  messageId?: string
) {
  const jobId = jobRecord.job_id;

  if (modalData.status === "failed") {
    const errCode = modalData.error?.code || "EXTRACTION_FAILED";
    const errMsg = modalData.error?.message || "Extraction failed in processing engine.";
    const isPasswordError = errCode === "PDF_PASSWORD_ERROR" || errMsg.toLowerCase().includes("password");

    const finalStatus = isPasswordError ? "password_required" : "failed";

    await supabaseAdmin
      .from("statement_jobs")
      .update({
        status: finalStatus,
        error_code: errCode,
        error_message: errMsg,
        updated_at: new Date().toISOString(),
      })
      .eq("user_id", userId)
      .eq("job_id", jobId);

    return new Response(
      JSON.stringify({
        status: finalStatus,
        job_id: jobId,
        error_code: errCode,
        message: errMsg,
      }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  const result = modalData.result || {};
  const doc = result.document || {};
  const fields = result.statement_fields || {};
  const dbPayload = result.database_payload || {};

  const docType = doc.type || "bank_statement";
  const bankRows = dbPayload.bank_transactions || [];
  const cardRows = dbPayload.credit_card_transactions || [];

  console.log(
    `[process-statement] Extraction completed for ${jobId}: docType=${docType}, bankRows=${bankRows.length}, cardRows=${cardRows.length}`
  );

  let insertedCount = 0;

  // 1. Process Bank Transactions
  if (bankRows.length > 0) {
    // If statement transactions are descending (newest row at index 0),
    // chronological seq goes from oldest (1) to newest (N).
    const isDescending =
      bankRows.length > 1 &&
      new Date(bankRows[0].transaction_timestamp).getTime() >=
        new Date(bankRows[bankRows.length - 1].transaction_timestamp).getTime();

    const formattedBankRows = bankRows.map((r: any, idx: number) => {
      const calculatedSeq =
        r.seq != null ? r.seq : isDescending ? bankRows.length - idx : idx + 1;
      return {
        ...r,
        seq: calculatedSeq,
        user_id: userId,
        import_batch_id: jobRecord.id || undefined,
        import_batch_at: new Date().toISOString(),
      };
    });

    const chunkSize = 50;
    for (let i = 0; i < formattedBankRows.length; i += chunkSize) {
      const chunk = formattedBankRows.slice(i, i + chunkSize);
      const { error: upsertErr } = await supabaseAdmin
        .from("bank_transactions")
        .upsert(chunk, { onConflict: "user_id,txn_id" });

      if (upsertErr) {
        console.error(`[process-statement] Error upserting bank_transactions:`, upsertErr);
      }
    }
    insertedCount = formattedBankRows.length;
  }

  // 2. Process Credit Card Transactions
  if (cardRows.length > 0) {
    const formattedCardRows = cardRows.map((r: any) => ({
      ...r,
      user_id: userId,
      statement_id: jobId,
      statement_pdf_path: jobRecord.storage_path,
    }));

    const chunkSize = 50;
    for (let i = 0; i < formattedCardRows.length; i += chunkSize) {
      const chunk = formattedCardRows.slice(i, i + chunkSize);
      const { error: upsertErr } = await supabaseAdmin
        .from("credit_card_transactions")
        .upsert(chunk, { onConflict: "user_id,reference_id" });

      if (upsertErr) {
        console.error(`[process-statement] Error upserting credit_card_transactions:`, upsertErr);
      }
    }

    // Mirror credit card transactions to bank_transactions so the habit engine,
    // recurring commitment detector, and AI telemetry seamlessly include them.
    const formattedCardForBankRows = cardRows.map((r: any, idx: number) => ({
      user_id: userId,
      txn_id: `CC_${r.reference_id || `card_${Date.now()}_${idx}`}`,
      type: r.transaction_type || "DEBIT",
      mode: r.payment_mode || "CARD",
      amount: typeof r.amount === "number" ? r.amount : parseFloat(r.amount) || 0,
      transaction_timestamp: r.transaction_date || new Date().toISOString(),
      narration: r.merchant_name || "Credit Card Transaction",
      clean_merchant_name: r.clean_merchant_name || r.merchant_name || "Credit Card Transaction",
      category: r.category || undefined,
      txn_kind: r.transaction_type === "CREDIT" ? "REFUND" : "SPEND",
      tag_source: "card_statement",
      import_batch_id: jobRecord.id || undefined,
      import_batch_at: new Date().toISOString(),
    }));

    for (let i = 0; i < formattedCardForBankRows.length; i += chunkSize) {
      const chunk = formattedCardForBankRows.slice(i, i + chunkSize);
      const { error: bankUpsertErr } = await supabaseAdmin
        .from("bank_transactions")
        .upsert(chunk, { onConflict: "user_id,txn_id" });

      if (bankUpsertErr) {
        console.error(`[process-statement] Error mirroring to bank_transactions:`, bankUpsertErr);
      }
    }

    insertedCount = formattedCardRows.length;
  }

  // 3. If triggered from Gmail Sync with message_id, ensure statement row is updated in email_extracted_transactions
  if (messageId && jobRecord.storage_path) {
    try {
      await supabaseAdmin
        .from("email_extracted_transactions")
        .upsert(
          {
            user_id: userId,
            gmail_message_id: messageId,
            merchant_name: doc.issuer_or_bank || "Bank Statement",
            is_statement: true,
            statement_pdf_path: jobRecord.storage_path,
            statement_period: fields.billing_cycle?.value_raw || null,
            statement_total_due: fields.closing_balance?.amount_decimal || null,
            updated_at: new Date().toISOString(),
          },
          { onConflict: "user_id,gmail_message_id" }
        );
    } catch (e) {
      console.warn(`[process-statement] Note: Could not sync email_extracted_transactions:`, e);
    }
  }

  // 4. Update statement_jobs to completed with full metadata
  const openingBal = fields.opening_balance?.amount_decimal
    ? parseFloat(fields.opening_balance.amount_decimal)
    : null;
  const closingBal = fields.closing_balance?.amount_decimal
    ? parseFloat(fields.closing_balance.amount_decimal)
    : null;
  const dueDate = fields.payment_due_date?.value_iso || null;

  await supabaseAdmin
    .from("statement_jobs")
    .update({
      status: "completed",
      document_type: docType,
      issuer_or_bank: doc.issuer_or_bank,
      page_count: doc.page_count,
      opening_balance: openingBal,
      closing_balance: closingBal,
      billing_cycle: fields.billing_cycle?.value_raw,
      payment_due_date: dueDate,
      total_transactions: insertedCount,
      raw_result: result,
      updated_at: new Date().toISOString(),
    })
    .eq("user_id", userId)
    .eq("job_id", jobId);

  // Trigger post-import pipeline to update habit profile, recurring commitments, and telemetry
  try {
    await supabaseAdmin.rpc("post_import_pipeline", { p_user_id: userId });
    console.log(`[process-statement] post_import_pipeline executed successfully for user ${userId}`);
  } catch (pipeErr) {
    console.warn(`[process-statement] post_import_pipeline error (non-fatal):`, pipeErr);
  }

  return new Response(
    JSON.stringify({
      status: "completed",
      job_id: jobId,
      document_type: docType,
      issuer_or_bank: doc.issuer_or_bank,
      page_count: doc.page_count,
      opening_balance: openingBal,
      closing_balance: closingBal,
      total_transactions: insertedCount,
      raw_result: result,
      message: `Successfully extracted and saved ${insertedCount} transactions to Supabase!`,
    }),
    { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
  );
}


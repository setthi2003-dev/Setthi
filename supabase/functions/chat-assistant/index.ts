import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@^2.45.4";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

interface ToolCall {
  name: string;
  args?: Record<string, unknown>;
}

// Tool declarations for Google Gemini 1.5 Flash
const geminiTools = [
  {
    functionDeclarations: [
      {
        name: "get_current_balance",
        description:
          "Retrieves the user's latest bank account balance in INR and the date it was recorded. Call this whenever the user asks for their balance, how much money they have, or account status.",
        parameters: {
          type: "OBJECT",
          properties: {},
        },
      },
      {
        name: "get_spending_summary",
        description:
          "Calculates total spending (debit flows), transaction count, and top 3 transactions for a given category, merchant, or date range. Call this when asked about how much was spent, category spending (food, groceries, travel, shopping), or merchant spending (Swiggy, Zomato, Uber, etc.).",
        parameters: {
          type: "OBJECT",
          properties: {
            category: {
              type: "STRING",
              description:
                "Optional category name, e.g. 'Food & Dining', 'Groceries', 'Shopping', 'Transport', 'Entertainment', 'Bills & Utilities'",
            },
            merchant: {
              type: "STRING",
              description:
                "Optional merchant name or keyword, e.g. 'Swiggy', 'Zomato', 'Amazon', 'Starbucks', 'Uber'",
            },
            start_date: {
              type: "STRING",
              description: "Optional ISO start date in YYYY-MM-DD format",
            },
            end_date: {
              type: "STRING",
              description: "Optional ISO end date in YYYY-MM-DD format",
            },
          },
        },
      },
      {
        name: "list_recent_transactions",
        description:
          "Lists up to 5 most recent transactions with merchant name, amount, date, and flow type (DEBIT/CREDIT). Call this when the user asks to see recent purchases, latest activity, or transactions.",
        parameters: {
          type: "OBJECT",
          properties: {
            limit: {
              type: "INTEGER",
              description: "Number of transactions to fetch (between 1 and 5, default 5)",
            },
            flow_type: {
              type: "STRING",
              enum: ["DEBIT", "CREDIT"],
              description: "Optional filter: 'DEBIT' for spending/outflows, 'CREDIT' for income/inflows",
            },
          },
        },
      },
      {
        name: "get_safe_to_spend",
        description:
          "Calculates safe-to-spend amounts (daily and total for the remainder of the month) after reserving funds for upcoming recurring bills. Call this when the user asks how much they can safely spend today or this month, or about budget leeway.",
        parameters: {
          type: "OBJECT",
          properties: {},
        },
      },
      {
        name: "detect_recurring_costs",
        description:
          "Identifies active recurring subscriptions, bills, and fixed commitments with merchant names, monthly amounts, and categories. Call this when the user asks about subscriptions, fixed costs, bills, or recurring charges.",
        parameters: {
          type: "OBJECT",
          properties: {},
        },
      },
      {
        name: "get_cashflow_velocity",
        description:
          "Calculates daily cash burn velocity over the last N days (default 7) compared to the previous period, burn delta percentage, and estimated runway in days. Call this when the user asks about burn rate, cash flow velocity, runway, or spending pace.",
        parameters: {
          type: "OBJECT",
          properties: {
            days: {
              type: "INTEGER",
              description: "Number of days for velocity calculation window (default 7)",
            },
          },
        },
      },
    ],
  },
];

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    let geminiApiKey = Deno.env.get("GEMINI_API_KEY") || Deno.env.get("GOOGLE_API_KEY");

    const supabase = createClient(supabaseUrl, serviceRoleKey);

    // If not in Deno.env, fetch from Supabase Vault (vault.decrypted_secrets)
    if (!geminiApiKey) {
      try {
        const { data: vaultKey } = await supabase.rpc("get_vault_secret", {
          p_name: "GEMINI_API_KEY",
        });
        if (vaultKey) {
          geminiApiKey = String(vaultKey).trim();
          console.log("[chat-assistant] Successfully loaded GEMINI_API_KEY from Supabase Vault.");
        }
      } catch (err) {
        console.error("[chat-assistant] Note: Vault retrieval failed:", err);
      }
    }

    // 1. Verify Authentication JWT
    const authHeader = req.headers.get("Authorization") ?? "";
    const token = authHeader.replace(/^Bearer\s+/i, "").trim();
    if (!token) {
      return new Response(
        JSON.stringify({ error: "Unauthorized", message: "Missing Bearer token" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const {
      data: { user },
      error: userError,
    } = await supabase.auth.getUser(token);

    if (userError || !user) {
      return new Response(
        JSON.stringify({ error: "Unauthorized", message: userError?.message ?? "Invalid user token" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // 2. Parse Request Payload
    let body: Record<string, unknown> = {};
    try {
      body = await req.json();
    } catch (_) {
      return new Response(
        JSON.stringify({ error: "Bad Request", message: "Invalid JSON body" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const userPrompt = String(body.prompt ?? body.message ?? "").trim();
    if (!userPrompt) {
      return new Response(
        JSON.stringify({ error: "Bad Request", message: "Prompt cannot be empty" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // 3. User Profile & Credit Check
    const { data: profile } = await supabase
      .from("profiles")
      .select("ai_credits")
      .eq("id", user.id)
      .maybeSingle();

    const currentCredits = profile?.ai_credits ?? 3;
    if (currentCredits <= 0) {
      return new Response(
        JSON.stringify({
          error: "OUT_OF_CREDITS",
          message: "You have 0 AI credits remaining. Credit top-ups coming soon!",
          ai_credits: 0,
        }),
        { status: 402, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // 4. Fallback if GEMINI_API_KEY is not configured
    if (!geminiApiKey) {
      console.error("[chat-assistant] Missing GEMINI_API_KEY in environment");
      return new Response(
        JSON.stringify({
          error: "CONFIGURATION_ERROR",
          message: "Gemini API key is not configured. Please set GEMINI_API_KEY in Supabase Edge Function secrets.",
        }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // 5. Fetch Recent Conversation History (last 6 messages)
    const { data: historyRows } = await supabase
      .from("chat_messages")
      .select("role, content")
      .eq("user_id", user.id)
      .order("created_at", { ascending: false })
      .limit(6);

    const history = (historyRows ?? []).reverse();

    // Persist the user's incoming message immediately
    await supabase.from("chat_messages").insert({
      user_id: user.id,
      role: "user",
      content: userPrompt,
      metadata: {
        source: "flutter_client",
        timestamp: new Date().toISOString(),
      },
    });

    // 6. Instant Memory Snapshot Injection
    let snapshotText = "No prior transactions available.";
    try {
      const [snapRes, safeRes] = await Promise.all([
        supabase
          .from("user_financial_snapshot")
          .select("*")
          .eq("user_id", user.id)
          .maybeSingle(),
        supabase.rpc("get_safe_to_spend", { p_user_id: user.id }),
      ]);

      const snap = snapRes.data;
      const safe = safeRes.data;

      if (snap) {
        const bal = Number(snap.current_balance ?? 0).toLocaleString("en-IN");
        const spent = Number(snap.spent_last_7d ?? 0).toLocaleString("en-IN");
        const inflow = Number(snap.inflow_last_7d ?? 0).toLocaleString("en-IN");
        const topCat = snap.top_category_7d ?? "General";
        const ratio = snap.impulse_ratio_7d ?? 0;
        const safeSpend = safe?.safe_to_spend_daily != null
          ? Number(safe.safe_to_spend_daily).toLocaleString("en-IN")
          : "N/A";
        const periodLabel = snap.is_live_data ? "Past 7 Days" : (snap.statement_period_label ?? "Statement Period");

        snapshotText = `Current Balance: ₹${bal}, Active Window: ${periodLabel} (${snap.is_live_data ? "LIVE" : "HISTORICAL STATEMENT"}), 7-day spend: ₹${spent}, 7-day inflow: ₹${inflow} (Top: ${topCat}), Impulse Ratio: ${ratio}%, Daily Safe Spend: ₹${safeSpend}.`;
      }
    } catch (err) {
      console.warn("[chat-assistant] Failed to fetch financial snapshot:", err);
    }

    // 7. Assemble Gemini Prompt & Instructions
    const nowIso = new Date().toISOString();
    const istTime = new Date().toLocaleString("en-IN", { timeZone: "Asia/Kolkata" });

    const systemInstruction = {
      role: "system",
      parts: [
        {
          text: `You are Setthi AI, a witty, empathetic, candid Gen Z personal finance companion (inspired by Cleo).
You talk like a savvy, candid best friend who helps the user understand their money with light humor, emojis, and real talk.
Always format currency in Indian Rupee format (₹X,XXX).
Current Date & Time in India (IST): ${istTime} (ISO: ${nowIso}).

USER FINANCIAL SNAPSHOT (0ms Instant Memory):
${snapshotText}

CRITICAL RULES:
1. You already know these baseline stats from the user's snapshot above! For casual greetings (e.g., "Hi", "How am I doing?", "How's my balance?"), directly reference these baseline snapshot stats with conversational flair. DO NOT invoke tools for casual greetings or basic balance queries unless the user asks for a specific date range, category breakdown, or updated transaction details.
2. NEVER guess, estimate, or hallucinate financial amounts not in the snapshot or tool outputs.
3. If the user asks how much they can safely spend, call \`get_safe_to_spend\`.
4. If the user asks about recurring costs, subscriptions, or fixed bills, call \`detect_recurring_costs\`.
5. If the user asks about burn rate, cash flow velocity, or runway, call \`get_cashflow_velocity\`.
6. If the user asks for category or merchant spending breakdown, call \`get_spending_summary\`.
7. If the user asks for recent purchases or account activity, call \`list_recent_transactions\`.
8. Keep your final answers punchy, helpful, formatted with clean bullets if listing items, and never more than 2-3 short paragraphs.

GENERATIVE UI PROTOCOL:
When summarizing cash flow, budgets, safe-to-spend, or category breakdowns, output a hidden UI widget tag at the very end of your message in this format:
<!--WIDGET:{"type":"split_card","title":"CASH FLOW","gaugeProgress":0.65,"gaugeLabel":"Retention","keyValues":[{"label":"Inflow","value":"₹12,000"},{"label":"Outflow","value":"₹6,400"}]}-->
Available types:
1. split_card: {"type":"split_card","title":"CASH FLOW","gaugeProgress":0.65,"gaugeLabel":"Retention","keyValues":[{"label":"Inflow","value":"₹12,000"},{"label":"Outflow","value":"₹6,400"}]}
2. segmented_bar: {"type":"segmented_bar","title":"SPEND BREAKDOWN","segments":[{"label":"UPI","value":82,"color":"#97C5B8"},{"label":"Cards","value":18,"color":"#D1BA8E"}]}
3. radial_gauge: {"type":"radial_gauge","title":"FINANCIAL HEALTH","value":85,"max":100,"subtitle":"Healthy"}
Use it only when visual summary aids understanding. Ensure valid JSON inside the tag and place it at the very end of your final response without extra trailing characters.`,
        },
      ],
    };

    // Format chat history for Gemini contents
    const contents: Array<Record<string, unknown>> = [];
    for (const msg of history) {
      contents.push({
        role: msg.role === "assistant" ? "model" : "user",
        parts: [{ text: msg.content }],
      });
    }

    // Add current user prompt
    contents.push({
      role: "user",
      parts: [{ text: userPrompt }],
    });

    // 7. Function Calling Evaluation Loop (up to 3 tool turns)
    const geminiEndpoint = `https://generativelanguage.googleapis.com/v1beta/models/gemini-3.6-flash:generateContent?key=${geminiApiKey}`;

    interface ExecutedToolRecord {
      tool: string;
      args: Record<string, unknown>;
      result: unknown;
      timestamp: string;
    }

    const executedTools: ExecutedToolRecord[] = [];
    const startTimeMs = Date.now();

    let needsAnotherTurn = true;
    let turnCount = 0;
    const maxToolTurns = 3;

    while (needsAnotherTurn && turnCount < maxToolTurns) {
      turnCount++;

      const res = await fetch(geminiEndpoint, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          contents,
          systemInstruction,
          tools: geminiTools,
          toolConfig: {
            functionCallingConfig: {
              mode: "AUTO",
            },
          },
          generationConfig: {
            temperature: 0.7,
            maxOutputTokens: 800,
          },
        }),
      });

      if (!res.ok) {
        const errBody = await res.text();
        console.error(`[chat-assistant] Gemini API error: ${errBody}`);
        throw new Error(`Gemini generation failed (${res.status}): ${errBody}`);
      }

      const resJson = await res.json();
      const candidate = resJson.candidates?.[0];
      const parts = candidate?.content?.parts ?? [];

      // Check if candidate made any function call
      const functionCalls: ToolCall[] = [];
      for (const p of parts) {
        if (p.functionCall) {
          functionCalls.push(p.functionCall);
        }
      }

      if (functionCalls.length === 0) {
        // No function calls made; model generated text or final answer
        needsAnotherTurn = false;
        break;
      }

      // Add the model's functionCall turn to conversation
      contents.push(candidate.content);

      // Execute each tool call against PostgreSQL via Supabase PostgREST
      const functionResponseParts: Array<Record<string, unknown>> = [];

      for (const call of functionCalls) {
        const fnName = call.name;
        const fnArgs = (call.args ?? {}) as Record<string, unknown>;
        console.log(`[chat-assistant] Invoking tool ${fnName} with args:`, fnArgs);

        let toolResult: unknown = {};

        try {
          if (fnName === "get_current_balance") {
            const { data, error } = await supabase.rpc("get_current_balance", {
              p_user_id: user.id,
            });
            toolResult = error ? { error: error.message } : data;
          } else if (fnName === "get_spending_summary") {
            const { data, error } = await supabase.rpc("get_spending_summary", {
              p_category: fnArgs.category ? String(fnArgs.category) : null,
              p_merchant: fnArgs.merchant ? String(fnArgs.merchant) : null,
              p_start_date: fnArgs.start_date ? String(fnArgs.start_date) : null,
              p_end_date: fnArgs.end_date ? String(fnArgs.end_date) : null,
              p_user_id: user.id,
            });
            toolResult = error ? { error: error.message } : data;
          } else if (fnName === "list_recent_transactions") {
            const { data, error } = await supabase.rpc("list_recent_transactions", {
              p_limit: fnArgs.limit ? Number(fnArgs.limit) : 5,
              p_flow_type: fnArgs.flow_type ? String(fnArgs.flow_type) : null,
              p_user_id: user.id,
            });
            toolResult = error ? { error: error.message } : data;
          } else if (fnName === "get_safe_to_spend") {
            const { data, error } = await supabase.rpc("get_safe_to_spend", {
              p_user_id: user.id,
            });
            toolResult = error ? { error: error.message } : data;
          } else if (fnName === "detect_recurring_costs") {
            const { data, error } = await supabase.rpc("detect_recurring_costs", {
              p_user_id: user.id,
            });
            toolResult = error ? { error: error.message } : data;
          } else if (fnName === "get_cashflow_velocity") {
            const { data, error } = await supabase.rpc("get_cashflow_velocity", {
              p_user_id: user.id,
              p_days: fnArgs.days ? Number(fnArgs.days) : 7,
            });
            toolResult = error ? { error: error.message } : data;
          } else {
            toolResult = { error: `Unknown tool name: ${fnName}` };
          }
        } catch (rpcErr) {
          console.error(`[chat-assistant] RPC execution failed for ${fnName}:`, rpcErr);
          toolResult = { error: String(rpcErr) };
        }

        console.log(`[chat-assistant] Tool ${fnName} result:`, toolResult);

        executedTools.push({
          tool: fnName,
          args: fnArgs,
          result: toolResult,
          timestamp: new Date().toISOString(),
        });

        functionResponseParts.push({
          functionResponse: {
            name: fnName,
            response: {
              result: toolResult,
            },
          },
        });
      }

      // Add tool responses back to conversation contents
      contents.push({
        role: "user",
        parts: functionResponseParts,
      });
    }

    // 8. Stream Final Response with Server-Sent Events (SSE)
    const streamEndpoint = `https://generativelanguage.googleapis.com/v1beta/models/gemini-3.6-flash:streamGenerateContent?alt=sse&key=${geminiApiKey}`;

    const geminiStreamRes = await fetch(streamEndpoint, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        contents,
        systemInstruction,
        generationConfig: {
          temperature: 0.7,
          maxOutputTokens: 800,
        },
      }),
    });

    if (!geminiStreamRes.ok) {
      const errText = await geminiStreamRes.text();
      console.error(`[chat-assistant] Gemini stream error: ${errText}`);
      throw new Error(`Failed to initiate Gemini text stream: ${errText}`);
    }

    // Transform stream into SSE lines for the Flutter client
    let accumulatedText = "";
    const reader = geminiStreamRes.body?.getReader();
    const decoder = new TextDecoder();
    const encoder = new TextEncoder();

    const customStream = new ReadableStream({
      async start(controller) {
        if (!reader) {
          controller.close();
          return;
        }

        let buffer = "";

        try {
          while (true) {
            const { done, value } = await reader.read();
            if (done) break;

            buffer += decoder.decode(value, { stream: true });
            const lines = buffer.split("\n");
            buffer = lines.pop() ?? "";

            for (const line of lines) {
              const trimmed = line.trim();
              if (trimmed.startsWith("data: ")) {
                const jsonStr = trimmed.substring(6).trim();
                if (jsonStr === "[DONE]") continue;

                try {
                  const parsed = JSON.parse(jsonStr);
                  const candidate = parsed.candidates?.[0];
                  const textChunk = candidate?.content?.parts?.[0]?.text;

                  if (textChunk) {
                    accumulatedText += textChunk;
                    controller.enqueue(
                      encoder.encode(
                        `data: ${JSON.stringify({ text: textChunk, done: false })}\n\n`
                      )
                    );
                  }
                } catch (_) {
                  // Non-JSON line or keep-alive
                }
              }
            }
          }

          // Stream completed: Deduct 1 credit atomically
          let remainingCredits = currentCredits - 1;
          try {
            const { data: deducted } = await supabase.rpc("deduct_ai_credit", {
              p_user_id: user.id,
            });

            if (deducted) {
              const { data: updatedProfile } = await supabase
                .from("profiles")
                .select("ai_credits")
                .eq("id", user.id)
                .maybeSingle();

              if (updatedProfile?.ai_credits !== undefined) {
                remainingCredits = updatedProfile.ai_credits;
              }
            }
          } catch (deductErr) {
            console.error("[chat-assistant] Failed to deduct credit:", deductErr);
          }

          // Persist the completed assistant message to chat_messages
          if (accumulatedText.trim().length > 0) {
            const assistantMetadata = {
              model: "gemini-3.6-flash",
              latency_ms: Date.now() - startTimeMs,
              turn_count: turnCount,
              tools_called: executedTools.map((t) => t.tool),
              tools_executed: executedTools,
              remaining_credits: remainingCredits,
            };

            await supabase.from("chat_messages").insert({
              user_id: user.id,
              role: "assistant",
              content: accumulatedText.trim(),
              metadata: assistantMetadata,
            });
          }

          // Emit the final SSE event with updated credit balance
          controller.enqueue(
            encoder.encode(
              `data: ${JSON.stringify({
                done: true,
                remaining_credits: remainingCredits,
              })}\n\n`
            )
          );

          controller.close();
        } catch (streamErr) {
          console.error("[chat-assistant] Error inside streaming controller:", streamErr);
          controller.enqueue(
            encoder.encode(
              `data: ${JSON.stringify({
                error: String(streamErr),
                done: true,
              })}\n\n`
            )
          );
          controller.close();
        }
      },
    });

    return new Response(customStream, {
      status: 200,
      headers: {
        ...corsHeaders,
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
        Connection: "keep-alive",
      },
    });
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`[chat-assistant] Fatal exception: ${msg}`);
    return new Response(
      JSON.stringify({ error: "INTERNAL_ERROR", message: msg }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});

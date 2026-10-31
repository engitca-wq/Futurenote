// FUTURENOTE assistant: a Supabase Edge Function that keeps the model
// provider's key on the server. It talks to any open-source model host that
// speaks the chat-completions protocol (OpenRouter, Groq, Ollama, vLLM...).
// The app sends { task, notes, question } and gets { text }.
//
// Deploy:
//   supabase secrets set AI_BASE_URL=https://openrouter.ai/api/v1 \
//     AI_MODEL=qwen/qwen-2.5-72b-instruct AI_API_KEY=...
//   supabase functions deploy ai --no-verify-jwt
// Then paste the function URL into the app's assistant settings.

const BASE_URL = (Deno.env.get("AI_BASE_URL") ?? "").replace(/\/+$/, "");
const MODEL = Deno.env.get("AI_MODEL") ?? "";
const API_KEY = Deno.env.get("AI_API_KEY") ?? "";
const MAX_NOTES_CHARS = 200_000;

// Keep in sync with lib/ai.dart.
const SYSTEM =
  "You are the assistant inside FUTURENOTE, a handwriting and voice notes app " +
  "used mostly by Arabic speakers, many in Egypt. The notes come from " +
  "handwriting recognition and speech-to-text, so expect misread letters, " +
  "missing dots and dialect; read through those errors to the intended " +
  "meaning. Base everything only on the notes; never invent names, numbers, " +
  "dates or decisions. Write plain text with simple \"- \" bullets, no " +
  "Markdown headings or bold. Keep lines short so they fit on a notebook " +
  "page.";

function instruction(task: string, question?: string): string | null {
  switch (task) {
    case "summary":
      return "Summarize these notes in the language they are mostly written in. Start " +
        "with one sentence on what they are about, then up to 7 short bullets " +
        "with the key points.";
    case "minutes":
      return "Turn these notes into meeting minutes in the language they are mostly " +
        "written in, with three parts: the topic, the decisions taken, and the " +
        "action items. Write each action item as \"- task - owner - due date\", " +
        "leaving owner or date out when the notes do not say them.";
    case "translateEn":
      return "Translate these notes into clear English. Keep the line structure. " +
        "Output only the translation.";
    case "translateAr":
      return "Translate these notes into clear Modern Standard Arabic. Keep the line " +
        "structure. Output only the translation.";
    case "ask":
      return "Answer this question using only the notes, in the language of the " +
        "question. If the notes do not contain the answer, say so in one " +
        `sentence.\n\nQuestion: ${question ?? ""}`;
    default:
      return null;
  }
}

function reply(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return reply(405, { error: "POST only" });
  let input: { task?: string; notes?: string; question?: string };
  try {
    input = await req.json();
  } catch {
    return reply(400, { error: "طلب غير صالح" });
  }
  const notes = (input.notes ?? "").trim();
  const ask = instruction(input.task ?? "", input.question);
  if (!ask || !notes) return reply(400, { error: "طلب غير صالح" });
  if (notes.length > MAX_NOTES_CHARS) {
    return reply(413, { error: "الملاحظات طويلة جدًا. جرّب صفحة واحدة." });
  }

  try {
    const res = await fetch(`${BASE_URL}/chat/completions`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        ...(API_KEY ? { authorization: `Bearer ${API_KEY}` } : {}),
      },
      body: JSON.stringify({
        model: MODEL,
        temperature: 0.3,
        messages: [
          { role: "system", content: SYSTEM },
          { role: "user", content: `<notes>\n${notes}\n</notes>\n\n${ask}` },
        ],
      }),
    });
    if (res.status === 429) {
      return reply(429, { error: "طلبات كتير ورا بعض. استنى دقيقة." });
    }
    if (!res.ok) {
      console.error(`Model host error ${res.status}: ${await res.text()}`);
      return reply(502, { error: "الخدمة مشغولة دلوقتي. جرّب كمان شوية." });
    }
    const data = await res.json();
    const text = String(data?.choices?.[0]?.message?.content ?? "")
      .replace(/<think>[\s\S]*?<\/think>/g, "")
      .trim();
    if (!text) return reply(200, { error: "ما رجعش رد. جرّب تاني." });
    return reply(200, { text });
  } catch (error) {
    console.error(error);
    return reply(500, { error: "حصلت مشكلة في السيرفر." });
  }
});

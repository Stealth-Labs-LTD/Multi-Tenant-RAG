import type { ChatRequest, ChatbotConfig, StreamedChatResponse } from "./models";

function getHeaders(): Record<string, string> {
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
  };

  const subscriptionKey = import.meta.env.VITE_APIM_SUBSCRIPTION_KEY;
  if (subscriptionKey) {
    headers["Ocp-Apim-Subscription-Key"] = subscriptionKey;
  }

  return headers;
}

export async function* chatStream(
  request: ChatRequest
): AsyncGenerator<StreamedChatResponse> {
  const response = await fetch("/chat", {
    method: "POST",
    headers: getHeaders(),
    body: JSON.stringify(request),
  });

  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(`Chat request failed: ${response.status} ${errorText}`);
  }

  if (!response.body) {
    throw new Error("Response body is empty");
  }

  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;

    buffer += decoder.decode(value, { stream: true });
    const lines = buffer.split("\n");
    buffer = lines.pop() ?? "";

    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed) continue;

      try {
        const parsed: StreamedChatResponse = JSON.parse(trimmed);
        yield parsed;
      } catch {
        // Skip malformed lines
      }
    }
  }

  if (buffer.trim()) {
    try {
      const parsed: StreamedChatResponse = JSON.parse(buffer.trim());
      yield parsed;
    } catch {
      // Skip malformed trailing data
    }
  }
}

export async function getConfig(appId: string): Promise<ChatbotConfig> {
  const response = await fetch(`/config/${encodeURIComponent(appId)}`, {
    headers: getHeaders(),
  });

  if (!response.ok) {
    throw new Error(`Config request failed: ${response.status}`);
  }

  return response.json();
}

export interface ChatMessage {
  role: "user" | "assistant" | "system";
  content: string;
}

export interface ChatRequest {
  messages: ChatMessage[];
  context: {
    app_id: string;
  };
}

export interface StreamedChatResponse {
  delta: {
    content: string;
    role: string;
  };
  citations?: Citation[];
}

export interface Citation {
  index: number;
  title: string;
  source_file: string;
  content: string;
}

export interface ChatbotConfig {
  chatbotId: string;
  chatbotName: string;
  welcomeMessage: string;
  primaryColor: string;
  logoUrl?: string;
}

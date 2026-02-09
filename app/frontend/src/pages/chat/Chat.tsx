import { useCallback, useEffect, useRef, useState } from "react";
import { chatStream, getConfig } from "../../api/api";
import type {
  ChatMessage,
  ChatbotConfig,
  Citation,
} from "../../api/models";
import { Answer } from "../../components/Answer";
import { ChatInput } from "../../components/ChatInput";
import { CitationPanel } from "../../components/CitationPanel";
import { appId, defaultBranding } from "../../config";

export function Chat() {
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [isLoading, setIsLoading] = useState(false);
  const [citations, setCitations] = useState<Citation[]>([]);
  const [selectedCitation, setSelectedCitation] = useState<number | undefined>();
  const [config, setConfig] = useState<ChatbotConfig | null>(null);
  const messagesEndRef = useRef<HTMLDivElement>(null);

  const brandName = config?.chatbotName ?? defaultBranding.chatbotName;
  const primaryColor = config?.primaryColor ?? defaultBranding.primaryColor;
  const welcomeMessage =
    config?.welcomeMessage ?? defaultBranding.welcomeMessage;

  useEffect(() => {
    getConfig(appId)
      .then(setConfig)
      .catch(() => {
        // Use default branding on error
      });
  }, []);

  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages]);

  const handleSend = useCallback(
    async (content: string) => {
      const userMessage: ChatMessage = { role: "user", content };
      const updatedMessages = [...messages, userMessage];
      setMessages(updatedMessages);
      setIsLoading(true);
      setCitations([]);
      setSelectedCitation(undefined);

      const assistantMessage: ChatMessage = { role: "assistant", content: "" };
      setMessages([...updatedMessages, assistantMessage]);

      try {
        const stream = chatStream({
          messages: updatedMessages,
          context: { app_id: appId },
        });

        let accumulated = "";

        for await (const chunk of stream) {
          if (chunk.delta.content) {
            accumulated += chunk.delta.content;
            setMessages([
              ...updatedMessages,
              { role: "assistant", content: accumulated },
            ]);
          }

          if (chunk.citations) {
            setCitations(chunk.citations);
          }
        }
      } catch (error) {
        const errorContent =
          error instanceof Error ? error.message : "An error occurred";
        setMessages([
          ...updatedMessages,
          {
            role: "assistant",
            content: `Sorry, an error occurred: ${errorContent}`,
          },
        ]);
      } finally {
        setIsLoading(false);
      }
    },
    [messages]
  );

  return (
    <div style={styles.container}>
      <header style={{ ...styles.header, backgroundColor: primaryColor }}>
        <div style={styles.headerContent}>
          {config?.logoUrl && (
            <img
              src={config.logoUrl}
              alt={brandName}
              style={styles.logo}
            />
          )}
          <h1 style={styles.title}>{brandName}</h1>
        </div>
      </header>

      <div style={styles.main}>
        <div style={styles.chatArea}>
          <div style={styles.messageList}>
            {messages.length === 0 && (
              <div style={styles.welcome}>
                <p style={styles.welcomeText}>{welcomeMessage}</p>
              </div>
            )}

            {messages.map((msg, i) => (
              <div
                key={i}
                style={{
                  ...styles.messageRow,
                  justifyContent:
                    msg.role === "user" ? "flex-end" : "flex-start",
                }}
              >
                <div
                  style={{
                    ...styles.messageBubble,
                    ...(msg.role === "user"
                      ? {
                          backgroundColor: primaryColor,
                          color: "#fff",
                          borderBottomRightRadius: 4,
                        }
                      : {
                          backgroundColor: "#f0f0f0",
                          color: "#1a1a1a",
                          borderBottomLeftRadius: 4,
                        }),
                  }}
                >
                  {msg.role === "assistant" ? (
                    <Answer
                      content={msg.content}
                      citations={citations}
                      onCitationClick={setSelectedCitation}
                    />
                  ) : (
                    <span>{msg.content}</span>
                  )}
                </div>
              </div>
            ))}

            {isLoading && messages[messages.length - 1]?.content === "" && (
              <div style={styles.loadingDots}>Thinking...</div>
            )}

            <div ref={messagesEndRef} />
          </div>

          <ChatInput onSend={handleSend} disabled={isLoading} />
        </div>

        {citations.length > 0 && (
          <CitationPanel
            citations={citations}
            selectedIndex={selectedCitation}
          />
        )}
      </div>
    </div>
  );
}

const styles: Record<string, React.CSSProperties> = {
  container: {
    display: "flex",
    flexDirection: "column",
    height: "100%",
  },
  header: {
    padding: "12px 24px",
    color: "#fff",
    flexShrink: 0,
  },
  headerContent: {
    display: "flex",
    alignItems: "center",
    gap: 12,
    maxWidth: 1200,
    margin: "0 auto",
  },
  logo: {
    height: 32,
    width: 32,
    objectFit: "contain" as const,
  },
  title: {
    margin: 0,
    fontSize: 18,
    fontWeight: 600,
  },
  main: {
    display: "flex",
    flex: 1,
    overflow: "hidden",
  },
  chatArea: {
    display: "flex",
    flexDirection: "column",
    flex: 1,
    minWidth: 0,
  },
  messageList: {
    flex: 1,
    overflowY: "auto" as const,
    padding: "24px",
    display: "flex",
    flexDirection: "column",
    gap: 16,
  },
  welcome: {
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    flex: 1,
  },
  welcomeText: {
    fontSize: 16,
    color: "#666",
    textAlign: "center" as const,
  },
  messageRow: {
    display: "flex",
  },
  messageBubble: {
    maxWidth: "70%",
    padding: "10px 16px",
    borderRadius: 16,
    lineHeight: 1.5,
    fontSize: 14,
    wordBreak: "break-word" as const,
  },
  loadingDots: {
    padding: "10px 16px",
    color: "#888",
    fontSize: 14,
    fontStyle: "italic",
  },
};
